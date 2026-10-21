#import <XCTest/XCTest.h>
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <poll.h>
#import <signal.h>
#import <string.h>
#import <netinet/in.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <sys/socket.h>
#import <unistd.h>
#import "../ProxyConfigHelper/HelperTaskRunner.h"
#import "../ProxyConfigHelper/CoreSocketOwnership.h"
#import "../ProxyConfigHelper/ProxyConfigHelper.h"
#import "../ProxyConfigHelper/ProxyConfigRemoteProcessProtocol.h"
#import "../ProxyConfigHelper/ProxySettingTool.h"
#import "../ProxyConfigHelper/ProxySettingDNSPolicy.h"
#import "../ProxyConfigHelper/ProxyConfigHelperTrustPolicy.h"

@interface ProxySettingTool (DNSFailurePropagationTests)
- (nullable NSString *)applySCNetworkSettingWithRef:(NSString *(^)(SCPreferencesRef ref))callback;
- (void)localAuth;
@end

@interface ProxyConfigHelperTrustPolicyTests : XCTestCase
@end

@implementation ProxyConfigHelperTrustPolicyTests

- (void)testAdHocClientRequiresExactPinnedCDHashAndExpectedBundle {
    NSString *clientHash = @"0123456789abcdef0123456789abcdef01234567";
    XCTAssertFalse(ClashFXTrustPolicyCanAuthorizeClient(
        NO, YES, YES, YES, ClashFXHelperClientBundleIdentifier, clientHash, nil
    ));
    XCTAssertFalse(ClashFXTrustPolicyCanAuthorizeClient(
        NO, YES, YES, YES, ClashFXHelperClientBundleIdentifier, clientHash,
        @"0123456789abcdef0123456789abcdef01234568"
    ));
    XCTAssertFalse(ClashFXTrustPolicyCanAuthorizeClient(
        NO, YES, YES, NO, ClashFXHelperClientBundleIdentifier, clientHash, clientHash
    ));
    XCTAssertTrue(ClashFXTrustPolicyCanAuthorizeClient(
        NO, YES, YES, YES, ClashFXHelperClientBundleIdentifier, clientHash, clientHash
    ));
    XCTAssertFalse(ClashFXTrustPolicyCanAuthorizeClient(
        NO, NO, YES, YES, ClashFXHelperClientBundleIdentifier, clientHash, clientHash
    ));
}

- (void)testDeveloperIDRequirementRemainsAuthoritative {
    XCTAssertTrue(ClashFXTrustPolicyCanAuthorizeClient(
        YES, YES, NO, YES, ClashFXHelperClientBundleIdentifier, nil, nil
    ));
    XCTAssertFalse(ClashFXTrustPolicyCanAuthorizeClient(
        NO, NO, NO, YES, ClashFXHelperClientBundleIdentifier, nil, nil
    ));
    XCTAssertFalse(ClashFXTrustPolicyCanAuthorizeClient(
        YES, YES, NO, YES, @"com.example.other", nil, nil
    ));
}

- (void)testTrustFileMetadataRequiresRootOwnershipReadOnlyModeAndImmutableFlag {
    XCTAssertTrue(ClashFXTrustPolicyIsSafeRootOwnedImmutableFile(
        0, 0, S_IFREG | S_IRUSR | S_IXUSR, UF_IMMUTABLE, YES
    ));
    XCTAssertFalse(ClashFXTrustPolicyIsSafeRootOwnedImmutableFile(
        501, 0, S_IFREG | S_IRUSR | S_IXUSR, UF_IMMUTABLE, YES
    ));
    XCTAssertFalse(ClashFXTrustPolicyIsSafeRootOwnedImmutableFile(
        0, 20, S_IFREG | S_IRUSR | S_IXUSR, UF_IMMUTABLE, YES
    ));
    XCTAssertFalse(ClashFXTrustPolicyIsSafeRootOwnedImmutableFile(
        0, 0, S_IFREG | S_IRUSR | S_IWUSR | S_IXUSR, UF_IMMUTABLE, YES
    ));
    XCTAssertFalse(ClashFXTrustPolicyIsSafeRootOwnedImmutableFile(
        0, 0, S_IFREG | S_IRUSR | S_IXUSR, 0, YES
    ));
    XCTAssertTrue(ClashFXTrustPolicyIsSafeRootOwnedDirectory(
        0, 0, S_IFDIR | S_IRUSR | S_IWUSR | S_IXUSR | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH
    ));
    XCTAssertFalse(ClashFXTrustPolicyIsSafeRootOwnedDirectory(
        0, 0, S_IFDIR | S_IRUSR | S_IWUSR | S_IXUSR | S_IWOTH
    ));
    XCTAssertFalse(ClashFXTrustPolicyIsSafeRootOwnedDirectory(
        0, 20, S_IFDIR | S_IRUSR | S_IWUSR | S_IXUSR
    ));
}

@end

@interface DNSFailingProxySettingTool : ProxySettingTool
@property (nonatomic, copy) NSString *injectedPreferencesError;
@property (nonatomic, assign) BOOL didInvokePreferencesCallback;
@end

@implementation DNSFailingProxySettingTool

- (void)localAuth {
    // Keep these tests independent of authorization and the live preferences store.
}

- (nullable NSString *)applySCNetworkSettingWithRef:(NSString *(^)(SCPreferencesRef ref))callback {
    if (self.injectedPreferencesError) {
        return self.injectedPreferencesError;
    }
    self.didInvokePreferencesCallback = YES;
    return callback(NULL);
}

@end

@interface DNSXPCCodecStub : NSObject
@property (nonatomic, copy) NSDictionary *snapshot;
@property (nonatomic, copy) NSDictionary *receivedApplySnapshot;
@property (nonatomic, copy) NSDictionary *receivedRestoreSnapshot;
@property (nonatomic, copy) NSArray<NSString *> *receivedApplyServers;
@end

@implementation DNSXPCCodecStub

- (void)captureDNSWithFilterInterface:(BOOL)filterInterface reply:(dictReplyBlock)reply {
    (void)filterInterface;
    reply(self.snapshot);
}

- (void)applyDNSWithSnapshot:(NSDictionary *)snapshot
                     servers:(NSArray<NSString *> *)servers
                       reply:(stringReplyBlock)reply {
    self.receivedApplySnapshot = snapshot;
    self.receivedApplyServers = servers;
    reply(nil);
}

- (void)restoreDNSWithSavedInfo:(NSDictionary *)savedInfo
                filterInterface:(BOOL)filterInterface
                          reply:(stringReplyBlock)reply {
    (void)filterInterface;
    self.receivedRestoreSnapshot = savedInfo;
    reply(nil);
}

