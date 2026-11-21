#!/bin/sh
# Downloads the pinned airplay-cli release into vendor/cliairplay and verifies its checksum.
set -e
cd "$(dirname "$0")/.."
VERSION=v0.5.15
ASSET=cliairplay-macos-arm64
SHA256=1253d3566d618a4d7b78a89238f3f16a299cab4199b429fd23ddfbcf138ef582
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
gh release download "$VERSION" -R music-assistant/airplay-cli -p "$ASSET" -p LICENSE -p THIRD_PARTY_NOTICES.md -D "$TMP"
GOT=$(shasum -a 256 "$TMP/$ASSET" | cut -d' ' -f1)
if [ "$GOT" != "$SHA256" ]; then
  echo "checksum mismatch: got $GOT, want $SHA256" >&2
  exit 1
fi
mkdir -p vendor
mv "$TMP/$ASSET" vendor/cliairplay
mv "$TMP/LICENSE" vendor/cliairplay-LICENSE
mv "$TMP/THIRD_PARTY_NOTICES.md" vendor/cliairplay-THIRD_PARTY_NOTICES.md
chmod +x vendor/cliairplay
vendor/cliairplay --check
