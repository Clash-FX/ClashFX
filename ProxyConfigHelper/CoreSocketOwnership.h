#import <Foundation/Foundation.h>

// Parse lsof -Fn name records. TCP input must already be filtered to LISTEN.
// Connected UDP endpoints (local->peer) are outbound sockets, not evidence of
// an unconnected DNS listener. Never interpret their peer port as a local port.
static inline NSArray<NSNumber *> *ClashFXListeningPortsFromLsofOutput(NSString *output) {
    NSMutableSet<NSNumber *> *ports = [NSMutableSet set];
    NSCharacterSet *nonDigits = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
    for (NSString *line in [output componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (![line hasPrefix:@"n"]) {
            continue;
        }
        NSString *endpoint = [line substringFromIndex:1];
        if ([endpoint containsString:@"->"]) {
            continue;
        }
        NSRange separator = [endpoint rangeOfString:@":" options:NSBackwardsSearch];
        if (separator.location == NSNotFound || separator.location == 0) {
            continue;
        }
        NSString *portString = [endpoint substringFromIndex:NSMaxRange(separator)];
        if (portString.length == 0 || portString.length > 5 ||
            [portString rangeOfCharacterFromSet:nonDigits].location != NSNotFound) {
            continue;
        }
        NSInteger port = portString.integerValue;
        if (port > 0 && port <= 65535) {
            [ports addObject:@(port)];
        }
    }
    return [[ports allObjects] sortedArrayUsingSelector:@selector(compare:)];
}