- (void)getCurrentDNSSetting:(dictReplyBlock)reply {
    reply(self.snapshot);
}

@end

@interface DNSXPCCodecListenerDelegate : NSObject <NSXPCListenerDelegate>
@property (nonatomic, strong) DNSXPCCodecStub *stub;
@property (nonatomic, strong) NSXPCConnection *acceptedConnection;
@end

@implementation DNSXPCCodecListenerDelegate

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection {
    (void)listener;
    NSXPCInterface *interface = [NSXPCInterface interfaceWithProtocol:@protocol(ProxyConfigRemoteProcessProtocol)];
    ClashFXConfigureHelperXPCInterface(interface);
    newConnection.exportedInterface = interface;
    newConnection.exportedObject = self.stub;
    self.acceptedConnection = newConnection;
    [newConnection resume];
    return YES;
}

@end

@interface ProxyConfigHelper (HelperTaskRunnerTests)
- (instancetype)initForTesting;
- (void)getMihomoCoreStatusWithReply:(dictReplyBlock)reply;
- (void)restoreDNSWithSavedInfo:(NSDictionary *)savedInfo
                filterInterface:(BOOL)filterInterface
                          reply:(stringReplyBlock)reply;
- (void)terminateMihomoTask:(NSTask *)task
                   launchID:(NSString *)launchID
                 completion:(stringReplyBlock)completion;
- (BOOL)isMihomoTaskExitConfirmed:(NSTask *)task;
- (NSArray<NSNumber *> *)listeningPortsForPID:(pid_t)pid
                                     protocol:(NSString *)protocol
                                     deadline:(NSTimeInterval)deadline;
- (NSArray<NSString *> *)mihomoArgumentsFromKernelBuffer:(NSData *)data;
- (BOOL)mihomoArguments:(NSArray<NSString *> *)arguments
      matchExpectedHome:(NSString *)expectedHome
    expectedBinaryPath:(NSString *)expectedBinaryPath;
- (BOOL)managedMihomoTaskMatchesCleanupHome:(NSString *)expectedHome;
- (void)stopManagedMihomoTaskForCleanupAtHome:(NSString *)expectedHome
                                   completion:(stringReplyBlock)completion;
- (NSArray<NSNumber *> *)mihomoProcessIDsMatchingBinaryPath:(NSString *)binaryPath
                                                 configPath:(NSString *)configPath
                                                    homeDir:(NSString *)homeDir;
@end

static void AppendTestCString(NSMutableData *data, NSString *value) {
    const char *bytes = value.UTF8String;
    [data appendBytes:bytes length:strlen(bytes) + 1];
}

@interface SlowSocketProbeHelper : ProxyConfigHelper
@property (atomic, assign) BOOL probeRunning;
@property (atomic, assign) BOOL probeShouldFail;
@property (atomic, assign) NSTimeInterval probeDelay;
@property (atomic, assign) NSUInteger probeCount;
@property (atomic, assign) BOOL forceExitUnconfirmed;
@end

@implementation SlowSocketProbeHelper

- (instancetype)init {
    return [super initForTesting];
}

- (NSArray<NSNumber *> *)listeningPortsForPID:(pid_t)pid
                                     protocol:(NSString *)protocol
                                     deadline:(NSTimeInterval)deadline {
    self.probeCount += 1;
    self.probeRunning = YES;
    NSTimeInterval delay = self.probeDelay;
    if (delay > 0) {
        usleep((useconds_t)(delay * 1000000.0));
    }
    self.probeRunning = NO;
    return self.probeShouldFail ? nil : @[];
}

- (BOOL)isMihomoTaskExitConfirmed:(NSTask *)task {
    return self.forceExitUnconfirmed ? NO : [super isMihomoTaskExitConfirmed:task];
}

@end

@interface HelperTaskRunnerTests : XCTestCase
@property (nonatomic, strong) NSTask *temporaryCoreTask;
@property (nonatomic, strong) NSMutableArray<NSTask *> *temporaryScanTasks;
@property (nonatomic, strong) NSMutableArray<NSPipe *> *temporaryScanPipes;
- (void)stopTemporaryTask:(NSTask *)task;
@end

@implementation HelperTaskRunnerTests

- (NSTask *)launchTemporarySleepTaskIgnoringTERM:(BOOL)ignoreTERM {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    task.arguments = @[
        @"-c",
        ignoreTERM
            ? @"trap '' TERM; printf ready; exec /bin/sleep 20"
            : @"exec /bin/sleep 20"
    ];
    NSError *error = nil;
    XCTAssertTrue([task launchAndReturnError:&error], @"%@", error.localizedDescription);
    return task;
}

- (NSTask *)launchTERMResistantSleepTaskAndWaitUntilReady {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    task.arguments = @[@"-c", @"trap '' TERM; printf ready; exec /bin/sleep 20"];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        XCTFail(@"temporary TERM-resistant task failed to launch: %@", error.localizedDescription);
        return task;
    }

    int fileDescriptor = pipe.fileHandleForReading.fileDescriptor;
    int flags = fcntl(fileDescriptor, F_GETFL);
    BOOL readReady = flags >= 0 && fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0;
    NSMutableData *readyData = [NSMutableData data];
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 2.0;
    while (readReady && readyData.length < 5 && task.isRunning) {
        NSTimeInterval remaining = deadline - NSProcessInfo.processInfo.systemUptime;
        if (remaining <= 0) {
            break;
        }
        struct pollfd pollDescriptor = {fileDescriptor, POLLIN | POLLHUP | POLLERR, 0};
        int waitMilliseconds = (int)MIN(100.0, MAX(1.0, ceil(remaining * 1000.0)));
        int pollResult = poll(&pollDescriptor, 1, waitMilliseconds);
        if (pollResult < 0 && errno == EINTR) {
            continue;
        }
        if (pollResult < 0) {
            break;
        }
        uint8_t buffer[5];
        ssize_t count = read(fileDescriptor, buffer, sizeof(buffer));
        if (count > 0) {
            [readyData appendBytes:buffer length:(NSUInteger)count];
        } else if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            break;
        } else if (count == 0) {
            break;
        }
    }

    NSString *readyToken = [[NSString alloc] initWithData:readyData encoding:NSUTF8StringEncoding];
    BOOL didBecomeTERMResistant = [readyToken isEqualToString:@"ready"];
    if (!didBecomeTERMResistant) {
        [self stopTemporaryTask:task];
        XCTFail(@"temporary task did not publish its TERM-resistant ready barrier");
    }
    [pipe.fileHandleForReading closeFile];
    return task;
}

