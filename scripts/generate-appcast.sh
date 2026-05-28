#!/bin/bash
# Rebuild appcast.xml from the current state of GitHub Releases and push it
# to the `gh-pages` branch. Idempotent — safe to re-run.
#
# Called by release.sh after every release. You can also run it manually if
# you edit release notes on GitHub after the fact and want the feed to mirror
# them, or if gh-pages somehow got out of sync.

set -euo pipefail

OWNER_REPO="FindingDory0-0/CCBar"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

WORKTREE="$PROJECT_ROOT/.gh-pages-worktree"
APPCAST="$WORKTREE/appcast.xml"

command -v gh >/dev/null || { echo "✘ gh CLI not found"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "✘ gh not authenticated"; exit 1; }

# Ensure gh-pages branch exists, creating it as an orphan on first run.
#
# CRITICAL: every git mutation here happens inside $WORKTREE, never in the
# main checkout. An earlier version ran `git switch --orphan` + `rm -rf build
# .build …` directly in the main working tree, which deleted the user's
# uncommitted build artifacts. Worktree isolation makes that impossible —
# `git rm -rf .` only ever touches the throwaway worktree directory.
rm -rf "$WORKTREE"
if git ls-remote --exit-code --heads origin gh-pages >/dev/null 2>&1; then
    git worktree add "$WORKTREE" gh-pages
    git -C "$WORKTREE" fetch origin gh-pages
    git -C "$WORKTREE" reset --hard origin/gh-pages
else
    echo "▸ Creating gh-pages branch (orphan, first-time setup)…"
    # Detached worktree, then re-root it on a fresh orphan branch. All file
    # ops below are scoped to $WORKTREE.
    git worktree add --detach "$WORKTREE" >/dev/null
    (
        cd "$WORKTREE"
        git checkout --orphan gh-pages
        git rm -rf . >/dev/null 2>&1 || true   # worktree-local only — main tree untouched
        cat > index.html <<'HTML'
<!doctype html>
<meta charset="utf-8">
<title>CCBar</title>
<h1>CCBar</h1>
<p>macOS menu-bar app for Claude Code sessions — <a href="https://github.com/FindingDory0-0/CCBar">repository</a>.</p>
<p>Sparkle feed: <a href="appcast.xml">appcast.xml</a></p>
HTML
        git add index.html
        git -c user.email="saleslogis.ai@gmail.com" -c user.name="FindingDory0-0" \
            commit -m "Initial gh-pages — Sparkle appcast host"
        git push -u origin gh-pages
    )
fi

echo "▸ Querying releases…"
SIGN_TOOL="$PROJECT_ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$SIGN_TOOL" ]] || { echo "✘ sign_update not found — run 'swift build' first"; exit 1; }

# Cache downloaded zips so re-runs don't re-fetch every release.
CACHE="$PROJECT_ROOT/build/appcast-cache"
mkdir -p "$CACHE"

# One TSV row per published release with a zip asset, oldest→newest.
# Release notes are base64'd so embedded newlines/tabs don't break the TSV.
RELEASES_TSV=$(gh api "repos/$OWNER_REPO/releases" --paginate | jq -r '
    [.[] | select(.draft == false) | {
        version: (.tag_name | ltrimstr("v")),
        title: .name,
        published: .published_at,
        notes_b64: ((.body // "") | @base64),
        asset: ([.assets[] | select(.name | endswith(".zip"))] | first)
    } | select(.asset != null)] | reverse[]
    | [.version, .title, .published, .asset.browser_download_url, (.asset.size|tostring), .notes_b64]
    | @tsv')

# Build the <item> list, signing each zip with our EdDSA key. sign_update
# emits  sparkle:edSignature="…" length="…"  ready to drop into <enclosure>.
ITEMS=""
while IFS=$'\t' read -r version title published url size notes_b64; do
    [[ -z "$version" ]] && continue
    zip="$CACHE/$(basename "$url")"
    if [[ ! -f "$zip" ]]; then
        echo "  ↓ $(basename "$url")"
        curl -fsSL -o "$zip" "$url"
    fi
    SIG_ATTRS=$("$SIGN_TOOL" "$zip")   # → sparkle:edSignature="…" length="…"
    notes=$(printf '%s' "$notes_b64" | base64 --decode)
    ITEMS+="    <item>
      <title>${title}</title>
      <sparkle:version>${version}</sparkle:version>
      <sparkle:shortVersionString>${version}</sparkle:shortVersionString>
      <pubDate>${published}</pubDate>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[${notes}]]></description>
      <enclosure url=\"${url}\" ${SIG_ATTRS} type=\"application/octet-stream\" />
    </item>
"
done <<< "$RELEASES_TSV"

mkdir -p "$(dirname "$APPCAST")"
{
    cat <<'HEAD'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>CCBar Updates</title>
    <link>https://findingdory0-0.github.io/CCBar/appcast.xml</link>
    <description>Auto-update feed for CCBar — Claude Code menu bar app.</description>
    <language>en</language>
HEAD
    printf '%s\n' "$ITEMS"
    cat <<'TAIL'
  </channel>
</rss>
TAIL
} > "$APPCAST"

# Stage first so an untracked appcast.xml (first run) is also visible to the
# diff. `git diff --quiet appcast.xml` alone misses new files.
git -C "$WORKTREE" add appcast.xml
if git -C "$WORKTREE" diff --cached --quiet; then
    echo "  ✓ appcast.xml unchanged"
else
    git -C "$WORKTREE" \
        -c user.email="saleslogis.ai@gmail.com" \
        -c user.name="FindingDory0-0" \
        commit -m "appcast: regenerate from GitHub Releases"
    git -C "$WORKTREE" push origin gh-pages
    echo "  ✓ appcast.xml pushed to gh-pages"
fi
