//
//  ProxyConfigHelper.m
//  com.clashfx.app.Helper
//
//  Created by yichengchen on 2019/8/17.
//  Copyright © 2019 west2online. All rights reserved.
//

#import "ProxyConfigHelper.h"
#import "HelperTaskRunner.h"
#import "ProxyConfigHelperTrustPolicy.h"
#import "BundleDisplayMetadata.h"
#import <AppKit/AppKit.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <libproc.h>
#import <limits.h>
#import <signal.h>
#import <stdlib.h>
#import <string.h>
#import <sys/proc_info.h>
#import <sys/sysctl.h>
#import <unistd.h>
#import "ProxyConfigRemoteProcessProtocol.h"
#import "ProxySettingTool.h"
#import "ProxySettingDNSPolicy.h"

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
@property (nonatomic, copy) NSString *mihomoConfigPath;
@property (nonatomic, copy) NSString *mihomoBinaryPath;
@property (nonatomic, copy) NSString *mihomoSourceBinaryPath;
@property (nonatomic, strong) NSMutableArray *mihomoLifecycleOperations;
@property (nonatomic, assign) BOOL mihomoLifecycleOperationInFlight;
@property (nonatomic, copy) NSString *mihomoSocketSnapshotLaunchID;
@property (nonatomic, assign) pid_t mihomoSocketSnapshotPID;
@property (nonatomic, copy) NSArray<NSNumber *> *mihomoSocketSnapshotTCPPorts;
@property (nonatomic, copy) NSArray<NSNumber *> *mihomoSocketSnapshotUDPPorts;
@property (nonatomic, assign) NSTimeInterval mihomoSocketSnapshotUptime;
@property (nonatomic, copy) NSString *mihomoSocketQueryID;
@property (nonatomic, assign) BOOL mihomoSocketQueryInFlight;
@property (nonatomic, copy) NSString *latestDNSCaptureTransactionID;
@property (nonatomic, copy) NSString *latestDNSWriteTransactionID;
@property (nonatomic, assign) BOOL latestDNSWriteRestored;

- (void)enqueueMihomoLifecycleOperation:(dispatch_block_t)operation;
- (void)runNextMihomoLifecycleOperation;
- (void)finishMihomoLifecycleOperation;
- (void)terminateMihomoTask:(NSTask *)task
                   launchID:(NSString *)launchID
                 completion:(stringReplyBlock)completion;
- (BOOL)isMihomoTaskExitConfirmed:(NSTask *)task;
- (instancetype)initForTesting;
- (instancetype)initWithListenerEnabled:(BOOL)listenerEnabled;
- (NSArray<NSNumber *> *)listeningPortsForPID:(pid_t)pid
                                     protocol:(NSString *)protocol
                                     deadline:(NSTimeInterval)deadline;
- (NSDictionary *)approvedTrustEntryForClientCDHash:(NSString *)clientCDHash
                                         sourcePath:(NSString *)sourcePath
                                            failure:(NSString **)failure;
- (NSString *)validatedMihomoSourcePath:(NSString *)binaryPath
                                forConnection:(NSXPCConnection *)connection
                     clientCDHashOutput:(NSString **)clientCDHashOutput
                                       failure:(NSString **)failure;
- (NSArray<NSNumber *> *)mihomoProcessIDsMatchingBinaryPaths:(NSArray<NSString *> *)binaryPaths
                                                   configPath:(NSString *)configPath
                                                      homeDir:(NSString *)homeDir;
- (NSArray<NSString *> *)mihomoArgumentsFromKernelBuffer:(NSData *)data;
- (BOOL)mihomoArguments:(NSArray<NSString *> *)arguments
      matchExpectedHome:(NSString *)expectedHome
    expectedBinaryPath:(NSString *)expectedBinaryPath;
- (BOOL)managedMihomoTaskMatchesCleanupHome:(NSString *)expectedHome;
- (void)stopManagedMihomoTaskForCleanupAtHome:(NSString *)expectedHome
                                   completion:(stringReplyBlock)completion;
- (NSArray<NSString *> *)kernelArgumentsForProcessID:(pid_t)pid
                                               exited:(BOOL *)exited
                                              failure:(NSString **)failure;
- (void)launchMihomoCoreWithBinaryPath:(NSString *)binaryPath
                    sourceBinaryPath:(NSString *)sourceBinaryPath
                         clientCDHash:(NSString *)clientCDHash
                            configPath:(NSString *)configPath
                               homeDir:(NSString *)homeDir
                                 reply:(stringReplyBlock)reply;

@end

@implementation ProxyConfigHelper

static const NSTimeInterval kMihomoGracefulStopTimeout = 2.0;
static const NSTimeInterval kMihomoSocketQueryTimeout = 0.30;
static const NSTimeInterval kMihomoSocketKnownCacheLifetime = 2.0;
static const NSTimeInterval kMihomoSocketUnknownCacheLifetime = 0.35;
static const NSUInteger kMihomoSocketMaximumDescriptorCount = 16384;
static const unsigned long long kMihomoCoreLogMaximumBytes = 4 * 1024 * 1024;
static const NSUInteger kMihomoDiagnosticFileLimit = 24;
static const NSTimeInterval kDNSCacheCommandTimeout = 2.0;
static const NSUInteger kMihomoMaxKernelArgumentsSize = 1024 * 1024;
static const NSUInteger kMihomoMaxKernelArgumentCount = 65536;
static const NSUInteger kMihomoMaxProcessCount = 1024 * 1024;
static const NSUInteger kTrustReceiptMaximumBytes = 64 * 1024;
static const uint32_t kAdHocCodeSignatureFlag = 0x2;
// Give a newly launched ClashFX instance enough time to attach before an
// invalidated connection from the previous instance lets the helper exit.
static const NSTimeInterval kIdleExitGracePeriod = 10.0;
// launchd can start the helper well before the original XPC request is
// delivered when the system is under heavy load. Five seconds caused the
// helper to exit cleanly before ClashFX could connect, which in turn made the
// app repeatedly reinstall an already healthy helper.
static const NSTimeInterval kInitialConnectionGracePeriod = 60.0;

static NSString *LowercaseHexString(const unsigned char *bytes, NSUInteger length) {
    if (!bytes || length == 0) {
        return nil;
    }
    NSMutableString *result = [NSMutableString stringWithCapacity:length * 2];
    for (NSUInteger index = 0; index < length; index += 1) {
        [result appendFormat:@"%02x", bytes[index]];
    }
    return result;
}

static NSString *SHA256HexForFileDescriptor(int fileDescriptor) {
    if (fileDescriptor < 0 || lseek(fileDescriptor, 0, SEEK_SET) < 0) {
        return nil;
    }

    CC_SHA256_CTX context;
    if (CC_SHA256_Init(&context) != 1) {
        return nil;
    }
    unsigned char buffer[64 * 1024];
    for (;;) {
        ssize_t count = read(fileDescriptor, buffer, sizeof(buffer));
        if (count == 0) {
            break;
        }
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            return nil;
        }
        if (CC_SHA256_Update(&context, buffer, (CC_LONG)count) != 1) {
            return nil;
        }
    }

    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    if (CC_SHA256_Final(digest, &context) != 1) {
        return nil;
    }
    return LowercaseHexString(digest, sizeof(digest));
}

static NSData *ReadFileDescriptorWithLimit(int fileDescriptor, NSUInteger maximumBytes) {
    if (fileDescriptor < 0 || lseek(fileDescriptor, 0, SEEK_SET) < 0) {
        return nil;
    }

    NSMutableData *data = [NSMutableData data];
    unsigned char buffer[4096];
    for (;;) {
        ssize_t count = read(fileDescriptor, buffer, sizeof(buffer));
        if (count == 0) {
            return data;
        }
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            return nil;
        }
        if ((NSUInteger)count > maximumBytes - data.length) {
            return nil;
        }
        [data appendBytes:buffer length:(NSUInteger)count];
    }
}

static BOOL TrustedCoreDirectoriesHaveSafeOwnership(void) {
    NSArray<NSString *> *directories = @[
        @"/",
        @"/Library",
        @"/Library/PrivilegedHelperTools"
    ];
    for (NSString *path in directories) {
        struct stat info = {0};
        if (lstat(path.fileSystemRepresentation, &info) != 0 ||
            !ClashFXTrustPolicyIsSafeRootOwnedDirectory(info.st_uid, info.st_gid, info.st_mode)) {
            return NO;
        }
    }
    return YES;
}

static void RemoveRootOwnedStagedAppBundle(NSURL *stagedBundleURL);

