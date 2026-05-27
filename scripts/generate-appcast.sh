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

# Ensure gh-pages branch exists. Create as an orphan on first run.
if ! git ls-remote --exit-code --heads origin gh-pages >/dev/null 2>&1; then
    echo "▸ Creating gh-pages branch (orphan, first-time setup)…"
    SAVED_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    git switch --orphan gh-pages
    git rm -rf --cached . >/dev/null 2>&1 || true
    rm -rf -- *.swift Sources Tests scripts Package.swift README.md .build build 2>/dev/null || true
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
    git switch "$SAVED_BRANCH"
fi

# Use a worktree so we don't disturb the user's main checkout.
if [[ ! -d "$WORKTREE" ]]; then
    git worktree add "$WORKTREE" gh-pages
else
    git -C "$WORKTREE" fetch origin gh-pages
    git -C "$WORKTREE" reset --hard origin/gh-pages
fi

echo "▸ Querying releases…"
# Pull every published (non-draft, non-prerelease) release with its zip asset.
# jq turns it into one Sparkle <item> per release.
RELEASES_JSON=$(gh api "repos/$OWNER_REPO/releases" --paginate)

ITEMS=$(printf '%s' "$RELEASES_JSON" | jq -r '
    [.[] | select(.draft == false) | {
        tag: .tag_name,
        version: (.tag_name | ltrimstr("v")),
        title: .name,
        notes: (.body // ""),
        published: .published_at,
        asset: ([.assets[] | select(.name | endswith(".zip"))] | first)
    } | select(.asset != null)] | reverse[]   # oldest → newest in feed
    | "    <item>\n" +
      "      <title>" + .title + "</title>\n" +
      "      <sparkle:version>" + .version + "</sparkle:version>\n" +
      "      <sparkle:shortVersionString>" + .version + "</sparkle:shortVersionString>\n" +
      "      <pubDate>" + .published + "</pubDate>\n" +
      "      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>\n" +
      "      <description><![CDATA[" + .notes + "]]></description>\n" +
      "      <enclosure url=\"" + .asset.browser_download_url + "\"\n" +
      "                 length=\"" + (.asset.size | tostring) + "\"\n" +
      "                 type=\"application/octet-stream\" />\n" +
      "    </item>"')

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
