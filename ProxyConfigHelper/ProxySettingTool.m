//
//  ProxySettingTool.m
//  com.clashfx.app.Helper
//
//  Created by yichengchen on 2019/8/17.
//  Copyright © 2019 west2online. All rights reserved.
//

#import "ProxySettingTool.h"
#import <SystemConfiguration/SystemConfiguration.h>
#import <AppKit/AppKit.h>
#import "CommonUtils.h"
#import "ProxySettingRestorationPolicy.h"
#import "ProxySettingDNSPolicy.h"

static NSString * const ClashFXProxyCaptureErrorKey = @"__ClashFXProxyCaptureError";
static NSString * const ClashFXCapturedServiceIDsKey = @"__ClashFXCapturedServiceIDs";
static NSString * const ClashFXDNSCaptureErrorKey = @"error";
static NSString * const ClashFXDNSServicesKey = @"services";
static NSString * const ClashFXDNSVersionKey = @"version";
static NSString * const ClashFXDNSExpectedServersKey = @"expectedServers";

@interface ProxySettingTool()
@property (nonatomic, assign) AuthorizationRef authRef;
+ (NSDictionary *)dnsServiceMapForPreferences:(SCPreferencesRef)ref
                               filterInterface:(BOOL)filterInterface
                                         error:(NSString **)error;
- (nullable NSString *)setDNSChanges:(NSDictionary<NSString *, id> *)changes
                      inPreferences:(SCPreferencesRef)ref;
- (nullable NSString *)verifyDNSChanges:(NSDictionary<NSString *, id> *)changes;

@end

@implementation ProxySettingTool

- (instancetype)init {
    if (self = [super init]) {
        [self localAuth];
    }
    return self;
}

// MARK: - Public

- (nullable NSString *)enableProxyWithport:(int)port socksPort:(int)socksPort
                     pacUrl:(NSString *)pacUrl
            filterInterface:(BOOL)filterInterface
                 ignoreList:(NSArray<NSString *>*)ignoreList {

    return [self applySCNetworkSettingWithRef:^NSString *(SCPreferencesRef ref) {
        __block NSString *error = nil;
        [ProxySettingTool getDiviceListWithPrefRef:ref filterInterface:filterInterface devices:^(NSString *key, NSDictionary *dict) {
            if (!error) {
                error = [self enableProxySettings:ref interface:key port:port socksPort:socksPort ignoreList:ignoreList pac:pacUrl];
            }
        }];
        return error;
    }];
}

- (nullable NSString *)disableProxyWithfilterInterface:(BOOL)filterInterface {
    return [self applySCNetworkSettingWithRef:^NSString *(SCPreferencesRef ref) {
        __block NSString *error = nil;
        [ProxySettingTool getDiviceListWithPrefRef:ref filterInterface:filterInterface devices:^(NSString *key, NSDictionary *dict) {
            if (!error) {
                error = [self disableProxySetting:ref interface:key];
            }
        }];
        return error;
    }];
}

- (nullable NSString *)restoreProxySetting:(NSDictionary *)savedInfo
                currentPort:(int)port
           currentSocksPort:(int)socksPort
            filterInterface:(BOOL)filterInterface{
    return [self applySCNetworkSettingWithRef:^NSString *(SCPreferencesRef ref) {
        __block NSString *error = nil;
        // Restore every current service. Captured dictionaries can be applied
        // idempotently; the tri-state policy leaves services added after the
        // capture untouched even if the user changed the filter while active.
        [ProxySettingTool getDiviceListWithPrefRef:ref filterInterface:NO devices:^(NSString *key, NSDictionary *dict) {
            if (error) {
                return;
            }
            ProxySettingRestorationAction action = ProxySettingRestorationActionLeaveUntouched;
            NSDictionary *proxySetting = [ProxySettingRestorationPolicy proxyDictionaryForServiceID:key
                                                                                           snapshot:savedInfo
                                                                                             action:&action];
            if (action == ProxySettingRestorationActionRemovePath) {
                error = [self removeProxyConfig:ref interface:key];
            } else if (action == ProxySettingRestorationActionApplyDictionary) {
                error = [self setProxyConfig:ref interface:key proxySetting:proxySetting];
            }
        }];
        return error;
    }];
}

