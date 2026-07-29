//
//  ProxyConfigHelper.m
//  com.clashfx.app.Helper
//
//  Created by yichengchen on 2019/8/17.
//  Copyright © 2019 west2online. All rights reserved.
//

#import "ProxyConfigHelper.h"
#import <AppKit/AppKit.h>
#import <Security/Security.h>
#import <fcntl.h>
#import <libproc.h>
#import <signal.h>
#import <string.h>
#import <unistd.h>
#import "ProxyConfigRemoteProcessProtocol.h"
#import "ProxySettingTool.h"

@interface ProxyConfigHelper()
<
NSXPCListenerDelegate,
ProxyConfigRemoteProcessProtocol
>

@property (nonatomic, strong) NSXPCListener *listener;
@property (nonatomic, strong) NSMutableSet<NSXPCConnection *> *connections;
@property (nonatomic, strong) NSTimer *checkTimer;
@property (nonatomic, strong) NSTimer *idleExitTimer;
@property (nonatomic, assign) BOOL shouldQuit;
@property (nonatomic, strong) NSTask *mihomoTask;
@property (nonatomic, copy) NSString *mihomoLaunchID;
@property (nonatomic, copy) NSString *mihomoLogPath;
@property (nonatomic, copy) NSString *mihomoHomeDir;
@property (nonatomic, strong) NSDate *mihomoLaunchDate;
@property (nonatomic, assign) pid_t mihomoProcessID;
@property (nonatomic, copy) NSString *mihomoLastTerminationSummary;

- (void)terminateMihomoTask:(NSTask *)task completion:(dispatch_block_t)completion;
- (void)launchMihomoCoreWithBinaryPath:(NSString *)binaryPath
                            configPath:(NSString *)configPath
                               homeDir:(NSString *)homeDir
                                 reply:(stringReplyBlock)reply;

@end

@implementation ProxyConfigHelper

static const NSTimeInterval kMihomoGracefulStopTimeout = 2.0;
static const unsigned long long kMihomoCoreLogMaximumBytes = 4 * 1024 * 1024;
static const NSUInteger kMihomoDiagnosticFileLimit = 24;
static const NSTimeInterval kDNSCacheCommandTimeout = 2.0;
// Give a newly launched ClashFX instance enough time to attach before an
// invalidated connection from the previous instance lets the helper exit.
static const NSTimeInterval kIdleExitGracePeriod = 10.0;
// launchd can start the helper well before the original XPC request is
// delivered when the system is under heavy load. Five seconds caused the
// helper to exit cleanly before ClashFX could connect, which in turn made the
// app repeatedly reinstall an already healthy helper.
static const NSTimeInterval kInitialConnectionGracePeriod = 60.0;

static void AppendLineToFile(NSString *path, NSString *line) {
    if (path.length == 0 || line.length == 0) {
        return;
    }

    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_APPEND);
    if (fd < 0) {
        return;
    }

    NSString *terminatedLine = [line hasSuffix:@"\n"] ? line : [line stringByAppendingString:@"\n"];
    NSData *data = [terminatedLine dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length > 0) {
        (void)write(fd, data.bytes, data.length);
    }
    close(fd);
}

static BOOL RunTaskWithTimeout(NSString *executablePath,
                               NSArray<NSString *> *arguments,
                               NSTimeInterval timeout) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:executablePath];
    task.arguments = arguments;

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        NSLog(@"Command failed to launch (%@): %@",
              executablePath.lastPathComponent,
              launchError.localizedDescription);
        return NO;
    }

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (task.isRunning && deadline.timeIntervalSinceNow > 0) {
        usleep(50 * 1000);
    }
    if (!task.isRunning) {
        return task.terminationStatus == 0;
    }

    NSLog(@"Command timed out after %.1fs: %@",
          timeout,
          executablePath.lastPathComponent);
    [task terminate];

    NSDate *terminationDeadline = [NSDate dateWithTimeIntervalSinceNow:0.5];
    while (task.isRunning && terminationDeadline.timeIntervalSinceNow > 0) {
        usleep(50 * 1000);
    }
    if (task.isRunning) {
        kill(task.processIdentifier, SIGKILL);
    }
    return NO;
}