static NSURL *CreateRootOwnedStagedAppBundle(NSURL *sourceBundleURL, NSString **failure) {
    if (failure) {
        *failure = nil;
    }
    if (!TrustedCoreDirectoriesHaveSafeOwnership() ||
        [sourceBundleURL.pathExtension caseInsensitiveCompare:@"app"] != NSOrderedSame) {
        if (failure) {
            *failure = @"authorized client app bundle path or root staging directory is invalid";
        }
        return nil;
    }

    NSString *stagingRoot = [[ClashFXHelperApprovedCorePath stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:[NSString stringWithFormat:@".clashfx-trust-stage-%@",
                                        NSUUID.UUID.UUIDString.lowercaseString]];
    if (mkdir(stagingRoot.fileSystemRepresentation, S_IRUSR | S_IWUSR | S_IXUSR) != 0 ||
        chown(stagingRoot.fileSystemRepresentation, 0, 0) != 0 ||
        chmod(stagingRoot.fileSystemRepresentation, S_IRUSR | S_IWUSR | S_IXUSR) != 0) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"cannot create root-owned app staging directory: %s",
                        strerror(errno)];
        }
        return nil;
    }

    NSURL *stagedBundleURL = [NSURL fileURLWithPath:
        [stagingRoot stringByAppendingPathComponent:sourceBundleURL.lastPathComponent]
        isDirectory:YES];
    NSError *copyError = nil;
    if (![[NSFileManager defaultManager] copyItemAtURL:sourceBundleURL
                                                 toURL:stagedBundleURL
                                                 error:&copyError]) {
        [[NSFileManager defaultManager] removeItemAtPath:stagingRoot error:nil];
        if (failure) {
            *failure = [NSString stringWithFormat:@"cannot stage authorized client app bundle: %@",
                        copyError.localizedDescription ?: @"copy failed"];
        }
        return nil;
    }

    struct stat stagedBundleInfo = {0};
    if (lstat(stagedBundleURL.fileSystemRepresentation, &stagedBundleInfo) != 0 ||
        !S_ISDIR(stagedBundleInfo.st_mode) ||
        chown(stagedBundleURL.fileSystemRepresentation, 0, 0) != 0 ||
        chmod(stagedBundleURL.fileSystemRepresentation,
              (stagedBundleInfo.st_mode & 07777) & ~(S_IWUSR | S_IWGRP | S_IWOTH)) != 0) {
        RemoveRootOwnedStagedAppBundle(stagedBundleURL);
        if (failure) {
            *failure = @"staged app root is not a root-owned, non-writable directory";
        }
        return nil;
    }

    int displayMetadataError = ClashFXRemoveStagedBundleDisplayMetadata(stagedBundleURL.fileSystemRepresentation);
    if (displayMetadataError != 0) {
        RemoveRootOwnedStagedAppBundle(stagedBundleURL);
        if (failure) {
            *failure = [NSString stringWithFormat:@"cannot normalize staged app display metadata: %s",
                        strerror(displayMetadataError)];
        }
        return nil;
    }

    NSString *stagePrefix = [stagingRoot stringByAppendingString:@"/"];
    __block NSString *treeFailure = nil;
    NSDirectoryEnumerator<NSURL *> *enumerator = [[NSFileManager defaultManager]
        enumeratorAtURL:stagedBundleURL
        includingPropertiesForKeys:nil
        options:0
        errorHandler:^BOOL(NSURL *url, NSError *error) {
            treeFailure = [NSString stringWithFormat:@"cannot inspect staged app item %@: %@",
                           url.path, error.localizedDescription ?: @"unknown error"];
            return NO;
        }];
    for (NSURL *itemURL in enumerator) {
        struct stat info = {0};
        if (lstat(itemURL.fileSystemRepresentation, &info) != 0) {
            treeFailure = [NSString stringWithFormat:@"cannot inspect staged app item %@: %s",
                           itemURL.path, strerror(errno)];
            break;
        }
        if (S_ISLNK(info.st_mode)) {
            NSString *resolvedPath = itemURL.path.stringByResolvingSymlinksInPath;
            if (![resolvedPath hasPrefix:stagePrefix] || lchown(itemURL.fileSystemRepresentation, 0, 0) != 0) {
                treeFailure = @"staged app contains an escaping or untrusted symbolic link";
                break;
            }
            continue;
        }
        if (!S_ISREG(info.st_mode) && !S_ISDIR(info.st_mode)) {
            treeFailure = @"staged app contains a non-file object";
            break;
        }
        displayMetadataError = ClashFXRemoveStagedBundleDisplayMetadata(itemURL.fileSystemRepresentation);
        if (displayMetadataError != 0) {
            treeFailure = [NSString stringWithFormat:@"cannot normalize staged item display metadata: %s",
                           strerror(displayMetadataError)];
            break;
        }
        mode_t mode = info.st_mode & 07777;
        mode &= (mode_t)~(S_IWUSR | S_IWGRP | S_IWOTH);
        if (S_ISDIR(info.st_mode)) {
            mode |= S_IRUSR | S_IXUSR;
        } else {
            mode |= S_IRUSR;
        }
        if (chown(itemURL.fileSystemRepresentation, 0, 0) != 0 ||
            chmod(itemURL.fileSystemRepresentation, mode) != 0) {
            treeFailure = [NSString stringWithFormat:@"cannot lock staged app item %@: %s",
                           itemURL.path, strerror(errno)];
            break;
        }
    }

    struct stat stageInfo = {0};
    if (!treeFailure &&
        (lstat(stagingRoot.fileSystemRepresentation, &stageInfo) != 0 ||
         !S_ISDIR(stageInfo.st_mode) ||
         chown(stagingRoot.fileSystemRepresentation, 0, 0) != 0 ||
         chmod(stagingRoot.fileSystemRepresentation, S_IRUSR | S_IXUSR) != 0 ||
         lstat(stagedBundleURL.fileSystemRepresentation, &stagedBundleInfo) != 0 ||
         !S_ISDIR(stagedBundleInfo.st_mode) ||
         chown(stagedBundleURL.fileSystemRepresentation, 0, 0) != 0 ||
         chmod(stagedBundleURL.fileSystemRepresentation,
               (stagedBundleInfo.st_mode & 07777) & ~(S_IWUSR | S_IWGRP | S_IWOTH)) != 0)) {
        treeFailure = @"cannot lock root-owned app staging directory";
    }
    if (treeFailure) {
        chmod(stagingRoot.fileSystemRepresentation, S_IRUSR | S_IWUSR | S_IXUSR);
        [[NSFileManager defaultManager] removeItemAtPath:stagingRoot error:nil];
        if (failure) {
            *failure = treeFailure;
        }
        return nil;
    }
    return stagedBundleURL;
}

static void RemoveRootOwnedStagedAppBundle(NSURL *stagedBundleURL) {
    NSString *stagingRoot = [stagedBundleURL.path stringByDeletingLastPathComponent];
    (void)chmod(stagingRoot.fileSystemRepresentation, S_IRUSR | S_IWUSR | S_IXUSR);
    (void)chmod(stagedBundleURL.fileSystemRepresentation, S_IRUSR | S_IWUSR | S_IXUSR);
    [[NSFileManager defaultManager] removeItemAtPath:stagingRoot error:nil];
}

static NSString *TemporaryTrustPathForDestination(NSString *destination) {
    NSString *directory = [destination stringByDeletingLastPathComponent];
    NSString *name = [NSString stringWithFormat:@".clashfx-trust-%@",
                      NSUUID.UUID.UUIDString.lowercaseString];
    return [directory stringByAppendingPathComponent:name];
}

static BOOL RemoveExistingTrustedFile(NSString *path, NSString **failure) {
    struct stat info = {0};
    if (lstat(path.fileSystemRepresentation, &info) != 0) {
        if (errno == ENOENT) {
            return YES;
        }
        if (failure) {
            *failure = [NSString stringWithFormat:@"cannot inspect existing trust file %@: %s",
                        path, strerror(errno)];
        }
        return NO;
    }
    if (!S_ISREG(info.st_mode) || info.st_uid != 0 || info.st_gid != 0) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"refusing to replace untrusted path %@", path];
        }
        return NO;
    }
    if ((info.st_flags & UF_IMMUTABLE) != 0 && chflags(path.fileSystemRepresentation, 0) != 0) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"cannot clear immutable flag on %@: %s",
                        path, strerror(errno)];
        }
        return NO;
    }
    if (unlink(path.fileSystemRepresentation) != 0) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"cannot replace %@: %s", path, strerror(errno)];
        }
        return NO;
    }
    return YES;
}

static BOOL InstallImmutableDataAtPath(NSData *data,
                                       NSString *destination,
                                       mode_t mode,
                                       NSString **failure) {
    if (!data || !TrustedCoreDirectoriesHaveSafeOwnership()) {
        if (failure) {
            *failure = @"root-owned helper trust directory validation failed";
        }
        return NO;
    }
    NSString *temporaryPath = TemporaryTrustPathForDestination(destination);
    int descriptor = open(temporaryPath.fileSystemRepresentation,
                          O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                          S_IRUSR | S_IWUSR);
    if (descriptor < 0) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"cannot create trust file: %s", strerror(errno)];
        }
        return NO;
    }

    BOOL succeeded = fchown(descriptor, 0, 0) == 0;
    const unsigned char *bytes = data.bytes;
    NSUInteger remaining = data.length;
    while (succeeded && remaining > 0) {
        ssize_t written = write(descriptor, bytes, remaining);
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written <= 0) {
            succeeded = NO;
            break;
        }
        bytes += written;
        remaining -= (NSUInteger)written;
    }
    succeeded = succeeded && fchmod(descriptor, mode) == 0 && fsync(descriptor) == 0;
    int savedErrno = errno;
    close(descriptor);
    if (!succeeded) {
        unlink(temporaryPath.fileSystemRepresentation);
        if (failure) {
            *failure = [NSString stringWithFormat:@"cannot write trust file: %s", strerror(savedErrno)];
        }
        return NO;
    }
    if (!RemoveExistingTrustedFile(destination, failure) ||
        rename(temporaryPath.fileSystemRepresentation, destination.fileSystemRepresentation) != 0 ||
        chflags(destination.fileSystemRepresentation, UF_IMMUTABLE) != 0) {
        savedErrno = errno;
        unlink(temporaryPath.fileSystemRepresentation);
        if (failure && !*failure) {
            *failure = [NSString stringWithFormat:@"cannot install immutable trust file: %s",
                        strerror(savedErrno)];
        }
        return NO;
    }
    struct stat installedInfo = {0};
    if (lstat(destination.fileSystemRepresentation, &installedInfo) != 0 ||
        !ClashFXTrustPolicyIsSafeRootOwnedImmutableFile(
            installedInfo.st_uid, installedInfo.st_gid, installedInfo.st_mode,
            installedInfo.st_flags, mode & S_IXUSR
        )) {
        if (failure) {
            *failure = @"installed trust file failed ownership or mode verification";
        }
        return NO;
    }
    return YES;
}

static NSString *InstallImmutableCoreFromSource(NSString *sourcePath, NSString **failure) {
    if (failure) {
        *failure = nil;
    }
    if (!TrustedCoreDirectoriesHaveSafeOwnership()) {
        if (failure) {
            *failure = @"root-owned helper trust directory validation failed";
        }
        return nil;
    }
    int sourceDescriptor = open(sourcePath.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (sourceDescriptor < 0) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"cannot open approved bundled core: %s", strerror(errno)];
        }
        return nil;
    }
    struct stat sourceInfo = {0};
    if (fstat(sourceDescriptor, &sourceInfo) != 0 || !S_ISREG(sourceInfo.st_mode) || sourceInfo.st_size <= 0) {
        close(sourceDescriptor);
        if (failure) {
            *failure = @"approved bundled core is not a regular executable file";
        }
        return nil;
    }

    NSString *destination = ClashFXHelperApprovedCorePath;
    NSString *temporaryPath = TemporaryTrustPathForDestination(destination);
    int destinationDescriptor = open(temporaryPath.fileSystemRepresentation,
                                     O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                                     S_IRUSR | S_IWUSR);
    if (destinationDescriptor < 0) {
        close(sourceDescriptor);
        if (failure) {
            *failure = [NSString stringWithFormat:@"cannot stage approved core: %s", strerror(errno)];
        }
        return nil;
    }
    BOOL succeeded = fchown(destinationDescriptor, 0, 0) == 0;
    CC_SHA256_CTX context;
    succeeded = succeeded && CC_SHA256_Init(&context) == 1;
    unsigned char buffer[64 * 1024];
    while (succeeded) {
        ssize_t count = read(sourceDescriptor, buffer, sizeof(buffer));
        if (count == 0) {
            break;
        }
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count < 0 || CC_SHA256_Update(&context, buffer, (CC_LONG)count) != 1) {
            succeeded = NO;
            break;
        }
        ssize_t offset = 0;
        while (offset < count) {
            ssize_t written = write(destinationDescriptor, buffer + offset, (size_t)(count - offset));
            if (written < 0 && errno == EINTR) {
                continue;
            }
            if (written <= 0) {
                succeeded = NO;
                break;
            }
            offset += written;
        }
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    succeeded = succeeded && CC_SHA256_Final(digest, &context) == 1 &&
        fchmod(destinationDescriptor, S_IRUSR | S_IXUSR | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH) == 0 &&
        fsync(destinationDescriptor) == 0;
    int savedErrno = errno;
    close(sourceDescriptor);
    close(destinationDescriptor);
    if (!succeeded) {
        unlink(temporaryPath.fileSystemRepresentation);
        if (failure) {
            *failure = [NSString stringWithFormat:@"cannot copy approved core: %s", strerror(savedErrno)];
        }
        return nil;
    }

    if (!RemoveExistingTrustedFile(destination, failure) ||
        rename(temporaryPath.fileSystemRepresentation, destination.fileSystemRepresentation) != 0 ||
        chflags(destination.fileSystemRepresentation, UF_IMMUTABLE) != 0) {
        savedErrno = errno;
        unlink(temporaryPath.fileSystemRepresentation);
        if (failure && !*failure) {
            *failure = [NSString stringWithFormat:@"cannot install immutable approved core: %s",
                        strerror(savedErrno)];
        }
        return nil;
    }
    struct stat installedInfo = {0};
    if (lstat(destination.fileSystemRepresentation, &installedInfo) != 0 ||
        !ClashFXTrustPolicyIsSafeRootOwnedImmutableFile(
            installedInfo.st_uid, installedInfo.st_gid, installedInfo.st_mode,
            installedInfo.st_flags, YES
        )) {
        if (failure) {
            *failure = @"installed Mihomo core failed ownership or mode verification";
        }
        return nil;
    }
    return LowercaseHexString(digest, sizeof(digest));
}