+ (NSMutableDictionary<NSString *, id> *)currentProxySettings {
    __block NSMutableDictionary<NSString *, id> *info = [NSMutableDictionary dictionary];
    SCPreferencesRef ref = SCPreferencesCreate(nil, CFSTR("ClashFX"), nil);
    if (!ref) {
        info[ClashFXProxyCaptureErrorKey] = @"Unable to create system network preferences for proxy capture";
        return info;
    }
    NSMutableArray<NSString *> *serviceIDs = [NSMutableArray array];
    [ProxySettingTool getDiviceListWithPrefRef:ref filterInterface:NO devices:^(NSString *key, NSDictionary *dev) {
        [serviceIDs addObject:key];
        NSDictionary *proxySettings = dev[(__bridge NSString *)kSCEntNetProxies];
        if ([proxySettings isKindOfClass:[NSDictionary class]]) {
            // Keep the property-list payload byte-for-byte. Do not synthesize
            // disabled keys for a partial/PAC-only proxy configuration.
            info[key] = [proxySettings copy];
        }
    }];
    info[ClashFXCapturedServiceIDsKey] = [serviceIDs copy];
    CFRelease(ref);
    
    return info;
}

// MARK: - Private

- (void)dealloc {
    [self freeAuth];
}


- (NSDictionary *)getProxySetting:(BOOL)enable port:(int) port
                        socksPort: (int)socksPort pac:(NSString *)pac
                       ignoreList:(NSArray<NSString *>*)ignoreList {
    
    NSMutableDictionary *proxySettings = [NSMutableDictionary dictionary];
    
    NSString *ip = enable ? @"127.0.0.1" : @"";
    NSInteger enableInt = enable ? 1 : 0;
    NSInteger enablePac = [pac length] > 0;
    
    proxySettings[(__bridge NSString *)kCFNetworkProxiesHTTPProxy] = ip;
    proxySettings[(__bridge NSString *)kCFNetworkProxiesHTTPEnable] = @(enableInt);
    proxySettings[(__bridge NSString *)kCFNetworkProxiesHTTPSProxy] = ip;
    proxySettings[(__bridge NSString *)kCFNetworkProxiesHTTPSEnable] = @(enableInt);
    
    proxySettings[(__bridge NSString *)kCFNetworkProxiesSOCKSProxy] = ip;
    proxySettings[(__bridge NSString *)kCFNetworkProxiesSOCKSEnable] = @(enableInt);
    
    if (enable) {
        proxySettings[(__bridge NSString *)kCFNetworkProxiesHTTPPort] = @(port);
        proxySettings[(__bridge NSString *)kCFNetworkProxiesHTTPSPort] = @(port);
        proxySettings[(__bridge NSString *)kCFNetworkProxiesSOCKSPort] = @(socksPort);
        proxySettings[(__bridge NSString *)kCFNetworkProxiesExcludeSimpleHostnames] = @(YES);
    } else {
        proxySettings[(__bridge NSString *)kCFNetworkProxiesHTTPPort] = nil;
        proxySettings[(__bridge NSString *)kCFNetworkProxiesHTTPSPort] = nil;
        proxySettings[(__bridge NSString *)kCFNetworkProxiesSOCKSPort] = nil;
    }
    
    proxySettings[(__bridge NSString *)kCFNetworkProxiesProxyAutoConfigEnable] = @(enablePac);
    if (enablePac) {
        proxySettings[(__bridge NSString *)kCFNetworkProxiesProxyAutoConfigURLString] = pac;
    } else {
        proxySettings[(__bridge NSString *)kCFNetworkProxiesProxyAutoConfigURLString] = nil;
    }
    
    if (enable) {
        proxySettings[(__bridge NSString *)kCFNetworkProxiesExceptionsList] = ignoreList;
    } else {
        proxySettings[(__bridge NSString *)kCFNetworkProxiesExceptionsList] = @[];
    }
    
    return proxySettings;
}

