#!/bin/bash
set -euo pipefail

LAB_TAG="${1:-}"
STABLE_TAG="${2:-}"
shift 2 2>/dev/null || true

AUTO_YES=false
ISSUES=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) AUTO_YES=true; shift ;;
    --issues) ISSUES="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: $0 <lab-tag> <stable-tag> [--yes] [--issues NN,NN]

Promote a Lab build (4-segment tag) to Stable (3-segment tag) by tagging
the same commit. CI auto-detects segment count and handles the rest.

Examples:
  $0 1.1.2.1 1.1.2 --issues 75,104
  $0 1.1.3.2 1.1.3 --yes
EOF
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$LAB_TAG" || -z "$STABLE_TAG" ]]; then
  echo "Usage: $0 <lab-tag> <stable-tag> [--yes] [--issues NN,NN]" >&2
  echo "       $0 --help" >&2
  exit 1
fi

if ! [[ "$LAB_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "❌ Lab tag must be 4-segment (e.g. 1.1.2.1), got: $LAB_TAG" >&2
  exit 1
fi
if ! [[ "$STABLE_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "❌ Stable tag must be 3-segment (e.g. 1.1.2), got: $STABLE_TAG" >&2
  exit 1
fi

REPO="Clash-FX/ClashFX"
APPCAST_URL="https://clash-fx.github.io/ClashFX/appcast.xml"

echo "============================================================"
echo "  Promote Lab → Stable"
echo "============================================================"
echo "  Lab tag:    $LAB_TAG"
echo "  Stable tag: $STABLE_TAG"
echo "  Repo:       $REPO"
echo "  Issues:     ${ISSUES:-(none)}"
echo

echo "▶ Step 1/11 — Verify gh account is mixc6763-prog"
ACCOUNT=$(gh api user --jq '.login' 2>/dev/null || echo "")
if [[ "$ACCOUNT" != "mixc6763-prog" ]]; then
  echo "  Active account is '$ACCOUNT', switching..."
  gh auth switch -u mixc6763-prog
fi
echo "  ✓ Active: mixc6763-prog"
echo

echo "▶ Step 2/11 — Verify working tree clean + main up-to-date"
if ! git diff --quiet HEAD; then
  echo "❌ Uncommitted changes. Stash or commit first." >&2
  exit 1
fi
git fetch -q origin main --tags
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)
if [[ "$LOCAL" != "$REMOTE" ]]; then
  echo "❌ Local main ($LOCAL) ≠ origin/main ($REMOTE). Pull first." >&2
  exit 1
fi
echo "  ✓ HEAD: ${LOCAL:0:8}"
echo

echo "▶ Step 3/11 — Verify Lab release exists & is prerelease"
LAB_INFO=$(gh release view "$LAB_TAG" -R "$REPO" --json isPrerelease,publishedAt 2>/dev/null) || {
  echo "❌ Lab release $LAB_TAG not found on $REPO" >&2
  exit 1
}
IS_PRE=$(echo "$LAB_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin)['isPrerelease'])")
PUB_AT=$(echo "$LAB_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin)['publishedAt'])")
if [[ "$IS_PRE" != "True" ]]; then
  echo "❌ Release $LAB_TAG is not prerelease. Refusing to promote a non-Lab build." >&2
  exit 1
fi
LAB_COMMIT=$(git rev-list -n 1 "$LAB_TAG")
if [[ -z "$LAB_COMMIT" ]]; then
  echo "❌ Could not resolve Lab tag $LAB_TAG to a commit." >&2
  exit 1
fi
if ! git merge-base --is-ancestor "$LAB_COMMIT" origin/main; then
  echo "❌ Lab commit $LAB_COMMIT is not contained in origin/main." >&2
  exit 1
fi
LAB_AGE_HOURS=$(python3 -c "
from datetime import datetime, timezone
pub = datetime.fromisoformat('$PUB_AT'.replace('Z','+00:00'))
print(int((datetime.now(timezone.utc) - pub).total_seconds() / 3600))
")
echo "  ✓ Lab release exists, age ${LAB_AGE_HOURS}h"

if [[ "$LAB_AGE_HOURS" -lt 24 ]]; then
  echo "  ⚠ Observation window < 24h (recommend 24-48h)"
  if [[ "$AUTO_YES" != true ]]; then
    read -p "    Promote anyway? [y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Aborted."; exit 0; }
  fi
fi
echo

echo "▶ Step 4/11 — Verify stable tag $STABLE_TAG doesn't exist yet"
if gh release view "$STABLE_TAG" -R "$REPO" --json tagName &>/dev/null; then
  echo "❌ Release $STABLE_TAG already exists on $REPO. Aborting." >&2
  exit 1
fi
echo "  ✓ $STABLE_TAG slot is free"
echo

if [[ -n "$ISSUES" ]]; then
  echo "▶ Step 5/11 — Check referenced issues for regression reports"
  IFS=',' read -ra ISSUE_LIST <<< "$ISSUES"
  for n in "${ISSUE_LIST[@]}"; do
    n=$(echo "$n" | tr -d ' ')
    echo "  --- #$n ---"
    gh issue view "$n" -R "$REPO" --json state,comments \
      --jq '"    state: " + .state + "\n    last by: " + ((.comments | last | .author.login) // "n/a") + " @ " + ((.comments | last | .createdAt) // "n/a") + "\n    body: " + (((.comments | last | .body) // "n/a")[0:160] | gsub("\n"; " "))'
  done
  echo
  if [[ "$AUTO_YES" != true ]]; then
    read -p "  Any regression you spotted? Continue with promote? [y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Aborted."; exit 0; }
  fi
else
  echo "▶ Step 5/11 — (skipped, no --issues)"
fi
echo

echo "▶ Step 6/11 — Final confirm"
echo "    Tag $STABLE_TAG → ${LAB_COMMIT:0:8} (Lab $LAB_TAG commit)"
echo "    CI will: build, sign, release (prerelease=false), update appcast,"
echo "             dispatch website (config.ts bump + Cloudflare deploy)"
if [[ "$AUTO_YES" != true ]]; then
  read -p "    Proceed? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Aborted."; exit 0; }
fi
echo

echo "▶ Step 7/11 — Create + push tag $STABLE_TAG"
git tag "$STABLE_TAG" "$LAB_COMMIT"
git push origin "$STABLE_TAG"
echo "  ✓ Tag pushed"
echo

echo "▶ Step 8/11 — Watch CI run (~7-10 min)"
sleep 6
RUN_ID=$(gh run list -R "$REPO" --workflow=main.yml --limit 5 --json databaseId,headBranch \
  --jq ".[] | select(.headBranch == \"$STABLE_TAG\") | .databaseId" | head -1)
if [[ -z "$RUN_ID" ]]; then
  echo "  ⚠ Could not find CI run yet, retrying once..."
  sleep 10
  RUN_ID=$(gh run list -R "$REPO" --workflow=main.yml --limit 5 --json databaseId,headBranch \
    --jq ".[] | select(.headBranch == \"$STABLE_TAG\") | .databaseId" | head -1)
fi
echo "  Run URL: https://github.com/$REPO/actions/runs/$RUN_ID"
gh run watch "$RUN_ID" -R "$REPO" --exit-status
echo "  ✓ CI succeeded"
echo

echo "▶ Step 9/11 — Verify Stable release (prerelease=false)"
STABLE_INFO=$(gh release view "$STABLE_TAG" -R "$REPO" --json isPrerelease,url)
STABLE_IS_PRE=$(echo "$STABLE_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin)['isPrerelease'])")
if [[ "$STABLE_IS_PRE" == "True" ]]; then
  echo "  ❌ Release $STABLE_TAG is prerelease. Investigate CI logic in main.yml." >&2
  exit 1
fi
RELEASE_URL=$(echo "$STABLE_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin)['url'])")
echo "  ✓ Stable release published: $RELEASE_URL"
echo

echo "▶ Step 10/11 — Verify appcast.xml (give appcast PR auto-merge 30s)"
sleep 30
APPCAST=$(curl -sS "$APPCAST_URL" --max-time 15)
RESULT=$(echo "$APPCAST" | python3 -c "
import sys, re
content = sys.stdin.read()
m = re.search(r'(?s)<item>(?:(?!<item>).)*?<sparkle:shortVersionString>${STABLE_TAG//./\\.}</sparkle:shortVersionString>(?:(?!</item>).)*?</item>', content)
if not m:
    print('MISSING')
elif '<sparkle:channel>' in m.group(0):
    print('HAS_CHANNEL_TAG_UNEXPECTED')
else:
    print('OK_NO_CHANNEL')
")
case "$RESULT" in
  OK_NO_CHANNEL) echo "  ✓ Appcast entry for $STABLE_TAG has no channel tag (all users receive)" ;;
  HAS_CHANNEL_TAG_UNEXPECTED) echo "  ⚠ Stable entry has channel tag — Stable users won't see it!" ;;
  MISSING) echo "  ⚠ Appcast entry not yet published (appcast PR may still be in flight)" ;;