- (SlowSocketProbeHelper *)helperWithRunningTemporaryTask:(NSTask *)task
                                                 launchID:(NSString *)launchID {
    SlowSocketProbeHelper *helper = [[SlowSocketProbeHelper alloc] init];
    [helper setValue:task forKey:@"mihomoTask"];
    [helper setValue:launchID forKey:@"mihomoLaunchID"];
    [helper setValue:@(task.processIdentifier) forKey:@"mihomoProcessID"];
    return helper;
}

- (void)stopTemporaryTask:(NSTask *)task {
    if (!task.isRunning) {
        return;
    }
    [task terminate];
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 0.5;
    while (task.isRunning && NSProcessInfo.processInfo.systemUptime < deadline) {
        usleep(10 * 1000);
    }
    if (task.isRunning) {
        (void)kill(task.processIdentifier, SIGKILL);
        deadline = NSProcessInfo.processInfo.systemUptime + 0.5;
        while (task.isRunning && NSProcessInfo.processInfo.systemUptime < deadline) {
            usleep(10 * 1000);
        }
    }
}

- (void)tearDown {
    [self stopTemporaryTask:self.temporaryCoreTask];
    for (NSTask *task in self.temporaryScanTasks) {
        [self stopTemporaryTask:task];
    }
    for (NSPipe *pipe in self.temporaryScanPipes) {
        [pipe.fileHandleForWriting closeFile];
    }
    [super tearDown];
}

- (NSTask *)launchScannerFixtureWithHome:(NSString *)home configPath:(NSString *)configPath {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    task.arguments = @[
        @"-c",
        @"trap 'exit 0' TERM; while IFS= read -r line; do :; done",
        @"mihomo-fixture",
        @"-f", configPath,
        @"-d", home
    ];
    NSPipe *inputPipe = [NSPipe pipe];
    task.standardInput = inputPipe;
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        XCTFail(@"temporary process-scanner fixture failed to launch: %@", error.localizedDescription);
        return task;
    }
    if (!self.temporaryScanTasks) {
        self.temporaryScanTasks = [NSMutableArray array];
        self.temporaryScanPipes = [NSMutableArray array];
    }
    [self.temporaryScanTasks addObject:task];
    [self.temporaryScanPipes addObject:inputPipe];
    return task;
}

- (void)testKernelArgvParserUsesBoundedNullTerminatedEntries {
    NSString *home = @"/tmp/Clash FX Home";
    NSString *config = [home stringByAppendingPathComponent:
        @".enhanced_config.12345678-1234-1234-1234-123456789abc.yaml"];
    NSArray<NSString *> *expected = @[@"/opt/mihomo", @"-f", config, @"-d", home];
    NSMutableData *kernelBuffer = [NSMutableData data];
    int argc = (int)expected.count;
    [kernelBuffer appendBytes:&argc length:sizeof(argc)];
    AppendTestCString(kernelBuffer, @"/opt/mihomo");
    const char padding = '\0';
    [kernelBuffer appendBytes:&padding length:1];
    for (NSString *argument in expected) {
        AppendTestCString(kernelBuffer, argument);
    }

    ProxyConfigHelper *helper = [[ProxyConfigHelper alloc] initForTesting];
    XCTAssertEqualObjects([helper mihomoArgumentsFromKernelBuffer:kernelBuffer], expected);

    NSMutableData *truncated = [kernelBuffer mutableCopy];
    [truncated setLength:truncated.length - 1];
    XCTAssertNil([helper mihomoArgumentsFromKernelBuffer:truncated]);

    int invalidArgc = INT_MAX;
    NSMutableData *invalidCount = [NSMutableData dataWithBytes:&invalidArgc length:sizeof(invalidArgc)];
    AppendTestCString(invalidCount, @"/opt/mihomo");
    XCTAssertNil([helper mihomoArgumentsFromKernelBuffer:invalidCount]);
}

- (void)testMihomoArgvOwnershipRequiresExactUniqueHomeAndConfigOptions {
    ProxyConfigHelper *helper = [[ProxyConfigHelper alloc] initForTesting];
    NSString *home = @"/tmp/Clash FX Home";
    NSString *config = [home stringByAppendingPathComponent:
        @".enhanced_config.12345678-1234-1234-1234-123456789abc.yaml"];
    NSString *protectedBinary = @"/Library/PrivilegedHelperTools/com.clashfx.app.Helper.mihomo_core";
    NSArray<NSString *> *fullPathArguments = @[protectedBinary, @"-f", config, @"-d", home];
    XCTAssertTrue([helper mihomoArguments:fullPathArguments
                         matchExpectedHome:home
                       expectedBinaryPath:protectedBinary]);

    NSArray<NSString *> *protectedBasenameArguments = @[
        protectedBinary.lastPathComponent, @"-d", home, @"-f", config
    ];
    XCTAssertTrue([helper mihomoArguments:protectedBasenameArguments
                         matchExpectedHome:home
                       expectedBinaryPath:protectedBinary]);

    NSString *bundledBinary = @"/Applications/ClashFX.app/Contents/Resources/mihomo_core";
    NSArray<NSString *> *bundledBasenameArguments = @[@"mihomo_core", @"-f", config, @"-d", home];
    XCTAssertTrue([helper mihomoArguments:bundledBasenameArguments
                         matchExpectedHome:home
                       expectedBinaryPath:bundledBinary]);

    NSArray<NSString *> *trailingHome = @[protectedBinary, @"-f", config, @"-d", [home stringByAppendingString:@"/"]];
    XCTAssertTrue([helper mihomoArguments:trailingHome matchExpectedHome:home expectedBinaryPath:protectedBinary]);
    NSArray<NSString *> *relativeHome = @[protectedBinary, @"-f", config, @"-d", @"relative/home"];
    XCTAssertFalse([helper mihomoArguments:relativeHome matchExpectedHome:home expectedBinaryPath:protectedBinary]);

    NSArray<NSString *> *wrongArgvZero = @[@"mihomo_core", @"-f", config, @"-d", home];
    XCTAssertFalse([helper mihomoArguments:wrongArgvZero
                          matchExpectedHome:home
                        expectedBinaryPath:protectedBinary]);

    NSArray<NSString *> *wrongHome = @[protectedBinary, @"-d", @"/tmp/Clash FX Home-other", @"-f", config];
    XCTAssertFalse([helper mihomoArguments:wrongHome
                          matchExpectedHome:home
                        expectedBinaryPath:protectedBinary]);
    NSArray<NSString *> *outsideConfig = @[
        protectedBinary, @"-d", home,
        @"-f", @"/tmp/other/.enhanced_config.12345678-1234-1234-1234-123456789abc.yaml"
    ];
    XCTAssertFalse([helper mihomoArguments:outsideConfig
                          matchExpectedHome:home
                        expectedBinaryPath:protectedBinary]);

    NSArray<NSString *> *legacyConfig = @[
        protectedBinary, @"-d", home,
        @"-f", [home stringByAppendingPathComponent:@".enhanced_config.yaml"]
    ];
    XCTAssertFalse([helper mihomoArguments:legacyConfig
                          matchExpectedHome:home
                        expectedBinaryPath:protectedBinary]);

    NSArray<NSString *> *duplicateHome = @[
        protectedBinary, @"-d", home, @"-d", @"/tmp/other", @"-f", config
    ];
    XCTAssertFalse([helper mihomoArguments:duplicateHome
                          matchExpectedHome:home
                        expectedBinaryPath:protectedBinary]);
    NSArray<NSString *> *duplicateConfig = @[
        protectedBinary, @"-d", home, @"-f", config, @"-f", @"/tmp/other/config.yaml"
    ];
    XCTAssertFalse([helper mihomoArguments:duplicateConfig
                          matchExpectedHome:home
                        expectedBinaryPath:protectedBinary]);
}