- (NSString *)proxySettingPathWithInterface:(NSString *)interfaceKey {
    return [NSString stringWithFormat:@"/%@/%@/%@",
            (NSString *)kSCPrefNetworkServices,
            interfaceKey,
            (NSString *)kSCEntNetProxies];
}

- (nullable NSString *)enableProxySettings:(SCPreferencesRef)prefs
                  interface:(NSString *)interfaceKey
                       port:(int) port
                  socksPort:(int) socksPort
                 ignoreList:(NSArray<NSString *>*)ignoreList
                        pac:(NSString *)pac {
    
    NSDictionary *proxySettings = [self getProxySetting:YES port:port socksPort:socksPort pac:pac ignoreList:ignoreList];
    return [self setProxyConfig:prefs interface:interfaceKey proxySetting:proxySettings];
    
}

- (nullable NSString *)disableProxySetting:(SCPreferencesRef)prefs
                  interface:(NSString *)interfaceKey {
    NSDictionary *proxySettings = [self getProxySetting:NO port:0 socksPort:0 pac:nil ignoreList:@[]];
    return [self setProxyConfig:prefs interface:interfaceKey proxySetting:proxySettings];
}

- (nullable NSString *)setProxyConfig:(SCPreferencesRef)prefs
             interface:(NSString *)interfaceKey
          proxySetting:(NSDictionary *)proxySettings {
    NSString *path = [self proxySettingPathWithInterface:interfaceKey];
    if (!SCPreferencesPathSetValue(prefs,
                                   (__bridge CFStringRef)path,
                                   (__bridge CFDictionaryRef)proxySettings)) {
        return [self preferenceErrorMessageForOperation:@"setting proxy preferences"];
    }
    return nil;
}

- (nullable NSString *)removeProxyConfig:(SCPreferencesRef)prefs interface:(NSString *)interfaceKey {
    NSString *path = [self proxySettingPathWithInterface:interfaceKey];
    if (!SCPreferencesPathRemoveValue(prefs, (__bridge CFStringRef)path)) {
        return [self preferenceErrorMessageForOperation:@"removing proxy preferences"];
    }
    return nil;
}

+ (void)getDiviceListWithPrefRef:(SCPreferencesRef)ref
                 filterInterface:(BOOL)filterInterface
                         devices:(void(^)(NSString *, NSDictionary *))callback {
    NSDictionary *sets = (__bridge NSDictionary *)SCPreferencesGetValue(ref, kSCPrefNetworkServices);
    if (![sets isKindOfClass:[NSDictionary class]]) {
        return;
    }
    for (NSString *key in [sets allKeys]) {
        NSMutableDictionary *dict = [sets objectForKey:key];
        NSString *hardware = [dict valueForKeyPath:@"Interface.Hardware"];
        if (!filterInterface || [hardware isEqualToString:@"AirPort"]
            || [hardware isEqualToString:@"Wi-Fi"]
            || [hardware isEqualToString:@"Ethernet"]
            ) {
            callback(key,dict);
        }
    }
}

- (NSString *)preferenceErrorMessageForOperation:(NSString *)operation {
    const char *errorString = SCErrorString(SCError());
    NSString *detail = errorString ? [NSString stringWithUTF8String:errorString] : @"unknown error";
    return [NSString stringWithFormat:@"Unable to %@: %@", operation, detail];
}

- (nullable NSString *)applySCNetworkSettingWithRef:(NSString *(^)(SCPreferencesRef))callback {
    SCPreferencesRef ref = SCPreferencesCreateWithAuthorization(nil, CFSTR("com.clashfx.app.Helper.config"), nil, self.authRef);
    if (!ref) {
        return @"Unable to create authorized system network preferences";
    }
    if (!SCPreferencesLock(ref, false)) {
        NSString *error = [self preferenceErrorMessageForOperation:@"locking system network preferences"];
        CFRelease(ref);
        return error;
    }

    NSString *operationError = callback(ref);
    if (!operationError && !SCPreferencesCommitChanges(ref)) {
        operationError = [self preferenceErrorMessageForOperation:@"committing system network preferences"];
    }
    if (!operationError && !SCPreferencesApplyChanges(ref)) {
        operationError = [self preferenceErrorMessageForOperation:@"applying system network preferences"];
    }

    if (!operationError) {
        // SystemConfiguration exposes synchronization as a void operation, so it
        // cannot provide a reliable per-call failure result. In particular, do
        // not inspect SCError() here: it may describe an earlier operation.
        SCPreferencesSynchronize(ref);
    }
    BOOL unlocked = SCPreferencesUnlock(ref);
    CFRelease(ref);
    if (!operationError && !unlocked) {
        return [self preferenceErrorMessageForOperation:@"unlocking system network preferences"];
    }
    return operationError;
}

