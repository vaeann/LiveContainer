// CZFKeepAlive.m
// 极简保活插件（LiveContainer 注入用 dylib），移植自 LiveContainer-zh
// 的同名实现 v1.4。原理：App 进后台后循环播放无声音频，保持进程不被
// 系统挂起。设计原则：只做保活这一件事——前台自动停、后台才开；
// 30 秒看门狗只检查不管闲事；全程异常兜底，绝不让宿主 App 崩。
// v1.1：静音音频改为内存数据直接播放（initWithData）。
// v1.2：白名单门——dylib 同目录放 CZFKeepAliveApps.txt（一行一个
// bundle id）时，只给名单里的 App 保活；没这个文件时所有 App 都保。
// v1.3：看门狗加 10 秒容差，系统可合并唤醒。
// v1.4（防 1 分钟内被掐）：提前启动 + 宿主通知——WillResignActive 就
// 提前播，切后台时音频会话已经是激活态；同时补宿主后台通知
// （NSExtensionHost*），游客的 UIApplication 后台通知在扩展里不一定
// 到，宿主通知才是可靠的那路。
// 本 fork 的增补：全程诊断日志——与宿主侧 CZFHostKeepAlive 写同一个
// 文件（<AppGroup>/CZFKeepAlive/keepalive.log），格式一致；另补了
// 音频服务丢失/重置两个通知的观察（zh 只有宿主侧有）。
// 播放层（2026-11-22 实验变量）：不用 AVAudioPlayer，改 AVAudioEngine
// + AVAudioPlayerNode 循环播 44.1kHz 立体声静音缓冲（Palladium 同款）；
// 触发、看门狗、白名单等逻辑与 zh v1.4 一致。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <dlfcn.h>
#import <unistd.h>

// LC 的 NSUserDefaults 类别（LiveContainerShared 提供，客人进程里已
// 加载）：拿 App Group 根目录拼日志路径。只声明、用前先 responds 检查。
@interface NSUserDefaults (CZFKeepAliveAppGroup)
+ (NSString *)lcAppGroupPath;
@end

static AVAudioEngine *gEngine = nil;
static AVAudioPlayerNode *gNode = nil;
static NSTimer *gWatchdog = nil;
static BOOL gInBackground = NO;
static NSTimeInterval gPlayStartedAt = 0;
// block 观察者返的 token 必须留住，丢掉就当场注销。
static NSMutableArray *gCZFKeepAliveObservers = nil;

// MARK: - 诊断日志（与宿主侧同文件、同格式）

static dispatch_queue_t CZFLogQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("czf.keepalive.log", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSString *CZFLogFilePath(void) {
    if (![NSUserDefaults respondsToSelector:@selector(lcAppGroupPath)]) return nil;
    NSString *root = [NSUserDefaults lcAppGroupPath];
    if (!root.length) return nil;
    return [[root stringByAppendingPathComponent:@"CZFKeepAlive"] stringByAppendingPathComponent:@"keepalive.log"];
}

static void CZFLog(NSString *event, NSString *details) {
    NSString *path = CZFLogFilePath();
    if (!path) return;
    NSString *tag = [[NSBundle mainBundle] bundleIdentifier] ?: @"guest";
    dispatch_async(CZFLogQueue(), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"MM-dd HH:mm:ss";
        NSString *line = [NSString stringWithFormat:@"%@ %@ · %@%@\n",
                          [formatter stringFromDate:[NSDate date]], tag, event,
                          details.length ? [@" " stringByAppendingString:details] : @""];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle) {
            [handle seekToEndOfFile];
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        } else {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    });
}

