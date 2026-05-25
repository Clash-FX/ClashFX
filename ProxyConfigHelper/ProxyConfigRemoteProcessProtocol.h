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

#define CLASHFX_HELPER_PROTOCOL_VERSION 1

@protocol ProxyConfigRemoteProcessProtocol <NSObject>
@required

- (void)getVersion:(stringReplyBlock)reply;

@optional

- (void)getProtocolVersion:(uintReplyBlock)reply NS_SWIFT_NAME(getHelperProtocolVersion(_:));

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