- (void)testNativeProcessScanFindsOnlyLiveExactArgvFixture {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"Clash FX Scanner %@", NSUUID.UUID.UUIDString]];
    NSString *home = [root stringByAppendingPathComponent:@"home with spaces"];
    NSString *foreignConfig = [root stringByAppendingPathComponent:
        @"outside/.enhanced_config.12345678-1234-1234-1234-123456789abc.yaml"];
    NSError *directoryError = nil;
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:home
                                            withIntermediateDirectories:YES
                                                             attributes:nil
                                                                  error:&directoryError],
                  @"%@", directoryError.localizedDescription);
    home = home.stringByResolvingSymlinksInPath;

    NSString *validConfig = [home stringByAppendingPathComponent:
        @".enhanced_config.12345678-1234-1234-1234-123456789abc.yaml"];
    NSTask *ownedTask = [self launchScannerFixtureWithHome:[home stringByAppendingString:@"/"] configPath:validConfig];
    NSTask *unownedTask = [self launchScannerFixtureWithHome:home configPath:foreignConfig];
    XCTAssertTrue(ownedTask.isRunning);
    XCTAssertTrue(unownedTask.isRunning);

    ProxyConfigHelper *helper = [[ProxyConfigHelper alloc] initForTesting];
    NSString *configPrefix = [home stringByAppendingPathComponent:@".enhanced_config."];
    NSArray<NSNumber *> *pids = [helper mihomoProcessIDsMatchingBinaryPath:@"/bin/sh"
                                                                 configPath:configPrefix
                                                                    homeDir:home];
    XCTAssertNotNil(pids);
    XCTAssertTrue([pids containsObject:@(ownedTask.processIdentifier)]);
    XCTAssertFalse([pids containsObject:@(unownedTask.processIdentifier)]);
}

- (void)testCleanupStopsMatchingManagedTaskAndConfirmsExit {
    self.temporaryCoreTask = [self launchTERMResistantSleepTaskAndWaitUntilReady];
    NSString *home = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"Clash FX Managed Home %@", NSUUID.UUID.UUIDString]];
    NSString *config = [home stringByAppendingPathComponent:
        @".enhanced_config.12345678-1234-1234-1234-123456789abc.yaml"];
    SlowSocketProbeHelper *helper = [self helperWithRunningTemporaryTask:self.temporaryCoreTask
                                                                 launchID:@"launch-cleanup-owned"];
    [helper setValue:ClashFXHelperApprovedCorePath forKey:@"mihomoBinaryPath"];
    [helper setValue:config forKey:@"mihomoConfigPath"];
    [helper setValue:home forKey:@"mihomoHomeDir"];

    XCTAssertTrue([helper managedMihomoTaskMatchesCleanupHome:home]);
    XCTestExpectation *cleanupStopReturned = [self expectationWithDescription:@"cleanup confirms managed task exit"];
    __block NSString *stopError = nil;
    [helper stopManagedMihomoTaskForCleanupAtHome:home completion:^(NSString *error) {
        stopError = error;
        [cleanupStopReturned fulfill];
    }];

    [self waitForExpectations:@[cleanupStopReturned] timeout:3.0];

    XCTAssertNil(stopError);
    XCTAssertFalse(self.temporaryCoreTask.isRunning);
    XCTAssertNil([helper valueForKey:@"mihomoTask"]);
}

- (void)testCleanupDoesNotStopManagedTaskForAnotherHome {
    self.temporaryCoreTask = [self launchTemporarySleepTaskIgnoringTERM:NO];
    NSString *requestedHome = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"Clash FX Requested Home %@", NSUUID.UUID.UUIDString]];
    NSString *managedHome = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"Clash FX Foreign Home %@", NSUUID.UUID.UUIDString]];
    NSString *managedConfig = [managedHome stringByAppendingPathComponent:
        @".enhanced_config.12345678-1234-1234-1234-123456789abc.yaml"];
    SlowSocketProbeHelper *helper = [self helperWithRunningTemporaryTask:self.temporaryCoreTask
                                                                 launchID:@"launch-cleanup-foreign"];
    [helper setValue:ClashFXHelperApprovedCorePath forKey:@"mihomoBinaryPath"];
    [helper setValue:managedConfig forKey:@"mihomoConfigPath"];
    [helper setValue:managedHome forKey:@"mihomoHomeDir"];

    XCTAssertFalse([helper managedMihomoTaskMatchesCleanupHome:requestedHome]);
    XCTestExpectation *cleanupSkippedTask = [self expectationWithDescription:@"cleanup leaves another home running"];
    [helper stopManagedMihomoTaskForCleanupAtHome:requestedHome completion:^(NSString *error) {
        XCTAssertNil(error);
        [cleanupSkippedTask fulfill];
    }];
    [self waitForExpectations:@[cleanupSkippedTask] timeout:0.5];

    XCTAssertTrue(self.temporaryCoreTask.isRunning);
    XCTAssertEqual([helper valueForKey:@"mihomoTask"], self.temporaryCoreTask);
}