static void CZFLogTrimIfNeeded(void) {
    NSString *path = CZFLogFilePath();
    if (!path) return;
    dispatch_async(CZFLogQueue(), ^{
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        long long size = [[attrs objectForKey:NSFileSize] longLongValue];
        if (size <= 512 * 1024) return;
        NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        NSArray *lines = [content componentsSeparatedByString:@"\n"];
        if (lines.count > 200) lines = [lines subarrayWithRange:NSMakeRange(lines.count - 200, 200)];
        [[lines componentsJoinedByString:@"\n"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    });
}

static BOOL CZFIsPlaying(void) {
    return gNode.isPlaying;
}

/// 节点播放时间轴上的秒数（单调递增），取不到时 -1。心跳双采样用它
/// 证明渲染真的在推进（等价于旧版 AVAudioPlayer 的 currentTime）。
static double CZFNodeTime(void) {
    if (!gNode) return -1;
    AVAudioTime *last = gNode.lastRenderTime;
    if (!last) return -1;
    AVAudioTime *pt = [gNode playerTimeForNodeTime:last];
    if (!pt || pt.sampleRate <= 0) return -1;
    return (double)pt.sampleTime / pt.sampleRate;
}

/// 1 秒静音 PCM 缓冲（44.1kHz 立体声浮点，全零），与宿主侧同配方。
static AVAudioPCMBuffer *CZFSilentBuffer(void) {
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];
    if (!format) return nil;
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:44100];
    if (!buffer || !buffer.floatChannelData) return nil;
    buffer.frameLength = 44100;
    for (UInt32 ch = 0; ch < format.channelCount; ch++) {
        memset(buffer.floatChannelData[ch], 0, 44100 * sizeof(float));
    }
    return buffer;
}

/// 搭引擎图：播放节点 → 主混音器，挂静音缓冲无限循环。
static void CZFBuildGraph(void) {
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];
    AVAudioPCMBuffer *buffer = CZFSilentBuffer();
    if (!format || !buffer) return;
    gEngine = [[AVAudioEngine alloc] init];
    gNode = [[AVAudioPlayerNode alloc] init];
    [gEngine attachNode:gNode];
    [gEngine connect:gNode to:gEngine.mainMixerNode format:format];
    [gNode scheduleBuffer:buffer atTime:nil options:AVAudioPlayerNodeBufferLoops completionHandler:nil];
}

static BOOL CZFRunEngine(NSError **outError) {
    if (!gEngine) CZFBuildGraph();
    if (!gEngine || !gNode) return NO;
    if (!gEngine.isRunning) {
        [gEngine prepare];
        if (![gEngine startAndReturnError:outError]) return NO;
    }
    if (!gNode.isPlaying) [gNode play];
    return YES;
}

static void CZFStartEngine(void) {
    if (CZFIsPlaying()) return;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *categoryError = nil;
    [session setCategory:AVAudioSessionCategoryPlayback
             withOptions:AVAudioSessionCategoryOptionMixWithOthers
                   error:&categoryError];
    NSError *activeError = nil;
    [session setActive:YES error:&activeError];
    BOOL created = (gEngine == nil);
    NSError *engineError = nil;
    if (!CZFRunEngine(&engineError)) {
        // 引擎可能在音频服务重置后失效：整套重建再试一次。
        [gNode stop];
        [gEngine stop];
        gEngine = nil;
        gNode = nil;
        CZFRunEngine(&engineError);
    }
    if (gPlayStartedAt == 0) gPlayStartedAt = [NSDate timeIntervalSinceReferenceDate];
    CZFLog(@"keep-alive-start", [NSString stringWithFormat:@"created=%d playing=%d nodeTime=%.3f categoryError=%@ activeError=%@ engineError=%@ pid=%d",
        created, CZFIsPlaying(), CZFNodeTime(),
        categoryError ? categoryError.localizedDescription : @"none",
        activeError ? activeError.localizedDescription : @"none",
        engineError ? engineError.localizedDescription : @"none",
        getpid()]);
}

static void CZFStartKeepAlive(void) {
    @try {
        CZFStartEngine();
        if (!gWatchdog) {
            gWatchdog = [NSTimer scheduledTimerWithTimeInterval:30.0 repeats:YES block:^(NSTimer *timer) {
                @try {
                    // 被打断/暂停后自动恢复
                    if (gInBackground && !CZFIsPlaying()) {
                        CZFLog(@"keep-alive-watchdog", @"action=restart playing=0");
                        CZFStartEngine();
                    }
                    // 心跳：节点时间间隔 0.5 秒双读，差值 ≈0.5 = 渲染真在推进
                    double ct1 = CZFNodeTime();
                    BOOL playing = CZFIsPlaying();
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        double ct2 = CZFNodeTime();
                        CZFLog(@"keep-alive-beat", [NSString stringWithFormat:@"ct1=%.4f ct2=%.4f playing=%d bg=%d", ct1, ct2, playing, gInBackground]);
                    });
                } @catch (__unused NSException *e) {}
            }];
            // 减发热：容差 10 秒，系统可合并唤醒
            gWatchdog.tolerance = 10.0;
            CZFLog(@"keep-alive-watchdog-armed", @"interval=30 tolerance=10");
        }
    } @catch (__unused NSException *e) {}
}

