#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <sys/types.h>

#ifndef ProxyConfigHelperTrustPolicy_h
#define ProxyConfigHelperTrustPolicy_h

static NSString * const ClashFXHelperApprovedCorePath =
    @"/Library/PrivilegedHelperTools/com.clashfx.app.Helper.mihomo_core";
static NSString * const ClashFXHelperTrustReceiptPath =
    @"/Library/PrivilegedHelperTools/com.clashfx.app.Helper.trust.plist";
static NSString * const ClashFXHelperClientBundleIdentifier = @"com.clashfx.app";
static NSInteger const ClashFXHelperTrustReceiptSchemaVersion = 1;

static inline BOOL ClashFXTrustPolicyIsLowercaseHexDigest(NSString *value, NSUInteger length) {
    if (![value isKindOfClass:[NSString class]] || value.length != length) {
        return NO;
    }
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
    return [value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

static inline BOOL ClashFXTrustPolicyCanAuthorizeClient(BOOL requirementValid,
                                                         BOOL signatureValid,
                                                         BOOL adHocSignature,
                                                         BOOL expectedBundleLayout,
                                                         NSString *bundleIdentifier,
                                                         NSString *clientCDHash,
                                                         NSString *pinnedCDHash) {
    if (!signatureValid ||
        !expectedBundleLayout ||
        ![bundleIdentifier isEqualToString:ClashFXHelperClientBundleIdentifier]) {
        return NO;
    }
    if (requirementValid) {
        return YES;
    }
    return adHocSignature &&
        ClashFXTrustPolicyIsLowercaseHexDigest(clientCDHash, 40) &&
        [clientCDHash isEqualToString:pinnedCDHash];
}

static inline BOOL ClashFXTrustPolicyIsSafeRootOwnedDirectory(uid_t owner, gid_t group, mode_t mode) {
    return owner == 0 &&
        group == 0 &&
        S_ISDIR(mode) &&
        (mode & (S_IWGRP | S_IWOTH)) == 0;
}

static inline BOOL ClashFXTrustPolicyIsSafeRootOwnedImmutableFile(uid_t owner,
                                                                  gid_t group,
                                                                  mode_t mode,
                                                                  unsigned long flags,
                                                                  BOOL executable) {
    BOOL hasRequiredAccess = executable ? (mode & S_IXUSR) != 0 : (mode & S_IRUSR) != 0;
    return owner == 0 &&
        group == 0 &&
        S_ISREG(mode) &&
        (mode & (S_IWUSR | S_IWGRP | S_IWOTH)) == 0 &&
        hasRequiredAccess &&
        (flags & UF_IMMUTABLE) != 0;
}

#endif /* ProxyConfigHelperTrustPolicy_h */
