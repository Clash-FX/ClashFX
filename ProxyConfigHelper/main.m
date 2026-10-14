//
//  main.m
//  ProxyConfigHelper
//
//  Created by yichengchen on 2019/8/16.
//  Copyright © 2019 west2online. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "ProxyConfigHelper.h"
#import "ProxySettingDNSPolicy.h"
#import "ProxySettingTool.h"
#import <errno.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>

// Installer-only recovery: a freshly validated, root-staged helper can restore
// an older daemon's DNS without unloading that daemon or stopping its core.
// Evidence remains on disk for the newly installed daemon to clear after readback.
static int RestoreDNSFromStandardInput(void) {
    if (geteuid() != 0) {
        fprintf(stderr, "DNS installation recovery requires administrator authorization\n");
        return 1;
    }
    const NSUInteger limit = 1024 * 1024;
    NSMutableData *data = [NSMutableData data];
    unsigned char buffer[4096];
    for (;;) {
        ssize_t count = read(STDIN_FILENO, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 || (count > 0 && (NSUInteger)count > limit - data.length)) {
            fprintf(stderr, "DNS installation recovery input is unreadable or exceeds 1 MiB\n");
            return 1;
        }
        if (count == 0) break;
        [data appendBytes:buffer length:(NSUInteger)count];
    }
    NSError *parseError = nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError];
    if (![value isKindOfClass:[NSDictionary class]]) {
        fprintf(stderr, "DNS installation recovery requires a JSON dictionary\n");
        return 1;
    }
    NSDictionary *snapshot = value;
    NSString *error = nil;
    if (ClashFXDNSClassifyRestoreSnapshot(snapshot, &error) == ClashFXDNSRestoreSnapshotKindInvalid) {
        fprintf(stderr, "%s\n", (error ?: @"Invalid DNS recovery snapshot").UTF8String);
        return 1;
    }
    if (snapshot.count == 0) return 0;
    error = [[ProxySettingTool new] restoreDNS:snapshot filterInterface:NO];
    if (error) {
        fprintf(stderr, "%s\n", error.UTF8String);
        return 1;
    }
    return 0;
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--restore-dns-json-stdin") == 0) {
            return RestoreDNSFromStandardInput();
        }
        if (argc != 1) return 1;
        [[NSProcessInfo processInfo] disableSuddenTermination];
        [[ProxyConfigHelper new] run];
        NSLog(@"ProxyConfigHelper exit");
    }
    return 0;
}