- (instancetype)init {
    
    if (self = [super init]) {
        self.connections = [NSMutableSet new];
        self.shouldQuit = NO;
        self.listener = [[NSXPCListener alloc] initWithMachServiceName:@"com.clashfx.app.Helper"];
        self.listener.delegate = self;
    }
    return self;
}

- (NSString *)newMihomoLaunchID {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"yyyyMMdd-HHmmss-SSS";
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];
    NSString *suffix = [[[NSUUID UUID] UUIDString] substringToIndex:8].lowercaseString;
    return [NSString stringWithFormat:@"%@-%@", timestamp, suffix];
}

- (void)pruneMihomoDiagnosticDirectory:(NSString *)directory
                           keepingPath:(NSString *)currentPath {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray<NSURL *> *files = [fileManager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:directory]
                                          includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                                             options:NSDirectoryEnumerationSkipsHiddenFiles
                                                               error:nil];
    files = [files filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *_) {
        return [url.pathExtension isEqualToString:@"log"] ||
            [url.lastPathComponent hasSuffix:@".sample.txt"];
    }]];
    files = [files sortedArrayUsingComparator:^NSComparisonResult(NSURL *lhs, NSURL *rhs) {
        NSDate *leftDate = nil;
        NSDate *rightDate = nil;
        [lhs getResourceValue:&leftDate forKey:NSURLContentModificationDateKey error:nil];
        [rhs getResourceValue:&rightDate forKey:NSURLContentModificationDateKey error:nil];
        return [(rightDate ?: NSDate.distantPast) compare:(leftDate ?: NSDate.distantPast)];
    }];

    NSUInteger kept = 0;
    for (NSURL *file in files) {
        if ([file.path isEqualToString:currentPath] || kept < kMihomoDiagnosticFileLimit) {
            kept += 1;
            continue;
        }
        [fileManager removeItemAtURL:file error:nil];
    }
}

- (NSString *)prepareMihomoLogForHomeDir:(NSString *)homeDir
                                launchID:(NSString *)launchID {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *logDirectory = [homeDir stringByAppendingPathComponent:@".mihomo_core_logs"];
    NSError *directoryError = nil;
    if (![fileManager createDirectoryAtPath:logDirectory
                withIntermediateDirectories:YES
                                 attributes:@{NSFilePosixPermissions: @(0755)}
                                      error:&directoryError]) {
        NSLog(@"[mihomo_core] Failed creating diagnostic directory: %@",
              directoryError.localizedDescription);
    }

    NSString *uniqueLogPath = [logDirectory
        stringByAppendingPathComponent:[NSString stringWithFormat:@"mihomo-%@.log", launchID]];
    [fileManager createFileAtPath:uniqueLogPath
                        contents:[NSData data]
                      attributes:@{NSFilePosixPermissions: @(0644)}];

    NSString *stableLogPath = [homeDir stringByAppendingPathComponent:@".mihomo_core.log"];
    [fileManager removeItemAtPath:stableLogPath error:nil];
    NSError *linkError = nil;
    if (![fileManager linkItemAtPath:uniqueLogPath toPath:stableLogPath error:&linkError]) {
        NSLog(@"[mihomo_core] Failed linking active log to diagnostic log: %@",
              linkError.localizedDescription);
        [fileManager removeItemAtPath:uniqueLogPath error:nil];
        [fileManager createFileAtPath:stableLogPath
                            contents:[NSData data]
                          attributes:@{NSFilePosixPermissions: @(0644)}];
        uniqueLogPath = stableLogPath;
    }

    [self pruneMihomoDiagnosticDirectory:logDirectory keepingPath:uniqueLogPath];
    return uniqueLogPath;
}