- (AuthorizationFlags)authFlags {
    AuthorizationFlags authFlags = kAuthorizationFlagDefaults
    | kAuthorizationFlagExtendRights
    | kAuthorizationFlagInteractionAllowed
    | kAuthorizationFlagPreAuthorize;
    return authFlags;
}

- (void)localAuth {
    OSStatus myStatus;
    AuthorizationFlags myFlags = [self authFlags];
    myStatus = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment, myFlags, &_authRef);
    
    if (myStatus != errAuthorizationSuccess)
    {
        return;
    }
    
    AuthorizationItem myItems = {kAuthorizationRightExecute, 0, NULL, 0};
    AuthorizationRights myRights = {1, &myItems};
    myStatus = AuthorizationCopyRights (self.authRef, &myRights, NULL, myFlags, NULL );
}


- (void)freeAuth {
    if (self.authRef) {
        AuthorizationFree(self.authRef, [self authFlags]);
    }
}

// MARK: - DNS

- (NSString *)dnsSettingPathWithInterface:(NSString *)interfaceKey {
    return [NSString stringWithFormat:@"/%@/%@/%@",
            (NSString *)kSCPrefNetworkServices,
            interfaceKey,
            (NSString *)kSCEntNetDNS];
}

+ (NSDictionary *)dnsServiceMapForPreferences:(SCPreferencesRef)ref
                               filterInterface:(BOOL)filterInterface
                                         error:(NSString **)error {
    if (error) {
        *error = nil;
    }
    CFPropertyListRef value = SCPreferencesGetValue(ref, kSCPrefNetworkServices);
    if (!value || CFGetTypeID(value) != CFDictionaryGetTypeID()) {
        if (error) {
            *error = @"Unable to read current network services for DNS operation";
        }
        return nil;
    }

    NSDictionary *networkServices = (__bridge NSDictionary *)value;
    NSMutableDictionary<NSString *, id> *dnsByServiceID = [NSMutableDictionary dictionary];
    for (id serviceID in networkServices) {
        id serviceValue = networkServices[serviceID];
        if (![serviceID isKindOfClass:[NSString class]] ||
            ![serviceValue isKindOfClass:[NSDictionary class]]) {
            if (error) {
                *error = @"Network preferences contain an invalid service entry";
            }
            return nil;
        }
        NSDictionary *service = serviceValue;
        NSString *hardware = [service valueForKeyPath:@"Interface.Hardware"];
        BOOL eligible = !filterInterface ||
            [hardware isEqualToString:@"AirPort"] ||
            [hardware isEqualToString:@"Wi-Fi"] ||
            [hardware isEqualToString:@"Ethernet"];
        if (!eligible) {
            continue;
        }

        id dnsSettings = service[(__bridge NSString *)kSCEntNetDNS];
        if (!dnsSettings) {
            dnsByServiceID[serviceID] = [NSNull null];
        } else if ([dnsSettings isKindOfClass:[NSDictionary class]]) {
            dnsByServiceID[serviceID] = [dnsSettings copy];
        } else {
            if (error) {
                *error = [NSString stringWithFormat:
                    @"Network service %@ has an invalid DNS settings value", serviceID];
            }
            return nil;
        }
    }
    return [dnsByServiceID copy];
}

