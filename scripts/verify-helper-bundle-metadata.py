#!/usr/bin/env python3
"""Reproduce helper bundle xattr cleanup without touching an installed app."""

import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


XATTR = "/usr/bin/xattr"
CODESIGN = "/usr/bin/codesign"
DITTO = "/usr/bin/ditto"
OTOOL = "/usr/bin/otool"
REMOVE_ATTRIBUTES = (
    "com.apple.FinderInfo",
    "com.apple.ResourceFork",
)
CUSTOM_ATTRIBUTE = "com.clashfx.verify-helper-bundle-metadata"
FINDER_INFO = bytes(8) + b"\x04\x00" + bytes(22)
RESOURCE_FORK = b"fixture resource fork"


class VerificationError(RuntimeError):
    pass


def run(command, *, input_text=None, check=True):
    result = subprocess.run(
        command,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode != 0:
        details = (result.stdout + result.stderr).strip()
        raise VerificationError(
            "command failed ({}): {}\n{}".format(
                result.returncode, " ".join(command), details
            )
        )
    return result


def require_tools():
    if sys.platform != "darwin":
        raise VerificationError("this verification requires macOS")
    for path in (XATTR, CODESIGN, DITTO, OTOOL):
        if not os.path.isfile(path):
            raise VerificationError("required macOS tool is missing: {}".format(path))
    if shutil.which("clang") is None:
        raise VerificationError("clang is required to build the fixture executable")
    header = Path(__file__).resolve().parents[1] / "ProxyConfigHelper" / "BundleDisplayMetadata.h"
    if not header.is_file():
        raise VerificationError("production metadata helper header is missing: {}".format(header))


def make_fixture(bundle):
    contents = bundle / "Contents"
    executable_dir = contents / "MacOS"
    resources = contents / "Resources"
    executable_dir.mkdir(parents=True)
    resources.mkdir()

    info = {
        "CFBundleExecutable": "Fixture",
        "CFBundleIdentifier": "com.clashfx.verify-helper-bundle-metadata",
        "CFBundleName": "Fixture",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
    }
    with (contents / "Info.plist").open("wb") as plist_file:
        plistlib.dump(info, plist_file)

    run(
        ["clang", "-x", "c", "-o", str(executable_dir / "Fixture"), "-"],
        input_text="int main(void) { return 0; }\n",
    )
    (resources / "nested.txt").write_text("signed fixture content\n", encoding="utf-8")
    run([CODESIGN, "--force", "--deep", "--sign", "-", str(bundle)])
    verify_strict(bundle, should_pass=True, label="fresh ad hoc signature")


def verify_strict(bundle, *, should_pass, label):
    result = run(
        [CODESIGN, "--verify", "--deep", "--strict", "--verbose=2", str(bundle)],
        check=False,
    )
    passed = result.returncode == 0
    if passed != should_pass:
        detail = (result.stdout + result.stderr).strip()
        raise VerificationError(
            "{}: strict verification {} (expected {})\n{}".format(
                label,
                "passed" if passed else "failed",
                "pass" if should_pass else "failure",
                detail,
            )
        )
    print("{}: strict {}".format(label, "PASS" if passed else "FAIL (expected)"))
    if detail := (result.stdout + result.stderr).strip():
        print("  {}".format(detail.replace("\n", "\n  ")))
    return result


def cdhash(bundle):
    result = run([CODESIGN, "-dv", "--verbose=4", str(bundle)], check=False)
    output = result.stdout + result.stderr
    for line in output.splitlines():
        if line.startswith("CDHash="):
            return line.partition("=")[2].strip()
    raise VerificationError("codesign did not report a CDHash for {}\n{}".format(bundle, output))


def write_xattr(path, name, value):
    run([XATTR, "-wx", name, value.hex(), str(path)])


def mirror_fixture_attributes(source, destination):
    for name in ("com.apple.FinderInfo", CUSTOM_ATTRIBUTE):
        write_xattr(destination, name, read_xattr(source, name))
    if source.is_file():
        write_xattr(destination, "com.apple.ResourceFork", read_xattr(source, "com.apple.ResourceFork"))


def read_xattr(path, name):
    result = subprocess.run(
        [XATTR, "-px", name, str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise VerificationError("missing xattr {} on {}: {}".format(name, path, detail))
    return bytes.fromhex(result.stdout.decode("ascii"))


def normalize_staged_copy(bundle):
    for name in REMOVE_ATTRIBUTES:
        # Missing attributes are expected; the postcondition check below ensures
        # all occurrences were actually removed.
        run([XATTR, "-r", "-s", "-d", name, str(bundle)], check=False)


def compile_native_normalizer(output_path):
    header_dir = Path(__file__).resolve().parents[1] / "ProxyConfigHelper"
    source = r'''#include "BundleDisplayMetadata.h"
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int normalize_path(const char *path) {
    struct stat info;
    if (lstat(path, &info) != 0) return errno;
    if (S_ISLNK(info.st_mode)) return 0;

    int status = ClashFXRemoveStagedBundleDisplayMetadata(path);
    if (status != 0 || !S_ISDIR(info.st_mode)) return status;

    DIR *directory = opendir(path);
    if (directory == NULL) return errno;
    struct dirent *entry;
    for (;;) {
        errno = 0;
        entry = readdir(directory);
        if (entry == NULL) {
            if (errno != 0) status = errno;
            break;
        }
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        size_t length = strlen(path) + strlen(entry->d_name) + 2;
        char *child = malloc(length);
        if (child == NULL) { status = ENOMEM; break; }
        snprintf(child, length, "%s/%s", path, entry->d_name);
        status = normalize_path(child);
        free(child);
        if (status != 0) break;
    }
    if (closedir(directory) != 0 && status == 0) status = errno;
    return status;
}

int main(int argc, char **argv) {
    if (argc != 2) return EINVAL;
    int status = normalize_path(argv[1]);
    if (status != 0) fprintf(stderr, "%s: %s\n", argv[1], strerror(status));
    return status == 0 ? 0 : 1;
}
'''
    run(
        ["clang", "-I", str(header_dir), "-x", "c", "-o", str(output_path), "-"],
        input_text=source,
    )


def assert_attribute_absent(bundle, name):
    paths = [bundle]
    paths.extend(path for path in bundle.rglob("*") if not path.is_symlink())
    remaining = []
    for path in paths:
        result = subprocess.run(
            [XATTR, "-px", name, str(path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if result.returncode == 0:
            remaining.append(str(path.relative_to(bundle)))
    if remaining:
        raise VerificationError(
            "{} remains on staged paths: {}".format(name, ", ".join(remaining))
        )


def copy_bundle(source, destination):
    run([DITTO, "--rsrc", "--extattr", "--acl", str(source), str(destination)])


def tamper_executable(bundle):
    executable = bundle / "Contents" / "MacOS" / "Fixture"
    load_commands = run([OTOOL, "-l", str(executable)]).stdout.splitlines()
    text_offset = None
    text_size = None
    for index, line in enumerate(load_commands):
        if line.strip() != "sectname __text":
            continue
        for section_line in load_commands[index + 1 : index + 12]:
            fields = section_line.split()
            if len(fields) == 2 and fields[0] == "offset":
                text_offset = int(fields[1], 0)
            elif len(fields) == 2 and fields[0] == "size":
                text_size = int(fields[1], 0)
        break
    if text_offset is None or text_size is None or text_size < 1:
        raise VerificationError("otool did not report a non-empty __text section")
    with executable.open("r+b") as executable_file:
        executable_file.seek(text_offset)
        code_byte = executable_file.read(1)
        executable_file.seek(text_offset)
        executable_file.write(bytes([code_byte[0] ^ 0x01]))


def assert_custom_xattrs(bundle, custom_value):
    nested = bundle / "Contents" / "Resources" / "nested.txt"
    for target in (bundle, nested):
        if read_xattr(target, CUSTOM_ATTRIBUTE) != custom_value:
            raise VerificationError("normalization removed or changed the custom xattr")


def assert_normalized(bundle, label, expected_cdhash, custom_value):
    assert_custom_xattrs(bundle, custom_value)
    verify_strict(bundle, should_pass=True, label=label)
    for name in REMOVE_ATTRIBUTES:
        assert_attribute_absent(bundle, name)
    actual_cdhash = cdhash(bundle)
    if actual_cdhash != expected_cdhash:
        raise VerificationError(
            "{} changed CDHash: {} -> {}".format(label, expected_cdhash, actual_cdhash)
        )
    print("{} CDHash unchanged: {}".format(label, expected_cdhash))


def make_symlink_fixture(root, name, outside_target, finder_info, resource_fork, custom_value):
    tree = root / name
    resources = tree / "Contents" / "Resources"
    resources.mkdir(parents=True)
    nested = resources / "nested.txt"
    nested.write_text("ordinary file in traversal tree\n", encoding="utf-8")
    write_xattr(tree, "com.apple.FinderInfo", finder_info)
    write_xattr(tree, CUSTOM_ATTRIBUTE, custom_value)
    write_xattr(nested, "com.apple.FinderInfo", finder_info)
    write_xattr(nested, "com.apple.ResourceFork", resource_fork)
    write_xattr(nested, CUSTOM_ATTRIBUTE, custom_value)
    (resources / "escape.txt").symlink_to(outside_target)
    return tree


def verify_symlink_protection(tree, outside_target, custom_value, label):
    for name in REMOVE_ATTRIBUTES:
        assert_attribute_absent(tree, name)
    assert_custom_xattrs(tree, custom_value)
    for name in REMOVE_ATTRIBUTES:
        if read_xattr(outside_target, name) != (
            RESOURCE_FORK if name == "com.apple.ResourceFork" else FINDER_INFO
        ):
            raise VerificationError("{} altered outside symlink target xattr {}".format(label, name))
    if read_xattr(outside_target, CUSTOM_ATTRIBUTE) != custom_value:
        raise VerificationError("{} altered outside symlink target custom xattr".format(label))
    print("{}: non-symlink metadata cleaned; outside symlink target unchanged: PASS".format(label))


def main():
    require_tools()
    with tempfile.TemporaryDirectory(prefix="clashfx-helper-metadata-") as temp_dir:
        root = Path(temp_dir)
        signed_bundle = root / "Fixture.app"
        make_fixture(signed_bundle)

        nested_file = signed_bundle / "Contents" / "Resources" / "nested.txt"
        write_xattr(signed_bundle, "com.apple.FinderInfo", FINDER_INFO)
        write_xattr(signed_bundle, CUSTOM_ATTRIBUTE, b"keep-this-unrelated-attribute")
        verify_strict(
            signed_bundle,
            should_pass=False,
            label="signed original with bundle-root FinderInfo",
        )

        custom_value = b"keep-this-unrelated-attribute"
        for name, value in (
            ("com.apple.FinderInfo", FINDER_INFO),
            ("com.apple.ResourceFork", RESOURCE_FORK),
            (CUSTOM_ATTRIBUTE, custom_value),
        ):
            write_xattr(nested_file, name, value)

        original_result = verify_strict(
            signed_bundle, should_pass=False, label="signed original with injected metadata"
        )
        before_hash = cdhash(signed_bundle)

        staged = root / "ShellNormalized.app"
        copy_bundle(signed_bundle, staged)
        staged_nested = staged / "Contents" / "Resources" / "nested.txt"
        # Mirror metadata when ditto omits FinderInfo or other extended attributes.
        mirror_fixture_attributes(signed_bundle, staged)
        mirror_fixture_attributes(nested_file, staged_nested)
        normalize_staged_copy(staged)
        assert_normalized(
            staged,
            "admin-script xattr normalized staged copy",
            before_hash,
            custom_value,
        )
        print("Original strict failure exit code: {}".format(original_result.returncode))

        native_tool = root / "normalize-helper-metadata"
        compile_native_normalizer(native_tool)
        native_staged = root / "NativeNormalized.app"
        copy_bundle(signed_bundle, native_staged)
        native_nested = native_staged / "Contents" / "Resources" / "nested.txt"
        mirror_fixture_attributes(signed_bundle, native_staged)
        mirror_fixture_attributes(nested_file, native_nested)
        run([str(native_tool), str(native_staged)])
        assert_normalized(
            native_staged,
            "production-header native normalized staged copy",
            before_hash,
            custom_value,
        )
        print("Unrelated custom xattr preserved on bundle and nested file: PASS")

        outside_target = root / "outside-target.txt"
        outside_target.write_text("outside fixture\n", encoding="utf-8")
        write_xattr(outside_target, "com.apple.FinderInfo", FINDER_INFO)
        write_xattr(outside_target, "com.apple.ResourceFork", RESOURCE_FORK)
        write_xattr(outside_target, CUSTOM_ATTRIBUTE, custom_value)
        shell_link_tree = make_symlink_fixture(
            root, "ShellSymlinkTree.app", outside_target, FINDER_INFO, RESOURCE_FORK, custom_value
        )
        normalize_staged_copy(shell_link_tree)
        verify_symlink_protection(
            shell_link_tree,
            outside_target,
            custom_value,
            "admin-script xattr traversal",
        )
        native_link_tree = make_symlink_fixture(
            root, "NativeSymlinkTree.app", outside_target, FINDER_INFO, RESOURCE_FORK, custom_value
        )
        run([str(native_tool), str(native_link_tree)])
        verify_symlink_protection(
            native_link_tree,
            outside_target,
            custom_value,
            "production-header native traversal",
        )

        executable_tamper = root / "TamperedExecutable.app"
        copy_bundle(native_staged, executable_tamper)
        tamper_executable(executable_tamper)
        normalize_staged_copy(executable_tamper)
        verify_strict(
            executable_tamper,
            should_pass=False,
            label="normalized copy after signed executable tamper",
        )

        content_tamper = root / "TamperedContent.app"
        copy_bundle(native_staged, content_tamper)
        tampered_content = content_tamper / "Contents" / "Resources" / "nested.txt"
        tampered_content.write_text("changed signed fixture content\n", encoding="utf-8")
        normalize_staged_copy(content_tamper)
        verify_strict(
            content_tamper,
            should_pass=False,
            label="normalized copy after signed resource tamper",
        )

    print("Temporary fixture removed: PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except VerificationError as error:
        print("verification failed: {}".format(error), file=sys.stderr)
        raise SystemExit(1)