static void CZFStopKeepAlive(NSString *reason) {
    @try {
        BOOL wasPlaying = CZFIsPlaying();
        NSTimeInterval seconds = gPlayStartedAt > 0 ? [NSDate timeIntervalSinceReferenceDate] - gPlayStartedAt : 0;
        if (wasPlaying || gPlayStartedAt > 0) {
            CZFLog(@"keep-alive-stop", [NSString stringWithFormat:@"reason=%@ wasPlaying=%d seconds=%.1f", reason, wasPlaying, seconds]);
        }
        gPlayStartedAt = 0;
        [gWatchdog invalidate];
        gWatchdog = nil;
        [gNode pause];
        [gEngine stop];
        [[AVAudioSession sharedInstance] setActive:NO
                                       withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                             error:nil];
    } @catch (__unused NSException *e) {}
}

// 白名单门：名单文件存在时按名单决定本 App 要不要保活；
// 文件不存在或读不到，一律保活（不改变现有用法）
static BOOL CZFShouldActivate(void) {
    Dl_info info;
    if (dladdr((void *)&CZFShouldActivate, &info) == 0 || !info.dli_fname) {
        CZFLog(@"keep-alive-whitelist", @"verdict=activate source=dladdr-failed");
        return YES;
    }
    NSString *dir = [@(info.dli_fname) stringByDeletingLastPathComponent];
    NSString *listPath = [dir stringByAppendingPathComponent:@"CZFKeepAliveApps.txt"];
    NSString *content = [NSString stringWithContentsOfFile:listPath encoding:NSUTF8StringEncoding error:nil];
    if (!content) {
        CZFLog(@"keep-alive-whitelist", @"verdict=activate source=no-file");
        return YES;
    }
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    NSInteger entries = 0;
    for (NSString *line in [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length) {
            entries++;
            if ([trimmed isEqualToString:bundleId]) {
                CZFLog(@"keep-alive-whitelist", [NSString stringWithFormat:@"verdict=activate source=file entries=%ld", (long)entries]);
                return YES;
            }
        }
    }
    CZFLog(@"keep-alive-whitelist", [NSString stringWithFormat:@"verdict=dormant source=file entries=%ld", (long)entries]);
    return NO;
}