- (NSArray<NSNumber *> *)mihomoProcessIDsMatchingBinaryPath:(NSString *)binaryPath
                                                 configPath:(NSString *)configPath
                                                    homeDir:(NSString *)homeDir {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/ps"];
    task.arguments = @[@"-axww", @"-o", @"pid=,args="];

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        NSLog(@"mihomo cleanup ps failed: %@", error.localizedDescription);
        return @[];
    }

    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    NSMutableArray<NSNumber *> *pids = [NSMutableArray array];
    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];

    for (NSString *line in [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:whitespace];
        if (trimmed.length == 0) {
            continue;
        }

        NSScanner *scanner = [NSScanner scannerWithString:trimmed];
        int pid = 0;
        if (![scanner scanInt:&pid] || pid <= 0) {
            continue;
        }

        NSString *args = [trimmed substringFromIndex:scanner.scanLocation];
        BOOL matchesClashFXCore = [args containsString:binaryPath] &&
            [args containsString:@" -f "] &&
            [args containsString:configPath] &&
            [args containsString:@" -d "] &&
            [args containsString:homeDir];
        if (matchesClashFXCore) {
            [pids addObject:@(pid)];
        }
    }

    return pids;
}

- (BOOL)isProcessRunning:(pid_t)pid {
    return kill(pid, 0) == 0;
}

- (void)terminateMihomoTask:(NSTask *)task completion:(dispatch_block_t)completion {
    if (!(task && task.isRunning)) {
        dispatch_async(dispatch_get_main_queue(), completion);
        return;
    }

    pid_t pid = task.processIdentifier;
    [task terminate];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kMihomoGracefulStopTimeout];
        while (task.isRunning && [deadline timeIntervalSinceNow] > 0) {
            usleep(100 * 1000);
        }

        if (task.isRunning) {
            NSLog(@"[mihomo_core] Graceful stop timed out; force killing pid %d", pid);
            kill(pid, SIGKILL);
        }
        [task waitUntilExit];

        dispatch_async(dispatch_get_main_queue(), completion);
    });
}

- (void)cleanupMihomoCoreWithBinaryPath:(NSString *)binaryPath
                             configPath:(NSString *)configPath
                                homeDir:(NSString *)homeDir
                                  reply:(stringReplyBlock)reply {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray<NSNumber *> *pids = [self mihomoProcessIDsMatchingBinaryPath:binaryPath
                                                                  configPath:configPath
                                                                     homeDir:homeDir];
        for (NSNumber *pidNumber in pids) {
            pid_t pid = pidNumber.intValue;
            kill(pid, SIGTERM);
        }

        [NSThread sleepForTimeInterval:1.0];

        NSSet<NSNumber *> *stillMatchedPids = [NSSet setWithArray:[self mihomoProcessIDsMatchingBinaryPath:binaryPath
                                                                                                configPath:configPath
                                                                                                   homeDir:homeDir]];

        for (NSNumber *pidNumber in pids) {
            pid_t pid = pidNumber.intValue;
            if ([stillMatchedPids containsObject:pidNumber] && [self isProcessRunning:pid]) {
                kill(pid, SIGKILL);
            }
        }

        if (pids.count > 0) {
            NSLog(@"Cleaned up %lu ClashFX mihomo_core process(es)", (unsigned long)pids.count);
        }
        reply(nil);
    });
}

- (void)run {
    [self.listener resume];
    self.checkTimer =
    [NSTimer timerWithTimeInterval:kInitialConnectionGracePeriod
                            target:self
                          selector:@selector(connectionCheckOnLaunch)
                          userInfo:nil
                           repeats:NO];
    [[NSRunLoop currentRunLoop] addTimer:self.checkTimer forMode:NSDefaultRunLoopMode];
    while (!self.shouldQuit) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2.0]];
    }
}

- (void)connectionCheckOnLaunch {
    if (self.connections.count == 0 && !(self.mihomoTask && self.mihomoTask.isRunning)) {
        self.shouldQuit = YES;
    }
}

- (void)cancelIdleExit {
    void (^cancel)(void) = ^{
        [self.idleExitTimer invalidate];
        self.idleExitTimer = nil;
    };
    if (NSThread.isMainThread) {
        cancel();
    } else {
        dispatch_sync(dispatch_get_main_queue(), cancel);
    }
}