- (NSDictionary *)captureDNSWithFilterInterface:(BOOL)filterInterface {
    SCPreferencesRef ref = SCPreferencesCreate(nil, CFSTR("ClashFX DNS capture"), nil);
    if (!ref) {
        return @{ClashFXDNSCaptureErrorKey: @"Unable to create system network preferences for DNS capture"};
    }

    NSString *captureError = nil;
    NSDictionary *services = [ProxySettingTool dnsServiceMapForPreferences:ref
                                                           filterInterface:filterInterface
                                                                     error:&captureError];
    CFRelease(ref);
    if (!services) {
        return @{ClashFXDNSCaptureErrorKey: captureError ?: @"Unable to capture current DNS settings"};
    }

    NSDictionary *snapshot = ClashFXDNSCaptureSnapshot(NSUUID.UUID.UUIDString, services);
    return snapshot ?: @{ClashFXDNSCaptureErrorKey: @"Unable to create DNS snapshot metadata"};
}

- (nullable NSString *)applyDNSWithSnapshot:(NSDictionary *)snapshot
                                    servers:(NSArray<NSString *> *)servers {
    if (![snapshot isKindOfClass:[NSDictionary class]] ||
        ![snapshot[ClashFXDNSVersionKey] respondsToSelector:@selector(integerValue)] ||
        [snapshot[ClashFXDNSVersionKey] integerValue] != 2) {
        return @"DNS apply requires a version 2 snapshot";
    }
    NSDictionary<NSString *, id> *originals = snapshot[ClashFXDNSServicesKey];
    if (![originals isKindOfClass:[NSDictionary class]] || originals.count == 0) {
        return @"DNS snapshot contains no captured services";
    }
    NSArray<NSString *> *requestedServiceIDs = ClashFXDNSApplyServiceIDs(snapshot);
    if (!requestedServiceIDs) {
        return @"DNS snapshot contains no services selected for apply";
    }
    if (!ClashFXDNSIsValidServerList(servers)) {
        return @"DNS server list is invalid";
    }
    id alreadyAppliedValue = snapshot[ClashFXDNSExpectedServersKey] ?: servers;
    if (!ClashFXDNSIsValidServerList(alreadyAppliedValue)) {
        return @"DNS snapshot contains an invalid expected server list";
    }
    NSArray<NSString *> *alreadyAppliedServers = alreadyAppliedValue;

    __block NSMutableDictionary<NSString *, id> *changes = [NSMutableDictionary dictionary];
    NSString *operationError = [self applySCNetworkSettingWithRef:^NSString *(SCPreferencesRef ref) {
        NSString *readError = nil;
        NSDictionary<NSString *, id> *current = [ProxySettingTool dnsServiceMapForPreferences:ref
                                                                             filterInterface:NO
                                                                                       error:&readError];
        if (!current) {
            return readError;
        }

        NSUInteger presentServiceCount = 0;
        for (NSString *serviceID in requestedServiceIDs) {
            id original = ClashFXDNSOriginalFromSnapshotEntry(originals[serviceID]);
            if (!original) {
                return @"DNS snapshot contains an invalid service original";
            }
            id currentSettings = current[serviceID];
            if (!currentSettings) {
                // A service removed since capture needs neither an apply nor a restore.
                continue;
            }
            presentServiceCount += 1;
            if (!ClashFXDNSCurrentMatchesOriginalOrApplied(currentSettings,
                                                           original,
                                                           alreadyAppliedServers)) {
                return [NSString stringWithFormat:
                    @"DNS settings for service %@ changed after capture", serviceID];
            }

            NSDictionary *target = ClashFXDNSSettingsByReplacingServers(original, servers);
            if (!target) {
                return [NSString stringWithFormat:
                    @"Unable to build DNS settings for service %@", serviceID];
            }
            if (![currentSettings isEqual:target]) {
                changes[serviceID] = target;
            }
        }
        if (presentServiceCount == 0) {
            return @"No captured DNS service remains available to apply";
        }
        return [self setDNSChanges:changes inPreferences:ref];
    }];
    if (operationError) {
        return operationError;
    }
    return changes.count > 0 ? [self verifyDNSChanges:changes] : nil;
}