__attribute__((constructor))
static void CZFKeepAliveInit(void) {
    @autoreleasepool {
        CZFLogTrimIfNeeded();
        NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        CZFLog(@"keep-alive-loaded", [NSString stringWithFormat:@"bundle=%@ pid=%d", bundleId, getpid()]);
        if (!CZFShouldActivate()) {
            CZFLog(@"keep-alive-dormant", @"reason=whitelist");
            return;
        }
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        NSOperationQueue *mainQ = [NSOperationQueue mainQueue];
        if (!gCZFKeepAliveObservers) gCZFKeepAliveObservers = [NSMutableArray array];

        [gCZFKeepAliveObservers addObject:[nc addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil queue:mainQ
                    usingBlock:^(NSNotification *note) {
                        CZFLog(@"keep-alive-notify", @"name=didEnterBackground");
                        gInBackground = YES;
                        CZFStartKeepAlive();
                    }]];

        [gCZFKeepAliveObservers addObject:[nc addObserverForName:UIApplicationWillEnterForegroundNotification
                        object:nil queue:mainQ
                    usingBlock:^(NSNotification *note) {
                        CZFLog(@"keep-alive-notify", @"name=willEnterForeground");
                        gInBackground = NO;
                        CZFStopKeepAlive(@"willEnterForeground");
                    }]];

        // 宿主切后台的通知：扩展里 UIApplication 后台通知不一定到，
        // 宿主通知是可靠的那路（Dead10ccFix 同款信号）。
        [gCZFKeepAliveObservers addObject:[nc addObserverForName:NSExtensionHostDidEnterBackgroundNotification
                        object:nil queue:mainQ
                    usingBlock:^(NSNotification *note) {
                        CZFLog(@"keep-alive-notify", @"name=extensionHostDidEnterBackground");
                        gInBackground = YES;
                        CZFStartKeepAlive();
                    }]];

        [gCZFKeepAliveObservers addObject:[nc addObserverForName:NSExtensionHostWillEnterForegroundNotification
                        object:nil queue:mainQ
                    usingBlock:^(NSNotification *note) {
                        CZFLog(@"keep-alive-notify", @"name=extensionHostWillEnterForeground");
                        gInBackground = NO;
                        CZFStopKeepAlive(@"extensionHostWillEnterForeground");
                    }]];

        // 提前启动：切后台前（上滑切 App、来电弹框等）就先播，切后台时
        // 音频会话已经是激活态，不留“先被掐、后才开始播”的空档。
        // 回前台时 DidBecomeActive 停掉，短暂误触发成本只有几秒静音。
        [gCZFKeepAliveObservers addObject:[nc addObserverForName:UIApplicationWillResignActiveNotification
                        object:nil queue:mainQ
                    usingBlock:^(NSNotification *note) {
                        CZFLog(@"keep-alive-notify", @"name=willResignActive");
                        gInBackground = YES;
                        CZFStartKeepAlive();
                    }]];

        [gCZFKeepAliveObservers addObject:[nc addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil queue:mainQ
                    usingBlock:^(NSNotification *note) {
                        CZFLog(@"keep-alive-notify", @"name=didBecomeActive");
                        gInBackground = NO;
                        CZFStopKeepAlive(@"didBecomeActive");
                    }]];

        // 启动时已经在后台的兜底（极少见）
        [gCZFKeepAliveObservers addObject:[nc addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil queue:mainQ
                    usingBlock:^(NSNotification *note) {
                        UIApplicationState state = [UIApplication sharedApplication].applicationState;
                        CZFLog(@"keep-alive-notify", [NSString stringWithFormat:@"name=didFinishLaunching state=%ld", (long)state]);
                        if (state == UIApplicationStateBackground) {
                            gInBackground = YES;
                            CZFStartKeepAlive();
                        }
                    }]];

        // 音频被来电等打断：开始只记日志，结束后还在后台就恢复播放
        [gCZFKeepAliveObservers addObject:[nc addObserverForName:AVAudioSessionInterruptionNotification
                        object:[AVAudioSession sharedInstance] queue:mainQ
                    usingBlock:^(NSNotification *note) {
                        NSNumber *typeNum = note.userInfo[AVAudioSessionInterruptionTypeKey];
                        if (typeNum && typeNum.unsignedIntegerValue == AVAudioSessionInterruptionTypeBegan) {
                            CZFLog(@"keep-alive-notify", @"name=interruptionBegan");
                        } else if (typeNum && typeNum.unsignedIntegerValue == AVAudioSessionInterruptionTypeEnded) {
                            CZFLog(@"keep-alive-notify", [NSString stringWithFormat:@"name=interruptionEnded bg=%d", gInBackground]);
                            if (gInBackground) {
                                CZFStartKeepAlive();
                            }
                        }
                    }]];

        // 音频服务丢失/重置（mediaserverd 重启）：播放器会静默停掉，
        // 还在后台且没在播就重起（zh 只有宿主侧听这两个，这里补上）。
        [gCZFKeepAliveObservers addObject:[nc addObserverForName:AVAudioSessionMediaServicesWereLostNotification
                        object:nil queue:mainQ
                    usingBlock:^(NSNotification *note) {
                        CZFLog(@"keep-alive-notify", [NSString stringWithFormat:@"name=mediaServicesLost bg=%d playing=%d", gInBackground, CZFIsPlaying()]);
                        if (gInBackground && !CZFIsPlaying()) {
                            CZFStartKeepAlive();
                        }
                    }]];

        [gCZFKeepAliveObservers addObject:[nc addObserverForName:AVAudioSessionMediaServicesWereResetNotification
                        object:nil queue:mainQ
                    usingBlock:^(NSNotification *note) {
                        CZFLog(@"keep-alive-notify", [NSString stringWithFormat:@"name=mediaServicesReset bg=%d playing=%d", gInBackground, CZFIsPlaying()]);
                        if (gInBackground && !CZFIsPlaying()) {
                            CZFStartKeepAlive();
                        }
                    }]];

        CZFLog(@"keep-alive-observers", [NSString stringWithFormat:@"count=%lu", (unsigned long)gCZFKeepAliveObservers.count]);
    }
}
