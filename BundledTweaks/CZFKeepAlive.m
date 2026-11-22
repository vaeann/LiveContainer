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
// 微珠式设置（2026-11-22）：保活上限与日志开关由宿主写进同目录的
// config.plist 下发。播放层定版为 AVAudioPlayer（引擎版是二分期
// 的实验，已移除）。
// 设置页定版（同日晚）：看门狗可关、频率按已保活时长分档变慢
// （见 CZFWatchdogInterval）；上限改独立定时器整点触发；每进程
// 写一份状态 JSON（state/ 目录）供宿主设置页汇总，照微珠。
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

static AVAudioPlayer *gPlayer = nil;
static NSTimer *gWatchdog = nil;
static BOOL gInBackground = NO;
static NSTimeInterval gPlayStartedAt = 0;
// 宿主下发的配置（<AppGroup>/CZFKeepAlive/config.plist）：保活上限
// 秒数（0 = 不限）、日志开关、看门狗开关。游客进程读不到宿主的
// 标准 defaults，只能走这个文件；加载、起播、看门狗轮次时各刷新一次。
static NSTimeInterval gLimitSeconds = 0;
static BOOL gLogEnabled = YES;
static BOOL gWatchdogEnabled = YES;

// 上限定时器：与看门狗分开的一次性定时，到上限整点触发停播。
static NSTimer *gLimitTimer = nil;
static BOOL gTimedOut = NO;
// 上一轮保活的收尾（状态文件用）。
static NSTimeInterval gLastEnd = 0;
static NSTimeInterval gLastSeconds = 0;
static NSString *gLastReason = nil;

static void CZFStartPlayer(void);
static void CZFStopKeepAlive(NSString *reason);
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

static void CZFLoadConfig(void) {
    if (![NSUserDefaults respondsToSelector:@selector(lcAppGroupPath)]) return;
    NSString *root = [NSUserDefaults lcAppGroupPath];
    if (!root.length) return;
    NSString *path = [[root stringByAppendingPathComponent:@"CZFKeepAlive"] stringByAppendingPathComponent:@"config.plist"];
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:path];
    NSNumber *limit = config[@"limitSeconds"];
    if (limit) gLimitSeconds = limit.doubleValue;
    NSNumber *logEnabled = config[@"logEnabled"];
    if (logEnabled) gLogEnabled = logEnabled.boolValue;
    NSNumber *watchdog = config[@"watchdogEnabled"];
    if (watchdog) gWatchdogEnabled = watchdog.boolValue;
}

// MARK: - 保活状态（微珠式：每进程一份 JSON，宿主设置页汇总）

static NSString *CZFStateFilePath(void) {
    if (![NSUserDefaults respondsToSelector:@selector(lcAppGroupPath)]) return nil;
    NSString *root = [NSUserDefaults lcAppGroupPath];
    if (!root.length) return nil;
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
    NSString *safe = [[bundle stringByReplacingOccurrencesOfString:@"/" withString:@"_"]
                      stringByReplacingOccurrencesOfString:@":" withString:@"_"];
    NSString *dir = [[root stringByAppendingPathComponent:@"CZFKeepAlive"] stringByAppendingPathComponent:@"state"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"keepalive-%@.json", safe]];
}

static void CZFWriteState(void) {
    NSString *path = CZFStateFilePath();
    if (!path) return;
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *name = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"]
                  ?: [bundle objectForInfoDictionaryKey:@"CFBundleName"] ?: @"";
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate] + NSTimeIntervalSince1970;
    NSDictionary *state = @{
        @"v": @1,
        @"pid": @(getpid()),
        @"role": @"guest",
        @"bundle": bundle.bundleIdentifier ?: @"",
        @"name": name,
        @"playing": @(gPlayer.isPlaying),
        @"background": @(gInBackground),
        @"enabled": @YES,
        @"limitSeconds": @(gLimitSeconds),
        @"watchdog": @(gWatchdogEnabled),
        @"timedOut": @(gTimedOut),
        @"playStart": @(gPlayStartedAt > 0 ? gPlayStartedAt + NSTimeIntervalSince1970 : 0),
        @"beat": @(now),
        @"lastEnd": @(gLastEnd),
        @"lastSeconds": @(gLastSeconds),
        @"lastReason": gLastReason ?: @"",
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
    if (data) [data writeToFile:path atomically:YES];
}

