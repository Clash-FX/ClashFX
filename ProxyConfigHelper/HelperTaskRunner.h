// Bounded NSTask execution shared by the helper and its focused tests.

#import <Foundation/Foundation.h>
#import <errno.h>
#import <fcntl.h>
#import <math.h>
#import <poll.h>
#import <signal.h>
#import <stdint.h>
#import <unistd.h>

static const NSTimeInterval kClashFXTaskTerminateGrace = 0.05;
static const NSTimeInterval kClashFXTaskKillReapTimeout = 0.20;

static inline void ClashFXDrainTaskPipe(int fileDescriptor,
                                        NSMutableData *capturedOutput,
                                        NSUInteger maximumOutputBytes,
                                        BOOL *reachedEOF,
                                        BOOL *exceededOutputLimit,
                                        BOOL *readFailed) {
    uint8_t buffer[4096];
    while (!*reachedEOF && !*exceededOutputLimit && !*readFailed) {
        ssize_t count = read(fileDescriptor, buffer, sizeof(buffer));
        if (count > 0) {
            if (capturedOutput.length + (NSUInteger)count > maximumOutputBytes) {
                *exceededOutputLimit = YES;
                return;
            }
            [capturedOutput appendBytes:buffer length:(NSUInteger)count];
            continue;
        }
        if (count == 0) {
            *reachedEOF = YES;
            return;
        }
        if (errno == EINTR) {
            continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            return;
        }
        *readFailed = YES;
    }
}

static inline void ClashFXWaitForTaskExit(NSTask *task, NSTimeInterval timeout) {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    while (task.isRunning && NSProcessInfo.processInfo.systemUptime < deadline) {
        usleep(10 * 1000);
    }
}

// deadline is an absolute NSProcessInfo.systemUptime value. Captured output is
// read nonblocking, so a child that keeps a pipe open cannot strand its caller.
// All post-timeout termination and exit checks are bounded; this never calls
// waitUntilExit.
static inline BOOL ClashFXRunTaskUntilDeadline(NSTask *task,
                                              NSTimeInterval deadline,
                                              BOOL captureStandardOutput,
                                              NSUInteger maximumOutputBytes,
                                              NSData **capturedOutput,
                                              NSString **failure) {
    if (capturedOutput) {
        *capturedOutput = [NSData data];
    }
    if (failure) {
        *failure = nil;
    }
    if (NSProcessInfo.processInfo.systemUptime >= deadline) {
        if (failure) {
            *failure = @"deadline elapsed before launch";
        }
        return NO;
    }

    NSPipe *pipe = captureStandardOutput ? [NSPipe pipe] : nil;
    task.standardOutput = pipe ?: [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        if (failure) {
            *failure = launchError.localizedDescription ?: @"process launch failed";
        }
        return NO;
    }

    int fileDescriptor = -1;
    NSMutableData *output = [NSMutableData data];
    BOOL reachedEOF = !captureStandardOutput;
    BOOL exceededOutputLimit = NO;
    BOOL readFailed = NO;
    if (captureStandardOutput) {
        fileDescriptor = pipe.fileHandleForReading.fileDescriptor;
        int flags = fcntl(fileDescriptor, F_GETFL);
        if (flags < 0 || fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) < 0) {
            readFailed = YES;
        }
    }

    BOOL timedOut = NO;
    while (!readFailed && !exceededOutputLimit) {
        if (captureStandardOutput) {
            ClashFXDrainTaskPipe(fileDescriptor,
                                 output,
                                 maximumOutputBytes,
                                 &reachedEOF,
                                 &exceededOutputLimit,
                                 &readFailed);
        }
        if (readFailed || exceededOutputLimit) {
            break;
        }
        if (!task.isRunning && reachedEOF) {
            break;
        }

        NSTimeInterval remaining = deadline - NSProcessInfo.processInfo.systemUptime;
        if (remaining <= 0) {
            timedOut = YES;
            break;
        }

        int waitMilliseconds = (int)MIN(50.0, MAX(1.0, ceil(remaining * 1000.0)));
        if (captureStandardOutput && !reachedEOF) {
            struct pollfd pollDescriptor = {fileDescriptor, POLLIN | POLLHUP | POLLERR, 0};
            (void)poll(&pollDescriptor, 1, waitMilliseconds);
        } else {
            usleep((useconds_t)waitMilliseconds * 1000);
        }
    }

    if (timedOut || readFailed || exceededOutputLimit) {
        if (task.isRunning) {
            [task terminate];
            ClashFXWaitForTaskExit(task, kClashFXTaskTerminateGrace);
        }
        if (task.isRunning) {
            (void)kill(task.processIdentifier, SIGKILL);
            ClashFXWaitForTaskExit(task, kClashFXTaskKillReapTimeout);
        }
    }

    BOOL exitConfirmed = !task.isRunning;
    if (captureStandardOutput && !reachedEOF && fileDescriptor >= 0 && !readFailed) {
        ClashFXDrainTaskPipe(fileDescriptor,
                             output,
                             maximumOutputBytes,
                             &reachedEOF,
                             &exceededOutputLimit,
                             &readFailed);
    }
    if (captureStandardOutput) {
        [pipe.fileHandleForReading closeFile];
    }
    if (capturedOutput) {
        *capturedOutput = [output copy];
    }

    NSString *failureReason = nil;
    if (!exitConfirmed) {
        failureReason = @"process exit was not confirmed after SIGKILL";
    } else if (timedOut) {
        failureReason = @"process or pipe read exceeded its deadline";
    } else if (readFailed) {
        failureReason = @"failed reading process output";
    } else if (exceededOutputLimit) {
        failureReason = @"process output exceeded its limit";
    } else if (captureStandardOutput && !reachedEOF) {
        failureReason = @"process output pipe did not reach EOF before its deadline";
    } else if (task.terminationStatus != 0) {
        failureReason = [NSString stringWithFormat:@"process exited with status %d", task.terminationStatus];
    }

    if (failure) {
        *failure = failureReason;
    }
    return failureReason == nil;
}
