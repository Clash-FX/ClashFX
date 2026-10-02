#import <XCTest/XCTest.h>
#import <errno.h>
#import <fcntl.h>
#import <poll.h>
#import <signal.h>
#import <unistd.h>
#import "../ProxyConfigHelper/HelperTaskRunner.h"
#import "../ProxyConfigHelper/ProxyConfigHelper.h"
#import "../ProxyConfigHelper/ProxyConfigRemoteProcessProtocol.h"

@interface ProxyConfigHelper (HelperTaskRunnerTests)
- (instancetype)initForTesting;
- (void)getMihomoCoreStatusWithReply:(dictReplyBlock)reply;
- (void)terminateMihomoTask:(NSTask *)task
                   launchID:(NSString *)launchID
                 completion:(stringReplyBlock)completion;
- (BOOL)isMihomoTaskExitConfirmed:(NSTask *)task;
- (NSArray<NSNumber *> *)listeningPortsForPID:(pid_t)pid
                                     protocol:(NSString *)protocol
                                     deadline:(NSTimeInterval)deadline;
@end

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
    [super tearDown];
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
    XCTestExpectation *mainQueueServiced = [self expectationWithDescription:@"main queue serviced during lsof probe"];
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
