#!/usr/bin/env bash
#
# One-command TestFlight release for Kiki.
#
#   ios/scripts/testflight-release.sh
#
# Does the whole pipeline: picks the next build number (highest on TestFlight + 1),
# bumps it, archives, exports with App Store distribution signing, uploads, then waits
# for processing and pushes the build to the External public-link group (+ Beta App Review).
#
# Requirements:
#   - Xcode 26+ selected (xcode-select -p). Apple rejects uploads built with older SDKs.
#   - App Store Connect API key .p8 at ~/.appstoreconnect/private_keys/ (see asc.mjs / env below).
#   - Export compliance is already baked into the project (INFOPLIST_KEY_ITSAppUsesNonExemptEncryption=NO).
#
# Notes:
#   - Testers already in the group do NOT re-use the invite link; new builds appear in their
#     TestFlight app (auto-install if they enabled Automatic Updates, else a one-tap Update).
#   - Public link: https://testflight.apple.com/join/zKYJuSat  (tester cap is set in App Store Connect).
#   - This commits nothing. Commit the build-number bump yourself after a successful run.
set -euo pipefail

SCHEME="Kiki"
ASC_KEY_ID="${ASC_KEY_ID:-KKBU3VH69S}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-227d4525-7a03-4792-8d9e-692a2743778c}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_KKBU3VH69S.p8}"

cd "$(dirname "$0")/.."   # -> ios/

# Guard: must be on Xcode 26+ or the upload will be rejected server-side.
XCODE_MAJOR="$(xcodebuild -version | sed -n 's/^Xcode \([0-9]*\).*/\1/p')"
if [ "${XCODE_MAJOR:-0}" -lt 26 ]; then
  echo "ERROR: Xcode $XCODE_MAJOR active; App Store requires Xcode 26+ (iOS 26 SDK)." >&2
  echo "       sudo xcode-select -s /Applications/Xcode.app  (point at Xcode 26)" >&2
  exit 1
fi

if [ ! -f "$ASC_KEY_PATH" ]; then
  echo "ERROR: API key not found at $ASC_KEY_PATH" >&2
  exit 1
fi

NEXT="$(node scripts/asc.mjs next-build)"
echo "==> Next build number: $NEXT"
agvtool new-version -all "$NEXT" >/dev/null
echo "==> Bumped CURRENT_PROJECT_VERSION to $NEXT"

WORK="$(mktemp -d)"
ARCHIVE="$WORK/Kiki.xcarchive"
EXPORT="$WORK/export"

echo "==> Archiving..."
# Auth flags on the archive step too: on a clean machine (CI runner) with no local
# signing identity, cloud-managed signing needs the API key at archive time as well.
# Harmless locally — same flags the export step already uses.
xcodebuild -scheme "$SCHEME" -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  archive

echo "==> Exporting (App Store distribution, cloud-managed signing)..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist scripts/ExportOptions.plist \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

echo "==> Uploading to App Store Connect..."
xcrun altool --upload-app -f "$EXPORT/Kiki.ipa" -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "==> Distributing build $NEXT to External group (waits for processing)..."
node scripts/asc.mjs distribute "$NEXT"

echo ""
echo "Done. Build $NEXT is live to testers. Remember to commit the build-number bump:"
echo "    git add ios/Kiki.xcodeproj/project.pbxproj && git commit -m \"chore(ios): bump build to $NEXT\""
