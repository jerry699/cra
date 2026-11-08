#!/bin/bash
# Publishes a fork release of Cra to the fork's GitHub Releases and signs the
# Sparkle appcast, so installed copies update themselves from it.
#
# The fork build is upstream main plus local patches (zh-Hans UI, Max provider);
# its feed URL and SUPublicEDKey in resources/Info.plist point at this channel,
# NOT at the author's. The signing key lives in the login keychain under the
# "cra-fork" account — never in git.
#
#   scripts/release-fork.sh <version>            e.g. 0.1.1
#   FORK_NOTES=<file.html>                       extra release notes (HTML)
#   FORK_REPO=jerry699/cra                       the GitHub repo to publish to
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release-fork.sh <version>}"
FORK_REPO="${FORK_REPO:-jerry699/cra}"
export CRA_VERSION="$VERSION"
export CRA_RELEASE=1
export SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-cra-fork}"

scripts/build.sh release
scripts/package.sh

ZIP="build/dist/Cra.zip"
CRA_UPDATE_URL="https://github.com/${FORK_REPO}/releases/download/v${VERSION}/Cra.zip" \
  scripts/appcast.sh "$ZIP" build/Cra.app

NOTES_ARGS=()
if [ -n "${FORK_NOTES:-}" ] && [ -f "$FORK_NOTES" ]; then
  NOTES_ARGS=(--notes-file "$FORK_NOTES")
else
  NOTES_ARGS=(--notes "Fork build: upstream main + local patches (Simplified Chinese UI, Max via your own OpenAI-compatible provider).")
fi

gh release create "v$VERSION" --repo "$FORK_REPO" --title "v$VERSION" \
  "${NOTES_ARGS[@]}" \
  "$ZIP" "build/dist/Cra.dmg" "build/dist/appcast.xml" "build/dist/SHA256SUMS.txt"

echo "Published https://github.com/${FORK_REPO}/releases/tag/v${VERSION}"
