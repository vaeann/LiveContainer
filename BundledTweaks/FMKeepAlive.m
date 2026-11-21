// FMKeepAlive.m — 后台保活（独立模块版）：切后台时每个进程播一路静音音频，保持不被系统挂起
//
// 引擎取自微珠 LCOrbit 的 FMKeepAlive（其机制来源：LiveContainer-zh 的
// CZFHostKeepAlive（宿主侧）+ CZFKeepAlive（游客侧）），状态机与起停逻辑
// 原样保留。与 LCOrbit 的三处耦合已换成独立实现：
//   · 设置存储：不再走 LCOrbitStorage，直接读 App Group 里同一位置的
//     同一文件 <AppGroup>/LCOrbit/config.json（格式与微珠一致），
//     LC 的「后台保活」设置页负责写；
//   · 宿主判定：LCOrbitHost.isHostUI 换成本文件内的运行时判定（调 LC
//     自己的 NSUserDefaults 类别方法，与 LCOrbitHost 同一套问法）；
//   · 日志：LCOrbitLog 不带过来，FMKLog 直接丢弃事件。
// 微珠自带的 UIKit 设置子页不在本文件内：设置入口在 LC 设置页，
// 写的就是同一批键（LCFloatingMenu.keepAliveEnabled / keepAliveMinutes /
// keepAliveWatchdog）。
//
// 两层保活（进程独立、互不感知）：
//   宿主进程（LC 界面）   条件 = 开关开 && 已切后台 && 有游客在跑 → 播
//                        作用：宿主不被回收，LiveProcess 扩展才不被连带回收
//   游客进程（每个 Guest）条件 = 开关开 && 已切后台 → 播
//
// 起停：WillResignActive 提前起播（堵「先被掐、后才开播」的空档），
//       DidEnterBackground 确认；回前台三路信号任一即停。
//       扩展进程补 NSExtensionHost* 通知（UIApplication 的后台通知在扩展里不一定送达）。
//
// 看门狗（可关）：自适应 0-5min 30s / 5-10min 45s / >10min 60s。只做两件事：
//       判超时、查音频是否还在播（不在播就重建播放器重拉）。
//       局限：进程被挂起后 timer 不执行，只能救「音频断了但进程还活着」的窗口，
//       所以真正的第一道防线是提前起播和音频中断通知，看门狗只是兜底。
//
// 超时：后台满 10/20/30 分钟停播并标记，回前台复位。
//
// 接入点：dylib 构造函数里装配，不 swizzle 任何上游方法。

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import <dlfcn.h>
#import <signal.h>
#import <errno.h>

static NSString *const kModuleName = @"LCFloatingMenu";

// 偏好键（与主文件设置页共用同一 LCOrbitStorage 空间）。
static NSString *const kKeyEnabled = @"keepAliveEnabled";     // 默认 YES
static NSString *const kKeyMinutes = @"keepAliveMinutes";     // 10 / 20 / 30，默认 20
static NSString *const kKeyWatchdog = @"keepAliveWatchdog";   // 1 自适应 / 0 关闭，默认 1

// ---- 引擎状态 ---------------------------------------------------------------

static AVAudioPlayer *gPlayer = nil;
static NSTimer *gWatchdog = nil;
static NSTimer *gTimeoutTimer = nil;   // 超时计时：独立于看门狗，关闭看门狗也生效
static BOOL gInBackground = NO;
static NSTimeInterval gBackgroundStart = 0;
static BOOL gTimedOut = NO;          // 本次后台已满时长，回前台才复位
static BOOL gInstalled = NO;
static BOOL gIsHost = NO;            // YES = 纯 LC 界面进程；NO = 游客进程
static UIBackgroundTaskIdentifier gBGTask;   // 宿主第二通道（UIBackgroundTaskInvalid 不是编译期常量，用标志位区分）
static BOOL gBGTaskActive = NO;

// 保活计时（面板展示用）：
//   gPlayStart      本次保活真正起播的时刻，0 = 当前没在播
//   gLastPlayEnd    上一次保活结束的时刻（回前台/到时长/关开关都会记）
//   gLastPlaySeconds上一次保活持续了多久
// 面板刷新读的是各进程写进 JSON 的副本，所以切回前台后「上次」仍然看得到。
static NSTimeInterval gPlayStart = 0;
static NSTimeInterval gLastPlayEnd = 0;
static NSTimeInterval gLastPlaySeconds = 0;
static NSString *gLastPlayReason = nil;