- (nullable NSString *)overrideDNSWithServers:(NSArray<NSString *> *)servers
                              filterInterface:(BOOL)filterInterface {
    if (!ClashFXDNSIsValidServerList(servers)) {
        return @"DNS server list is invalid";
    }

    __block NSMutableDictionary<NSString *, id> *changes = [NSMutableDictionary dictionary];
    NSString *operationError = [self applySCNetworkSettingWithRef:^NSString *(SCPreferencesRef ref) {
        NSString *readError = nil;
        NSDictionary<NSString *, id> *current = [ProxySettingTool dnsServiceMapForPreferences:ref
                                                                             filterInterface:filterInterface
                                                                                       error:&readError];
        if (!current) {
            return readError;
        }
        for (NSString *serviceID in current) {
            NSDictionary *target = ClashFXDNSSettingsByReplacingServers(current[serviceID], servers);
            if (!target) {
                return [NSString stringWithFormat:
                    @"Unable to build DNS settings for service %@", serviceID];
            }
            if (![current[serviceID] isEqual:target]) {
                changes[serviceID] = target;
            }
        }
        return [self setDNSChanges:changes inPreferences:ref];
    }];
    if (operationError) {
        return operationError;
    }
    return changes.count > 0 ? [self verifyDNSChanges:changes] : nil;
}

- (nullable NSString *)restoreDNS:(NSDictionary *)savedInfo
                  filterInterface:(BOOL)filterInterface {
    (void)filterInterface;
    NSString *snapshotError = nil;
    ClashFXDNSRestoreSnapshotKind snapshotKind = ClashFXDNSClassifyRestoreSnapshot(savedInfo,
                                                                                   &snapshotError);
    if (snapshotKind == ClashFXDNSRestoreSnapshotKindInvalid) {
        return snapshotError ?: @"DNS restore snapshot is invalid";
    }
    BOOL isVersion2 = snapshotKind == ClashFXDNSRestoreSnapshotKindVersion2;
    NSDictionary<NSString *, id> *originals = isVersion2
        ? savedInfo[ClashFXDNSServicesKey]
        : savedInfo;
    if (![originals isKindOfClass:[NSDictionary class]]) {
        return @"DNS restore snapshot has no service map";
    }

    NSArray<NSString *> *expectedServers = ClashFXTUNDNSServers();
    if (isVersion2 && savedInfo[ClashFXDNSExpectedServersKey]) {
        id savedExpectedServers = savedInfo[ClashFXDNSExpectedServersKey];
        if (!ClashFXDNSIsValidServerList(savedExpectedServers)) {
            return @"DNS snapshot contains an invalid expected server list";
        }
        expectedServers = savedExpectedServers;
    }

    __block NSMutableDictionary<NSString *, id> *changes = [NSMutableDictionary dictionary];
    __block NSMutableArray<NSString *> *ownershipConflicts = [NSMutableArray array];
    NSString *operationError = [self applySCNetworkSettingWithRef:^NSString *(SCPreferencesRef ref) {
        NSString *readError = nil;
        NSDictionary<NSString *, id> *current = [ProxySettingTool dnsServiceMapForPreferences:ref
                                                                             filterInterface:NO
                                                                                       error:&readError];
        if (!current) {
            return readError;
        }

        for (id serviceID in originals) {
            if (![serviceID isKindOfClass:[NSString class]]) {
                return @"DNS restore snapshot contains an invalid service id";
            }
            id currentSettings = current[serviceID];
            if (!currentSettings) {
                // A removed service cannot be restored and must not be recreated.
                continue;
            }

            id original = isVersion2
                ? ClashFXDNSOriginalFromSnapshotEntry(originals[serviceID])
                : originals[serviceID];
            if (isVersion2) {
                if (!original) {
                    return [NSString stringWithFormat:
                        @"DNS snapshot contains an invalid original for service %@", serviceID];
                }
                ClashFXDNSRestoreDecision decision = ClashFXDNSRestoreDecisionForCurrent(
                    currentSettings, original, expectedServers);
                if (decision == ClashFXDNSRestoreDecisionRestoreDictionary) {
                    changes[serviceID] = original;
                } else if (decision == ClashFXDNSRestoreDecisionRemovePath) {
                    changes[serviceID] = [NSNull null];
                } else if (decision == ClashFXDNSRestoreDecisionOwnershipChanged) {
                    [ownershipConflicts addObject:serviceID];
                } else if (decision == ClashFXDNSRestoreDecisionInvalidSnapshot) {
                    return [NSString stringWithFormat:
                        @"DNS snapshot contains invalid restore data for service %@", serviceID];
                }
            } else {
                // Legacy flat snapshots could not represent absence. Only use a
                // captured dictionary whose current settings still match the exact
                // ClashFX TUN override and its original preserved fields.
                if (![original isKindOfClass:[NSDictionary class]]) {
                    continue;
                }
                if ([currentSettings isEqual:original]) {
                    continue;
                }
                if (!ClashFXDNSCurrentHasTUNServer(currentSettings)) {
                    continue;
                }
                if (ClashFXDNSLegacyCurrentIsOwned(currentSettings, original)) {
                    changes[serviceID] = original;
                } else {
                    [ownershipConflicts addObject:serviceID];
                }
            }
        }
        return [self setDNSChanges:changes inPreferences:ref];
    }];
    if (operationError) {
        return operationError;
    }

    if (changes.count > 0) {
        NSString *readbackError = [self verifyDNSChanges:changes];
        if (readbackError) {
            return readbackError;
        }
    }
    if (ownershipConflicts.count > 0) {
        return [NSString stringWithFormat:
            @"DNS settings changed outside ClashFX for service id(s): %@; refusing to restore them",
            [ownershipConflicts componentsJoinedByString:@", "]];
    }
    return nil;
}