static dispatch_queue_t ClashFXDNSOperationQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL,
            QOS_CLASS_UTILITY,
            0
        );
        queue = dispatch_queue_create("com.clashfx.helper.dns-operations", attributes);
    });
    return queue;
}

static dispatch_queue_t ClashFXTrustInstallQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL,
            QOS_CLASS_UTILITY,
            0
        );
        queue = dispatch_queue_create("com.clashfx.helper.trust-install", attributes);
    });
    return queue;
}

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

static NSArray<NSString *> *MihomoArgumentsFromKernelBuffer(const void *buffer,
                                                            size_t length,
                                                            NSString **failure) {
    if (failure) {
        *failure = nil;
    }
    if (!buffer || length < sizeof(int)) {
        if (failure) {
            *failure = @"KERN_PROCARGS2 buffer is shorter than argc";
        }
        return nil;
    }

    int argc = 0;
    memcpy(&argc, buffer, sizeof(argc));
    if (argc <= 0 || (NSUInteger)argc > kMihomoMaxKernelArgumentCount) {
        if (failure) {
            *failure = @"KERN_PROCARGS2 contains an invalid argc";
        }
        return nil;
    }

    const unsigned char *bytes = buffer;
    size_t offset = sizeof(argc);
    const unsigned char *execPathEnd = memchr(bytes + offset, '\0', length - offset);
    if (!execPathEnd || execPathEnd == bytes + offset) {
        if (failure) {
            *failure = @"KERN_PROCARGS2 has no complete executable path";
        }
        return nil;
    }
    offset = (size_t)(execPathEnd - bytes) + 1;
    while (offset < length && bytes[offset] == '\0') {
        offset += 1;
    }

    NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithCapacity:(NSUInteger)argc];
    for (int index = 0; index < argc; index += 1) {
        if (offset >= length) {
            if (failure) {
                *failure = @"KERN_PROCARGS2 ended before all argv entries were read";
            }
            return nil;
        }
        const unsigned char *argumentEnd = memchr(bytes + offset, '\0', length - offset);
        if (!argumentEnd) {
            if (failure) {
                *failure = @"KERN_PROCARGS2 contains an unterminated argv entry";
            }
            return nil;
        }
        size_t argumentLength = (size_t)(argumentEnd - (bytes + offset));
        NSString *argument = [[NSString alloc] initWithBytes:bytes + offset
                                                     length:argumentLength
                                                   encoding:NSUTF8StringEncoding];
        if (!argument) {
            if (failure) {
                *failure = @"KERN_PROCARGS2 contains a non-UTF-8 argv entry";
            }
            return nil;
        }
        [arguments addObject:argument];
        offset = (size_t)(argumentEnd - bytes) + 1;
    }
    return arguments;
}

static BOOL IsConfirmedProcessAbsence(pid_t pid) {
    if (pid <= 0) {
        return YES;
    }
    errno = 0;
    return kill(pid, 0) == -1 && errno == ESRCH;
}

static NSString *ResolvedProcessBinaryPath(pid_t pid, BOOL *exited) {
    if (exited) {
        *exited = NO;
    }
    char pathBuffer[PROC_PIDPATHINFO_MAXSIZE] = {0};
    int pathLength = proc_pidpath(pid, pathBuffer, (uint32_t)sizeof(pathBuffer));
    if (pathLength <= 0) {
        if (IsConfirmedProcessAbsence(pid) && exited) {
            *exited = YES;
        }
        return nil;
    }
    const char *pathEnd = memchr(pathBuffer, '\0', sizeof(pathBuffer));
    if (!pathEnd) {
        return nil;
    }
    NSString *path = [[NSString alloc] initWithBytes:pathBuffer
                                              length:(NSUInteger)(pathEnd - pathBuffer)
                                            encoding:NSUTF8StringEncoding];
    return path.length > 0 ? path.stringByResolvingSymlinksInPath : nil;
}

static BOOL IsAllowedMihomoConfigPath(NSString *configPath, NSString *expectedHome) {
    NSString *configPrefix = [expectedHome stringByAppendingPathComponent:@".enhanced_config."];
    NSString *configSuffix = @".yaml";
    if (![configPath hasPrefix:configPrefix] || ![configPath hasSuffix:configSuffix]) {
        return NO;
    }
    NSUInteger uuidStart = configPrefix.length;
    NSUInteger uuidLength = configPath.length - configPrefix.length - configSuffix.length;
    if (uuidLength != 36) {
        return NO;
    }
    NSString *uuidString = [configPath substringWithRange:NSMakeRange(uuidStart, uuidLength)];
    return [[NSUUID alloc] initWithUUIDString:uuidString] != nil;
}

static BOOL CopyAllMihomoProcessIDs(pid_t **processIDs,
                                    size_t *processCount,
                                    NSString **failure) {
    if (failure) {
        *failure = nil;
    }
    if (processIDs) {
        *processIDs = NULL;
    }
    if (processCount) {
        *processCount = 0;
    }

    size_t capacity = 256;
    for (NSUInteger attempt = 0; attempt < 16; attempt += 1) {
        if (capacity > kMihomoMaxProcessCount ||
            capacity > (size_t)INT_MAX / sizeof(pid_t)) {
            if (failure) {
                *failure = @"Process list exceeded the bounded enumeration capacity";
            }
            return NO;
        }

        pid_t *buffer = calloc(capacity, sizeof(pid_t));
        if (!buffer) {
            if (failure) {
                *failure = @"Unable to allocate the native process list";
            }
            return NO;
        }
        int count = proc_listallpids(buffer, (int)(capacity * sizeof(pid_t)));
        if (count <= 0) {
            int errorCode = errno;
            free(buffer);
            if (failure) {
                *failure = count == 0
                    ? @"proc_listallpids returned no processes for a running helper"
                    : [NSString stringWithFormat:@"proc_listallpids failed: %s", strerror(errorCode)];
            }
            return NO;
        }
        if ((size_t)count < capacity) {
            if (processIDs) {
                *processIDs = buffer;
            } else {
                free(buffer);
            }
            if (processCount) {
                *processCount = (size_t)count;
            }
            return YES;
        }

        free(buffer);
        capacity = MAX(capacity * 2, (size_t)count + 1);
    }

    if (failure) {
        *failure = @"Process list changed too quickly to enumerate safely";
    }
    return NO;
}

static BOOL RunTaskWithTimeout(NSString *executablePath,
                               NSArray<NSString *> *arguments,
                               NSTimeInterval timeout) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:executablePath];
    task.arguments = arguments;
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    NSString *failure = nil;
    BOOL succeeded = ClashFXRunTaskUntilDeadline(task, deadline, NO, 0, NULL, &failure);
    if (!succeeded) {
        NSLog(@"Command failed or timed out (%@): %@",
              executablePath.lastPathComponent,
              failure ?: @"unknown error");
    }
    return succeeded;
}

- (instancetype)init {
    return [self initWithListenerEnabled:YES];
}

- (instancetype)initForTesting {
    return [self initWithListenerEnabled:NO];
}

- (instancetype)initWithListenerEnabled:(BOOL)listenerEnabled {
    if (self = [super init]) {
        self.connections = [NSMutableSet new];
        self.mihomoLifecycleOperations = [NSMutableArray array];
        self.shouldQuit = NO;
        if (listenerEnabled) {
            self.listener = [[NSXPCListener alloc] initWithMachServiceName:@"com.clashfx.app.Helper"];
            self.listener.delegate = self;
        }
    }
    return self;
}

- (BOOL)isMihomoTaskExitConfirmed:(NSTask *)task {
    return !task.isRunning;
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
    return [self mihomoProcessIDsMatchingBinaryPaths:@[binaryPath ?: @""]
                                          configPath:configPath
                                             homeDir:homeDir];
}

- (NSArray<NSNumber *> *)mihomoProcessIDsMatchingBinaryPaths:(NSArray<NSString *> *)binaryPaths
                                                   configPath:(NSString *)configPath
                                                      homeDir:(NSString *)homeDir {
    NSMutableSet<NSString *> *expectedBinaries = [NSMutableSet set];
    for (NSString *binaryPath in binaryPaths) {
        NSString *expectedBinary = binaryPath.stringByResolvingSymlinksInPath;
        if (expectedBinary.length > 0) {
            [expectedBinaries addObject:expectedBinary];
        }
    }
    NSString *expectedHome = homeDir.stringByResolvingSymlinksInPath;
    NSString *configPrefix = [expectedHome stringByAppendingPathComponent:@".enhanced_config."];
    if (expectedBinaries.count == 0 || expectedHome.length == 0 ||
        ![configPath.stringByResolvingSymlinksInPath isEqualToString:configPrefix]) {
        NSLog(@"mihomo cleanup rejected unexpected config identity: %@", configPath);
        return @[];
    }

    pid_t *processIDs = NULL;
    size_t processCount = 0;
    NSString *enumerationFailure = nil;
    if (!CopyAllMihomoProcessIDs(&processIDs, &processCount, &enumerationFailure)) {
        NSLog(@"mihomo cleanup process enumeration failed: %@",
              enumerationFailure ?: @"unknown error");
        return nil;
    }

    NSMutableArray<NSNumber *> *matchingPIDs = [NSMutableArray array];
    for (size_t index = 0; index < processCount; index += 1) {
        pid_t pid = processIDs[index];
        if (pid <= 0) {
            continue;
        }

        // Resolve the executable first. Most processes are discarded here,
        // without requesting their command-line arguments.
        BOOL pathExited = NO;
        NSString *actualBinary = ResolvedProcessBinaryPath(pid, &pathExited);
        if (![expectedBinaries containsObject:actualBinary]) {
            continue;
        }

        struct proc_bsdinfo initialInfo = {0};
        int infoLength = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &initialInfo, sizeof(initialInfo));
        if (infoLength != (int)sizeof(initialInfo)) {
            if (IsConfirmedProcessAbsence(pid)) {
                continue;
            }
            free(processIDs);
            NSLog(@"mihomo cleanup could not identify candidate pid %d", pid);
            return nil;
        }

        BOOL argvExited = NO;
        NSString *argvFailure = nil;
        NSArray<NSString *> *arguments = [self kernelArgumentsForProcessID:pid
                                                                    exited:&argvExited
                                                                   failure:&argvFailure];
        if (!arguments) {
            if (argvExited || IsConfirmedProcessAbsence(pid)) {
                continue;
            }
            free(processIDs);
            NSLog(@"mihomo cleanup could not read candidate argv for pid %d: %@",
                  pid,
                  argvFailure ?: @"unknown error");
            return nil;
        }

        struct proc_bsdinfo finalInfo = {0};
        infoLength = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &finalInfo, sizeof(finalInfo));
        if (infoLength != (int)sizeof(finalInfo)) {
            if (IsConfirmedProcessAbsence(pid)) {
                continue;
            }
            free(processIDs);
            NSLog(@"mihomo cleanup could not recheck candidate pid %d", pid);
            return nil;
        }
        if (initialInfo.pbi_pid != finalInfo.pbi_pid ||
            initialInfo.pbi_start_tvsec != finalInfo.pbi_start_tvsec ||
            initialInfo.pbi_start_tvusec != finalInfo.pbi_start_tvusec) {
            continue;
        }

        BOOL finalPathExited = NO;
        NSString *finalBinary = ResolvedProcessBinaryPath(pid, &finalPathExited);
        if (!finalBinary && finalPathExited) {
            continue;
        }
        if (!finalBinary) {
            free(processIDs);
            NSLog(@"mihomo cleanup could not recheck candidate executable for pid %d", pid);
            return nil;
        }
        if (![expectedBinaries containsObject:finalBinary]) {
            continue;
        }

        if ([self mihomoArguments:arguments
                matchExpectedHome:expectedHome
              expectedBinaryPath:actualBinary]) {
            [matchingPIDs addObject:@(pid)];
        }
    }

    free(processIDs);
    return matchingPIDs;
}