static void CZFLog(NSString *event, NSString *details) {
    if (!gLogEnabled) return;
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

// 生成 1 秒静音 WAV 数据（8000Hz 单声道 16bit PCM），生成一次后缓存
static NSData *CZFSilentWAVData(void) {
    static NSData *cached = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const uint32_t sampleRate = 8000;
        const uint16_t channels = 1;
        const uint16_t bitsPerSample = 16;
        const uint32_t dataSize = sampleRate * channels * (bitsPerSample / 8);
        const uint32_t chunkSize = 36 + dataSize;
        const uint16_t blockAlign = channels * (bitsPerSample / 8);
        const uint32_t byteRate = sampleRate * (uint32_t)blockAlign;

        NSMutableData *data = [NSMutableData dataWithCapacity:44 + dataSize];
        [data appendBytes:"RIFF" length:4];
        [data appendBytes:&chunkSize length:4];
        [data appendBytes:"WAVE" length:4];
        [data appendBytes:"fmt " length:4];
        uint32_t subChunk1Size = 16;
        uint16_t audioFormat = 1; // PCM
        [data appendBytes:&subChunk1Size length:4];
        [data appendBytes:&audioFormat length:2];
        [data appendBytes:&channels length:2];
        [data appendBytes:&sampleRate length:4];
        [data appendBytes:&byteRate length:4];
        [data appendBytes:&blockAlign length:2];
        [data appendBytes:&bitsPerSample length:2];
        [data appendBytes:"data" length:4];
        [data appendBytes:&dataSize length:4];
        [data increaseLengthBy:dataSize]; // 补零 = 静音采样
        cached = [data copy];
    });
    return cached;
}

static void CZFStartPlayer(void) {
    if (gPlayer && gPlayer.isPlaying) return;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *categoryError = nil;
    [session setCategory:AVAudioSessionCategoryPlayback
             withOptions:AVAudioSessionCategoryOptionMixWithOthers
                   error:&categoryError];
    NSError *activeError = nil;
    [session setActive:YES error:&activeError];
    BOOL created = NO;
    NSError *playerError = nil;
    if (!gPlayer) {
        gPlayer = [[AVAudioPlayer alloc] initWithData:CZFSilentWAVData() error:&playerError];
        gPlayer.numberOfLoops = -1; // 无限循环
        gPlayer.volume = 0.0;
        [gPlayer prepareToPlay];
        created = YES;
    }
    [gPlayer play];
    if (gPlayStartedAt == 0) gPlayStartedAt = [NSDate timeIntervalSinceReferenceDate];
    CZFLog(@"keep-alive-start", [NSString stringWithFormat:@"created=%d playing=%d currentTime=%.3f categoryError=%@ activeError=%@ playerError=%@ pid=%d",
        created, gPlayer.isPlaying, gPlayer.currentTime,
        categoryError ? categoryError.localizedDescription : @"none",
        activeError ? activeError.localizedDescription : @"none",
        playerError ? playerError.localizedDescription : @"none",
        getpid()]);
}

// 看门狗频率（Ann 定版，按本轮已保活时长，越久越慢）：前 2 分钟
// 15 秒，2–5 分钟 30 秒，5–10 分钟 45 秒，10 分钟以上 60 秒。
// 看门狗可关（配置下发），关了就没有自动恢复、心跳也停。
// 保活上限不归看门狗管：CZFArmLimitTimer 单独整点触发。
static NSTimeInterval CZFWatchdogInterval(void) {
    NSTimeInterval elapsed = gPlayStartedAt > 0 ? [NSDate timeIntervalSinceReferenceDate] - gPlayStartedAt : 0;
    if (elapsed < 120) return 15.0;
    if (elapsed < 300) return 30.0;
    if (elapsed < 600) return 45.0;
    return 60.0;
}