esac
echo

if [[ -n "$ISSUES" ]]; then
  echo "▶ Step 11/11 — Post promote notice to issues"
  IFS=',' read -ra ISSUE_LIST <<< "$ISSUES"
  for n in "${ISSUE_LIST[@]}"; do
    n=$(echo "$n" | tr -d ' ')
    gh issue comment "$n" -R "$REPO" --body "已 promote 到 Stable [v${STABLE_TAG}](https://github.com/${REPO}/releases/tag/${STABLE_TAG})。

如果你之前没切到 Lab，现在 ClashFX 会在下一次自动检查更新时（默认每天一次）提示升级。手动检查：菜单栏 → 帮助 → 检查更新。

Lab 通道在 v${LAB_TAG} 观察期没有新增回归报告，这版修复正式纳入 Stable。如果你这边确认问题不再复现，可以随时关闭这个 issue 🙏"
    echo "  ✓ Commented on #$n"
  done
else
  echo "▶ Step 11/11 — (skipped, no --issues)"
fi
echo

echo "============================================================"
echo "  ✓ Promote complete: $LAB_TAG → $STABLE_TAG"
echo "============================================================"
echo "  Release:   $RELEASE_URL"
echo "  Appcast:   $APPCAST_URL"
echo "  Next:      Stable users get the update via Sparkle within ~24h."
echo "             Issues stay open until user confirms or a few days pass."