- (NSArray<NSString *> *)mihomoArgumentsFromKernelBuffer:(NSData *)data {
    if (data.length > kMihomoMaxKernelArgumentsSize) {
        return nil;
    }
    return MihomoArgumentsFromKernelBuffer(data.bytes, data.length, nil);
}

- (BOOL)mihomoArguments:(NSArray<NSString *> *)arguments
      matchExpectedHome:(NSString *)expectedHome
    expectedBinaryPath:(NSString *)expectedBinaryPath {
    if (arguments.count < 2 || expectedHome.length == 0) {
        return NO;
    }

    NSString *argumentZero = arguments.firstObject;
    NSString *expectedBinary = expectedBinaryPath.stringByResolvingSymlinksInPath;
    if (argumentZero.length == 0 || expectedBinary.length == 0) {
        return NO;
    }
    BOOL argumentZeroIsPath = [argumentZero containsString:@"/"];
    BOOL argumentZeroMatches = argumentZeroIsPath
        ? [argumentZero.stringByResolvingSymlinksInPath isEqualToString:expectedBinary]
        : [argumentZero isEqualToString:expectedBinary.lastPathComponent];
    if (!argumentZeroMatches) {
        return NO;
    }

    NSString *homeArgument = nil;
    NSString *configArgument = nil;
    for (NSUInteger index = 1; index < arguments.count; index += 1) {
        NSString *option = arguments[index];
        if (![option isEqualToString:@"-d"] && ![option isEqualToString:@"-f"]) {
            continue;
        }
        if (index + 1 >= arguments.count) {
            return NO;
        }
        NSString *value = arguments[index + 1];
        if ([option isEqualToString:@"-d"]) {
            if (homeArgument) {
                return NO;
            }
            homeArgument = value;
        } else {
            if (configArgument) {
                return NO;
            }
            configArgument = value;
        }
        index += 1;
    }
    // Launch callers may supply a trailing slash (kConfigFolderPath does).
    // Compare resolved absolute paths consistently with the scanner's expected
    // home, while rejecting relative paths and retaining exact config ownership.
    if (!homeArgument.isAbsolutePath || !expectedHome.isAbsolutePath) {
        return NO;
    }
    NSString *normalizedHome = homeArgument.stringByResolvingSymlinksInPath;
    NSString *normalizedExpectedHome = expectedHome.stringByResolvingSymlinksInPath;
    return [normalizedHome isEqualToString:normalizedExpectedHome] &&
        IsAllowedMihomoConfigPath(configArgument, normalizedExpectedHome);
}

- (NSArray<NSString *> *)kernelArgumentsForProcessID:(pid_t)pid
                                               exited:(BOOL *)exited
                                              failure:(NSString **)failure {
    if (exited) {
        *exited = NO;
    }
    if (failure) {
        *failure = nil;
    }

    int mib[] = {CTL_KERN, KERN_PROCARGS2, (int)pid};
    size_t bufferSize = 0;
    if (sysctl(mib, 3, NULL, &bufferSize, NULL, 0) != 0) {
        int errorCode = errno;
        if (IsConfirmedProcessAbsence(pid)) {
            if (exited) {
                *exited = YES;
            }
            return nil;
        }
        if (failure) {
            *failure = [NSString stringWithFormat:@"KERN_PROCARGS2 size query failed: %s",
                        strerror(errorCode)];
        }
        return nil;
    }
    if (bufferSize < sizeof(int) || bufferSize > kMihomoMaxKernelArgumentsSize) {
        if (failure) {
            *failure = @"KERN_PROCARGS2 returned an invalid or oversized buffer length";
        }
        return nil;
    }

    NSMutableData *data = [NSMutableData dataWithLength:bufferSize];
    size_t actualSize = bufferSize;
    if (sysctl(mib, 3, data.mutableBytes, &actualSize, NULL, 0) != 0) {
        int errorCode = errno;
        if (IsConfirmedProcessAbsence(pid)) {
            if (exited) {
                *exited = YES;
            }
            return nil;
        }
        if (failure) {
            *failure = [NSString stringWithFormat:@"KERN_PROCARGS2 read failed: %s",
                        strerror(errorCode)];
        }
        return nil;
    }
    if (actualSize > bufferSize || actualSize < sizeof(int)) {
        if (failure) {
            *failure = @"KERN_PROCARGS2 returned an inconsistent buffer length";
        }
        return nil;
    }
    data.length = actualSize;

    NSString *parseFailure = nil;
    NSArray<NSString *> *arguments = MihomoArgumentsFromKernelBuffer(data.bytes,
                                                                      data.length,
                                                                      &parseFailure);
    if (!arguments && IsConfirmedProcessAbsence(pid)) {
        if (exited) {
            *exited = YES;
        }
        return nil;
    }
    if (!arguments && failure) {
        *failure = parseFailure ?: @"KERN_PROCARGS2 argv parsing failed";
    }
    return arguments;
}

- (BOOL)isProcessRunning:(pid_t)pid {
    return kill(pid, 0) == 0 || errno == EPERM;
}

- (NSArray<NSNumber *> *)listeningPortsForPID:(pid_t)pid
                                     protocol:(NSString *)protocol
                                     deadline:(NSTimeInterval)deadline {
    if (pid <= 0 || ![@[@"TCP", @"UDP"] containsObject:protocol]) {
        return nil;
    }

    size_t descriptorCapacity = 64;
    struct proc_fdinfo *descriptors = NULL;
    size_t descriptorCount = 0;
    NSString *failure = nil;
    while (descriptorCapacity <= kMihomoSocketMaximumDescriptorCount) {
        if (NSProcessInfo.processInfo.systemUptime >= deadline) {
            failure = @"native socket inspection deadline expired while listing file descriptors";
            break;
        }
        size_t byteCapacity = descriptorCapacity * sizeof(struct proc_fdinfo);
        struct proc_fdinfo *buffer = calloc(descriptorCapacity, sizeof(struct proc_fdinfo));
        if (!buffer) {
            failure = @"unable to allocate native socket descriptor list";
            break;
        }
        errno = 0;
        int bytesRead = proc_pidinfo(pid,
                                     PROC_PIDLISTFDS,
                                     0,
                                     buffer,
                                     (int)byteCapacity);
        if (bytesRead <= 0) {
            int errorCode = errno;
            free(buffer);
            failure = [NSString stringWithFormat:
                @"proc_pidinfo(PROC_PIDLISTFDS) failed: %@",
                errorCode == 0 ? @"returned no descriptors" : [NSString stringWithUTF8String:strerror(errorCode)]];
            break;
        }
        if ((size_t)bytesRead % sizeof(struct proc_fdinfo) != 0) {
            free(buffer);
            failure = @"proc_pidinfo returned a partial file descriptor record";
            break;
        }
        if ((size_t)bytesRead < byteCapacity) {
            descriptors = buffer;
            descriptorCount = (size_t)bytesRead / sizeof(struct proc_fdinfo);
            break;
        }
        free(buffer);
        if (descriptorCapacity == kMihomoSocketMaximumDescriptorCount) {
            failure = @"process file descriptor list exceeded the bounded inspection capacity";
            break;
        }
        descriptorCapacity = MIN(descriptorCapacity * 2, kMihomoSocketMaximumDescriptorCount);
    }

    if (!descriptors) {
        NSLog(@"[mihomo_core] native %@ socket query for pid %d failed: %@",
              protocol,
              pid,
              failure ?: @"unable to enumerate file descriptors");
        return nil;
    }

    NSMutableSet<NSNumber *> *ports = [NSMutableSet set];
    BOOL queryFailed = NO;
    for (size_t index = 0; index < descriptorCount; index += 1) {
        if (NSProcessInfo.processInfo.systemUptime >= deadline) {
            failure = @"native socket inspection deadline expired while reading sockets";
            queryFailed = YES;
            break;
        }
        if (descriptors[index].proc_fdtype != PROX_FDTYPE_SOCKET) {
            continue;
        }

        struct socket_fdinfo socketInfo = {0};
        errno = 0;
        int bytesRead = proc_pidfdinfo(pid,
                                       descriptors[index].proc_fd,
                                       PROC_PIDFDSOCKETINFO,
                                       &socketInfo,
                                       (int)sizeof(socketInfo));
        if (bytesRead != (int)sizeof(socketInfo)) {
            int errorCode = errno;
            if (bytesRead <= 0 && (errorCode == EBADF || errorCode == ENOENT)) {
                // The process closed this descriptor after PROC_PIDLISTFDS returned it.
                continue;
            }
            NSString *detail = errorCode == 0
                ? @"returned a short socket-info record"
                : [NSString stringWithUTF8String:strerror(errorCode)];
            failure = [NSString stringWithFormat:
                @"proc_pidfdinfo(PROC_PIDFDSOCKETINFO) failed for fd %d: %@",
                descriptors[index].proc_fd,
                detail];
            queryFailed = YES;
            break;
        }

        int rawPort = 0;
        if ([protocol isEqualToString:@"TCP"] &&
            socketInfo.psi.soi_kind == SOCKINFO_TCP &&
            socketInfo.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN) {
            rawPort = socketInfo.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport;
        } else if ([protocol isEqualToString:@"UDP"] &&
                   socketInfo.psi.soi_kind == SOCKINFO_IN &&
                   socketInfo.psi.soi_protocol == IPPROTO_UDP &&
                   socketInfo.psi.soi_proto.pri_in.insi_fport == 0) {
            // An outbound connected UDP socket is not a DNS listener.
            rawPort = socketInfo.psi.soi_proto.pri_in.insi_lport;
        }
        int port = (int)ntohs((in_port_t)rawPort);
        if (port > 0 && port <= 65535) {
            [ports addObject:@(port)];
        }
    }
    free(descriptors);
    if (queryFailed) {
        NSLog(@"[mihomo_core] native %@ socket query for pid %d failed: %@",
              protocol,
              pid,
              failure ?: @"unknown error");
        return nil;
    }
    return [[ports allObjects] sortedArrayUsingSelector:@selector(compare:)];
}