static void CZFArmWatchdog(BOOL logArmed) {
    [gWatchdog invalidate];
    gWatchdog = nil;
    if (!gWatchdogEnabled) return;
    NSTimeInterval interval = CZFWatchdogInterval();
    gWatchdog = [NSTimer scheduledTimerWithTimeInterval:interval repeats:NO block:^(NSTimer *timer) {
        gWatchdog = nil;
        @try {
            CZFLoadConfig();
            // 被打断/暂停后自动恢复。
            if (gInBackground && !gPlayer.isPlaying) {
                CZFLog(@"keep-alive-watchdog", @"action=restart playing=0");
                CZFStartPlayer();
            }
            // 心跳：currentTime 间隔 0.5 秒双读，差值 ≈0.5 = 真在播；
            // next 是下一轮的自适应间隔。
            double ct1 = gPlayer.currentTime;
            BOOL playing = gPlayer.isPlaying;
            NSTimeInterval next = CZFWatchdogInterval();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                double ct2 = gPlayer.currentTime;
                CZFLog(@"keep-alive-beat", [NSString stringWithFormat:@"ct1=%.4f ct2=%.4f playing=%d bg=%d next=%.0f", ct1, ct2, playing, gInBackground, next]);
            });
            CZFWriteState();
            if (gInBackground) {
                CZFArmWatchdog(NO);
            }
        } @catch (__unused NSException *e) {}
    }];
    // 容差随间隔缩放，系统可合并唤醒、减发热
    gWatchdog.tolerance = interval * 0.3;
    if (logArmed) {
        CZFLog(@"keep-alive-watchdog-armed", [NSString stringWithFormat:@"interval=%.0f tolerance=%.0f", interval, interval * 0.3]);
    }
}

/// 上限定时器：起播时按剩余时间单独排一发，到点停播（置 timedOut），
/// 与看门狗间隔无关、整点触发。
static void CZFArmLimitTimer(void) {
    [gLimitTimer invalidate];
    gLimitTimer = nil;
    if (gLimitSeconds <= 0 || gPlayStartedAt <= 0) return;
    NSTimeInterval remaining = gLimitSeconds - ([NSDate timeIntervalSinceReferenceDate] - gPlayStartedAt);
    if (remaining <= 0) return;
    gLimitTimer = [NSTimer scheduledTimerWithTimeInterval:remaining repeats:NO block:^(NSTimer *timer) {
        gLimitTimer = nil;
        gTimedOut = YES;
        CZFStopKeepAlive(@"limit");
    }];
}

static void CZFStartKeepAlive(void) {
    @try {
        CZFLoadConfig();
        BOOL fresh = (gPlayStartedAt == 0);
        CZFStartPlayer();
        if (fresh) {
            gTimedOut = NO;
        }
        if (!gWatchdog) {
            CZFArmWatchdog(YES);
        }
        if (!gLimitTimer) {
            CZFArmLimitTimer();
        }
        CZFWriteState();
    } @catch (__unused NSException *e) {}
}

static void CZFStopKeepAlive(NSString *reason) {
    @try {
        BOOL wasPlaying = gPlayer.isPlaying;
        NSTimeInterval seconds = gPlayStartedAt > 0 ? [NSDate timeIntervalSinceReferenceDate] - gPlayStartedAt : 0;
        if (wasPlaying || gPlayStartedAt > 0) {
            CZFLog(@"keep-alive-stop", [NSString stringWithFormat:@"reason=%@ wasPlaying=%d seconds=%.1f", reason, wasPlaying, seconds]);
            gLastEnd = [NSDate timeIntervalSinceReferenceDate] + NSTimeIntervalSince1970;
            gLastSeconds = seconds;
            gLastReason = reason;
            if ([reason isEqualToString:@"limit"]) gTimedOut = YES;
        }
        gPlayStartedAt = 0;
        [gWatchdog invalidate];
        gWatchdog = nil;
        [gLimitTimer invalidate];
        gLimitTimer = nil;
        [gPlayer pause];
        [[AVAudioSession sharedInstance] setActive:NO
                                       withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                             error:nil];
        CZFWriteState();
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
        CZFLoadConfig();
        if (gLogEnabled) CZFLogTrimIfNeeded();
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
                        CZFLog(@"keep-alive-notify", [NSString stringWithFormat:@"name=mediaServicesLost bg=%d playing=%d", gInBackground, gPlayer.isPlaying]);
                        if (gInBackground && !gPlayer.isPlaying) {
                            CZFStartKeepAlive();
                        }
                    }]];

        [gCZFKeepAliveObservers addObject:[nc addObserverForName:AVAudioSessionMediaServicesWereResetNotification
                        object:nil queue:mainQ
                    usingBlock:^(NSNotification *note) {
                        CZFLog(@"keep-alive-notify", [NSString stringWithFormat:@"name=mediaServicesReset bg=%d playing=%d", gInBackground, gPlayer.isPlaying]);
                        if (gInBackground && !gPlayer.isPlaying) {
                            CZFStartKeepAlive();
                        }
                    }]];

        CZFLog(@"keep-alive-observers", [NSString stringWithFormat:@"count=%lu", (unsigned long)gCZFKeepAliveObservers.count]);
        CZFWriteState();
    }
}