static void FMKRefresh(void);   // 前置声明：播放决策在多处被调用，定义在下方

// ---- LC 运行时接口（代 LCOrbitHost / LCOrbitStorage 的最小子集） -----------
//
// LCBootstrap 给 NSUserDefaults 挂了一组类别方法（lcUserDefaults /
// lcAppGroupPath / guestAppInfo / lcMainBundle / isSideStore /
// isLiveProcess），宿主与游客进程里都能问到。LCOrbitHost 本来就是这样
// 转发的，这里照抄同一套问法，不链接 LC 的任何符号。

static id FMKCallHostSelector(NSString *name) {
    SEL sel = NSSelectorFromString(name);
    if(![NSUserDefaults respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(NSUserDefaults.class, sel);
}

static NSUserDefaults *FMKHostDefaults(void) {
    id defaults = FMKCallHostSelector(@"lcUserDefaults");
    return [defaults isKindOfClass:NSUserDefaults.class] ? defaults
                                                         : NSUserDefaults.standardUserDefaults;
}

static NSString *FMKAppGroupPath(void) {
    id path = FMKCallHostSelector(@"lcAppGroupPath");
    return [path isKindOfClass:NSString.class] ? path : nil;
}

// App Group 下的 LCOrbit 目录：config.json 与 state/ 都放这里，
// 与微珠同位置（LCOrbitStorage.appGroupRootPath 的返回值）。
static NSString *FMKAppGroupRoot(void) {
    NSString *path = FMKAppGroupPath();
    if(!path.length) return nil;
    return [path stringByAppendingPathComponent:@"LCOrbit"];
}

// 与 LCOrbitHost.isHostUI 完全相同的判定：只有 LC 本体界面进程算宿主。
static BOOL FMKIsHostUI(void) {
    if(FMKCallHostSelector(@"guestAppInfo")) return NO;
    if(![FMKHostDefaults() boolForKey:@"LCLoadTweaksToSelf"]) return NO;
    NSBundle *hostBundle = (NSBundle *)FMKCallHostSelector(@"lcMainBundle");
    if(![hostBundle isKindOfClass:NSBundle.class] ||
       ![hostBundle.bundlePath isEqualToString:NSBundle.mainBundle.bundlePath]) return NO;
    SEL side = NSSelectorFromString(@"isSideStore");
    SEL process = NSSelectorFromString(@"isLiveProcess");
    if(![NSUserDefaults respondsToSelector:side] ||
       ![NSUserDefaults respondsToSelector:process]) return NO;
    return !((BOOL (*)(id, SEL))objc_msgSend)(NSUserDefaults.class, side) &&
           !((BOOL (*)(id, SEL))objc_msgSend)(NSUserDefaults.class, process);
}

static void FMKLog(NSString *event, id details) {
    (void)event; (void)details;   // 独立版不带 LCOrbit 日志系统，事件直接丢弃
}

// 设置读取：每次都现读 config.json（宿主改设置后各进程下次决策即生效），
// 读失败（文件还没有 / 损坏）时用上一次读到的值兜底；再没有就返回 nil，
// 调用方按默认值处理（开 / 20 分钟 / 看门狗自适应）。
static NSDictionary *FMKPreferences(void) {
    static NSDictionary *lastGood = nil;
    NSString *root = FMKAppGroupRoot();
    if(!root.length) return lastGood;
    NSData *data = [NSData dataWithContentsOfFile:
        [root stringByAppendingPathComponent:@"config.json"]];
    id doc = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if(![doc isKindOfClass:NSDictionary.class]) return lastGood;
    id prefs = doc[@"preferences"];
    if(![prefs isKindOfClass:NSDictionary.class]) return lastGood;
    lastGood = prefs;
    return lastGood;
}

static id FMKPref(NSString *key) {
    return FMKPreferences()[[kModuleName stringByAppendingFormat:@".%@", key]];
}

static BOOL FMKEnabled(void) {
    id value = FMKPref(kKeyEnabled);
    return value ? [value boolValue] : YES;
}

static NSInteger FMKMinutes(void) {
    id value = FMKPref(kKeyMinutes);
    NSInteger minutes = value ? [value integerValue] : 20;
    if(minutes != 10 && minutes != 20 && minutes != 30) minutes = 20;
    return minutes;
}

// 1 = 自适应，0 = 关闭
static NSInteger FMKWatchdogMode(void) {
    id value = FMKPref(kKeyWatchdog);
    return value ? ([value integerValue] == 0 ? 0 : 1) : 1;
}

static NSTimeInterval FMKNow(void) {
    return NSDate.date.timeIntervalSince1970;
}

// ---- 静音音频 ---------------------------------------------------------------

// 1 秒静音 WAV（8000Hz 单声道 16bit PCM），内存合成一次后缓存，不落盘。
static NSData *FMKSilentWAVData(void) {
    static NSData *cached = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const uint32_t sampleRate = 8000;
        const uint16_t channels = 1;
        const uint16_t bitsPerSample = 16;
        const uint32_t dataSize = sampleRate * channels * (bitsPerSample / 8);
        const uint32_t chunkSize = 36 + dataSize;
        const uint16_t blockAlign = channels * (bitsPerSample / 8);
        const uint32_t byteRate = sampleRate * blockAlign;

        NSMutableData *data = [NSMutableData dataWithCapacity:44 + dataSize];
        [data appendBytes:"RIFF" length:4];
        [data appendBytes:&chunkSize length:4];
        [data appendBytes:"WAVE" length:4];
        [data appendBytes:"fmt " length:4];
        uint32_t subChunk1Size = 16;
        uint16_t audioFormat = 1;
        [data appendBytes:&subChunk1Size length:4];
        [data appendBytes:&audioFormat length:2];
        [data appendBytes:&channels length:2];
        [data appendBytes:&sampleRate length:4];
        [data appendBytes:&byteRate length:4];
        [data appendBytes:&blockAlign length:2];
        [data appendBytes:&bitsPerSample length:2];
        [data appendBytes:"data" length:4];
        [data appendBytes:&dataSize length:4];
        [data increaseLengthBy:dataSize];   // 补零 = 静音采样
        cached = [data copy];
    });
    return cached;
}

