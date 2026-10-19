//
//  ProxySettingTool.h
//  com.clashfx.app.Helper
//
//  Created by yichengchen on 2019/8/17.
//  Copyright © 2019 west2online. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ProxySettingTool : NSObject

- (nullable NSString *)enableProxyWithport:(int)port socksPort:(int)socksPort
                     pacUrl:(NSString *)pacUrl
            filterInterface:(BOOL)filterInterface
                 ignoreList:(NSArray<NSString *>*)ignoreList;

- (nullable NSString *)disableProxyWithfilterInterface:(BOOL)filterInterFace;

- (nullable NSString *)restoreProxySetting:(NSDictionary *)savedInfo
                currentPort:(int)port
           currentSocksPort:(int)socksPort
            filterInterface:(BOOL)filterInterface;
+ (NSMutableDictionary<NSString *, id> *)currentProxySettings;

- (NSDictionary *)captureDNSWithFilterInterface:(BOOL)filterInterface;

- (nullable NSString *)applyDNSWithSnapshot:(NSDictionary *)snapshot
                                    servers:(NSArray<NSString *> *)servers;

- (nullable NSString *)overrideDNSWithServers:(NSArray<NSString *> *)servers
                              filterInterface:(BOOL)filterInterface;

- (nullable NSString *)restoreDNS:(NSDictionary *)savedInfo
                  filterInterface:(BOOL)filterInterface;

+ (NSMutableDictionary<NSString *,NSDictionary *> *)currentDNSSettings;

@end

NS_ASSUME_NONNULL_END
