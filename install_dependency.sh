#!/bin/bash
set -e

DASHBOARD_TAG="v1.266.1"
DASHBOARD_COMMIT="3a880c5946b7c6f29f3886044afa85783557698a"
DASHBOARD_SHA256="78c58e4411da4f9c493aa0a0ab35684c2681a9e197cb88d20d0f30878fbd8fe8"
DASHBOARD_ARCHIVE_URL="https://github.com/MetaCubeX/metacubexd/releases/download/${DASHBOARD_TAG}/compressed-dist.tgz"

REPOSITORY_ROOT="$(cd "$(dirname "$0")" && pwd)"
echo "Build Clash core"

cd "$REPOSITORY_ROOT/ClashFX/goClash"
python3 build_clash_universal.py
cd "$REPOSITORY_ROOT"

echo "Pod install"
bundle install --jobs 4
bundle exec pod install
echo "delete old files"
rm -f "$REPOSITORY_ROOT/ClashFX/Resources/Country.mmdb"
rm -f "$REPOSITORY_ROOT"/GeoLite2-Country.*
echo "install mmdb"
curl -LO https://github.com/Dreamacro/maxmind-geoip/releases/latest/download/Country.mmdb
gzip Country.mmdb
mv Country.mmdb.gz "$REPOSITORY_ROOT/ClashFX/Resources/Country.mmdb.gz"
echo "install dashboard"
DASHBOARD_DIR="$REPOSITORY_ROOT/ClashFX/Resources/dashboard"
DASHBOARD_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clashfx-dashboard.XXXXXX")"
DASHBOARD_STAGE_DIR="$(mktemp -d "${DASHBOARD_DIR}.stage.XXXXXX")"
DASHBOARD_BACKUP_DIR="${DASHBOARD_DIR}.previous.$$"

cleanup_dashboard_temp() {
    rm -rf "$DASHBOARD_TEMP_DIR" "$DASHBOARD_STAGE_DIR"
}
trap cleanup_dashboard_temp EXIT

echo "download dashboard ${DASHBOARD_TAG} (${DASHBOARD_COMMIT})"
curl --fail --location --retry 3 --output "$DASHBOARD_TEMP_DIR/compressed-dist.tgz" "$DASHBOARD_ARCHIVE_URL"
ACTUAL_DASHBOARD_SHA256="$(shasum -a 256 "$DASHBOARD_TEMP_DIR/compressed-dist.tgz" | awk '{print $1}')"
if [ "$ACTUAL_DASHBOARD_SHA256" != "$DASHBOARD_SHA256" ]; then
    echo "Dashboard checksum mismatch for ${DASHBOARD_TAG}: expected ${DASHBOARD_SHA256}, got ${ACTUAL_DASHBOARD_SHA256}" >&2
    exit 1
fi

tar -xzf "$DASHBOARD_TEMP_DIR/compressed-dist.tgz" -C "$DASHBOARD_STAGE_DIR"
if [ ! -r "$DASHBOARD_STAGE_DIR/index.html" ]; then
    echo "Dashboard archive has no static index.html" >&2
    exit 1
fi
if ! grep -q 'appVersion:"1.266.1"' "$DASHBOARD_STAGE_DIR/index.html"; then
    echo "Dashboard archive does not contain expected version 1.266.1" >&2
    exit 1
fi

if [ -e "$DASHBOARD_BACKUP_DIR" ]; then
    echo "Dashboard backup path already exists: $DASHBOARD_BACKUP_DIR" >&2
    exit 1
fi
if [ -e "$DASHBOARD_DIR" ]; then
    mv "$DASHBOARD_DIR" "$DASHBOARD_BACKUP_DIR"
fi
if ! mv "$DASHBOARD_STAGE_DIR" "$DASHBOARD_DIR"; then
    if [ -e "$DASHBOARD_BACKUP_DIR" ]; then
        mv "$DASHBOARD_BACKUP_DIR" "$DASHBOARD_DIR"
    fi
    echo "Dashboard replacement failed" >&2
    exit 1
fi
if [ -e "$DASHBOARD_BACKUP_DIR" ]; then
    rm -rf "$DASHBOARD_BACKUP_DIR"
fi
echo "Installed MetaCubeXD dashboard ${DASHBOARD_TAG} (${DASHBOARD_COMMIT})"
