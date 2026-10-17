#import <Foundation/Foundation.h>
#import <Security/Security.h>

static inline NSDictionary<NSString *, id> * _Nullable ClashFXCurrentProcessSigningDetails(void) {
    SecCodeRef currentCode = NULL;
    OSStatus status = SecCodeCopySelf(kSecCSDefaultFlags, &currentCode);
    if (status != errSecSuccess || currentCode == NULL) {
        return nil;
    }
    status = SecCodeCheckValidity(currentCode, kSecCSStrictValidate, NULL);
    if (status != errSecSuccess) {
        CFRelease(currentCode);
        return nil;
    }

    CFDictionaryRef signingInfo = NULL;
    status = SecCodeCopySigningInformation(currentCode,
                                           kSecCSSigningInformation,
                                           &signingInfo);
    CFRelease(currentCode);
    if (status != errSecSuccess || signingInfo == NULL) {
        return nil;
    }

    CFDataRef cdHash = CFDictionaryGetValue(signingInfo, kSecCodeInfoUnique);
    CFNumberRef signatureFlags = CFDictionaryGetValue(signingInfo, kSecCodeInfoFlags);
    if (!cdHash || CFGetTypeID(cdHash) != CFDataGetTypeID() ||
        !signatureFlags || CFGetTypeID(signatureFlags) != CFNumberGetTypeID()) {
        CFRelease(signingInfo);
        return nil;
    }

    const UInt8 *bytes = CFDataGetBytePtr(cdHash);
    CFIndex length = CFDataGetLength(cdHash);
    if (!bytes || length <= 0) {
        CFRelease(signingInfo);
        return nil;
    }
    NSMutableString *hexHash = [NSMutableString stringWithCapacity:(NSUInteger)length * 2];
    for (CFIndex index = 0; index < length; index += 1) {
        [hexHash appendFormat:@"%02x", bytes[index]];
    }

    int64_t rawFlags = 0;
    (void)CFNumberGetValue(signatureFlags, kCFNumberSInt64Type, &rawFlags);
    NSDictionary<NSString *, id> *details = @{
        @"CDHash": [hexHash copy],
        @"AdHoc": @((rawFlags & 0x2) != 0)
    };
    CFRelease(signingInfo);
    return details;
}