// ---- 宿主：是否有游客在跑 ---------------------------------------------------

// ---- 跨进程保活状态 --------------------------------------------------
//
// 每个进程写一份 keepalive-<bundle>.json（宿主是 keepalive-host.json）。
//
// 位置放在 App Group 的 LCOrbit/state/ 下，和 config.json 同处一个目录：
//   · 主客拿到的是同一个物理路径（经 +[NSUserDefaults lcAppGroupPath]）；
//   · 用户在 Filza 里看得见、能手动清；
//   · 不在 Tweaks 里，LC 的插件页不会把它当成插件条目列出来。
//
// 看门狗每次巡检更新 beat —— 心跳在跳 = 进程真的在被系统调度（没被挂起）。

static void FMKWriteState(void);   // 前置声明：dladdr 取本 dylib 路径也用它

static NSString *FMKPluginDirectory(void) {
    static NSString *cached = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Dl_info info;
        if(dladdr((void *)&FMKWriteState, &info) == 0 || !info.dli_fname) return;
        cached = [@(info.dli_fname) stringByDeletingLastPathComponent];
    });
    return cached;
}

// 状态目录放 App Group 下的 state/：主客拿到的是同一个物理路径，
// 不依赖 rootPath 的猜路径逻辑。App Group 不可用时退回 dylib 同目录。
static NSString *FMKStateDirectory(void) {
    static NSString *cached = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *root = FMKAppGroupRoot();
        if(!root.length) {
            cached = FMKPluginDirectory();
            FMKLog(@"keep-alive-state-dir", @{@"root": @"(no-app-group)",
                                              @"dir": cached ?: @"", @"host": @(gIsHost)});
            return;
        }
        NSString *dir = [root stringByAppendingPathComponent:@"state"];
        BOOL ok = [NSFileManager.defaultManager createDirectoryAtPath:dir
                                          withIntermediateDirectories:YES
                                                           attributes:nil error:nil];
        cached = ok ? dir : FMKPluginDirectory();
        // 定位问题的唯一线索：游客到底把状态写到哪个目录了。
        FMKLog(@"keep-alive-state-dir", @{@"root": root, @"dir": cached ?: @"",
                                          @"created": @(ok), @"host": @(gIsHost)});
    });
    return cached;
}