- (void)enqueueMihomoLifecycleOperation:(dispatch_block_t)operation {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.mihomoLifecycleOperations addObject:[operation copy]];
        [self runNextMihomoLifecycleOperation];
    });
}

- (void)runNextMihomoLifecycleOperation {
    if (self.mihomoLifecycleOperationInFlight || self.mihomoLifecycleOperations.count == 0) {
        return;
    }

    self.mihomoLifecycleOperationInFlight = YES;
    dispatch_block_t operation = self.mihomoLifecycleOperations.firstObject;
    [self.mihomoLifecycleOperations removeObjectAtIndex:0];
    operation();
}

- (void)finishMihomoLifecycleOperation {
    self.mihomoLifecycleOperationInFlight = NO;
    [self runNextMihomoLifecycleOperation];
}

- (void)terminateMihomoTask:(NSTask *)task
                   launchID:(NSString *)launchID
                 completion:(stringReplyBlock)completion {
    if (!task) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }

    if (self.mihomoTask != task ||
        launchID.length == 0 ||
        ![self.mihomoLaunchID isEqualToString:launchID]) {
        NSLog(@"[mihomo_core] Skipping stale termination for launch %@", launchID ?: @"unknown");
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(@"Refusing to stop a Mihomo process whose launch identity is stale");
        });
        return;
    }

    if (!task.isRunning) {
        self.mihomoTask = nil;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }

    pid_t pid = task.processIdentifier;
    [task terminate];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + kMihomoGracefulStopTimeout;
        while (task.isRunning && NSProcessInfo.processInfo.systemUptime < deadline) {
            usleep(100 * 1000);
        }

        if (task.isRunning) {
            NSLog(@"[mihomo_core] Graceful stop timed out; force killing pid %d", pid);
            (void)kill(pid, SIGKILL);
            ClashFXWaitForTaskExit(task, kClashFXTaskKillReapTimeout);
        }

        BOOL exitConfirmed = [self isMihomoTaskExitConfirmed:task];

        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL launchIDStillMatches = [self.mihomoLaunchID isEqualToString:launchID];
            BOOL noReplacementLaunch = self.mihomoTask == task || self.mihomoTask == nil;
            BOOL stillSameLaunch = launchIDStillMatches && noReplacementLaunch;
            if (exitConfirmed && stillSameLaunch && self.mihomoTask == task) {
                self.mihomoTask = nil;
            }
            if (!exitConfirmed) {
                NSString *failure = [NSString stringWithFormat:
                    @"Mihomo launch %@ (pid %d) did not exit after SIGKILL; refusing to start another core",
                    launchID,
                    pid];
                NSLog(@"[mihomo_core] %@", failure);
                completion(failure);
                return;
            }
            if (!stillSameLaunch) {
                completion(@"Mihomo launch identity changed before stop completion");
                return;
            }
            completion(nil);
        });
    });
}

- (void)cleanupMihomoCoreWithBinaryPath:(NSString *)binaryPath
                             configPath:(NSString *)configPath
                                homeDir:(NSString *)homeDir
                                  reply:(stringReplyBlock)reply {
    NSString *validationFailure = nil;
    NSString *sourcePath = [self validatedMihomoSourcePath:binaryPath
                                            forConnection:NSXPCConnection.currentConnection
                                      clientCDHashOutput:nil
                                                   failure:&validationFailure];
    if (!sourcePath) {
        reply(validationFailure ?: @"Mihomo cleanup rejected an unapproved executable path");
        return;
    }

    NSString *expectedHome = homeDir.stringByResolvingSymlinksInPath;
    NSString *expectedConfigPrefix = [expectedHome stringByAppendingPathComponent:@".enhanced_config."];
    NSString *normalizedConfigPrefix = configPath.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    if (!homeDir.isAbsolutePath || expectedHome.length == 0 ||
        ![normalizedConfigPrefix isEqualToString:expectedConfigPrefix]) {
        reply(@"Mihomo cleanup rejected an unexpected home or config prefix");
        return;
    }

    NSArray<NSString *> *scanPaths = @[ClashFXHelperApprovedCorePath, sourcePath];
    [self enqueueMihomoLifecycleOperation:^{
        stringReplyBlock finish = ^(NSString *error) {
            [self finishMihomoLifecycleOperation];
            reply(error);
        };

        dispatch_block_t scanAndStopUnmanaged = ^{
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSArray<NSNumber *> *pids = [self mihomoProcessIDsMatchingBinaryPaths:scanPaths
                                                                            configPath:expectedConfigPrefix
                                                                               homeDir:expectedHome];
                NSString *failure = nil;
                if (!pids) {
                    failure = @"Unable to inspect existing Mihomo processes before cleanup";
                } else if (pids.count > 0) {
                    for (NSNumber *pidNumber in pids) {
                        (void)kill(pidNumber.intValue, SIGTERM);
                    }

                    [NSThread sleepForTimeInterval:1.0];

                    NSArray<NSNumber *> *stillMatchedArray = [self mihomoProcessIDsMatchingBinaryPaths:scanPaths
                                                                                              configPath:expectedConfigPrefix
                                                                                                 homeDir:expectedHome];
                    if (!stillMatchedArray) {
                        failure = @"Unable to verify Mihomo processes after SIGTERM";
                    } else {
                        NSSet<NSNumber *> *stillMatchedPids = [NSSet setWithArray:stillMatchedArray];
                        for (NSNumber *pidNumber in pids) {
                            if ([stillMatchedPids containsObject:pidNumber] &&
                                [self isProcessRunning:pidNumber.intValue]) {
                                (void)kill(pidNumber.intValue, SIGKILL);
                            }
                        }

                        NSTimeInterval reapDeadline = NSProcessInfo.processInfo.systemUptime + 0.50;
                        NSMutableArray<NSNumber *> *remainingPids = [NSMutableArray array];
                        do {
                            [remainingPids removeAllObjects];
                            for (NSNumber *pidNumber in stillMatchedPids) {
                                if ([self isProcessRunning:pidNumber.intValue]) {
                                    [remainingPids addObject:pidNumber];
                                }
                            }
                            if (remainingPids.count == 0 ||
                                NSProcessInfo.processInfo.systemUptime >= reapDeadline) {
                                break;
                            }
                            usleep(20 * 1000);
                        } while (YES);

                        if (remainingPids.count > 0) {
                            failure = [NSString stringWithFormat:
                                @"Mihomo cleanup could not confirm exit for process id(s): %@",
                                remainingPids];
                        }
                    }
                    if (!failure) {
                        NSLog(@"Cleaned up %lu ClashFX mihomo_core process(es)", (unsigned long)pids.count);
                    }
                }

                dispatch_async(dispatch_get_main_queue(), ^{
                    finish(failure);
                });
            });
        };

        if ([self managedMihomoTaskMatchesCleanupHome:expectedHome]) {
            [self stopManagedMihomoTaskForCleanupAtHome:expectedHome completion:^(NSString *error) {
                if (error) {
                    finish(error);
                } else {
                    scanAndStopUnmanaged();
                }
            }];
        } else {
            scanAndStopUnmanaged();
        }
    }];
}

- (BOOL)managedMihomoTaskMatchesCleanupHome:(NSString *)expectedHome {
    if (!self.mihomoTask ||
        ![self.mihomoBinaryPath isEqualToString:ClashFXHelperApprovedCorePath]) {
        return NO;
    }
    NSString *managedHome = self.mihomoHomeDir.stringByResolvingSymlinksInPath;
    return [managedHome isEqualToString:expectedHome] &&
        IsAllowedMihomoConfigPath(self.mihomoConfigPath, expectedHome);
}