- (void)testPipeReadDeadlineTerminatesAndReapsSleepingTask {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    task.arguments = @[@"-c", @"printf ready; exec /bin/sleep 20"];
    NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
    NSData *output = nil;
    NSString *failure = nil;

    BOOL succeeded = ClashFXRunTaskUntilDeadline(
        task,
        start + 0.20,
        YES,
        1024,
        &output,
        &failure
    );

    NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - start;
    XCTAssertFalse(succeeded);
    XCTAssertTrue([failure containsString:@"deadline"]);
    XCTAssertEqualObjects([[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding], @"ready");
    XCTAssertLessThan(elapsed, 1.0);
    XCTAssertFalse(task.isRunning, @"a timed out pipe read must leave no running child after bounded signaling");
    XCTAssertEqual(task.terminationReason, NSTaskTerminationReasonUncaughtSignal);
}

- (void)testManagedStopEscalatesTERMResistantTaskAndConfirmsExit {
    self.temporaryCoreTask = [self launchTERMResistantSleepTaskAndWaitUntilReady];
    SlowSocketProbeHelper *helper = [self helperWithRunningTemporaryTask:self.temporaryCoreTask
                                                                 launchID:@"launch-stop"];
    XCTestExpectation *stopReturned = [self expectationWithDescription:@"managed stop returned"];
    __block NSString *stopError = nil;

    [helper terminateMihomoTask:self.temporaryCoreTask
                       launchID:@"launch-stop"
                     completion:^(NSString *error) {
        stopError = error;
        [stopReturned fulfill];
    }];

    [self waitForExpectations:@[stopReturned] timeout:3.0];

    XCTAssertNil(stopError);
    XCTAssertFalse(self.temporaryCoreTask.isRunning);
    XCTAssertNil([helper valueForKey:@"mihomoTask"]);
    XCTAssertEqual(self.temporaryCoreTask.terminationReason, NSTaskTerminationReasonUncaughtSignal);
    XCTAssertEqual(self.temporaryCoreTask.terminationStatus, SIGKILL);
}

- (void)testStaleLaunchStopReturnsErrorWithoutSignalingCurrentTask {
    self.temporaryCoreTask = [self launchTemporarySleepTaskIgnoringTERM:NO];
    SlowSocketProbeHelper *helper = [self helperWithRunningTemporaryTask:self.temporaryCoreTask
                                                                 launchID:@"launch-current"];
    XCTestExpectation *stopReturned = [self expectationWithDescription:@"stale stop rejected"];
    __block NSString *stopError = nil;

    [helper terminateMihomoTask:self.temporaryCoreTask
                       launchID:@"launch-old"
                     completion:^(NSString *error) {
        stopError = error;
        [stopReturned fulfill];
    }];

    [self waitForExpectations:@[stopReturned] timeout:0.5];

    XCTAssertTrue([stopError containsString:@"stale"]);
    XCTAssertTrue(self.temporaryCoreTask.isRunning, @"a stale launch request must not signal the current task");
    XCTAssertEqual([helper valueForKey:@"mihomoTask"], self.temporaryCoreTask);
}

- (void)testUnconfirmedExitReturnsErrorAndRetainsTaskOwner {
    self.temporaryCoreTask = [self launchTERMResistantSleepTaskAndWaitUntilReady];
    SlowSocketProbeHelper *helper = [self helperWithRunningTemporaryTask:self.temporaryCoreTask
                                                                 launchID:@"launch-unconfirmed"];
    helper.forceExitUnconfirmed = YES;
    XCTestExpectation *stopReturned = [self expectationWithDescription:@"unconfirmed stop failed safely"];
    __block NSString *stopError = nil;

    [helper terminateMihomoTask:self.temporaryCoreTask
                       launchID:@"launch-unconfirmed"
                     completion:^(NSString *error) {
        stopError = error;
        [stopReturned fulfill];
    }];

    [self waitForExpectations:@[stopReturned] timeout:3.0];

    XCTAssertTrue([stopError containsString:@"did not exit after SIGKILL"]);
    XCTAssertEqual([helper valueForKey:@"mihomoTask"], self.temporaryCoreTask);
    XCTAssertFalse(self.temporaryCoreTask.isRunning, @"test seam reports unconfirmed reap after the real child was killed");
}

- (void)testSlowSocketProbeLeavesMainQueueServiceableAndRejectsStaleLaunchResults {
    self.temporaryCoreTask = [self launchTemporarySleepTaskIgnoringTERM:NO];
    SlowSocketProbeHelper *helper = [self helperWithRunningTemporaryTask:self.temporaryCoreTask
                                                                 launchID:@"launch-old"];
    helper.probeDelay = 0.35;
    XCTestExpectation *mainQueueServiced = [self expectationWithDescription:@"main queue serviced during native socket probe"];
    XCTestExpectation *statusReturned = [self expectationWithDescription:@"status callback returned"];
    XCTestExpectation *concurrentStatusReturned = [self expectationWithDescription:@"concurrent status returned without another probe"];
    __block BOOL mainQueueServicedDuringProbe = NO;
    __block NSDictionary *status = nil;
    __block NSDictionary *concurrentStatus = nil;

    [helper getMihomoCoreStatusWithReply:^(NSDictionary *value) {
        status = value;
        [statusReturned fulfill];
    }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        mainQueueServicedDuringProbe = helper.probeRunning;
        [helper setValue:@"launch-new" forKey:@"mihomoLaunchID"];
        [helper setValue:@(self.temporaryCoreTask.processIdentifier + 1) forKey:@"mihomoProcessID"];
        [helper getMihomoCoreStatusWithReply:^(NSDictionary *value) {
            concurrentStatus = value;
            [concurrentStatusReturned fulfill];
        }];
        [mainQueueServiced fulfill];
    });

    [self waitForExpectations:@[mainQueueServiced, statusReturned, concurrentStatusReturned] timeout:2.0];

    XCTAssertTrue(mainQueueServicedDuringProbe);
    XCTAssertEqual(helper.probeCount, 2u, @"one TCP and one UDP subprocess should cover both status requests");
    XCTAssertEqualObjects(status[@"launchID"], @"launch-old");
    XCTAssertEqualObjects(status[@"pid"], @(self.temporaryCoreTask.processIdentifier));
    XCTAssertEqualObjects(status[@"tcpListenPorts"], @[]);
    XCTAssertEqualObjects(status[@"udpListenPorts"], @[]);
    XCTAssertEqualObjects(status[@"tcpListenPortsState"], @"unknown");
    XCTAssertEqualObjects(status[@"udpListenPortsState"], @"unknown");
    XCTAssertEqualObjects(concurrentStatus[@"tcpListenPortsState"], @"unknown");
    XCTAssertEqualObjects(concurrentStatus[@"udpListenPortsState"], @"unknown");
}