// 固定文件名：宿主一份、每个游客按 bundle 一份。进程重启覆盖同一个文件，
// 文件数天然封顶（1 + 用过几个 App），不依赖清理逻辑是否可靠。
// 代价是同一个 App 多开时后写的那份覆盖前一份，面板会少一行——保活本身不受影响。
static NSUInteger const kFMKStateLimit = 32;   // 兜底上限，正常永远碰不到
static NSString *FMKStateFileName(void) {
    if(gIsHost) return @"keepalive-host.json";
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"";
    if(!bundle.length) return [NSString stringWithFormat:@"keepalive-pid%d.json", getpid()];
    NSString *safe = [[bundle stringByReplacingOccurrencesOfString:@"/" withString:@"_"]
                              stringByReplacingOccurrencesOfString:@":" withString:@"_"];
    return [NSString stringWithFormat:@"keepalive-%@.json", safe];
}

// 进程启动时清一次：pid 已不存在、超过 24 小时、或总数超过 32 份时删最旧的。
// 面板打开时另外还会清一次死进程。
static void FMKPurgeStaleStates(void) {
    NSString *dir = FMKStateDirectory();
    if(!dir.length) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSTimeInterval now = FMKNow();
    NSString *own = FMKStateFileName();
    NSMutableArray<NSString *> *alive = [NSMutableArray array];
    for(NSString *name in [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[]) {
        if(![name hasPrefix:@"keepalive-"] || ![name hasSuffix:@".json"]) continue;
        if([name isEqualToString:own]) continue;   // 自己的那份不动
        NSString *path = [dir stringByAppendingPathComponent:name];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        NSTimeInterval modified = [attrs[NSFileModificationDate] timeIntervalSince1970];
        // 文件名不再带 pid，只能从内容里取。读不出来就当成可回收。
        NSData *data = [NSData dataWithContentsOfFile:path];
        id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSInteger pid = [obj isKindOfClass:NSDictionary.class] ? [obj[@"pid"] integerValue] : 0;
        BOOL dead = pid > 0 && pid != (NSInteger)getpid() &&
                    kill((pid_t)pid, 0) != 0 && errno == ESRCH;
        BOOL stale = modified > 0 && now - modified > 24 * 3600;
        if(dead || stale) { [fm removeItemAtPath:path error:nil]; continue; }
        [alive addObject:path];
    }
    if(alive.count > kFMKStateLimit) {
        NSArray<NSString *> *sorted = [alive sortedArrayUsingComparator:
            ^NSComparisonResult(NSString *a, NSString *b) {
                NSTimeInterval ta = [[fm attributesOfItemAtPath:a error:nil][NSFileModificationDate]
                                     timeIntervalSince1970];
                NSTimeInterval tb = [[fm attributesOfItemAtPath:b error:nil][NSFileModificationDate]
                                     timeIntervalSince1970];
                if(ta == tb) return NSOrderedSame;
                return ta < tb ? NSOrderedAscending : NSOrderedDescending;
            }];
        for(NSUInteger i = 0; i + kFMKStateLimit < sorted.count; i++)
            [fm removeItemAtPath:sorted[i] error:nil];
    }
    // 旧位置遗留：v26 及更早直接写在插件目录里，中间版本写在 .lcfm/ 里，
    // 都清掉，否则插件页里那几个 json 会一直留着。
    NSString *pluginDir = FMKPluginDirectory();
    NSMutableArray<NSString *> *legacyDirs = [NSMutableArray array];
    if(pluginDir.length && ![pluginDir isEqualToString:dir]) [legacyDirs addObject:pluginDir];
    NSString *hidden = [pluginDir stringByAppendingPathComponent:@".lcfm"];
    if(hidden.length && ![hidden isEqualToString:dir]) [legacyDirs addObject:hidden];
    for(NSString *legacy in legacyDirs) {
        for(NSString *name in [fm contentsOfDirectoryAtPath:legacy error:nil] ?: @[]) {
            if(![name hasPrefix:@"keepalive-"] || ![name hasSuffix:@".json"]) continue;
            [fm removeItemAtPath:[legacy stringByAppendingPathComponent:name] error:nil];
        }
    }
}

static void FMKWriteState(void) {
    NSString *dir = FMKStateDirectory();
    if(!dir.length) return;
    NSDictionary *state = @{
        @"v": @1,
        @"pid": @(getpid()),
        @"role": gIsHost ? @"host" : @"guest",
        @"bundle": NSBundle.mainBundle.bundleIdentifier ?: @"",
        @"playing": @(gPlayer.isPlaying ? YES : NO),
        @"background": @(gInBackground),
        @"timedOut": @(gTimedOut),
        @"enabled": @(FMKEnabled()),
        @"minutes": @(FMKMinutes()),
        @"watchdog": @(FMKWatchdogMode()),
        @"since": @(gBackgroundStart),
        @"beat": @(FMKNow()),
        @"playStart": @(gPlayStart),
        @"lastEnd": @(gLastPlayEnd),
        @"lastSeconds": @(gLastPlaySeconds),
        @"lastReason": gLastPlayReason ?: @"",
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
    if(!data) return;
    NSString *path = [dir stringByAppendingPathComponent:FMKStateFileName()];
    [data writeToFile:path atomically:YES];
}

// 判定取证：三路原始值都记下来。下次测试直接从日志看出哪一路有效，
// 不用再猜。（dock 的 apps 属性无 @objc，ObjC 运行时不可见，这里是实证记录。）
static NSDictionary *FMKGuestsProbe(void) {
    NSMutableDictionary *probe = [NSMutableDictionary dictionary];

    Class multitask = NSClassFromString(@"LCOrbitMultitask");
    SEL windowsSel = NSSelectorFromString(@"windows");
    if(!multitask) {
        probe[@"windows"] = @"no-class";
    } else if(![multitask respondsToSelector:windowsSel]) {
        probe[@"windows"] = @"no-selector";
    } else {
        id windows = ((id (*)(id, SEL))objc_msgSend)((id)multitask, windowsSel);
        probe[@"windows"] = @([windows respondsToSelector:@selector(count)] ? [windows count] : -1);
    }

    Class dockClass = NSClassFromString(@"MultitaskDockManager")
                   ?: NSClassFromString(@"LiveContainerSwiftUI.MultitaskDockManager");
    probe[@"dockClass"] = dockClass ? NSStringFromClass(dockClass) : @"nil";
    if(dockClass) {
        SEL appsSel = NSSelectorFromString(@"apps");
        probe[@"dockApps"] = @([dockClass instancesRespondToSelector:appsSel] ||
                               [dockClass respondsToSelector:appsSel]);
    }

    probe[@"scenes"] = @(UIApplication.sharedApplication.connectedScenes.count);
    return probe;
}

// 宿主音频整进程一份，只有「有游客在跑」时才值得播——没游客就不耗电。
// 首选 LCOrbitMultitask.windows（宿主侧多任务窗口列表，是我们基线里的 ObjC 类，
// 虚拟窗口模式同样有效）；拿不到再退回 Swift dock 管理器与场景数。
// 注意：曾用「猜 Swift 类名 + connectedScenes.count>1」两路判定，实测在虚拟窗口
// 模式下两路都拿不到（dock 类名带模块前缀、Guest 场景不在 connectedScenes 里），
// 结果有游客在跑也判成"没有"，宿主保活从不启动。
static BOOL FMKGuestsRunning(void) {
    Class multitask = NSClassFromString(@"LCOrbitMultitask");
    if(multitask) {
        SEL windowsSel = NSSelectorFromString(@"windows");
        if([multitask respondsToSelector:windowsSel]) {
            id windows = ((id (*)(id, SEL))objc_msgSend)((id)multitask, windowsSel);
            if([windows respondsToSelector:@selector(count)]) return [windows count] > 0;
        }
    }
    // 次选：NSClassFromString 对 Swift @objc 类需带模块前缀，两种写法都试。
    Class dockClass = NSClassFromString(@"MultitaskDockManager")
                   ?: NSClassFromString(@"LiveContainerSwiftUI.MultitaskDockManager");
    if(dockClass) {
        SEL sharedSel = NSSelectorFromString(@"shared");
        if([dockClass respondsToSelector:sharedSel]) {
            id manager = ((id (*)(id, SEL))objc_msgSend)((id)dockClass, sharedSel);
            SEL appsSel = NSSelectorFromString(@"apps");
            if(manager && [manager respondsToSelector:appsSel]) {
                id apps = ((id (*)(id, SEL))objc_msgSend)(manager, appsSel);
                if([apps respondsToSelector:@selector(count)]) return [apps count] > 0;
            }
        }
    }
    // 两路都判不了：保守播。宿主保活多一路音频，比"判定失败导致扩展被回收"划算。
    // （不再用 connectedScenes.count 兜底：虚拟窗口模式下 Guest 场景不在
    // connectedScenes 里，恒为 1，会把"有游客"误判成"没有"。）
    return YES;
}

// ---- 播放控制 ---------------------------------------------------------------

static void FMKStopWatchdog(void) {
    [gWatchdog invalidate];
    gWatchdog = nil;
}

static void FMKStopTimeoutTimer(void) {
    [gTimeoutTimer invalidate];
    gTimeoutTimer = nil;
}

static void FMKStopPlayback(NSString *reason);   // 前置声明：超时 timer 的回调里会调用

// 超时计时独立于看门狗：看门狗管「音频还活着吗」，这个 timer 管「保活多久」。
// 之前超时判定寄生在看门狗巡检里，关闭看门狗后巡检不跑，超时永远不会触发，
// 保活会一直播到回到前台——设计缺陷，已拆开。
static void FMKStartTimeoutTimer(void) {
    FMKStopTimeoutTimer();
    NSInteger minutes = FMKMinutes();
    if(minutes <= 0) return;
    NSTimeInterval remaining = minutes * 60.0 - (FMKNow() - gBackgroundStart);
    if(remaining <= 0) {
        gTimedOut = YES;
        FMKLog(@"keep-alive-timeout", @{@"minutes": @(minutes),
                                        @"role": gIsHost ? @"host" : @"guest",
                                        @"immediate": @YES});
        FMKStopPlayback(@"timeout");
        return;
    }
    NSInteger limit = minutes;
    gTimeoutTimer = [NSTimer scheduledTimerWithTimeInterval:remaining repeats:NO block:^(NSTimer *timer) {
        if(!gInBackground) { FMKStopTimeoutTimer(); return; }
        gTimedOut = YES;
        FMKLog(@"keep-alive-timeout", @{@"minutes": @(limit),
                                        @"role": gIsHost ? @"host" : @"guest"});
        FMKStopPlayback(@"timeout");
    }];
}

static void FMKEndBackgroundTask(void) {
    if(!gBGTaskActive) return;
    [UIApplication.sharedApplication endBackgroundTask:gBGTask];
    gBGTask = 0;
    gBGTaskActive = NO;
}

// 宿主第二通道：音频被打断时后台任务先顶住；过期时重开音频并续一个新任务。
static void FMKBeginBackgroundTask(void) {
    if(!gIsHost || gBGTaskActive) return;
    gBGTask = [UIApplication.sharedApplication beginBackgroundTaskWithExpirationHandler:^{
        FMKEndBackgroundTask();
        if(gInBackground && !gTimedOut) {
            gPlayer = nil;      // 会话/播放器一并重建
            FMKRefresh();
        }
    }];
    gBGTaskActive = YES;
}

static void FMKStartPlayback(NSString *trigger) {
    @try {
        if(gPlayer && gPlayer.isPlaying) {
            FMKBeginBackgroundTask();
            return;
        }
        if(!gPlayer) {
            AVAudioSession *session = AVAudioSession.sharedInstance;
            [session setCategory:AVAudioSessionCategoryPlayback
                     withOptions:AVAudioSessionCategoryOptionMixWithOthers
                           error:nil];
            [session setActive:YES error:nil];
            gPlayer = [[AVAudioPlayer alloc] initWithData:FMKSilentWAVData() error:nil];
            gPlayer.numberOfLoops = -1;     // 无限循环
            gPlayer.volume = 0.0;
            [gPlayer prepareToPlay];
        }
        [gPlayer play];
        if(gPlayStart <= 0) gPlayStart = FMKNow();
        FMKBeginBackgroundTask();
        FMKLog(@"keep-alive-start", @{@"role": gIsHost ? @"host" : @"guest",
                                       @"trigger": trigger ?: @"",
                                       @"pid": @(getpid())});
        FMKWriteState();
    } @catch (__unused NSException *e) {
        // 保活失败绝不能拖垮宿主/游客：静默放弃，下次触发再试。
    }
}

static void FMKStopPlayback(NSString *reason) {
    @try {
        FMKStopWatchdog();
        FMKStopTimeoutTimer();
        // 记录「上次保活」：只有真起播过才写，否则前台反复刷新会把历史冲成 0 秒。
        if(gPlayStart > 0) {
            gLastPlayEnd = FMKNow();
            gLastPlaySeconds = gLastPlayEnd - gPlayStart;
            gLastPlayReason = reason ?: @"";
            gPlayStart = 0;
        }
        [gPlayer pause];
        [[AVAudioSession sharedInstance] setActive:NO
                                       withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                             error:nil];
        FMKEndBackgroundTask();
        if(gPlayer) FMKLog(@"keep-alive-stop", @{@"reason": reason ?: @"",
                                                  @"role": gIsHost ? @"host" : @"guest"});
        FMKWriteState();
    } @catch (__unused NSException *e) {}
}

// ---- 看门狗 ---------------------------------------------------------------

// 自适应分档：0-5 分钟 30 秒 / 5-10 分钟 45 秒 / 10 分钟以上 60 秒。0 = 不启用。
static NSTimeInterval FMKWatchdogInterval(void) {
    if(FMKWatchdogMode() == 0) return 0;
    NSTimeInterval elapsed = FMKNow() - gBackgroundStart;
    if(elapsed < 300.0) return 30.0;
    if(elapsed < 600.0) return 45.0;
    return 60.0;
}

static void FMKStartWatchdog(void) {
    FMKStopWatchdog();
    NSTimeInterval interval = FMKWatchdogInterval();
    if(interval <= 0) return;
    gWatchdog = [NSTimer scheduledTimerWithTimeInterval:interval repeats:NO block:^(NSTimer *timer) {
        if(!gInBackground) { FMKStopWatchdog(); return; }

        // 超时判定已移到独立的 gTimeoutTimer（看门狗关闭也生效）。
        // 这里只负责两件事：音频存活检查、心跳。

        // 1) 音频存活检查：停了就重建（会话可能已失效，连 player 一起重建）
        if(!gTimedOut && (!gPlayer || !gPlayer.isPlaying)) {
            FMKLog(@"keep-alive-revive", @{@"role": gIsHost ? @"host" : @"guest"});
            gPlayer = nil;
            FMKStartPlayback(@"watchdog");
        }

        // 2) 心跳：证明本进程仍在被调度（没被挂起）
        FMKWriteState();

        // 3) 重建自己，让间隔随时间自适应
        FMKStartWatchdog();
    }];
    // 允许系统合并唤醒，省一点电
    gWatchdog.tolerance = MIN(interval * 0.3, 10.0);
}

// ---- 播放决策 ---------------------------------------------------------------

// 所有触发点都走这里，避免多处状态打架。
static void FMKRefresh(void) {
    static BOOL lastSkipNoGuests = NO;   // 去重：同一状态只记一条
    if(!FMKEnabled()) { FMKStopPlayback(@"disabled"); return; }
    if(!gInBackground) { FMKStopPlayback(@"foreground"); return; }
    if(gTimedOut) { FMKStopPlayback(@"timeout"); return; }
    if(gIsHost && !FMKGuestsRunning()) {
        if(!lastSkipNoGuests) {
            lastSkipNoGuests = YES;
            FMKLog(@"keep-alive-skip", @{@"reason": @"no-guests",
                                          @"probe": FMKGuestsProbe() ?: @{}});
            FMKWriteState();
        }
        FMKStopPlayback(@"no-guests");
        return;
    }
    lastSkipNoGuests = NO;
    FMKStartPlayback(@"refresh");
    if(!gWatchdog) FMKStartWatchdog();
}

// ---- 前后台切换 ---------------------------------------------------------------

static void FMKEnterBackground(NSString *source) {
    if(gInBackground) { FMKRefresh(); return; }
    gInBackground = YES;
    gBackgroundStart = FMKNow();
    gTimedOut = NO;
    NSMutableDictionary *bg = [NSMutableDictionary dictionaryWithDictionary:@{
        @"source": source ?: @"",
        @"role": gIsHost ? @"host" : @"guest",
    }];
    if(gIsHost) [bg addEntriesFromDictionary:FMKGuestsProbe()];
    FMKLog(@"keep-alive-background", bg);
    FMKStartTimeoutTimer();   // 独立于看门狗：关着看门狗也要按设定时长停
    FMKWriteState();
    FMKRefresh();
}

static void FMKEnterForeground(NSString *source) {
    if(!gInBackground) return;
    gInBackground = NO;
    gTimedOut = NO;
    FMKLog(@"keep-alive-foreground", @{@"source": source ?: @"",
                                       @"role": gIsHost ? @"host" : @"guest"});
    FMKWriteState();
    FMKStopPlayback(@"foreground");
}

// ---- 通知装配 ---------------------------------------------------------------

static void FMKAddObserver(NSString *name, id object, void (^block)(NSNotification *)) {
    [NSNotificationCenter.defaultCenter addObserverForName:name
                                                    object:object
                                                     queue:NSOperationQueue.mainQueue
                                                 usingBlock:block];
}

__attribute__((constructor))
static void FMKeepAliveInit(void) {
    @autoreleasepool {
        if(gInstalled) return;
        gInstalled = YES;
        gIsHost = FMKIsHostUI();
        FMKLog(@"keep-alive-loaded", @{@"pid": @(getpid()),
                                       @"host": @(gIsHost),
                                       @"bundle": NSBundle.mainBundle.bundleIdentifier ?: @""});

        // 提前起播：WillResignActive 早于真正进后台，切后台时音频会话已是激活态。
        FMKAddObserver(UIApplicationWillResignActiveNotification, nil, ^(NSNotification *note) {
            FMKEnterBackground(@"resignActive");
        });
        FMKAddObserver(UIApplicationDidEnterBackgroundNotification, nil, ^(NSNotification *note) {
            FMKEnterBackground(@"didEnterBackground");
        });
        FMKAddObserver(UIApplicationDidBecomeActiveNotification, nil, ^(NSNotification *note) {
            FMKEnterForeground(@"becomeActive");
        });
        FMKAddObserver(UIApplicationWillEnterForegroundNotification, nil, ^(NSNotification *note) {
            FMKEnterForeground(@"willEnterForeground");
        });

        // 扩展进程：UIApplication 的后台通知不一定送达，宿主通知才是可靠的那路。
        // 两个常量不在公开头文件，用字符串字面量避免编译期找不到符号。
        FMKAddObserver(@"NSExtensionHostDidEnterBackgroundNotification", nil, ^(NSNotification *note) {
            FMKEnterBackground(@"extensionHostBg");
        });
        FMKAddObserver(@"NSExtensionHostWillEnterForegroundNotification", nil, ^(NSNotification *note) {
            FMKEnterForeground(@"extensionHostFg");
        });

        // 音频被打断（来电等）结束后，仍在后台就立即恢复——快路径，不受看门狗开关影响。
        FMKAddObserver(AVAudioSessionInterruptionNotification, AVAudioSession.sharedInstance,
                       ^(NSNotification *note) {
            NSNumber *typeNum = note.userInfo[AVAudioSessionInterruptionTypeKey];
            if(!typeNum) return;
            if((AVAudioSessionInterruptionType)typeNum.unsignedIntegerValue !=
               AVAudioSessionInterruptionTypeEnded) return;
            if(!gInBackground || gTimedOut) return;
            FMKLog(@"keep-alive-interruption-ended", nil);
            gPlayer = nil;      // 会话可能已失效，整体重建
            FMKRefresh();
        });

        // 音频服务崩溃重启：所有会话失效，必须重建 player 才会恢复。
        FMKAddObserver(AVAudioSessionMediaServicesWereResetNotification, AVAudioSession.sharedInstance,
                       ^(NSNotification *note) {
            if(!gInBackground || gTimedOut) return;
            FMKLog(@"keep-alive-services-reset", nil);
            gPlayer = nil;
            FMKRefresh();
        });

        FMKPurgeStaleStates();   // 清掉已退出进程留下的状态、以及旧位置（插件目录）的遗留
        FMKWriteState();   // 初值：让状态面板立刻能看到本进程

        // 冷启动就处于后台（极少见）
        dispatch_async(dispatch_get_main_queue(), ^{
            if(UIApplication.sharedApplication.applicationState == UIApplicationStateBackground)
                FMKEnterBackground(@"launchedInBackground");
        });
    }
}