- (nullable NSString *)setDNSChanges:(NSDictionary<NSString *, id> *)changes
                      inPreferences:(SCPreferencesRef)ref {
    for (NSString *serviceID in changes) {
        NSString *path = [self dnsSettingPathWithInterface:serviceID];
        id settings = changes[serviceID];
        BOOL succeeded = settings == [NSNull null]
            ? SCPreferencesPathRemoveValue(ref, (__bridge CFStringRef)path)
            : SCPreferencesPathSetValue(ref,
                                        (__bridge CFStringRef)path,
                                        (__bridge CFDictionaryRef)settings);
        if (!succeeded) {
            return [self preferenceErrorMessageForOperation:
                settings == [NSNull null] ? @"removing DNS preferences" : @"setting DNS preferences"];
        }
    }
    return nil;
}

- (nullable NSString *)verifyDNSChanges:(NSDictionary<NSString *, id> *)changes {
    SCPreferencesRef ref = SCPreferencesCreate(nil, CFSTR("ClashFX DNS verification"), nil);
    if (!ref) {
        return @"Unable to create system network preferences for DNS readback verification";
    }
    SCPreferencesSynchronize(ref);
    NSString *readError = nil;
    NSDictionary<NSString *, id> *current = [ProxySettingTool dnsServiceMapForPreferences:ref
                                                                         filterInterface:NO
                                                                                   error:&readError];
    CFRelease(ref);
    if (!current) {
        return readError ?: @"Unable to read DNS preferences after applying changes";
    }
    for (NSString *serviceID in changes) {
        id actual = current[serviceID];
        if (!actual || ![actual isEqual:changes[serviceID]]) {
            return [NSString stringWithFormat:
                @"DNS readback verification failed for service %@", serviceID];
        }
    }
    return nil;
}

+ (NSMutableDictionary<NSString *, NSDictionary *> *)currentDNSSettings {
    NSMutableDictionary<NSString *, NSDictionary *> *info = [NSMutableDictionary dictionary];
    SCPreferencesRef ref = SCPreferencesCreate(nil, CFSTR("ClashFX DNS current settings"), nil);
    if (!ref) {
        return info;
    }
    NSString *readError = nil;
    NSDictionary<NSString *, id> *services = [ProxySettingTool dnsServiceMapForPreferences:ref
                                                                         filterInterface:YES
                                                                                   error:&readError];
    CFRelease(ref);
    if (!services) {
        (void)readError;
        return info;
    }
    for (NSString *serviceID in services) {
        id settings = services[serviceID];
        if ([settings isKindOfClass:[NSDictionary class]]) {
            info[serviceID] = [settings copy];
        }
    }
    return info;
}

@end
