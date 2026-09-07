#!/bin/bash
set -eu

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 /path/to/ClashFX.app" >&2
    exit 64
fi

APP_PATH="$1"
RESOURCES_PATH="$APP_PATH/Contents/Resources"
COMPATIBILITY_SCRIPT="$RESOURCES_PATH/DashboardCompatibility/clashfx-compat.js"
DASHBOARD_INDEX="$RESOURCES_PATH/dashboard/index.html"

if [ ! -r "$COMPATIBILITY_SCRIPT" ]; then
    echo "Missing dashboard compatibility resource: $COMPATIBILITY_SCRIPT" >&2
    exit 1
fi
if [ ! -r "$DASHBOARD_INDEX" ]; then
    echo "Missing dashboard index: $DASHBOARD_INDEX" >&2
    exit 1
fi
if ! grep -q '__CLASHFX_DASHBOARD_COMPAT__' "$COMPATIBILITY_SCRIPT"; then
    echo "Dashboard compatibility diagnostic marker is missing" >&2
    exit 1
fi
if ! grep -q 'appVersion:"1.266.1"' "$DASHBOARD_INDEX"; then
    echo "Dashboard version marker 1.266.1 is missing" >&2
    exit 1
fi
if grep -qi 'Dashboard not available' "$DASHBOARD_INDEX"; then
    echo "Dashboard index is a placeholder" >&2
    exit 1
fi

echo "Dashboard compatibility bundle verified: $APP_PATH"
