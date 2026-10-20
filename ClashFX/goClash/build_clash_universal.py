import argparse
import platform
import sys
import subprocess
import datetime
import plistlib
import os
import filecmp
from core_overlay import core_modfile


def get_version():
    with open("./go.mod") as file:
        for line in file.readlines():
            if "mihomo" in line and "ClashX" not in line:
                parts = line.strip().split()
                if len(parts) >= 2:
                    return parts[-1].lstrip("v")
            elif "clash" in line and "ClashX" not in line:
                return line.split("-")[-1].strip()[:6]
    return "unknown"


go_bin = "go"
go_modfile = ""


def build_clash(version, build_time, arch):
    command = f"""
{go_bin} build -modfile='{go_modfile}' -trimpath -tags with_gvisor -ldflags '-X "github.com/metacubex/mihomo/constant.Version={version}" \
-X "github.com/metacubex/mihomo/constant.BuildTime={build_time}"' \
-buildmode=c-archive -o goClash_{arch}.a """
    envs = os.environ.copy()
    envs.update(
        {
            "GOOS": "darwin",
            "GOARCH": arch,
            "CGO_ENABLED": "1",
            "CGO_LDFLAGS": "-mmacosx-version-min=10.14",
            "CGO_CFLAGS": "-mmacosx-version-min=10.14",
        }
    )
    subprocess.check_output(command, shell=True, env=envs)


def mergeLibs():
    if not filecmp.cmp("goClash_amd64.h", "goClash_arm64.h"):
        exit(-1)
    os.rename("goClash_amd64.h", "goClash.h")
    command = "lipo *.a -create -output goClash.a"
    subprocess.check_output(command, shell=True)


def build_mihomo_bin(version, build_time, arch):
    command = f"""
{go_bin} build -modfile='{go_modfile}' -trimpath -tags with_gvisor -ldflags '-X "github.com/metacubex/mihomo/constant.Version={version}" \
-X "github.com/metacubex/mihomo/constant.BuildTime={build_time}"' \
-o mihomo_core_{arch} ./mihomo-bin/ """
    envs = os.environ.copy()
    envs.update(
        {
            "GOOS": "darwin",
            "GOARCH": arch,
            "CGO_ENABLED": "0",
        }
    )
    subprocess.check_output(command, shell=True, env=envs)


def mergeMihomoBins():
    command = "lipo mihomo_core_arm64 mihomo_core_amd64 -create -output mihomo_core"
    subprocess.check_output(command, shell=True)
    subprocess.check_output(
        "codesign --sign - --force --identifier com.clashx.mihomo-core mihomo_core",
        shell=True,
    )


def clean():
    cmd = "rm -f *amd* *arm*"
    subprocess.check_output(cmd, shell=True)


def write_to_info(version):
    path = "../info.plist"

    with open(path, "rb") as f:
        contents = plistlib.load(f)

    if not contents:
        exit(-1)

    contents["coreVersion"] = version
    with open(path, "wb") as f:
        plistlib.dump(contents, f, sort_keys=False)


def run(native=False):
    global go_modfile
    version = get_version()
    print("current clash version:", version)
    build_time = datetime.datetime.now().strftime("%Y-%m-%d-%H%M")
    with core_modfile() as modfile:
        go_modfile = modfile
        print("verify core workaround and Go tests")
        subprocess.check_call(
            [go_bin, "test", f"-modfile={go_modfile}", "./..."],
        )
        print("clean existing")
        subprocess.check_output("rm -f *Clash*.h *.a mihomo_core_*", shell=True)
        if native:
            machine = platform.machine().lower()
            arch = {"arm64": "arm64", "aarch64": "arm64", "x86_64": "amd64", "amd64": "amd64"}.get(machine)
            if arch is None:
                raise RuntimeError("Unsupported native macOS architecture: " + machine)
            print("create native library and core:", arch)
            build_clash(version, build_time, arch)
            os.replace("goClash_" + arch + ".a", "goClash.a")
            os.replace("goClash_" + arch + ".h", "goClash.h")
            build_mihomo_bin(version, build_time, arch)
            os.replace("mihomo_core_" + arch, "mihomo_core")
            subprocess.check_output(["codesign", "--sign", "-", "--force", "--identifier", "com.clashx.mihomo-core", "mihomo_core"])
        else:
            print("create arm64 library")
            build_clash(version, build_time, "arm64")
            print("create amd64 library")
            build_clash(version, build_time, "amd64")
            print("merge libraries")
            mergeLibs()
            print("create arm64 mihomo-bin")
            build_mihomo_bin(version, build_time, "arm64")
            print("create amd64 mihomo-bin")
            build_mihomo_bin(version, build_time, "amd64")
            print("merge and codesign mihomo-bin")
            mergeMihomoBins()
        subprocess.check_call([sys.executable, "../../scripts/verify-core-build-capabilities.py",
                               "--core", os.path.abspath("mihomo_core")])
        print("clean")
        clean()
    if os.environ.get("CI", False) or os.environ.get("GITHUB_ACTIONS", False):
        print("writing info.plist")
        write_to_info(version)
    print("done")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Build the full-featured embedded and external cores")
    parser.add_argument("--native", action="store_true", help="build only this Mac's architecture for local Xcode testing")
    run(native=parser.parse_args().native)