- (void)stopManagedMihomoTaskForCleanupAtHome:(NSString *)expectedHome
                                   completion:(stringReplyBlock)completion {
    NSTask *task = self.mihomoTask;
    if (!task || ![self managedMihomoTaskMatchesCleanupHome:expectedHome]) {
        completion(nil);
        return;
    }
    [self terminateMihomoTask:task
                     launchID:[self.mihomoLaunchID copy]
                   completion:completion];
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

- (NSDictionary *)approvedTrustEntryForClientCDHash:(NSString *)clientCDHash
                                         sourcePath:(NSString *)sourcePath
                                            failure:(NSString **)failure {
    if (failure) {
        *failure = nil;
    }
    if (!ClashFXTrustPolicyIsLowercaseHexDigest(clientCDHash, 40) ||
        sourcePath.length == 0 ||
        !TrustedCoreDirectoriesHaveSafeOwnership()) {
        if (failure) {
            *failure = @"approved core trust paths or client CDHash are invalid";
        }
        return nil;
    }

    int receiptDescriptor = open(ClashFXHelperTrustReceiptPath.fileSystemRepresentation,
                                 O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (receiptDescriptor < 0) {
        if (failure) {
            *failure = @"approved core trust receipt is missing or cannot be opened safely";
        }
        return nil;
    }
    struct stat receiptInfo = {0};
    BOOL receiptIsTrusted = fstat(receiptDescriptor, &receiptInfo) == 0 &&
        receiptInfo.st_size > 0 &&
        (uint64_t)receiptInfo.st_size <= kTrustReceiptMaximumBytes &&
        ClashFXTrustPolicyIsSafeRootOwnedImmutableFile(
            receiptInfo.st_uid, receiptInfo.st_gid, receiptInfo.st_mode,
            receiptInfo.st_flags, NO
        );
    NSData *receiptData = receiptIsTrusted
        ? ReadFileDescriptorWithLimit(receiptDescriptor, kTrustReceiptMaximumBytes)
        : nil;
    close(receiptDescriptor);
    if (!receiptData) {
        if (failure) {
            *failure = @"approved core trust receipt ownership, permissions, or immutable flag is invalid";
        }
        return nil;
    }

    NSError *propertyListError = nil;
    id propertyList = [NSPropertyListSerialization propertyListWithData:receiptData
                                                                 options:NSPropertyListImmutable
                                                                  format:nil
                                                                   error:&propertyListError];
    NSDictionary *receipt = [propertyList isKindOfClass:[NSDictionary class]] ? propertyList : nil;
    NSNumber *schemaVersion = [receipt[@"SchemaVersion"] isKindOfClass:[NSNumber class]]
        ? receipt[@"SchemaVersion"]
        : nil;
    NSArray *approvedClients = [receipt[@"ApprovedClients"] isKindOfClass:[NSArray class]]
        ? receipt[@"ApprovedClients"]
        : nil;
    if (schemaVersion.integerValue != ClashFXHelperTrustReceiptSchemaVersion || !approvedClients) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"approved core trust receipt schema is invalid: %@",
                        propertyListError.localizedDescription ?: @"missing fields"];
        }
        return nil;
    }

    NSString *normalizedSourcePath = sourcePath.stringByStandardizingPath;
    NSDictionary *matchingEntry = nil;
    for (id candidate in approvedClients) {
        if (![candidate isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary *entry = candidate;
        if ([entry[@"BundleIdentifier"] isEqualToString:ClashFXHelperClientBundleIdentifier] &&
            [entry[@"ClientCDHash"] isEqualToString:clientCDHash] &&
            [entry[@"ApprovedSourcePath"] isEqualToString:normalizedSourcePath] &&
            ClashFXTrustPolicyIsLowercaseHexDigest(entry[@"CoreSHA256"], 64)) {
            matchingEntry = entry;
            break;
        }
    }
    if (!matchingEntry) {
        if (failure) {
            *failure = @"client CDHash or bundled core path is not approved by the root receipt";
        }
        return nil;
    }

    int coreDescriptor = open(ClashFXHelperApprovedCorePath.fileSystemRepresentation,
                              O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (coreDescriptor < 0) {
        if (failure) {
            *failure = @"approved root-owned Mihomo core is missing or cannot be opened safely";
        }
        return nil;
    }
    struct stat coreInfo = {0};
    BOOL coreIsTrusted = fstat(coreDescriptor, &coreInfo) == 0 &&
        coreInfo.st_size > 0 &&
        ClashFXTrustPolicyIsSafeRootOwnedImmutableFile(
            coreInfo.st_uid, coreInfo.st_gid, coreInfo.st_mode,
            coreInfo.st_flags, YES
        );
    NSString *coreSHA256 = coreIsTrusted ? SHA256HexForFileDescriptor(coreDescriptor) : nil;
    close(coreDescriptor);
    if (!coreSHA256 || ![coreSHA256 isEqualToString:matchingEntry[@"CoreSHA256"]]) {
        if (failure) {
            *failure = @"installed Mihomo core does not match its root trust receipt";
        }
        return nil;
    }
    return matchingEntry;
}

- (NSString *)validatedMihomoSourcePath:(NSString *)binaryPath
                         forConnection:(NSXPCConnection *)connection
                     clientCDHashOutput:(NSString **)clientCDHashOutput
                                failure:(NSString **)failure {
    if (clientCDHashOutput) {
        *clientCDHashOutput = nil;
    }
    if (failure) {
        *failure = nil;
    }
    if (!connection || ![self connectionIsValid:connection]) {
        if (failure) {
            *failure = @"Mihomo request did not come from an authenticated ClashFX client";
        }
        return nil;
    }

    pid_t pid = connection.processIdentifier;
    char executablePathBuffer[PROC_PIDPATHINFO_MAXSIZE] = {0};
    int executablePathLength = proc_pidpath(pid, executablePathBuffer, sizeof(executablePathBuffer));
    if (executablePathLength <= 0) {
        if (failure) {
            *failure = @"authenticated client executable path could not be resolved";
        }
        return nil;
    }
    NSString *executablePath = [[NSFileManager defaultManager]
        stringWithFileSystemRepresentation:executablePathBuffer
                                    length:strnlen(executablePathBuffer, sizeof(executablePathBuffer))];
    NSURL *executableURL = [NSURL fileURLWithPath:executablePath];
    NSURL *bundleURL = [[[executableURL URLByDeletingLastPathComponent]
        URLByDeletingLastPathComponent] URLByDeletingLastPathComponent];
    NSString *sourcePath = [[[bundleURL URLByAppendingPathComponent:@"Contents/Resources/mihomo_core"] path]
        stringByStandardizingPath];
    NSString *normalizedArgument = [binaryPath stringByStandardizingPath];
    if (binaryPath.length == 0 || ![normalizedArgument isEqualToString:sourcePath]) {
        if (failure) {
            *failure = @"Mihomo executable path must be the authenticated client's bundled core";
        }
        return nil;
    }

    SecCodeRef code = NULL;
    NSDictionary *attributes = @{(__bridge NSString *)kSecGuestAttributePid: @(pid)};
    OSStatus status = SecCodeCopyGuestWithAttributes(NULL,
                                                    (__bridge CFDictionaryRef)attributes,
                                                    kSecCSDefaultFlags,
                                                    &code);
    if (status != errSecSuccess || code == NULL) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"authenticated client code lookup failed: %d", status];
        }
        return nil;
    }
    CFDictionaryRef signingInfo = NULL;
    status = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &signingInfo);
    CFRelease(code);
    NSDictionary *info = status == errSecSuccess
        ? (__bridge_transfer NSDictionary *)signingInfo
        : nil;
    NSString *uniqueInfoKey = (__bridge NSString *)kSecCodeInfoUnique;
    NSData *cdHashData = [info[uniqueInfoKey] isKindOfClass:[NSData class]]
        ? info[uniqueInfoKey]
        : nil;
    NSString *clientHash = cdHashData
        ? LowercaseHexString(cdHashData.bytes, cdHashData.length)
        : nil;
    NSString *trustFailure = nil;
    if (![self approvedTrustEntryForClientCDHash:clientHash
                                    sourcePath:sourcePath
                                       failure:&trustFailure]) {
        if (failure) {
            *failure = trustFailure ?: @"client has no approved root core";
        }
        return nil;
    }
    if (clientCDHashOutput) {
        *clientCDHashOutput = clientHash;
    }
    return sourcePath;
}

- (BOOL)connectionIsValid:(NSXPCConnection *)connection {
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
        ![clientBundle.bundleIdentifier isEqualToString:authorizedBundleIdentifier] ||
        ![authorizedBundleIdentifier isEqualToString:ClashFXHelperClientBundleIdentifier]) {
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
    OSStatus requirementStatus = SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement);
    OSStatus signatureStatus = SecCodeCheckValidity(code, kSecCSStrictValidate, NULL);
    CFRelease(requirement);

    CFDictionaryRef signingInfo = NULL;
    OSStatus signingInfoStatus = SecCodeCopySigningInformation(code,
                                                               kSecCSSigningInformation,
                                                               &signingInfo);
    CFRelease(code);
    NSDictionary *info = signingInfoStatus == errSecSuccess
        ? (__bridge_transfer NSDictionary *)signingInfo
        : nil;
    NSString *uniqueInfoKey = (__bridge NSString *)kSecCodeInfoUnique;
    NSData *cdHashData = [info[uniqueInfoKey] isKindOfClass:[NSData class]]
        ? info[uniqueInfoKey]
        : nil;
    NSString *clientCDHash = cdHashData
        ? LowercaseHexString(cdHashData.bytes, cdHashData.length)
        : nil;
    NSString *flagsInfoKey = (__bridge NSString *)kSecCodeInfoFlags;
    uint32_t signatureFlags = [info[flagsInfoKey] respondsToSelector:@selector(unsignedIntValue)]
        ? [info[flagsInfoKey] unsignedIntValue]
        : 0;
    BOOL isAdHoc = (signatureFlags & kAdHocCodeSignatureFlag) != 0;

    NSString *sourcePath = [[[bundleURL URLByAppendingPathComponent:@"Contents/Resources/mihomo_core"] path]
        stringByStandardizingPath];
    NSString *trustFailure = nil;
    NSString *pinnedCDHash = nil;
    if (requirementStatus != errSecSuccess && isAdHoc) {
        NSDictionary *trustEntry = [self approvedTrustEntryForClientCDHash:clientCDHash
                                                                sourcePath:sourcePath
                                                                   failure:&trustFailure];
        pinnedCDHash = [trustEntry[@"ClientCDHash"] isKindOfClass:[NSString class]]
            ? trustEntry[@"ClientCDHash"]
            : nil;
    }
    BOOL valid = ClashFXTrustPolicyCanAuthorizeClient(
        requirementStatus == errSecSuccess,
        signatureStatus == errSecSuccess,
        isAdHoc,
        hasExpectedBundleLayout,
        clientBundle.bundleIdentifier,
        clientCDHash,
        pinnedCDHash
    );
    if (!valid) {
        NSLog(@"Rejected XPC client pid %d: requirement status=%d, strict signature status=%d, ad-hoc=%@, trust=%@",
              pid,
              requirementStatus,
              signatureStatus,
              isAdHoc ? @"yes" : @"no",
              trustFailure ?: @"signature or bundle identity mismatch");
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
    NSXPCInterface *exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(ProxyConfigRemoteProcessProtocol)];
    ClashFXConfigureHelperXPCInterface(exportedInterface);
    newConnection.exportedInterface = exportedInterface;
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