- (void)scheduleIdleExitIfNeeded {
    dispatch_block_t schedule = ^{
        [self.idleExitTimer invalidate];
        __weak ProxyConfigHelper *weakSelf = self;
        self.idleExitTimer =
        [NSTimer scheduledTimerWithTimeInterval:kIdleExitGracePeriod
                                        repeats:NO
                                          block:^(NSTimer *timer) {
            ProxyConfigHelper *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            strongSelf.idleExitTimer = nil;
            if (strongSelf.connections.count == 0 &&
                !(strongSelf.mihomoTask && strongSelf.mihomoTask.isRunning)) {
                NSLog(@"Helper idle grace elapsed; exiting");
                strongSelf.shouldQuit = YES;
            }
        }];
    };
    if (NSThread.isMainThread) {
        schedule();
    } else {
        dispatch_async(dispatch_get_main_queue(), schedule);
    }
}

- (BOOL)connectionIsValid: (NSXPCConnection *)connection {
    pid_t pid = connection.processIdentifier;
    NSString *requirementString = [self authorizedClientRequirement];
    if (requirementString.length == 0) {
        NSLog(@"Rejected XPC client because helper has no authorized client requirement");
        return NO;
    }

    NSString *authorizedBundleIdentifier = [self authorizedClientBundleIdentifierFromRequirement:requirementString];
    char executablePathBuffer[PROC_PIDPATHINFO_MAXSIZE] = {0};
    int executablePathLength = proc_pidpath(pid, executablePathBuffer, sizeof(executablePathBuffer));
    if (executablePathLength <= 0) {
        NSLog(@"Rejected XPC client because executable path lookup failed for pid %d", pid);
        return NO;
    }

    NSString *executablePath = [[NSFileManager defaultManager]
        stringWithFileSystemRepresentation:executablePathBuffer
                                    length:strnlen(executablePathBuffer, sizeof(executablePathBuffer))];
    NSURL *executableURL = [NSURL fileURLWithPath:executablePath];
    NSURL *bundleURL = [[[executableURL URLByDeletingLastPathComponent]
        URLByDeletingLastPathComponent] URLByDeletingLastPathComponent];
    NSBundle *clientBundle = [NSBundle bundleWithURL:bundleURL];

    BOOL hasExpectedBundleLayout =
        [bundleURL.pathExtension caseInsensitiveCompare:@"app"] == NSOrderedSame &&
        [executableURL.lastPathComponent isEqualToString:@"ClashFX"] &&
        [executableURL.path hasPrefix:
            [bundleURL.path stringByAppendingPathComponent:@"Contents/MacOS/"]];
    if (authorizedBundleIdentifier.length == 0 ||
        !hasExpectedBundleLayout ||
        ![clientBundle.bundleIdentifier isEqualToString:authorizedBundleIdentifier]) {
        NSLog(@"Rejected XPC client with pid %d, bundle id %@, executable %@",
              pid, clientBundle.bundleIdentifier, executablePath);
        return NO;
    }

    SecCodeRef code = NULL;
    NSDictionary *attributes = @{(__bridge NSString *)kSecGuestAttributePid: @(pid)};
    OSStatus status = SecCodeCopyGuestWithAttributes(NULL,
                                                    (__bridge CFDictionaryRef)attributes,
                                                    kSecCSDefaultFlags,
                                                    &code);
    if (status != errSecSuccess || code == NULL) {
        NSLog(@"Rejected XPC client because code lookup failed: %d", status);
        return NO;
    }

    SecRequirementRef requirement = NULL;
    status = SecRequirementCreateWithString((__bridge CFStringRef)requirementString,
                                            kSecCSDefaultFlags,
                                            &requirement);
    if (status != errSecSuccess || requirement == NULL) {
        NSLog(@"Rejected XPC client because requirement creation failed: %d", status);
        CFRelease(code);
        return NO;
    }

    status = SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement);
    CFRelease(requirement);
    CFRelease(code);

    if (status != errSecSuccess) {
        // Ad-hoc signing fallback: SMAuthorizedClients requires a Developer ID
        // certificate (subject.OU = MEWHFZ92DY), which ad-hoc signed builds
        // cannot satisfy. Bundle ID was already validated above; accept the
        // connection if the executable matches a ClashFX .app bundle.
        // TODO(#65): remove once releases ship with a Developer ID signature.
        if (hasExpectedBundleLayout) {
            NSLog(@"Allowing XPC client with ad-hoc signature (pid=%d, bundle=%@)",
                  pid, clientBundle.bundleIdentifier);
            return YES;
        }
        NSLog(@"Rejected XPC client because code signature validation failed: %d", status);
        return NO;
    }

    return YES;
}

