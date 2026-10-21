#!/usr/bin/env python3
"""Compile the production Helper ownership predicate without XPC or networking."""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "ProxyConfigHelper/ProxyConfigHelper.m")
    args = parser.parse_args()
    source = args.source.read_text()
    start = source.index("static BOOL IsAllowedMihomoConfigPath(")
    end = source.index("\nstatic BOOL CopyAllMihomoProcessIDs", start)
    function = source[start:end]
    start = source.index("- (BOOL)mihomoArguments:(NSArray<NSString *> *)arguments\n      matchExpectedHome:", source.index("@implementation"))
    end = source.index("\n- (NSArray<NSString *> *)kernelArgumentsForProcessID:", start)
    method = source[start:end]
    harness = r'''
#import <Foundation/Foundation.h>
@interface Fixture : NSObject
- (BOOL)mihomoArguments:(NSArray<NSString *> *)arguments matchExpectedHome:(NSString *)home expectedBinaryPath:(NSString *)binary;
@end
''' + function + "\n@implementation Fixture\n" + method + r'''
@end
int main(int argc, const char **argv) { @autoreleasepool {
    NSString *home = [[NSString stringWithUTF8String:argv[1]] stringByResolvingSymlinksInPath];
    NSString *binary = @"/Library/PrivilegedHelperTools/com.clashfx.app.Helper.mihomo_core";
    NSString *config = [home stringByAppendingPathComponent:@".enhanced_config.12345678-1234-1234-1234-123456789abc.yaml"];
    Fixture *helper = [Fixture new];
    NSArray *homes = @[home, [home stringByAppendingString:@"/"], [home stringByAppendingString:@"-other"], @"relative/home"];
    NSArray *expected = @[@YES, @YES, @NO, @NO];
    for (NSUInteger i = 0; i < homes.count; i++) {
        BOOL result = [helper mihomoArguments:@[binary, @"-f", config, @"-d", homes[i]] matchExpectedHome:home expectedBinaryPath:binary];
        if (result != [expected[i] boolValue]) { fprintf(stderr, "home identity case %lu failed\n", (unsigned long)i); return 1; }
    }
    NSArray *invalid = @[
        @[binary, @"-f", config, @"-d", home, @"-d", home],
        @[binary, @"-f", @"/tmp/foreign.yaml", @"-d", home],
        @[@"foreign_core", @"-f", config, @"-d", home],
        @[binary, @"-f", [home stringByAppendingPathComponent:@".enhanced_config.yaml"], @"-d", home]
    ];
    for (NSArray *args in invalid) {
        if ([helper mihomoArguments:args matchExpectedHome:home expectedBinaryPath:binary]) { fprintf(stderr, "foreign identity accepted\n"); return 1; }
    }
    NSString *alias = [NSString stringWithUTF8String:argv[2]];
    if (![helper mihomoArguments:@[binary, @"-f", config, @"-d", alias] matchExpectedHome:home expectedBinaryPath:binary]) { fprintf(stderr, "symlink home alias rejected\n"); return 1; }
    puts("Helper home identity regression passed: 9 cases; no XPC or network access");
    return 0;
} }
'''
    with tempfile.TemporaryDirectory(prefix="clashfx-helper-home-") as directory:
        stage = Path(directory)
        path = stage / "main.m"
        path.write_text(harness)
        executable = stage / "home-identity"
        subprocess.run(["clang", "-fobjc-arc", str(path), "-framework", "Foundation", "-o", str(executable)], check=True)
        home = stage / "home with spaces"
        home.mkdir()
        alias = stage / "home alias"
        alias.symlink_to(home, target_is_directory=True)
        subprocess.run([str(executable), str(home), str(alias)], check=True)

if __name__ == "__main__":
    main()
