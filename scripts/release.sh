#!/usr/bin/env bash
# Build a distributable Copilot Projects.app and (optionally) publish a GitHub
# release with a drag-to-Applications DMG.
#
#   scripts/release.sh 0.1.0            # build dist/Copilot-Projects-0.1.0.dmg locally
#   scripts/release.sh 0.1.0 --publish  # also create the GitHub release + tag
#
# The app is ad-hoc signed (not notarized), so downloaded copies are quarantined
# by Gatekeeper — the release notes tell users to clear it once with
#   xattr -dr com.apple.quarantine "/Applications/Copilot Projects.app"
#
# --publish uses the active `gh` account; run it as the account that owns $REPO.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REPO="${GITHUB_REPOSITORY:-sirfergy/copilot-projects}"
APP_NAME="Copilot Projects"

VERSION=""
PUBLISH=0
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    -*) echo "unknown arg: $arg" >&2; exit 1 ;;
    *)  VERSION="$arg" ;;
  esac
done
[ -n "$VERSION" ] || { echo "usage: scripts/release.sh <version> [--publish]" >&2; exit 1; }
VERSION="${VERSION#v}"   # accept either 0.1.0 or v0.1.0
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "error: version must be X.Y.Z (optionally prefixed with v)" >&2
  exit 1
}
TAG="v$VERSION"

# SwiftPM + git need this when the user's global git sets safe.bareRepository=explicit.
export GIT_CONFIG_COUNT="${GIT_CONFIG_COUNT:-1}"
export GIT_CONFIG_KEY_0="${GIT_CONFIG_KEY_0:-safe.bareRepository}"
export GIT_CONFIG_VALUE_0="${GIT_CONFIG_VALUE_0:-all}"

echo "==> building release app (v$VERSION)"
VERSION="$VERSION" ./scripts/build-app.sh --release

APP="$ROOT/dist/$APP_NAME.app"
[ -d "$APP" ] || { echo "error: $APP missing after build" >&2; exit 1; }

echo "==> packaging DMG"
DMG="$ROOT/dist/Copilot-Projects-$VERSION.dmg"
STAGING="$(mktemp -d)"
NOTES_FILE=""
RELEASE_CREATED=0
cleanup() {
  status=$?
  if [ "$status" -ne 0 ] && [ "$RELEASE_CREATED" = "1" ]; then
    cleanup_partial_release
  fi
  rm -rf "$STAGING"
  [ -z "$NOTES_FILE" ] || rm -f "$NOTES_FILE"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"   # drag-to-install target
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
echo "  $DMG"

if [ "$PUBLISH" = "0" ]; then
  echo "==> built locally (no --publish). To publish the GitHub release:"
  echo "    scripts/release.sh $VERSION --publish"
  exit 0
fi

command -v gh >/dev/null || { echo "error: gh CLI not found" >&2; exit 1; }

echo "==> publishing GitHub release $TAG to $REPO"
SHA="$(git rev-parse HEAD)"
NOTES_FILE="$(mktemp)"
cat > "$NOTES_FILE" <<NOTES
## Install

1. Download \`Copilot-Projects-$VERSION.dmg\` below and open it.
2. Drag **Copilot Projects** onto **Applications**.
3. The app is ad-hoc signed (not notarized), so clear the download quarantine once:
   \`\`\`bash
   xattr -dr com.apple.quarantine "/Applications/Copilot Projects.app"
   \`\`\`
   Then launch it normally.

Requires macOS 13+. Apple Silicon (arm64).
NOTES

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "error: release $TAG already exists" >&2
  exit 1
fi
if gh api "repos/$REPO/git/ref/tags/$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG already exists in $REPO" >&2
  exit 1
fi

cleanup_partial_release() {
  if [ "$(gh release view "$TAG" --repo "$REPO" --json isDraft --jq .isDraft 2>/dev/null || true)" = "true" ]; then
    gh release delete "$TAG" --repo "$REPO" --yes --cleanup-tag >/dev/null 2>&1 || true
  fi
}
RELEASE_CREATED=1
gh release create "$TAG" \
  --repo "$REPO" \
  --target "$SHA" \
  --title "Copilot Projects $VERSION" \
  --notes-file "$NOTES_FILE" \
  --draft
gh release upload "$TAG" "$DMG" --repo "$REPO"
gh release edit "$TAG" --repo "$REPO" --draft=false
RELEASE_CREATED=0

echo "==> done: https://github.com/$REPO/releases/tag/$TAG"
