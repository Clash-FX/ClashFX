//
//  ProxyConfigRemoteProcessProtocol.h
//  com.clashfx.app.Helper
//
//  Created by yichengchen on 2019/8/17.
//  Copyright © 2019 west2online. All rights reserved.
//

@import Foundation;

typedef void(^stringReplyBlock)(NSString *);
typedef void(^boolReplyBlock)(BOOL);
typedef void(^dictReplyBlock)(NSDictionary *);
typedef void(^uintReplyBlock)(NSUInteger);

#define CLASHFX_HELPER_PROTOCOL_VERSION 6

@protocol ProxyConfigRemoteProcessProtocol <NSObject>
@required

- (void)getVersion:(stringReplyBlock)reply;

@optional

- (void)getProtocolVersion:(uintReplyBlock)reply NS_SWIFT_NAME(getHelperProtocolVersion(_:));

- (void)getMihomoCoreStatusWithReply:(dictReplyBlock)reply
    NS_SWIFT_NAME(getMihomoCoreStatus(_:));

- (void)installApprovedMihomoCoreWithReply:(stringReplyBlock)reply
    NS_SWIFT_NAME(installApprovedMihomoCore(_:));

- (void)captureMihomoCoreDiagnosticWithReason:(NSString *)reason
                                        reply:(stringReplyBlock)reply;

- (void)restartMihomoCoreHostWithReply:(stringReplyBlock)reply;

- (void)captureDNSWithFilterInterface:(BOOL)filterInterface
                                reply:(dictReplyBlock)reply
    NS_SWIFT_NAME(captureDNS(filterInterface:reply:));

- (void)applyDNSWithSnapshot:(NSDictionary *)snapshot
                     servers:(NSArray<NSString *> *)servers
                       reply:(stringReplyBlock)reply
    NS_SWIFT_NAME(applyDNS(snapshot:servers:reply:));

@required

- (void)enableProxyWithPort:(int)port
                  socksPort:(int)socksPort
                        pac:(NSString *)pac
            filterInterface:(BOOL)filterInterface
                 ignoreList:(NSArray<NSString *>*)ignoreList
                      error:(stringReplyBlock)reply;

- (void)disableProxyWithFilterInterface:(BOOL)filterInterface
                                  reply:(stringReplyBlock)reply;

- (void)restoreProxyWithCurrentPort:(int)port
                          socksPort:(int)socksPort
                               info:(NSDictionary *)dict
                    filterInterface:(BOOL)filterInterface
                              error:(stringReplyBlock)reply;

- (void)getCurrentProxySetting:(dictReplyBlock)reply;

- (void)startMihomoCoreWithBinaryPath:(NSString *)binaryPath
                           configPath:(NSString *)configPath
                              homeDir:(NSString *)homeDir
                                reply:(stringReplyBlock)reply;

- (void)stopMihomoCoreWithReply:(stringReplyBlock)reply;

- (void)cleanupMihomoCoreWithBinaryPath:(NSString *)binaryPath
                             configPath:(NSString *)configPath
                                homeDir:(NSString *)homeDir
                                  reply:(stringReplyBlock)reply;

// DNS override for TUN mode
- (void)overrideDNSWithServers:(NSArray<NSString *> *)servers
               filterInterface:(BOOL)filterInterface
                         reply:(stringReplyBlock)reply;

- (void)restoreDNSWithSavedInfo:(NSDictionary *)savedInfo
                filterInterface:(BOOL)filterInterface
                          reply:(stringReplyBlock)reply;

- (void)getCurrentDNSSetting:(dictReplyBlock)reply;

- (void)flushDNSCacheWithReply:(stringReplyBlock)reply;
@end

static inline void ClashFXConfigureHelperXPCInterface(NSXPCInterface *interface) {
    if (!interface) {
        return;
    }

    NSSet *propertyListClasses = [NSSet setWithObjects:
        [NSArray class],
        [NSDictionary class],
        [NSString class],
        [NSNumber class],
        [NSNull class],
        nil
    ];

    [interface setClasses:propertyListClasses
              forSelector:@selector(captureDNSWithFilterInterface:reply:)
            argumentIndex:0
                  ofReply:YES];
    [interface setClasses:propertyListClasses
              forSelector:@selector(applyDNSWithSnapshot:servers:reply:)
            argumentIndex:0
                  ofReply:NO];
    [interface setClasses:propertyListClasses
              forSelector:@selector(applyDNSWithSnapshot:servers:reply:)
            argumentIndex:1
                  ofReply:NO];
    [interface setClasses:propertyListClasses
              forSelector:@selector(restoreDNSWithSavedInfo:filterInterface:reply:)
            argumentIndex:0
                  ofReply:NO];
    [interface setClasses:propertyListClasses
              forSelector:@selector(overrideDNSWithServers:filterInterface:reply:)
            argumentIndex:0
                  ofReply:NO];
    [interface setClasses:propertyListClasses
              forSelector:@selector(getCurrentDNSSetting:)
            argumentIndex:0
                  ofReply:YES];

    [interface setClasses:propertyListClasses
              forSelector:@selector(getCurrentProxySetting:)
            argumentIndex:0
                  ofReply:YES];
    [interface setClasses:propertyListClasses
              forSelector:@selector(restoreProxyWithCurrentPort:socksPort:info:filterInterface:error:)
            argumentIndex:2
                  ofReply:NO];
    [interface setClasses:propertyListClasses
              forSelector:@selector(enableProxyWithPort:socksPort:pac:filterInterface:ignoreList:error:)
            argumentIndex:4
                  ofReply:NO];
    [interface setClasses:propertyListClasses
              forSelector:@selector(getMihomoCoreStatusWithReply:)
            argumentIndex:0
                  ofReply:YES];
}