- (NSString *)authorizedClientRequirement {
    NSArray *authorizedClients = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"SMAuthorizedClients"];
    if (![authorizedClients isKindOfClass:[NSArray class]] || authorizedClients.count == 0) {
        return nil;
    }
    NSString *requirement = authorizedClients.firstObject;
    if (![requirement isKindOfClass:[NSString class]]) {
        return nil;
    }
    return requirement;
}

- (NSString *)authorizedClientBundleIdentifierFromRequirement:(NSString *)requirement {
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"identifier\\s+\\\"([^\\\"]+)\\\""
                                                                           options:0
                                                                             error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:requirement
                                                    options:0
                                                      range:NSMakeRange(0, requirement.length)];
    if (match.numberOfRanges < 2) {
        return nil;
    }
    NSRange range = [match rangeAtIndex:1];
    if (range.location == NSNotFound) {
        return nil;
    }
    return [requirement substringWithRange:range];
}

// MARK: - NSXPCListenerDelegate

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection {
    if (![self connectionIsValid:newConnection]) {
        return NO;
    }
    newConnection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(ProxyConfigRemoteProcessProtocol)];
    newConnection.exportedObject = self;
    __weak NSXPCConnection *weakConnection = newConnection;
    __weak ProxyConfigHelper *weakSelf = self;
    newConnection.invalidationHandler = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            ProxyConfigHelper *strongSelf = weakSelf;
            NSXPCConnection *strongConnection = weakConnection;
            if (!strongSelf) {
                return;
            }
            if (strongConnection) {
                [strongSelf.connections removeObject:strongConnection];
            }
            if (strongSelf.connections.count == 0) {
                [strongSelf scheduleIdleExitIfNeeded];
            }
        });
    };
    [self cancelIdleExit];
    void (^registerConnection)(void) = ^{
        [self.connections addObject:newConnection];
    };
    if (NSThread.isMainThread) {
        registerConnection();
    } else {
        dispatch_sync(dispatch_get_main_queue(), registerConnection);
    }
    [newConnection resume];
    return YES;
}

// MARK: - ProxyConfigRemoteProcessProtocol
- (void)getVersion:(stringReplyBlock)reply {
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (version == nil) {
        version = @"unknown";
    }
    reply(version);
}

- (void)getProtocolVersion:(uintReplyBlock)reply {
    reply(CLASHFX_HELPER_PROTOCOL_VERSION);
}

- (void)getMihomoCoreStatusWithReply:(dictReplyBlock)reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTask *task = self.mihomoTask;
        NSMutableDictionary *status = [NSMutableDictionary dictionary];
        status[@"running"] = @(task && task.isRunning);
        status[@"pid"] = @(self.mihomoProcessID);
        if (self.mihomoLaunchID.length > 0) {
            status[@"launchID"] = self.mihomoLaunchID;
        }
        if (self.mihomoLogPath.length > 0) {
            status[@"logPath"] = self.mihomoLogPath;
            NSDictionary *attributes = [[NSFileManager defaultManager]
                attributesOfItemAtPath:self.mihomoLogPath
                                 error:nil];
            status[@"logBytes"] = attributes[NSFileSize] ?: @0;
        }
        if (self.mihomoLaunchDate) {
            status[@"startedAt"] = @([self.mihomoLaunchDate timeIntervalSince1970]);
        }
        if (self.mihomoLastTerminationSummary.length > 0) {
            status[@"lastTermination"] = self.mihomoLastTerminationSummary;
        }
        reply(status);
    });
}