- (void)testLegacyLsofPortParserStillRejectsConnectedUDPPeerPorts {
    NSArray<NSNumber *> *ports = ClashFXListeningPortsFromLsofOutput(
        @"n127.0.0.1:53\nn127.0.0.1:53000->8.8.8.8:53\nn[::1]:5353\n"
    );
    XCTAssertEqualObjects(ports, (@[@53, @5353]));
}

- (void)testDNSCaptureSnapshotKeepsAbsentServiceJSONRepresentable {
    NSDictionary *snapshot = ClashFXDNSCaptureSnapshot(
        @"transaction-1",
        @{@"service-with-dns": @{@"ServerAddresses": @[@"10.0.0.1"], @"SearchDomains": @[@"corp"]},
          @"service-without-dns": [NSNull null]}
    );
    XCTAssertEqualObjects(snapshot[@"version"], @2);
    XCTAssertEqualObjects(snapshot[@"transactionID"], @"transaction-1");
    XCTAssertTrue([NSJSONSerialization isValidJSONObject:snapshot]);
    NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
    NSDictionary *decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    XCTAssertEqualObjects(decoded[@"services"][@"service-without-dns"],
                          @{@"original": [NSNull null]});
    XCTAssertEqualObjects(ClashFXDNSOriginalFromSnapshotEntry(
        decoded[@"services"][@"service-with-dns"]),
        (@{@"ServerAddresses": @[@"10.0.0.1"], @"SearchDomains": @[@"corp"]}));
    XCTAssertEqualObjects(ClashFXDNSOriginalFromSnapshotEntry(
        decoded[@"services"][@"service-without-dns"]), [NSNull null]);

    NSMutableDictionary *reapplySnapshot = [snapshot mutableCopy];
    reapplySnapshot[@"services"] = @{
        @"current-service": @{@"original": [NSNull null]},
        @"prior-service-only-for-restore": @{@"original": @{@"ServerAddresses": @[@"10.0.0.2"]}}
    };
    reapplySnapshot[@"applyServiceIDs"] = @[@"current-service"];
    XCTAssertEqualObjects(ClashFXDNSApplyServiceIDs(reapplySnapshot), @[@"current-service"]);
    reapplySnapshot[@"applyServiceIDs"] = @[@"new-uncaptured-service"];
    XCTAssertNil(ClashFXDNSApplyServiceIDs(reapplySnapshot));
}

- (void)testHelperXPCAllowedClassesRoundTripDNSNullAndNestedSnapshots {
    NSDictionary *snapshot = @{
        @"version": @2,
        @"transactionID": @"xpc-transaction",
        @"expectedServers": ClashFXTUNDNSServers(),
        @"applyServiceIDs": @[@"wifi-service"],
        @"services": @{
            @"wifi-service": @{@"original": [NSNull null]},
            @"ethernet-service": @{
                @"original": @{
                    @"ServerAddresses": @[@"10.0.0.1"],
                    @"SearchDomains": @[@"corp.example"]
                }
            }
        }
    };
    DNSXPCCodecStub *stub = [DNSXPCCodecStub new];
    stub.snapshot = snapshot;
    DNSXPCCodecListenerDelegate *delegate = [DNSXPCCodecListenerDelegate new];
    delegate.stub = stub;

    NSXPCListener *listener = [NSXPCListener anonymousListener];
    listener.delegate = delegate;
    [listener resume];

    NSXPCConnection *connection = [[NSXPCConnection alloc] initWithListenerEndpoint:listener.endpoint];
    NSXPCInterface *remoteInterface = [NSXPCInterface interfaceWithProtocol:@protocol(ProxyConfigRemoteProcessProtocol)];
    ClashFXConfigureHelperXPCInterface(remoteInterface);
    connection.remoteObjectInterface = remoteInterface;
    [connection resume];
    id<ProxyConfigRemoteProcessProtocol> remote = (id<ProxyConfigRemoteProcessProtocol>)[connection remoteObjectProxy];

    XCTestExpectation *roundTripFinished = [self expectationWithDescription:@"nested DNS snapshot crossed anonymous NSXPC"];
    __block NSDictionary *capturedSnapshot = nil;
    __block NSDictionary *oldCurrentDNSReply = nil;
    [remote captureDNSWithFilterInterface:NO reply:^(NSDictionary *captured) {
        capturedSnapshot = captured;
        XCTAssertEqualObjects(capturedSnapshot, snapshot);
        [remote applyDNSWithSnapshot:snapshot servers:ClashFXTUNDNSServers() reply:^(NSString *applyError) {
            XCTAssertNil(applyError);
            XCTAssertEqualObjects(stub.receivedApplySnapshot, snapshot);
            XCTAssertEqualObjects(stub.receivedApplyServers, ClashFXTUNDNSServers());
            [remote restoreDNSWithSavedInfo:snapshot filterInterface:NO reply:^(NSString *restoreError) {
                XCTAssertNil(restoreError);
                XCTAssertEqualObjects(stub.receivedRestoreSnapshot, snapshot);
                [remote getCurrentDNSSetting:^(NSDictionary *currentDNS) {
                    oldCurrentDNSReply = currentDNS;
                    XCTAssertEqualObjects(oldCurrentDNSReply, snapshot);
                    [roundTripFinished fulfill];
                }];
            }];
        }];
    }];

    [self waitForExpectations:@[roundTripFinished] timeout:3.0];
    [connection invalidate];
    [listener invalidate];
}

- (void)testDNSApplyAcceptsOriginalOrPriorAppStateAndPreservesOtherFields {
    NSDictionary *original = @{
        @"ServerAddresses": @[@"10.1.0.1"],
        @"SearchDomains": @[@"corp.example"],
        @"DomainName": @"corp.example"
    };
    NSArray<NSString *> *tunServers = ClashFXTUNDNSServers();
    NSDictionary *applied = ClashFXDNSSettingsByReplacingServers(original, tunServers);

    XCTAssertTrue(ClashFXDNSCurrentMatchesOriginalOrApplied(original, original, tunServers));
    XCTAssertTrue(ClashFXDNSCurrentMatchesOriginalOrApplied(applied, original, tunServers));
    XCTAssertEqualObjects(applied[@"ServerAddresses"], tunServers);
    XCTAssertEqualObjects(applied[@"SearchDomains"], original[@"SearchDomains"]);
    XCTAssertEqualObjects(applied[@"DomainName"], original[@"DomainName"]);

    NSMutableDictionary *externallyChanged = [applied mutableCopy];
    externallyChanged[@"SearchDomains"] = @[@"external.example"];
    XCTAssertFalse(ClashFXDNSCurrentMatchesOriginalOrApplied(externallyChanged, original, tunServers));
}

