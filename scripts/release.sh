#!/bin/bash
# Cut a new CCBar release: build the app, package it, upload to GitHub
# Releases, and update the Sparkle appcast on the gh-pages branch.
#
# Usage:
#   scripts/release.sh 0.2.0           # tag = v0.2.0
#   scripts/release.sh 0.2.0 "build notes"   # release notes appended below auto-generated body
#
# Prereqs (one-time):
#   - gh CLI authenticated (`gh auth status`)
#   - GitHub Pages enabled on the `gh-pages` branch (repo Settings → Pages)
#   - clean working tree on main (uncommitted changes block the release)
#
# What it does:
#   1) Validates version, working tree, gh auth.
#   2) Builds CCBar.app at the requested version (release config, ad-hoc signed).
#   3) Zips the .app → CCBar-<version>.zip.
#   4) Creates an annotated git tag `v<version>` and pushes it.
#   5) Creates a GitHub Release with the zip attached.
#   6) Regenerates appcast.xml from existing releases and pushes it to gh-pages.

set -euo pipefail

VERSION="${1:-}"
EXTRA_NOTES="${2:-}"
if [[ -z "$VERSION" ]]; then
    echo "usage: $0 <version>  e.g. $0 0.2.0"
    exit 2
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
    echo "✘ version must look like 0.2.0 or 0.2.0-beta1 (got: $VERSION)"
    exit 2
fi

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

OWNER_REPO="FindingDory0-0/CCBar"
FEED_URL="https://findingdory0-0.github.io/CCBar/appcast.xml"
APP_NAME="CCBar"
TAG="v$VERSION"
ZIP_NAME="CCBar-$VERSION.zip"
ZIP_PATH="$PROJECT_ROOT/build/$ZIP_NAME"

# --- Pre-flight checks -------------------------------------------------------
command -v gh >/dev/null || { echo "✘ gh CLI not found — brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "✘ gh not authenticated — gh auth login"; exit 1; }

if ! git diff-index --quiet HEAD --; then
    echo "✘ working tree dirty — commit or stash first"
    git status --short | head -5
    exit 1
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "✘ tag $TAG already exists"
    exit 1
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$BRANCH" != "main" ]]; then
    echo "  ⚠ releasing from non-main branch '$BRANCH' — proceeding"
fi

echo "▸ Building CCBar.app v$VERSION (release config)…"
# Let build-app.sh derive CFBundleVersion from CCBAR_VERSION (= marketing
# version). They MUST match the appcast's sparkle:version, which is also the
# marketing version — a timestamp build number here would break Sparkle's
# comparison.
CCBAR_VERSION="$VERSION" \
CCBAR_FEED_URL="$FEED_URL" \
    "$PROJECT_ROOT/scripts/build-app.sh" --release

APP_DIR="$PROJECT_ROOT/build/$APP_NAME.app"
[[ -d "$APP_DIR" ]] || { echo "✘ build did not produce $APP_DIR"; exit 1; }

echo "▸ Packaging ${ZIP_NAME}…"
rm -f "$ZIP_PATH"
# `ditto -c -k --keepParent` is the standard macOS app zipping recipe —
# preserves extended attributes and the .app's directory structure so
# Sparkle / Gatekeeper unzip it cleanly.
ditto -c -k --keepParent --sequesterRsrc "$APP_DIR" "$ZIP_PATH"
ZIP_SIZE=$(stat -f %z "$ZIP_PATH")
echo "  ✓ $ZIP_PATH ($ZIP_SIZE bytes)"

echo "▸ Tagging $TAG and pushing…"
git tag -a "$TAG" -m "CCBar $VERSION"
git push origin "$TAG"

echo "▸ Creating GitHub Release…"
RELEASE_BODY_FILE=$(mktemp)
trap 'rm -f "$RELEASE_BODY_FILE"' EXIT
{
    printf 'CCBar %s\n\n' "$VERSION"
    if [[ -n "$EXTRA_NOTES" ]]; then
        printf '%s\n\n' "$EXTRA_NOTES"
    fi
    printf '### Install\n'
    printf '1. Download `%s` below\n' "$ZIP_NAME"
    printf '2. Unzip → drag `CCBar.app` to `/Applications`\n'
    printf '3. First launch will ask for Accessibility + Apple Events permissions\n'
    printf '\n_Auto-update is live — future versions install themselves via Sparkle._\n'
} > "$RELEASE_BODY_FILE"

gh release create "$TAG" "$ZIP_PATH" \
    --repo "$OWNER_REPO" \
    --title "CCBar $VERSION" \
    --notes-file "$RELEASE_BODY_FILE"

echo "▸ Regenerating appcast.xml from all releases…"
"$PROJECT_ROOT/scripts/generate-appcast.sh"

echo ""
echo "✓ Released $TAG"
echo "  GitHub:  https://github.com/$OWNER_REPO/releases/tag/$TAG"
echo "  Feed:    $FEED_URL"
echo ""
echo "Users on previous versions will be offered the update on next Sparkle check"
echo "(daily by default, or immediately via ⚙ → 업데이트 확인)."
