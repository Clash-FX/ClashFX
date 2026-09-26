#import <XCTest/XCTest.h>
#import "ProxySettingRestorationPolicy.h"
#import "../ProxyConfigHelper/CoreSocketOwnership.h"

@interface ProxySettingRestorationPolicyTests : XCTestCase
@end

@implementation ProxySettingRestorationPolicyTests

- (void)testSocketOwnershipDoesNotTreatConnectedUDPPeersAsListeners {
    NSString *connectedOnly = @"p123\nf7\nn192.0.2.10:56653->198.51.100.20:7874\n"
        @"f8\nn[::1]:56654->[::1]:7874\n"
        @"f9\nn127.0.0.1:7874->127.0.0.1:53\n";
    XCTAssertEqualObjects(ClashFXListeningPortsFromLsofOutput(connectedOnly), @[]);
    NSString *withListener = [connectedOnly stringByAppendingString:@"f10\nn127.0.0.1:7874\n"];
    XCTAssertEqualObjects(ClashFXListeningPortsFromLsofOutput(withListener), (@[@7874]));
}

- (void)testSocketOwnershipAcceptsNumericIPv4IPv6AndWildcardListeners {
    NSString *output = @"p123\nf7\nn127.0.0.1:7874\nf8\nn[::1]:7874\n"
        @"n*:65535\nn[fe80::1%en0]:1053\n";
    XCTAssertEqualObjects(ClashFXListeningPortsFromLsofOutput(output), (@[@1053, @7874, @65535]));
}

- (void)testSocketOwnershipRejectsMalformedOrNonNumericPortRecords {
    NSString *output = @"n127.0.0.1:0\nn127.0.0.1:65536\nn127.0.0.1:7874junk\n"
        @"n127.0.0.1:domain\nn127.0.0.1:*\nn127.0.0.1:\nn:7874\n"
        @"n127.0.0.1:-1\nf7874\nnno-port\n";
    XCTAssertEqualObjects(ClashFXListeningPortsFromLsofOutput(output), @[]);
}

- (NSDictionary *)dictionaryForService:(NSString *)service inSnapshot:(NSDictionary *)snapshot action:(ProxySettingRestorationAction *)action {
    return [ProxySettingRestorationPolicy proxyDictionaryForServiceID:service snapshot:snapshot action:action];
}

- (void)testPartialAndPACSettingsAreReturnedUnchanged {
    NSDictionary *partial = @{
        @"HTTPEnable": @1,
        @"HTTPProxy": @"proxy.example",
        @"HTTPPort": @8080,
        @"HTTPSEnable": @1,
        @"HTTPSProxy": @"secure.example",
        @"HTTPSPort": @8443,
        @"SOCKSEnable": @0,
        @"ProxyAutoConfigEnable": @1,
        @"ProxyAutoConfigURLString": @"https://pac.example/proxy.pac",
        @"ExceptionsList": @[@"localhost", @"*.local"],
        @"ExcludeSimpleHostnames": @1,
    };
    ProxySettingRestorationAction action = ProxySettingRestorationActionLeaveUntouched;
    NSDictionary *result = [self dictionaryForService:@"wifi" inSnapshot:@{ @"wifi": partial } action:&action];
    XCTAssertEqual(action, ProxySettingRestorationActionApplyDictionary);
    XCTAssertEqualObjects(result, partial);
}

- (void)testSOCKSOnlyAndDisabledDictionariesArePreserved {
    NSDictionary *socksOnly = @{
        @"HTTPEnable": @0,
        @"HTTPSEnable": @0,
        @"SOCKSEnable": @1,
        @"SOCKSProxy": @"socks.example",
        @"SOCKSPort": @1080,
    };
    NSDictionary *disabled = @{
        @"HTTPEnable": @0,
        @"HTTPSEnable": @0,
        @"SOCKSEnable": @0,
        @"ExceptionsList": @[@"localhost"],
    };
    ProxySettingRestorationAction action = ProxySettingRestorationActionLeaveUntouched;
    XCTAssertEqualObjects([self dictionaryForService:@"wifi" inSnapshot:@{ @"wifi": socksOnly } action:&action], socksOnly);
    XCTAssertEqual(action, ProxySettingRestorationActionApplyDictionary);
    XCTAssertEqualObjects([self dictionaryForService:@"ethernet" inSnapshot:@{ @"ethernet": disabled } action:&action], disabled);
    XCTAssertEqual(action, ProxySettingRestorationActionApplyDictionary);
}

- (void)testClashShapedDictionaryIsNotSilentlyChanged {
    NSDictionary *clashLike = @{
        @"HTTPEnable": @1, @"HTTPProxy": @"127.0.0.1", @"HTTPPort": @7890,
        @"HTTPSEnable": @1, @"HTTPSProxy": @"127.0.0.1", @"HTTPSPort": @7890,
        @"SOCKSEnable": @1, @"SOCKSProxy": @"127.0.0.1", @"SOCKSPort": @7891,
    };
    ProxySettingRestorationAction action = ProxySettingRestorationActionLeaveUntouched;
    XCTAssertEqualObjects([self dictionaryForService:@"wifi" inSnapshot:@{ @"wifi": clashLike } action:&action], clashLike);
    XCTAssertEqual(action, ProxySettingRestorationActionApplyDictionary);
}

- (void)testCapturedServiceWithoutProxyPathRequestsRemoval {
    ProxySettingRestorationAction action = ProxySettingRestorationActionLeaveUntouched;
    NSDictionary *snapshot = @{ @"__ClashFXCapturedServiceIDs": @[@"wifi"] };
    XCTAssertNil([self dictionaryForService:@"wifi" inSnapshot:snapshot action:&action]);
    XCTAssertEqual(action, ProxySettingRestorationActionRemovePath);
}

- (void)testNewAndLegacyUnknownServicesAreLeftUntouched {
    ProxySettingRestorationAction action = ProxySettingRestorationActionApplyDictionary;
    NSDictionary *newSnapshot = @{ @"__ClashFXCapturedServiceIDs": @[@"wifi"] };
    XCTAssertNil([self dictionaryForService:@"new-service" inSnapshot:newSnapshot action:&action]);
    XCTAssertEqual(action, ProxySettingRestorationActionLeaveUntouched);

    NSDictionary *legacySnapshot = @{ @"wifi": @{ @"HTTPEnable": @0 } };
    XCTAssertNil([self dictionaryForService:@"new-service" inSnapshot:legacySnapshot action:&action]);
    XCTAssertEqual(action, ProxySettingRestorationActionLeaveUntouched);
}

@end