- (void)captureMihomoCoreDiagnosticWithReason:(NSString *)reason
                                        reply:(stringReplyBlock)reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTask *task = self.mihomoTask;
        if (!(task && task.isRunning)) {
            NSString *summary = self.mihomoLastTerminationSummary ?: @"none";
            reply([NSString stringWithFormat:@"error: core is not running; last termination=%@", summary]);
            return;
        }

        pid_t pid = task.processIdentifier;
        NSString *launchID = self.mihomoLaunchID ?: @"unknown";
        NSString *homeDir = self.mihomoHomeDir;
        NSString *coreLogPath = self.mihomoLogPath;
        NSString *diagnosticReason = reason.length > 0 ? reason : @"unspecified";
        NSString *diagnosticID = [self newMihomoLaunchID];

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSString *logDirectory = [homeDir stringByAppendingPathComponent:@".mihomo_core_logs"];
            [[NSFileManager defaultManager] createDirectoryAtPath:logDirectory
                                      withIntermediateDirectories:YES
                                                       attributes:@{NSFilePosixPermissions: @(0755)}
                                                            error:nil];
            NSString *samplePath = [logDirectory
                stringByAppendingPathComponent:[NSString stringWithFormat:
                    @"mihomo-%@-diagnostic-%@.sample.txt",
                    launchID,
                    diagnosticID]];

            BOOL sampled = RunTaskWithTimeout(
                @"/usr/bin/sample",
                @[
                    [NSString stringWithFormat:@"%d", pid],
                    @"2",
                    @"1",
                    @"-file",
                    samplePath
                ],
                6.0
            );
            NSString *context = [NSString stringWithFormat:
                @"ClashFX core diagnostic: reason=%@ pid=%d launch=%@ sampled=%@",
                diagnosticReason,
                pid,
                launchID,
                sampled ? @"yes" : @"no"];
            AppendLineToFile(samplePath, context);
            AppendLineToFile(
                coreLogPath,
                [NSString stringWithFormat:
                    @"[ClashFX Helper] captured core diagnostic reason=%@ sample=%@ result=%@",
                    diagnosticReason,
                    samplePath,
                    sampled ? @"success" : @"failed"]
            );
            NSLog(@"[mihomo_core] Captured core diagnostic for pid %d at %@ (success=%@)",
                  pid,
                  samplePath,
                  sampled ? @"yes" : @"no");
            [self pruneMihomoDiagnosticDirectory:logDirectory keepingPath:samplePath];
            reply(sampled
                ? samplePath
                : [NSString stringWithFormat:@"error: sample failed; diagnostic=%@", samplePath]);
        });
    });
}

- (void)restartMihomoCoreHostWithReply:(stringReplyBlock)reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTask *task = self.mihomoTask;
        self.mihomoTask = nil;
        [self terminateMihomoTask:task completion:^{
            NSLog(@"[mihomo_core] Restarting helper host after an external-core startup failure");
            reply(nil);
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                dispatch_get_main_queue(),
                ^{
                    self.shouldQuit = YES;
                }
            );
        }];
    });
}

- (void)enableProxyWithPort:(int)port
          socksPort:(int)socksPort
            pac:(NSString *)pac
            filterInterface:(BOOL)filterInterface
                 ignoreList:(NSArray<NSString *>*)ignoreList
            error:(stringReplyBlock)reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        ProxySettingTool *tool = [ProxySettingTool new];
        [tool enableProxyWithport:port socksPort:socksPort pacUrl:pac filterInterface:filterInterface ignoreList:ignoreList];
        reply(nil);
    });
}

- (void)disableProxyWithFilterInterface:(BOOL)filterInterface reply:(stringReplyBlock)reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        ProxySettingTool *tool = [ProxySettingTool new];
        [tool disableProxyWithfilterInterface:filterInterface];
        reply(nil);
    });
}