- (void)testDNSRestoreRequiresOwnedServersAndExpectedPreservedFields {
    NSDictionary *original = @{
        @"ServerAddresses": @[@"10.1.0.1"],
        @"SearchDomains": @[@"corp.example"]
    };
    NSArray<NSString *> *tunServers = ClashFXTUNDNSServers();
    NSDictionary *applied = ClashFXDNSSettingsByReplacingServers(original, tunServers);
    XCTAssertEqual(ClashFXDNSRestoreDecisionForCurrent(applied, original, tunServers),
                   ClashFXDNSRestoreDecisionRestoreDictionary);
    XCTAssertEqual(ClashFXDNSRestoreDecisionForCurrent(original, original, tunServers),
                   ClashFXDNSRestoreDecisionAlreadyRestored);

    NSDictionary *absentApplied = ClashFXDNSSettingsByReplacingServers([NSNull null], tunServers);
    XCTAssertEqual(ClashFXDNSRestoreDecisionForCurrent(absentApplied, [NSNull null], tunServers),
                   ClashFXDNSRestoreDecisionRemovePath);
    XCTAssertEqual(ClashFXDNSRestoreDecisionForCurrent([NSNull null], [NSNull null], tunServers),
                   ClashFXDNSRestoreDecisionAlreadyRestored);

    NSMutableDictionary *externalChange = [applied mutableCopy];
    externalChange[@"SearchDomains"] = @[@"external.example"];
    XCTAssertEqual(ClashFXDNSRestoreDecisionForCurrent(externalChange, original, tunServers),
                   ClashFXDNSRestoreDecisionOwnershipChanged);
    XCTAssertEqual(ClashFXDNSRestoreDecisionForCurrent(applied, original, @[@"9.9.9.9"]),
                   ClashFXDNSRestoreDecisionOwnershipChanged);
    NSDictionary *userChangedServers = @{
        @"ServerAddresses": @[@"8.8.8.8"],
        @"SearchDomains": @[@"corp.example"]
    };
    XCTAssertEqual(ClashFXDNSRestoreDecisionForCurrent(userChangedServers, original, tunServers),
                   ClashFXDNSRestoreDecisionDetached);
    XCTAssertEqual(ClashFXDNSRestoreDecisionForCurrent(externalChange, original, tunServers),
                   ClashFXDNSRestoreDecisionOwnershipChanged);
    XCTAssertTrue(ClashFXDNSLegacyCurrentIsOwned(
        @{@"ServerAddresses": tunServers}, original));
    XCTAssertFalse(ClashFXDNSLegacyCurrentIsOwned(externalChange, original));
}

- (void)testDNSRestoreFenceTracksWritesAndAllowsFreshHelperJournal {
    XCTAssertTrue(ClashFXDNSRestoreMatchesLatestWrite(nil, @"journal-1"));
    XCTAssertTrue(ClashFXDNSRestoreMatchesLatestWrite(@"journal-1", @"journal-1"));
    XCTAssertFalse(ClashFXDNSRestoreMatchesLatestWrite(@"newer-write", @"older-journal"));
    NSDictionary *pending = @{@"transactionID": @"pending-B", @"previousTransactionIDs": @[@"applied-A"]};
    XCTAssertTrue(ClashFXDNSRestoreSnapshotMatchesLatestWrite(@"applied-A", pending));
    XCTAssertTrue(ClashFXDNSRestoreSnapshotMatchesLatestWrite(@"pending-B", pending));
    XCTAssertFalse(ClashFXDNSRestoreSnapshotMatchesLatestWrite(@"later-C", pending));
    XCTAssertFalse(ClashFXDNSRestoreSnapshotMatchesLatestWrite(@"applied-A",
        @{@"transactionID": @"pending-B", @"previousTransactionIDs": @[@"applied-A", @42]}));
}

- (void)testDNSOperationsPropagateInjectedPreferencesFailuresWithoutWriting {
    DNSFailingProxySettingTool *tool = [DNSFailingProxySettingTool new];
    tool.injectedPreferencesError = @"injected SCPreferencesApplyChanges failure";
    NSArray<NSString *> *tunServers = ClashFXTUNDNSServers();
    NSDictionary *original = @{
        @"ServerAddresses": @[@"10.0.0.1"],
        @"SearchDomains": @[@"corp.example"]
    };
    NSDictionary *snapshot = @{
        @"version": @2,
        @"transactionID": @"transaction-1",
        @"expectedServers": tunServers,
        @"applyServiceIDs": @[@"service-1"],
        @"services": @{@"service-1": @{@"original": original}}
    };

    XCTAssertEqualObjects([tool overrideDNSWithServers:tunServers filterInterface:YES],
                          tool.injectedPreferencesError);
    XCTAssertFalse(tool.didInvokePreferencesCallback);
    XCTAssertEqualObjects([tool applyDNSWithSnapshot:snapshot servers:tunServers],
                          tool.injectedPreferencesError);
    XCTAssertFalse(tool.didInvokePreferencesCallback);
    XCTAssertEqualObjects([tool restoreDNS:snapshot filterInterface:YES],
                          tool.injectedPreferencesError);
    XCTAssertFalse(tool.didInvokePreferencesCallback);
    XCTAssertEqualObjects([tool restoreDNS:@{@"service-1": original} filterInterface:YES],
                          tool.injectedPreferencesError);
    XCTAssertFalse(tool.didInvokePreferencesCallback);

    NSDictionary *futureSnapshot = @{
        @"version": @3,
        @"transactionID": @"future-transaction",
        @"services": @{@"service-1": @{@"original": original}}
    };
    XCTAssertEqualObjects([tool restoreDNS:futureSnapshot filterInterface:YES],
                          @"Unsupported DNS snapshot version");
    XCTAssertFalse(tool.didInvokePreferencesCallback);

    NSDictionary *metadataWithoutVersion = @{
        @"transactionID": @"unversioned-transaction",
        @"services": @{@"service-1": @{@"original": original}}
    };
    XCTAssertEqualObjects([tool restoreDNS:metadataWithoutVersion filterInterface:YES],
                          @"DNS snapshot metadata requires a version");
    XCTAssertFalse(tool.didInvokePreferencesCallback);
}