- (void)installApprovedMihomoCoreWithReply:(stringReplyBlock)reply {
    NSXPCConnection *connection = NSXPCConnection.currentConnection;
    if (!connection || ![self connectionIsValid:connection]) {
        reply(@"Mihomo trust installation requires an authenticated ClashFX client");
        return;
    }

    NSString *requirementString = [self authorizedClientRequirement];
    NSString *authorizedBundleIdentifier = [self authorizedClientBundleIdentifierFromRequirement:requirementString];
    pid_t pid = connection.processIdentifier;
    char executablePathBuffer[PROC_PIDPATHINFO_MAXSIZE] = {0};
    int executablePathLength = proc_pidpath(pid, executablePathBuffer, sizeof(executablePathBuffer));
    if (executablePathLength <= 0 || authorizedBundleIdentifier.length == 0) {
        reply(@"Mihomo trust installation could not resolve the authorized client bundle");
        return;
    }
    NSString *executablePath = [[NSFileManager defaultManager]
        stringWithFileSystemRepresentation:executablePathBuffer
                                    length:strnlen(executablePathBuffer, sizeof(executablePathBuffer))];
    NSURL *executableURL = [NSURL fileURLWithPath:executablePath];
    NSURL *bundleURL = [[[executableURL URLByDeletingLastPathComponent]
        URLByDeletingLastPathComponent] URLByDeletingLastPathComponent];
    NSBundle *clientBundle = [NSBundle bundleWithURL:bundleURL];
    NSString *sourcePath = [[[bundleURL URLByAppendingPathComponent:@"Contents/Resources/mihomo_core"] path]
        stringByStandardizingPath];
    if (![clientBundle.bundleIdentifier isEqualToString:ClashFXHelperClientBundleIdentifier] ||
        ![authorizedBundleIdentifier isEqualToString:ClashFXHelperClientBundleIdentifier]) {
        reply(@"Mihomo trust installation rejected an unexpected client bundle identifier");
        return;
    }

    SecCodeRef guestCode = NULL;
    NSDictionary *attributes = @{(__bridge NSString *)kSecGuestAttributePid: @(pid)};
    OSStatus status = SecCodeCopyGuestWithAttributes(NULL,
                                                    (__bridge CFDictionaryRef)attributes,
                                                    kSecCSDefaultFlags,
                                                    &guestCode);
    SecRequirementRef requirement = NULL;
    if (status == errSecSuccess && guestCode) {
        status = SecRequirementCreateWithString((__bridge CFStringRef)requirementString,
                                                kSecCSDefaultFlags,
                                                &requirement);
    }
    OSStatus requirementStatus = status == errSecSuccess && requirement
        ? SecCodeCheckValidity(guestCode, kSecCSDefaultFlags, requirement)
        : status;
    if (requirement) {
        CFRelease(requirement);
    }
    if (requirementStatus != errSecSuccess || !guestCode) {
        if (guestCode) {
            CFRelease(guestCode);
        }
        reply(@"Mihomo trust installation requires the existing authorized Developer ID signature");
        return;
    }

    CFDictionaryRef signingInfo = NULL;
    status = SecCodeCopySigningInformation(guestCode, kSecCSSigningInformation, &signingInfo);
    CFRelease(guestCode);
    NSDictionary *info = status == errSecSuccess
        ? (__bridge_transfer NSDictionary *)signingInfo
        : nil;
    NSString *uniqueInfoKey = (__bridge NSString *)kSecCodeInfoUnique;
    NSData *cdHashData = [info[uniqueInfoKey] isKindOfClass:[NSData class]]
        ? info[uniqueInfoKey]
        : nil;
    NSString *clientCDHash = cdHashData
        ? LowercaseHexString(cdHashData.bytes, cdHashData.length)
        : nil;
    if (!ClashFXTrustPolicyIsLowercaseHexDigest(clientCDHash, 40)) {
        reply(@"Mihomo trust installation could not read the authorized client CDHash");
        return;
    }

    dispatch_async(ClashFXTrustInstallQueue(), ^{
        NSString *installFailure = nil;
        NSURL *stagedBundleURL = CreateRootOwnedStagedAppBundle(bundleURL, &installFailure);
        if (!stagedBundleURL) {
            reply(installFailure ?: @"Unable to create a root-owned app staging copy");
            return;
        }

        SecStaticCodeRef stagedCode = NULL;
        OSStatus stagedStatus = SecStaticCodeCreateWithPath((__bridge CFURLRef)stagedBundleURL,
                                                            kSecCSDefaultFlags,
                                                            &stagedCode);
        SecRequirementRef stagedRequirement = NULL;
        if (stagedStatus == errSecSuccess && stagedCode) {
            stagedStatus = SecRequirementCreateWithString((__bridge CFStringRef)requirementString,
                                                          kSecCSDefaultFlags,
                                                          &stagedRequirement);
        }
        SecCSFlags strictFlags = kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode;
        if (stagedStatus == errSecSuccess && stagedCode && stagedRequirement) {
            // This is a fresh Security validation of a unique root-owned, read-only
            // bundle copy; the mutable source app is never the trust boundary.
            stagedStatus = SecStaticCodeCheckValidity(stagedCode, strictFlags, stagedRequirement);
        }
        if (stagedRequirement) {
            CFRelease(stagedRequirement);
        }
        CFDictionaryRef stagedSigningInfo = NULL;
        if (stagedStatus == errSecSuccess && stagedCode) {
            stagedStatus = SecCodeCopySigningInformation(stagedCode,
                                                         kSecCSSigningInformation,
                                                         &stagedSigningInfo);
        }
        NSDictionary *stagedInfo = stagedStatus == errSecSuccess
            ? (__bridge_transfer NSDictionary *)stagedSigningInfo
            : nil;
        NSString *uniqueInfoKey = (__bridge NSString *)kSecCodeInfoUnique;
        NSData *stagedCDHashData = [stagedInfo[uniqueInfoKey] isKindOfClass:[NSData class]]
            ? stagedInfo[uniqueInfoKey]
            : nil;
        NSString *stagedCDHash = stagedCDHashData
            ? LowercaseHexString(stagedCDHashData.bytes, stagedCDHashData.length)
            : nil;
        if (stagedCode) {
            CFRelease(stagedCode);
        }
        if (stagedStatus != errSecSuccess || ![stagedCDHash isEqualToString:clientCDHash]) {
            RemoveRootOwnedStagedAppBundle(stagedBundleURL);
            reply([NSString stringWithFormat:
                @"Root-staged client bundle failed fresh signature/CDHash validation: %d",
                stagedStatus]);
            return;
        }

        NSString *stagedCorePath = [[[stagedBundleURL URLByAppendingPathComponent:
            @"Contents/Resources/mihomo_core"] path] stringByStandardizingPath];
        NSString *coreSHA256 = InstallImmutableCoreFromSource(stagedCorePath, &installFailure);
        if (!coreSHA256) {
            RemoveRootOwnedStagedAppBundle(stagedBundleURL);
            reply(installFailure ?: @"Unable to install approved immutable Mihomo core");
            return;
        }

        NSDictionary *approvedClient = @{
            @"BundleIdentifier": ClashFXHelperClientBundleIdentifier,
            @"ClientCDHash": clientCDHash,
            @"ApprovedSourcePath": sourcePath,
            @"CoreSHA256": coreSHA256
        };
        NSDictionary *receipt = @{
            @"SchemaVersion": @(ClashFXHelperTrustReceiptSchemaVersion),
            @"ApprovedClients": @[approvedClient]
        };
        NSError *serializationError = nil;
        NSData *receiptData = [NSPropertyListSerialization dataWithPropertyList:receipt
                                                                        format:NSPropertyListXMLFormat_v1_0
                                                                       options:0
                                                                         error:&serializationError];
        if (!receiptData || !InstallImmutableDataAtPath(receiptData,
                                                       ClashFXHelperTrustReceiptPath,
                                                       S_IRUSR | S_IRGRP | S_IROTH,
                                                       &installFailure)) {
            RemoveRootOwnedStagedAppBundle(stagedBundleURL);
            reply(installFailure ?: [NSString stringWithFormat:
                @"Unable to serialize approved Mihomo trust receipt: %@",
                serializationError.localizedDescription ?: @"unknown error"]);
            return;
        }
        RemoveRootOwnedStagedAppBundle(stagedBundleURL);
        reply(nil);
    });
}

- (void)getMihomoCoreStatusWithReply:(dictReplyBlock)reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTask *task = self.mihomoTask;
        NSString *launchID = [self.mihomoLaunchID copy];
        pid_t pid = self.mihomoProcessID;
        NSMutableDictionary *status = [NSMutableDictionary dictionary];
        BOOL running = task && task.isRunning;
        status[@"running"] = @(running);
        status[@"pid"] = @(pid);
        if (launchID.length > 0) {
            status[@"launchID"] = launchID;
        }
        if (self.mihomoConfigPath.length > 0) {
            status[@"configPath"] = [self.mihomoConfigPath copy];
        }
        if (self.mihomoBinaryPath.length > 0) {
            status[@"binaryPath"] = [self.mihomoBinaryPath copy];
        }
        if (self.mihomoSourceBinaryPath.length > 0) {
            status[@"sourceBinaryPath"] = [self.mihomoSourceBinaryPath copy];
        }
        if (self.mihomoLogPath.length > 0) {
            status[@"logPath"] = [self.mihomoLogPath copy];
        }
        if (self.mihomoLaunchDate) {
            status[@"startedAt"] = @([self.mihomoLaunchDate timeIntervalSince1970]);
        }
        if (self.mihomoLastTerminationSummary.length > 0) {
            status[@"lastTermination"] = self.mihomoLastTerminationSummary;
        }
        if (running && pid > 0 && launchID.length > 0) {
            struct rusage_info_v2 usage = {0};
            int result = proc_pid_rusage(
                pid,
                RUSAGE_INFO_V2,
                (rusage_info_t *)&usage
            );
            status[@"sampleUptime"] = @(NSProcessInfo.processInfo.systemUptime);
            if (result == 0) {
                uint64_t cpuTimeNanoseconds = usage.ri_user_time + usage.ri_system_time;
                status[@"cpuTimeNanoseconds"] = @(cpuTimeNanoseconds);
            } else {
                status[@"cpuSampleError"] = [NSString stringWithFormat:
                    @"proc_pid_rusage failed: %s", strerror(errno)];
            }
        } else {
            status[@"tcpListenPorts"] = @[];
            status[@"udpListenPorts"] = @[];
            status[@"tcpListenPortsState"] = running ? @"unknown" : @"notRunning";
            status[@"udpListenPortsState"] = running ? @"unknown" : @"notRunning";
            reply(status);
            return;
        }

        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        BOOL cacheMatchesLaunch = [self.mihomoSocketSnapshotLaunchID isEqualToString:launchID] &&
            self.mihomoSocketSnapshotPID == pid;
        NSTimeInterval cacheLifetime = self.mihomoSocketSnapshotTCPPorts &&
            self.mihomoSocketSnapshotUDPPorts
            ? kMihomoSocketKnownCacheLifetime
            : kMihomoSocketUnknownCacheLifetime;
        BOOL cacheIsFresh = cacheMatchesLaunch &&
            self.mihomoSocketSnapshotUptime > 0 &&
            now - self.mihomoSocketSnapshotUptime <= cacheLifetime;
        if (cacheIsFresh) {
            status[@"tcpListenPorts"] = self.mihomoSocketSnapshotTCPPorts ?: @[];
            status[@"udpListenPorts"] = self.mihomoSocketSnapshotUDPPorts ?: @[];
            status[@"tcpListenPortsState"] = self.mihomoSocketSnapshotTCPPorts ? @"known" : @"unknown";
            status[@"udpListenPortsState"] = self.mihomoSocketSnapshotUDPPorts ? @"known" : @"unknown";
            reply(status);
            return;
        }

        if (self.mihomoSocketQueryInFlight) {
            status[@"tcpListenPorts"] = @[];
            status[@"udpListenPorts"] = @[];
            status[@"tcpListenPortsState"] = @"unknown";
            status[@"udpListenPortsState"] = @"unknown";
            reply(status);
            return;
        }

        NSString *queryID = NSUUID.UUID.UUIDString;
        self.mihomoSocketQueryID = queryID;
        self.mihomoSocketQueryInFlight = YES;
        NSTimeInterval deadline = now + kMihomoSocketQueryTimeout;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSArray<NSNumber *> *tcpPorts = [self listeningPortsForPID:pid
                                                              protocol:@"TCP"
                                                              deadline:deadline];
            NSArray<NSNumber *> *udpPorts = [self listeningPortsForPID:pid
                                                              protocol:@"UDP"
                                                              deadline:deadline];
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.mihomoSocketQueryID isEqualToString:queryID]) {
                    self.mihomoSocketQueryInFlight = NO;
                    self.mihomoSocketQueryID = nil;
                }

                BOOL sameLaunch = self.mihomoTask == task &&
                    task.isRunning &&
                    self.mihomoProcessID == pid &&
                    [self.mihomoLaunchID isEqualToString:launchID];
                if (sameLaunch) {
                    self.mihomoSocketSnapshotLaunchID = launchID;
                    self.mihomoSocketSnapshotPID = pid;
                    self.mihomoSocketSnapshotTCPPorts = tcpPorts;
                    self.mihomoSocketSnapshotUDPPorts = udpPorts;
                    self.mihomoSocketSnapshotUptime = NSProcessInfo.processInfo.systemUptime;
                    status[@"tcpListenPorts"] = tcpPorts ?: @[];
                    status[@"udpListenPorts"] = udpPorts ?: @[];
                    status[@"tcpListenPortsState"] = tcpPorts ? @"known" : @"unknown";
                    status[@"udpListenPortsState"] = udpPorts ? @"known" : @"unknown";
                } else {
                    status[@"tcpListenPorts"] = @[];
                    status[@"udpListenPorts"] = @[];
                    status[@"tcpListenPortsState"] = @"unknown";
                    status[@"udpListenPortsState"] = @"unknown";
                }
                reply(status);
            });
        });
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
    void (^enqueueRestart)(void) = ^{
        [self enqueueMihomoLifecycleOperation:^{
            NSTask *task = self.mihomoTask;
            NSString *launchID = [self.mihomoLaunchID copy];
            if (task && task.isRunning &&
                (self.mihomoTask != task ||
                 launchID.length == 0 ||
                 ![self.mihomoLaunchID isEqualToString:launchID])) {
                NSLog(@"[mihomo_core] Skipping stale helper-host restart for launch %@",
                      launchID ?: @"unknown");
                reply(@"Refusing to restart the helper for a stale Mihomo launch");
                [self finishMihomoLifecycleOperation];
                return;
            }
            [self terminateMihomoTask:task launchID:launchID completion:^(NSString *error) {
                if (error) {
                    reply(error);
                    [self finishMihomoLifecycleOperation];
                    return;
                }
                NSLog(@"[mihomo_core] Restarting helper host after an external-core startup failure");
                reply(nil);
                [self finishMihomoLifecycleOperation];
                dispatch_after(
                    dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                    dispatch_get_main_queue(),
                    ^{
                        self.shouldQuit = YES;
                    }
                );
            }];
        }];
    };
    if (NSThread.isMainThread) {
        enqueueRestart();
    } else {
        dispatch_sync(dispatch_get_main_queue(), enqueueRestart);
    }
}