- (void)restoreProxyWithCurrentPort:(int)port
                          socksPort:(int)socksPort
                               info:(NSDictionary *)dict
                    filterInterface:(BOOL)filterInterface
                              error:(stringReplyBlock)reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        ProxySettingTool *tool = [ProxySettingTool new];
        [tool restoreProxySetting:dict currentPort:port currentSocksPort:socksPort filterInterface:filterInterface];
        reply(nil);
    });
}

- (void)getCurrentProxySetting:(dictReplyBlock)reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *info = [ProxySettingTool currentProxySettings];
        reply(info);
    });
}

- (void)startMihomoCoreWithBinaryPath:(NSString *)binaryPath
                           configPath:(NSString *)configPath
                              homeDir:(NSString *)homeDir
                                reply:(stringReplyBlock)reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.mihomoTask && self.mihomoTask.isRunning) {
            NSTask *staleTask = self.mihomoTask;
            self.mihomoTask = nil;
            [self terminateMihomoTask:staleTask completion:^{
                [self launchMihomoCoreWithBinaryPath:binaryPath
                                          configPath:configPath
                                             homeDir:homeDir
                                               reply:reply];
            }];
            return;
        }

        [self launchMihomoCoreWithBinaryPath:binaryPath
                                  configPath:configPath
                                     homeDir:homeDir
                                       reply:reply];
    });
}

- (void)launchMihomoCoreWithBinaryPath:(NSString *)binaryPath
                            configPath:(NSString *)configPath
                               homeDir:(NSString *)homeDir
                                 reply:(stringReplyBlock)reply {
    if (![[NSFileManager defaultManager] fileExistsAtPath:binaryPath]) {
        reply([NSString stringWithFormat:@"Binary not found: %@", binaryPath]);
        return;
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:binaryPath];
    task.arguments = @[@"-f", configPath, @"-d", homeDir];

    NSString *launchID = [self newMihomoLaunchID];
    NSString *logPath = [self prepareMihomoLogForHomeDir:homeDir launchID:launchID];
    NSDate *launchDate = [NSDate date];
    self.mihomoLaunchID = launchID;
    self.mihomoLogPath = logPath;
    self.mihomoHomeDir = homeDir;
    self.mihomoLaunchDate = launchDate;
    self.mihomoProcessID = 0;
    self.mihomoLastTerminationSummary = nil;

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;

    NSFileHandle *logHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (logHandle) {
        int flags = fcntl(logHandle.fileDescriptor, F_GETFL);
        if (flags >= 0) {
            (void)fcntl(logHandle.fileDescriptor, F_SETFL, flags | O_APPEND);
        }
    }
    __block BOOL didReportTruncation = NO;

    pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = [handle availableData];
        if (data.length == 0) {
            handle.readabilityHandler = nil;
            [logHandle closeFile];
            return;
        }

        unsigned long long offset = logHandle.offsetInFile;
        if (offset < kMihomoCoreLogMaximumBytes) {
            NSUInteger available = (NSUInteger)MIN(
                (unsigned long long)data.length,
                kMihomoCoreLogMaximumBytes - offset
            );
            if (available > 0) {
                [logHandle writeData:[data subdataWithRange:NSMakeRange(0, available)]];
            }
        }

        if (!didReportTruncation &&
            offset + data.length > kMihomoCoreLogMaximumBytes) {
            didReportTruncation = YES;
            NSLog(@"[mihomo_core] Log capped at %llu bytes to prevent a core error loop from exhausting resources",
                  kMihomoCoreLogMaximumBytes);
        }
    };

    __weak ProxyConfigHelper *weakSelf = self;
    task.terminationHandler = ^(NSTask *finishedTask) {
        NSString *reason = finishedTask.terminationReason == NSTaskTerminationReasonUncaughtSignal
            ? @"signal"
            : @"exit";
        NSTimeInterval duration = [[NSDate date] timeIntervalSinceDate:launchDate];
        NSString *summary = [NSString stringWithFormat:
            @"launch=%@ pid=%d reason=%@ status=%d duration=%.3fs log=%@",
            launchID,
            finishedTask.processIdentifier,
            reason,
            finishedTask.terminationStatus,
            duration,
            logPath];
        AppendLineToFile(
            logPath,
            [NSString stringWithFormat:@"[ClashFX Helper] terminated %@", summary]
        );
        NSLog(@"[mihomo_core] Process terminated %@", summary);

        dispatch_async(dispatch_get_main_queue(), ^{
            ProxyConfigHelper *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            if ([strongSelf.mihomoLaunchID isEqualToString:launchID]) {
                strongSelf.mihomoLastTerminationSummary = summary;
            }
            if (strongSelf.mihomoTask == finishedTask) {
                strongSelf.mihomoTask = nil;
            }
        });
    };

    NSError *error = nil;
    [task launchAndReturnError:&error];
    if (error) {
        pipe.fileHandleForReading.readabilityHandler = nil;
        [logHandle closeFile];
        NSString *summary = [NSString stringWithFormat:
            @"launch=%@ failed before start: %@",
            launchID,
            error.localizedDescription];
        self.mihomoLastTerminationSummary = summary;
        AppendLineToFile(logPath, [NSString stringWithFormat:@"[ClashFX Helper] %@", summary]);
        reply([NSString stringWithFormat:@"Launch failed: %@", error.localizedDescription]);
        return;
    }

    self.mihomoTask = task;
    self.mihomoProcessID = task.processIdentifier;
    AppendLineToFile(
        logPath,
        [NSString stringWithFormat:
            @"[ClashFX Helper] launched id=%@ pid=%d binary=%@ config=%@ home=%@",
            launchID,
            task.processIdentifier,
            binaryPath,
            configPath,
            homeDir]
    );
    NSLog(@"[mihomo_core] Launched id=%@ pid=%d log=%@",
          launchID,
          task.processIdentifier,
          logPath);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!task.isRunning) {
            NSLog(@"[mihomo_core] Process %@ pid %d exited within 1s with status: %d",
                  launchID,
                  task.processIdentifier,
                  task.terminationStatus);
        } else {
            NSDictionary *attributes = [[NSFileManager defaultManager]
                attributesOfItemAtPath:logPath
                                 error:nil];
            NSLog(@"[mihomo_core] Process %@ pid %d still running after 1s, log bytes=%@",
                  launchID,
                  task.processIdentifier,
                  attributes[NSFileSize] ?: @0);
        }
    });

    reply(nil);
}

