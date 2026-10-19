#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, ClashFXDNSRestoreDecision) {
    ClashFXDNSRestoreDecisionRestoreDictionary,
    ClashFXDNSRestoreDecisionRemovePath,
    ClashFXDNSRestoreDecisionAlreadyRestored,
    ClashFXDNSRestoreDecisionDetached,
    ClashFXDNSRestoreDecisionOwnershipChanged,
    ClashFXDNSRestoreDecisionInvalidSnapshot,
};

typedef NS_ENUM(NSInteger, ClashFXDNSRestoreSnapshotKind) {
    ClashFXDNSRestoreSnapshotKindInvalid,
    ClashFXDNSRestoreSnapshotKindLegacyFlat,
    ClashFXDNSRestoreSnapshotKindVersion2,
};

static inline ClashFXDNSRestoreSnapshotKind ClashFXDNSClassifyRestoreSnapshot(
    NSDictionary *snapshot,
    NSString **error) {
    if (error) {
        *error = nil;
    }
    if (![snapshot isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = @"DNS restore snapshot is invalid";
        }
        return ClashFXDNSRestoreSnapshotKindInvalid;
    }

    id version = snapshot[@"version"];
    if (version) {
        if (![version isKindOfClass:[NSNumber class]] ||
            [(NSNumber *)version compare:@2] != NSOrderedSame) {
            if (error) {
                *error = @"Unsupported DNS snapshot version";
            }
            return ClashFXDNSRestoreSnapshotKindInvalid;
        }
        if (![snapshot[@"services"] isKindOfClass:[NSDictionary class]]) {
            if (error) {
                *error = @"Version 2 DNS snapshot has no service map";
            }
            return ClashFXDNSRestoreSnapshotKindInvalid;
        }
        id transactionID = snapshot[@"transactionID"];
        if (![transactionID isKindOfClass:[NSString class]] ||
            [(NSString *)transactionID length] == 0) {
            if (error) {
                *error = @"Version 2 DNS snapshot has no transaction id";
            }
            return ClashFXDNSRestoreSnapshotKindInvalid;
        }
        return ClashFXDNSRestoreSnapshotKindVersion2;
    }

    for (NSString *metadataKey in @[@"services", @"transactionID", @"expectedServers", @"applyServiceIDs"]) {
        if (snapshot[metadataKey]) {
            if (error) {
                *error = @"DNS snapshot metadata requires a version";
            }
            return ClashFXDNSRestoreSnapshotKindInvalid;
        }
    }
    return ClashFXDNSRestoreSnapshotKindLegacyFlat;
}

static inline NSArray<NSString *> *ClashFXTUNDNSServers(void) {
    return @[@"198.18.0.2"];
}

static inline BOOL ClashFXDNSIsValidServerList(id servers) {
    if (![servers isKindOfClass:[NSArray class]]) {
        return NO;
    }
    for (id server in (NSArray *)servers) {
        if (![server isKindOfClass:[NSString class]] || [(NSString *)server length] == 0) {
            return NO;
        }
    }
    return YES;
}

static inline BOOL ClashFXDNSIsValidOriginal(id original) {
    return original == [NSNull null] || [original isKindOfClass:[NSDictionary class]];
}

static inline NSDictionary *ClashFXDNSSettingsByReplacingServers(id original,
                                                                  NSArray<NSString *> *servers) {
    if (!ClashFXDNSIsValidOriginal(original) || !ClashFXDNSIsValidServerList(servers)) {
        return nil;
    }
    NSMutableDictionary *settings = original == [NSNull null]
        ? [NSMutableDictionary dictionary]
        : [original mutableCopy];
    settings[@"ServerAddresses"] = [servers copy];
    return [settings copy];
}

static inline BOOL ClashFXDNSCurrentMatchesOriginalOrApplied(id current,
                                                            id original,
                                                            NSArray<NSString *> *alreadyAppliedServers) {
    if (!ClashFXDNSIsValidOriginal(original) ||
        !ClashFXDNSIsValidServerList(alreadyAppliedServers)) {
        return NO;
    }
    if ([current isEqual:original]) {
        return YES;
    }
    NSDictionary *applied = ClashFXDNSSettingsByReplacingServers(original, alreadyAppliedServers);
    return applied && [current isEqual:applied];
}