- (void)enableProxyWithPort:(int)port
          socksPort:(int)socksPort
            pac:(NSString *)pac
            filterInterface:(BOOL)filterInterface
                 ignoreList:(NSArray<NSString *>*)ignoreList
            error:(stringReplyBlock)reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        ProxySettingTool *tool = [ProxySettingTool new];
        reply([tool enableProxyWithport:port socksPort:socksPort pacUrl:pac filterInterface:filterInterface ignoreList:ignoreList]);
    });
}

- (void)disableProxyWithFilterInterface:(BOOL)filterInterface reply:(stringReplyBlock)reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        ProxySettingTool *tool = [ProxySettingTool new];
        reply([tool disableProxyWithfilterInterface:filterInterface]);
    });
}


- (void)restoreProxyWithCurrentPort:(int)port
                          socksPort:(int)socksPort
                               info:(NSDictionary *)dict
                    filterInterface:(BOOL)filterInterface
                              error:(stringReplyBlock)reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        ProxySettingTool *tool = [ProxySettingTool new];
        reply([tool restoreProxySetting:dict currentPort:port currentSocksPort:socksPort filterInterface:filterInterface]);
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
    NSString *validationFailure = nil;
    NSString *clientCDHash = nil;
    NSString *sourcePath = [self validatedMihomoSourcePath:binaryPath
                                            forConnection:NSXPCConnection.currentConnection
                                      clientCDHashOutput:&clientCDHash
                                                   failure:&validationFailure];
    if (!sourcePath) {
        reply(validationFailure ?: @"Mihomo launch rejected an unapproved executable path");
        return;
    }
    NSString *approvedBinaryPath = ClashFXHelperApprovedCorePath;
    [self enqueueMihomoLifecycleOperation:^{
        NSTask *staleTask = self.mihomoTask;
        NSString *staleLaunchID = [self.mihomoLaunchID copy];
        stringReplyBlock finishReply = ^(NSString *error) {
            [self finishMihomoLifecycleOperation];
            reply(error);
        };

        dispatch_block_t launch = ^{
            [self launchMihomoCoreWithBinaryPath:approvedBinaryPath
                                sourceBinaryPath:sourcePath
                                     clientCDHash:clientCDHash
                                      configPath:configPath
                                         homeDir:homeDir
                                           reply:finishReply];
        };
        if (staleTask && staleTask.isRunning) {
            [self terminateMihomoTask:staleTask launchID:staleLaunchID completion:^(NSString *error) {
                if (error) {
                    finishReply(error);
                } else {
                    launch();
                }
            }];
        } else {
            launch();
        }
    }];
}

- (void)launchMihomoCoreWithBinaryPath:(NSString *)binaryPath
                    sourceBinaryPath:(NSString *)sourceBinaryPath
                         clientCDHash:(NSString *)clientCDHash
                            configPath:(NSString *)configPath
                               homeDir:(NSString *)homeDir
                                 reply:(stringReplyBlock)reply {
    if (![binaryPath isEqualToString:ClashFXHelperApprovedCorePath]) {
        reply(@"Refusing to execute a Mihomo binary outside the approved root-owned helper path");
        return;
    }
    NSString *trustFailure = nil;
    if (![self approvedTrustEntryForClientCDHash:clientCDHash
                                     sourcePath:sourceBinaryPath
                                        failure:&trustFailure]) {
        reply(trustFailure ?: @"Approved Mihomo core trust validation failed");
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
    self.mihomoConfigPath = configPath;
    self.mihomoBinaryPath = ClashFXHelperApprovedCorePath;
    self.mihomoSourceBinaryPath = sourceBinaryPath;
    self.mihomoLaunchDate = launchDate;
    self.mihomoProcessID = 0;
    self.mihomoLastTerminationSummary = nil;
    self.mihomoSocketSnapshotLaunchID = nil;
    self.mihomoSocketSnapshotPID = 0;
    self.mihomoSocketSnapshotTCPPorts = nil;
    self.mihomoSocketSnapshotUDPPorts = nil;
    self.mihomoSocketSnapshotUptime = 0;

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
    void (^enqueueStop)(void) = ^{
        [self enqueueMihomoLifecycleOperation:^{
            NSTask *task = self.mihomoTask;
            NSString *launchID = [self.mihomoLaunchID copy];
            [self terminateMihomoTask:task launchID:launchID completion:^(NSString *error) {
                [self finishMihomoLifecycleOperation];
                reply(error);
            }];
        }];
    };
    if (NSThread.isMainThread) {
        enqueueStop();
    } else {
        dispatch_sync(dispatch_get_main_queue(), enqueueStop);
    }
}

// MARK: - DNS

- (void)overrideDNSWithServers:(NSArray<NSString *> *)servers
               filterInterface:(BOOL)filterInterface
                         reply:(stringReplyBlock)reply {
    dispatch_async(ClashFXDNSOperationQueue(), ^{
        ProxySettingTool *tool = [ProxySettingTool new];
        reply([tool overrideDNSWithServers:servers filterInterface:filterInterface]);
    });
}

- (void)captureDNSWithFilterInterface:(BOOL)filterInterface reply:(dictReplyBlock)reply {
    dispatch_async(ClashFXDNSOperationQueue(), ^{
        ProxySettingTool *tool = [ProxySettingTool new];
        NSDictionary *snapshot = [tool captureDNSWithFilterInterface:filterInterface];
        if (!snapshot[@"error"]) {
            self.latestDNSCaptureTransactionID = snapshot[@"transactionID"];
        }
        reply(snapshot);
    });
}

- (void)applyDNSWithSnapshot:(NSDictionary *)snapshot
                     servers:(NSArray<NSString *> *)servers
                       reply:(stringReplyBlock)reply {
    dispatch_async(ClashFXDNSOperationQueue(), ^{
        NSString *transactionID = [snapshot[@"transactionID"] isKindOfClass:[NSString class]]
            ? snapshot[@"transactionID"]
            : nil;
        if (transactionID.length == 0) {
            reply(@"DNS apply snapshot has no transaction id");
            return;
        }
        if (self.latestDNSCaptureTransactionID.length > 0 &&
            ![self.latestDNSCaptureTransactionID isEqualToString:transactionID]) {
            reply(@"DNS apply rejected a superseded snapshot transaction");
            return;
        }
        if (self.latestDNSWriteRestored &&
            [self.latestDNSWriteTransactionID isEqualToString:transactionID]) {
            reply(@"DNS apply rejected a transaction that has already been restored");
            return;
        }

        // Fence older restore RPCs before the preferences write can partially fail.
        self.latestDNSWriteTransactionID = transactionID;
        self.latestDNSWriteRestored = NO;
        ProxySettingTool *tool = [ProxySettingTool new];
        NSString *error = [tool applyDNSWithSnapshot:snapshot servers:servers];
        reply(error);
    });
}

- (void)restoreDNSWithSavedInfo:(NSDictionary *)savedInfo
                filterInterface:(BOOL)filterInterface
                          reply:(stringReplyBlock)reply {
    dispatch_async(ClashFXDNSOperationQueue(), ^{
        NSString *snapshotError = nil;
        ClashFXDNSRestoreSnapshotKind snapshotKind = ClashFXDNSClassifyRestoreSnapshot(savedInfo,
                                                                                       &snapshotError);
        if (snapshotKind == ClashFXDNSRestoreSnapshotKindInvalid) {
            reply(snapshotError ?: @"DNS restore snapshot is invalid");
            return;
        }
        BOOL isVersion2 = snapshotKind == ClashFXDNSRestoreSnapshotKindVersion2;
        NSString *transactionID = [savedInfo[@"transactionID"] isKindOfClass:[NSString class]]
            ? savedInfo[@"transactionID"]
            : nil;
        if (isVersion2 && !ClashFXDNSRestoreSnapshotMatchesLatestWrite(
                self.latestDNSWriteTransactionID, savedInfo)) {
            reply(@"DNS restore rejected a snapshot older than the latest write transaction");
            return;
        }
        ProxySettingTool *tool = [ProxySettingTool new];
        NSString *error = [tool restoreDNS:savedInfo filterInterface:filterInterface];
        if (!error && isVersion2 && transactionID.length > 0) {
            self.latestDNSWriteRestored = YES;
        }
        reply(error);
    });
}

- (void)getCurrentDNSSetting:(dictReplyBlock)reply {
    dispatch_async(ClashFXDNSOperationQueue(), ^{
        NSDictionary *info = [ProxySettingTool currentDNSSettings];
        reply(info);
    });
}

- (void)flushDNSCacheWithReply:(stringReplyBlock)reply {
    dispatch_async(ClashFXDNSOperationQueue(), ^{
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