- (void)stopMihomoCoreWithReply:(stringReplyBlock)reply {
    NSTask *task = self.mihomoTask;
    self.mihomoTask = nil;
    [self terminateMihomoTask:task completion:^{
        reply(nil);
    }];
}

// MARK: - DNS

- (void)overrideDNSWithServers:(NSArray<NSString *> *)servers
               filterInterface:(BOOL)filterInterface
                         reply:(stringReplyBlock)reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        ProxySettingTool *tool = [ProxySettingTool new];
        [tool overrideDNSWithServers:servers filterInterface:filterInterface];
        reply(nil);
    });
}

- (void)restoreDNSWithSavedInfo:(NSDictionary *)savedInfo
                filterInterface:(BOOL)filterInterface
                          reply:(stringReplyBlock)reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        ProxySettingTool *tool = [ProxySettingTool new];
        [tool restoreDNS:savedInfo filterInterface:filterInterface];
        reply(nil);
    });
}

- (void)getCurrentDNSSetting:(dictReplyBlock)reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *info = [ProxySettingTool currentDNSSettings];
        reply(info);
    });
}

- (void)flushDNSCacheWithReply:(stringReplyBlock)reply {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL flushSucceeded = RunTaskWithTimeout(
            @"/usr/bin/dscacheutil",
            @[@"-flushcache"],
            kDNSCacheCommandTimeout
        );
        BOOL hupSucceeded = RunTaskWithTimeout(
            @"/usr/bin/killall",
            @[@"-HUP", @"mDNSResponder"],
            kDNSCacheCommandTimeout
        );

        if (flushSucceeded && hupSucceeded) {
            reply(nil);
        } else {
            reply(@"DNS cache refresh timed out or failed");
        }
    });
}

@end