static inline BOOL ClashFXDNSCurrentHasTUNServer(id current) {
    if (![current isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    id servers = ((NSDictionary *)current)[@"ServerAddresses"];
    return [servers isKindOfClass:[NSArray class]] &&
        [(NSArray *)servers containsObject:@"198.18.0.2"];
}

static inline ClashFXDNSRestoreDecision ClashFXDNSRestoreDecisionForCurrent(id current,
                                                                            id original,
                                                                            NSArray<NSString *> *expectedServers) {
    if (!ClashFXDNSIsValidOriginal(original) ||
        !ClashFXDNSIsValidServerList(expectedServers)) {
        return ClashFXDNSRestoreDecisionInvalidSnapshot;
    }
    if ([current isEqual:original]) {
        return ClashFXDNSRestoreDecisionAlreadyRestored;
    }
    if (!ClashFXDNSCurrentHasTUNServer(current)) {
        return ClashFXDNSRestoreDecisionDetached;
    }
    if (![expectedServers containsObject:@"198.18.0.2"]) {
        return ClashFXDNSRestoreDecisionOwnershipChanged;
    }
    NSDictionary *applied = ClashFXDNSSettingsByReplacingServers(original, expectedServers);
    if (!applied || ![current isEqual:applied]) {
        return ClashFXDNSRestoreDecisionOwnershipChanged;
    }
    return original == [NSNull null]
        ? ClashFXDNSRestoreDecisionRemovePath
        : ClashFXDNSRestoreDecisionRestoreDictionary;
}

static inline BOOL ClashFXDNSLegacyCurrentIsOwned(id current, id original) {
    if (![original isKindOfClass:[NSDictionary class]] ||
        ![current isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    NSDictionary *preservedFields = ClashFXDNSSettingsByReplacingServers(original, ClashFXTUNDNSServers());
    NSDictionary *legacyReplacement = @{@"ServerAddresses": ClashFXTUNDNSServers()};
    return [current isEqual:preservedFields] || [current isEqual:legacyReplacement];
}

static inline NSDictionary *ClashFXDNSCaptureSnapshot(NSString *transactionID,
                                                       NSDictionary<NSString *, id> *services) {
    if (![transactionID isKindOfClass:[NSString class]] || transactionID.length == 0 ||
        ![services isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSMutableDictionary<NSString *, NSDictionary *> *wrappedServices = [NSMutableDictionary dictionary];
    for (id serviceID in services) {
        id original = services[serviceID];
        if (![serviceID isKindOfClass:[NSString class]] || !ClashFXDNSIsValidOriginal(original)) {
            return nil;
        }
        wrappedServices[serviceID] = @{@"original": original};
    }
    return @{@"version": @2,
             @"transactionID": [transactionID copy],
             @"services": [wrappedServices copy]};
}

static inline id ClashFXDNSOriginalFromSnapshotEntry(id entry) {
    if (![entry isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    id original = ((NSDictionary *)entry)[@"original"];
    return ClashFXDNSIsValidOriginal(original) ? original : nil;
}

static inline NSArray<NSString *> *ClashFXDNSApplyServiceIDs(NSDictionary *snapshot) {
    NSDictionary *services = snapshot[@"services"];
    if (![services isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    id requested = snapshot[@"applyServiceIDs"] ?: services.allKeys;
    if (![requested isKindOfClass:[NSArray class]] || [(NSArray *)requested count] == 0) {
        return nil;
    }
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id serviceID in (NSArray *)requested) {
        if (![serviceID isKindOfClass:[NSString class]] || !services[serviceID] ||
            [seen containsObject:serviceID]) {
            return nil;
        }
        [seen addObject:serviceID];
    }
    return [requested copy];
}

static inline BOOL ClashFXDNSRestoreMatchesLatestWrite(NSString *latestWriteTransactionID,
                                                       NSString *restoreTransactionID) {
    return latestWriteTransactionID.length == 0 ||
        [latestWriteTransactionID isEqualToString:restoreTransactionID];
}

// A write-ahead journal can advance before the next apply RPC arrives. Its
// bounded lineage permits recovery of that preceding write, while a later,
// unrelated write still fences an obsolete journal out.
static inline BOOL ClashFXDNSRestoreSnapshotMatchesLatestWrite(NSString *latestWriteTransactionID,
                                                               NSDictionary *snapshot) {
    NSString *transactionID = [snapshot[@"transactionID"] isKindOfClass:[NSString class]]
        ? snapshot[@"transactionID"] : nil;
    if (ClashFXDNSRestoreMatchesLatestWrite(latestWriteTransactionID, transactionID)) return YES;
    id lineage = snapshot[@"previousTransactionIDs"];
    if (![lineage isKindOfClass:[NSArray class]] || [lineage count] > 64) return NO;
    for (id value in lineage) {
        if (![value isKindOfClass:[NSString class]] || [value length] == 0) return NO;
    }
    return [lineage containsObject:latestWriteTransactionID];
}
