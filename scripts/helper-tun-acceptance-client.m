// Minimal, non-GUI XPC client used only by the GitHub-hosted Helper/TUN
// acceptance runner. Its enclosing app bundle is deliberately named ClashFX
// and carries the production client bundle identifier required by the Helper.

#import <Foundation/Foundation.h>
#import "ProxyConfigRemoteProcessProtocol.h"
#import <limits.h>

static void WriteResponse(NSDictionary *response) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:response options:0 error:&error];
    if (!data) {
        NSString *fallback = [NSString stringWithFormat:
            @"{\"ok\":false,\"error\":\"response JSON encoding failed: %@\"}",
            error.localizedDescription ?: @"unknown error"];
        fputs(fallback.UTF8String, stdout);
        fputc('\n', stdout);
        fflush(stdout);
        return;
    }
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static NSDictionary *Failure(NSString *operation, NSString *message) {
    return @{
        @"ok": @NO,
        @"operation": operation ?: @"unknown",
        @"error": message ?: @"unknown error"
    };
}

static BOOL ReadInt(NSDictionary *request, NSString *key, int *value) {
    id candidate = request[key];
    if (![candidate isKindOfClass:[NSNumber class]]) {
        return NO;
    }
    long long number = [candidate longLongValue];
    if (number < INT_MIN || number > INT_MAX) {
        return NO;
    }
    *value = (int)number;
    return YES;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSData *input = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
        NSError *jsonError = nil;
        id decoded = [NSJSONSerialization JSONObjectWithData:input options:0 error:&jsonError];
        if (![decoded isKindOfClass:[NSDictionary class]]) {
            WriteResponse(Failure(@"parse", jsonError.localizedDescription ?: @"stdin must contain a JSON object"));
            return 2;
        }

        NSDictionary *request = (NSDictionary *)decoded;
        NSString *operation = [request[@"operation"] isKindOfClass:[NSString class]]
            ? request[@"operation"]
            : @"";
        if (operation.length == 0) {
            WriteResponse(Failure(@"parse", @"operation is required"));
            return 2;
        }

        NSXPCConnection *connection = [[NSXPCConnection alloc]
            initWithMachServiceName:@"com.clashfx.app.Helper"
                            options:NSXPCConnectionPrivileged];
        NSXPCInterface *remoteInterface =
            [NSXPCInterface interfaceWithProtocol:@protocol(ProxyConfigRemoteProcessProtocol)];
        NSSet *propertyListClasses = [NSSet setWithObjects:
            [NSArray class], [NSDictionary class], [NSString class], [NSNumber class], [NSNull class], nil];
        [remoteInterface setClasses:propertyListClasses
                        forSelector:@selector(enableProxyWithPort:socksPort:pac:filterInterface:ignoreList:error:)
                      argumentIndex:4
                            ofReply:NO];
        [remoteInterface setClasses:propertyListClasses
                        forSelector:@selector(restoreProxyWithCurrentPort:socksPort:info:filterInterface:error:)
                      argumentIndex:2
                            ofReply:NO];
        [remoteInterface setClasses:propertyListClasses
                        forSelector:@selector(overrideDNSWithServers:filterInterface:reply:)
                      argumentIndex:0
                            ofReply:NO];
        [remoteInterface setClasses:propertyListClasses
                        forSelector:@selector(restoreDNSWithSavedInfo:filterInterface:reply:)
                      argumentIndex:0
                            ofReply:NO];
        [remoteInterface setClasses:propertyListClasses
                        forSelector:@selector(getCurrentProxySetting:)
                      argumentIndex:0
                            ofReply:YES];
        [remoteInterface setClasses:propertyListClasses
                        forSelector:@selector(getCurrentDNSSetting:)
                      argumentIndex:0
                            ofReply:YES];
        [remoteInterface setClasses:propertyListClasses
                        forSelector:@selector(getMihomoCoreStatusWithReply:)
                      argumentIndex:0
                            ofReply:YES];
        ClashFXConfigureHelperXPCInterface(remoteInterface);
        connection.remoteObjectInterface = remoteInterface;
        [connection resume];

        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        NSLock *completionLock = [NSLock new];
        __block NSDictionary *response = nil;
        __block BOOL didComplete = NO;
        void (^complete)(id, NSString *) = ^(id result, NSString *failure) {
            [completionLock lock];
            if (didComplete) {
                [completionLock unlock];
                return;
            }
            didComplete = YES;
            if (failure.length > 0) {
                response = Failure(operation, failure);
            } else {
                response = @{
                    @"ok": @YES,
                    @"operation": operation,
                    @"result": result ?: [NSNull null]
                };
            }
            [completionLock unlock];
            dispatch_semaphore_signal(semaphore);
        };

        id<ProxyConfigRemoteProcessProtocol> proxy = [connection
            remoteObjectProxyWithErrorHandler:^(NSError *error) {
                complete(nil, error.localizedDescription ?: @"XPC connection failed");
            }];

        stringReplyBlock operationReply = ^(NSString *error) {
            complete([NSNull null], error);
        };

        if ([operation isEqualToString:@"version"]) {
            [proxy getVersion:^(NSString *version) { complete(version, nil); }];
        } else if ([operation isEqualToString:@"protocolVersion"]) {
            if (![proxy respondsToSelector:@selector(getProtocolVersion:)]) {
                complete(nil, @"Helper does not expose getProtocolVersion");
            } else {
                [proxy getProtocolVersion:^(NSUInteger version) { complete(@(version), nil); }];
            }
        } else if ([operation isEqualToString:@"proxySnapshot"]) {
            [proxy getCurrentProxySetting:^(NSDictionary *settings) { complete(settings, nil); }];
        } else if ([operation isEqualToString:@"dnsSnapshot"]) {
            [proxy getCurrentDNSSetting:^(NSDictionary *settings) { complete(settings, nil); }];
        } else if ([operation isEqualToString:@"captureDNS"]) {
            [proxy captureDNSWithFilterInterface:[request[@"filterInterface"] boolValue]
                                           reply:^(NSDictionary *snapshot) { complete(snapshot, snapshot[@"error"]); }];
        } else if ([operation isEqualToString:@"applyDNS"]) {
            NSDictionary *snapshot = request[@"settings"];
            NSArray *servers = request[@"servers"];
            if (![snapshot isKindOfClass:[NSDictionary class]] || ![servers isKindOfClass:[NSArray class]]) {
                complete(nil, @"applyDNS requires a snapshot dictionary and servers array");
            } else {
                [proxy applyDNSWithSnapshot:snapshot servers:servers reply:operationReply];
            }
        } else if ([operation isEqualToString:@"coreStatus"]) {
            if (![proxy respondsToSelector:@selector(getMihomoCoreStatusWithReply:)]) {
                complete(nil, @"Helper does not expose core status");
            } else {
                [proxy getMihomoCoreStatusWithReply:^(NSDictionary *status) { complete(status, nil); }];
            }
        } else if ([operation isEqualToString:@"enableProxy"]) {
            int httpPort = 0;
            int socksPort = 0;
            NSArray *ignoreList = request[@"ignoreList"];
            if (!ReadInt(request, @"httpPort", &httpPort) ||
                !ReadInt(request, @"socksPort", &socksPort) ||
                ![ignoreList isKindOfClass:[NSArray class]]) {
                complete(nil, @"enableProxy requires integer httpPort/socksPort and an ignoreList array");
            } else {
                NSString *pac = [request[@"pac"] isKindOfClass:[NSString class]] ? request[@"pac"] : @"";
                BOOL filter = [request[@"filterInterface"] boolValue];
                [proxy enableProxyWithPort:httpPort
                                  socksPort:socksPort
                                        pac:pac
                            filterInterface:filter
                                 ignoreList:ignoreList
                                      error:operationReply];
            }
        } else if ([operation isEqualToString:@"disableProxy"]) {
            [proxy disableProxyWithFilterInterface:[request[@"filterInterface"] boolValue]
                                              reply:operationReply];
        } else if ([operation isEqualToString:@"restoreProxy"]) {
            int httpPort = 0;
            int socksPort = 0;
            NSDictionary *settings = request[@"settings"];
            if (!ReadInt(request, @"httpPort", &httpPort) ||
                !ReadInt(request, @"socksPort", &socksPort) ||
                ![settings isKindOfClass:[NSDictionary class]]) {
                complete(nil, @"restoreProxy requires integer ports and a settings dictionary");
            } else {
                [proxy restoreProxyWithCurrentPort:httpPort
                                          socksPort:socksPort
                                               info:settings
                                    filterInterface:[request[@"filterInterface"] boolValue]
                                              error:operationReply];
            }
        } else if ([operation isEqualToString:@"startCore"]) {
            NSString *binary = request[@"binaryPath"];
            NSString *config = request[@"configPath"];
            NSString *home = request[@"homeDir"];
            if (![binary isKindOfClass:[NSString class]] ||
                ![config isKindOfClass:[NSString class]] ||
                ![home isKindOfClass:[NSString class]]) {
                complete(nil, @"startCore requires binaryPath, configPath, and homeDir strings");
            } else {
                [proxy startMihomoCoreWithBinaryPath:binary
                                          configPath:config
                                             homeDir:home
                                               reply:operationReply];
            }
        } else if ([operation isEqualToString:@"stopCore"]) {
            [proxy stopMihomoCoreWithReply:operationReply];
        } else if ([operation isEqualToString:@"overrideDNS"]) {
            NSArray *servers = request[@"servers"];
            if (![servers isKindOfClass:[NSArray class]]) {
                complete(nil, @"overrideDNS requires a servers array");
            } else {
                [proxy overrideDNSWithServers:servers
                              filterInterface:[request[@"filterInterface"] boolValue]
                                        reply:operationReply];
            }
        } else if ([operation isEqualToString:@"restoreDNS"]) {
            NSDictionary *settings = request[@"settings"];
            if (![settings isKindOfClass:[NSDictionary class]]) {
                complete(nil, @"restoreDNS requires a settings dictionary");
            } else {
                [proxy restoreDNSWithSavedInfo:settings
                               filterInterface:[request[@"filterInterface"] boolValue]
                                         reply:operationReply];
            }
        } else {
            complete(nil, [NSString stringWithFormat:@"unknown operation: %@", operation]);
        }

        dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC);
        if (dispatch_semaphore_wait(semaphore, deadline) != 0) {
            [connection invalidate];
            WriteResponse(Failure(operation, @"timed out waiting for the Helper XPC reply"));
            return 3;
        }

        [connection invalidate];
        WriteResponse(response ?: Failure(operation, @"Helper returned no response"));
        return [response[@"ok"] boolValue] ? 0 : 1;
    }
}