- (void)testDNSHelperRPCRejectsFutureSnapshotBeforeCreatingPreferencesTool {
    ProxyConfigHelper *helper = [[ProxyConfigHelper alloc] initForTesting];
    NSDictionary *futureSnapshot = @{
        @"version": @3,
        @"transactionID": @"future-transaction",
        @"services": @{@"service-1": @{@"original": [NSNull null]}}
    };
    XCTestExpectation *restoreReturned = [self expectationWithDescription:@"future DNS version rejected"];
    __block NSString *restoreError = nil;
    [helper restoreDNSWithSavedInfo:futureSnapshot
                    filterInterface:YES
                              reply:^(NSString *error) {
        restoreError = error;
        [restoreReturned fulfill];
    }];

    [self waitForExpectations:@[restoreReturned] timeout:1.0];
    XCTAssertEqualObjects(restoreError, @"Unsupported DNS snapshot version");
}

- (void)testNativeSocketInspectionFindsLiveTCPListenerAndBoundUDPPort {
    int tcpSocket = socket(AF_INET, SOCK_STREAM, 0);
    int udpSocket = socket(AF_INET, SOCK_DGRAM, 0);
    XCTAssertGreaterThanOrEqual(tcpSocket, 0);
    XCTAssertGreaterThanOrEqual(udpSocket, 0);
    if (tcpSocket < 0 || udpSocket < 0) {
        if (tcpSocket >= 0) close(tcpSocket);
        if (udpSocket >= 0) close(udpSocket);
        return;
    }

    struct sockaddr_in tcpAddress = {0};
    tcpAddress.sin_len = sizeof(tcpAddress);
    tcpAddress.sin_family = AF_INET;
    tcpAddress.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    XCTAssertEqual(bind(tcpSocket, (struct sockaddr *)&tcpAddress, sizeof(tcpAddress)), 0);
    socklen_t tcpAddressLength = sizeof(tcpAddress);
    XCTAssertEqual(getsockname(tcpSocket, (struct sockaddr *)&tcpAddress, &tcpAddressLength), 0);
    XCTAssertEqual(listen(tcpSocket, 1), 0);

    struct sockaddr_in udpAddress = {0};
    udpAddress.sin_len = sizeof(udpAddress);
    udpAddress.sin_family = AF_INET;
    udpAddress.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    XCTAssertEqual(bind(udpSocket, (struct sockaddr *)&udpAddress, sizeof(udpAddress)), 0);
    socklen_t udpAddressLength = sizeof(udpAddress);
    XCTAssertEqual(getsockname(udpSocket, (struct sockaddr *)&udpAddress, &udpAddressLength), 0);

    int connectedUDP = socket(AF_INET, SOCK_DGRAM, 0);
    XCTAssertGreaterThanOrEqual(connectedUDP, 0);
    struct sockaddr_in connectedAddress = {0};
    connectedAddress.sin_len = sizeof(connectedAddress);
    connectedAddress.sin_family = AF_INET;
    connectedAddress.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    XCTAssertEqual(bind(connectedUDP, (struct sockaddr *)&connectedAddress, sizeof(connectedAddress)), 0);
    socklen_t connectedLength = sizeof(connectedAddress);
    XCTAssertEqual(getsockname(connectedUDP, (struct sockaddr *)&connectedAddress, &connectedLength), 0);
    XCTAssertEqual(connect(connectedUDP, (struct sockaddr *)&udpAddress, sizeof(udpAddress)), 0);

    ProxyConfigHelper *helper = [[ProxyConfigHelper alloc] initForTesting];
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 2.0;
    NSArray<NSNumber *> *tcpPorts = [helper listeningPortsForPID:getpid()
                                                        protocol:@"TCP"
                                                        deadline:deadline];
    NSArray<NSNumber *> *udpPorts = [helper listeningPortsForPID:getpid()
                                                        protocol:@"UDP"
                                                        deadline:deadline];
    XCTAssertNotNil(tcpPorts);
    XCTAssertNotNil(udpPorts);
    XCTAssertTrue([tcpPorts containsObject:@(ntohs(tcpAddress.sin_port))]);
    XCTAssertTrue([udpPorts containsObject:@(ntohs(udpAddress.sin_port))]);
    XCTAssertFalse([udpPorts containsObject:@(ntohs(connectedAddress.sin_port))]);

    close(connectedUDP);
    close(tcpSocket);
    close(udpSocket);
}

- (void)testSuccessfulEmptyPortsAndFailedProbeHaveDifferentStates {
    self.temporaryCoreTask = [self launchTemporarySleepTaskIgnoringTERM:NO];
    SlowSocketProbeHelper *helper = [self helperWithRunningTemporaryTask:self.temporaryCoreTask
                                                                 launchID:@"launch-empty"];
    XCTestExpectation *emptyStatusReturned = [self expectationWithDescription:@"empty port result returned"];
    __block NSDictionary *emptyStatus = nil;
    [helper getMihomoCoreStatusWithReply:^(NSDictionary *value) {
        emptyStatus = value;
        [emptyStatusReturned fulfill];
    }];
    [self waitForExpectations:@[emptyStatusReturned] timeout:1.0];

    XCTAssertEqualObjects(emptyStatus[@"tcpListenPorts"], @[]);
    XCTAssertEqualObjects(emptyStatus[@"udpListenPorts"], @[]);
    XCTAssertEqualObjects(emptyStatus[@"tcpListenPortsState"], @"known");
    XCTAssertEqualObjects(emptyStatus[@"udpListenPortsState"], @"known");

    helper.probeShouldFail = YES;
    [helper setValue:@0 forKey:@"mihomoSocketSnapshotUptime"];
    XCTestExpectation *unknownStatusReturned = [self expectationWithDescription:@"failed port query returned"];
    __block NSDictionary *unknownStatus = nil;
    [helper getMihomoCoreStatusWithReply:^(NSDictionary *value) {
        unknownStatus = value;
        [unknownStatusReturned fulfill];
    }];
    [self waitForExpectations:@[unknownStatusReturned] timeout:1.0];

    XCTAssertEqualObjects(unknownStatus[@"tcpListenPorts"], @[]);
    XCTAssertEqualObjects(unknownStatus[@"udpListenPorts"], @[]);
    XCTAssertEqualObjects(unknownStatus[@"tcpListenPortsState"], @"unknown");
    XCTAssertEqualObjects(unknownStatus[@"udpListenPortsState"], @"unknown");
}

@end
