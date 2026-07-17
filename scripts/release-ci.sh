#!/bin/bash
set -euo pipefail

# Build, sign, notarize, and Sparkle-sign a Clearly DMG on GitHub Actions.
# The tag-triggered workflow publishes build/Clearly.dmg and build/appcast.xml.

VERSION="${1:?Usage: bash scripts/release-ci.sh <version>}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "❌ Invalid release version: $VERSION"
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

required_secrets=(
  APPLE_TEAM_ID
  ASC_ISSUER_ID
  ASC_KEY_ID
  ASC_PRIVATE_KEY
  MACOS_CERTIFICATE_P12_BASE64
  SIGNING_IDENTITY_NAME
  SPARKLE_ED_PRIVATE_KEY
)
for name in "${required_secrets[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "❌ Required secret $name is missing or empty"
    exit 1
  fi
done

for command in xcodegen create-dmg xcodebuild security codesign xcrun gh; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "❌ Required command is unavailable: $command"
    exit 1
  fi
done

if [[ "${GITHUB_REF_NAME:-v$VERSION}" != "v$VERSION" ]]; then
  echo "❌ Tag ${GITHUB_REF_NAME:-<none>} does not match version $VERSION"
  exit 1
fi

CERTIFICATE_PATH="$RUNNER_TEMP/Certificates.p12"
ASC_KEY_PATH="$RUNNER_TEMP/AuthKey_${ASC_KEY_ID}.p8"
KEYCHAIN_PATH="$RUNNER_TEMP/clearly-release.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
SIGNING_IDENTITY="Developer ID Application: $SIGNING_IDENTITY_NAME ($APPLE_TEAM_ID)"

cleanup() {
  security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
  rm -f "$CERTIFICATE_PATH" "$ASC_KEY_PATH"
}
trap cleanup EXIT

umask 077
printf '%s' "$MACOS_CERTIFICATE_P12_BASE64" |
  openssl base64 -d -A -out "$CERTIFICATE_PATH"
printf '%s' "$ASC_PRIVATE_KEY" > "$ASC_KEY_PATH"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$CERTIFICATE_PATH" \
  -k "$KEYCHAIN_PATH" \
  -P "${MACOS_CERTIFICATE_PASSWORD:-}" \
  -A \
  -t cert \
  -f pkcs12
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "$KEYCHAIN_PASSWORD" \
  "$KEYCHAIN_PATH" >/dev/null
security list-keychains -d user -s "$KEYCHAIN_PATH"
security default-keychain -d user -s "$KEYCHAIN_PATH"

if ! security find-identity -v -p codesigning "$KEYCHAIN_PATH" |
  grep -Fq "$SIGNING_IDENTITY"; then
  echo "❌ Expected signing identity was not imported: $SIGNING_IDENTITY"
  exit 1
fi

echo "🔨 Building Clearly v$VERSION..."
xcodegen generate
rm -rf build
mkdir -p build

authentication_args=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$ASC_KEY_PATH"
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
)

xcodebuild \
  -project Clearly.xcodeproj \
  -scheme Clearly \
  -configuration Release \
  -archivePath build/Clearly.xcarchive \
  "${authentication_args[@]}" \
  archive \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION"

sed "s/\${APPLE_TEAM_ID}/$APPLE_TEAM_ID/g" \
  ExportOptions.plist > build/ExportOptions.plist
xcodebuild \
  -exportArchive \
  -archivePath build/Clearly.xcarchive \
  -exportOptionsPlist build/ExportOptions.plist \
  -exportPath build/export \
  "${authentication_args[@]}"

echo "🔑 Re-signing the exported app inside-out..."
sed "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/com.sabotage.clearly/g" \
  Clearly/Clearly.entitlements > build/Clearly.entitlements
cp ClearlyQuickLook/ClearlyQuickLook.entitlements \
  build/ClearlyQuickLook.entitlements

SPARKLE_FRAMEWORK="build/export/Clearly.app/Contents/Frameworks/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "❌ Sparkle.framework was not found in the exported app"
  exit 1
fi

shopt -s nullglob
sparkle_xpc_services=("$SPARKLE_FRAMEWORK"/Versions/B/XPCServices/*.xpc)
if [[ ${#sparkle_xpc_services[@]} -eq 0 ]]; then
  echo "❌ Sparkle XPC services were not found"
  exit 1
fi
for xpc in "${sparkle_xpc_services[@]}"; do
  codesign \
    --force \
    --sign "$SIGNING_IDENTITY" \
    --keychain "$KEYCHAIN_PATH" \
    --options runtime \
    --timestamp \
    "$xpc"
done

codesign \
  --force \
  --sign "$SIGNING_IDENTITY" \
  --keychain "$KEYCHAIN_PATH" \
  --options runtime \
  --timestamp \
  "$SPARKLE_FRAMEWORK"
codesign \
  --force \
  --sign "$SIGNING_IDENTITY" \
  --keychain "$KEYCHAIN_PATH" \
  --options runtime \
  --timestamp \
  --entitlements build/ClearlyQuickLook.entitlements \
  build/export/Clearly.app/Contents/PlugIns/ClearlyQuickLook.appex
codesign \
  --force \
  --sign "$SIGNING_IDENTITY" \
  --keychain "$KEYCHAIN_PATH" \
  --options runtime \
  --timestamp \
  --entitlements build/Clearly.entitlements \
  build/export/Clearly.app

if ! codesign -d --entitlements :- build/export/Clearly.app 2>/dev/null |
  grep -q "mach-lookup"; then
  echo "❌ Sparkle mach-lookup entitlements are missing after re-signing"
  exit 1
fi
scripts/verify-entitlements.sh build/export/Clearly.app
codesign --verify --deep --strict --verbose=2 build/export/Clearly.app

notary_args=(
  --key "$ASC_KEY_PATH"
  --key-id "$ASC_KEY_ID"
  --issuer "$ASC_ISSUER_ID"
  --wait
  --output-format json
)

echo "🔏 Notarizing and stapling Clearly.app..."
ditto \
  -c \
  -k \
  --keepParent \
  build/export/Clearly.app \
  build/Clearly-notarization.zip
xcrun notarytool submit \
  build/Clearly-notarization.zip \
  "${notary_args[@]}" |
  tee build/notarization-app.json
if [[ "$(plutil -extract status raw build/notarization-app.json)" != "Accepted" ]]; then
  echo "❌ App notarization was not accepted"
  exit 1
fi
xcrun stapler staple build/export/Clearly.app
xcrun stapler validate build/export/Clearly.app

create_clearly_dmg() {
  local output_path="$1"
  rm -f "$output_path"

  create-dmg \
    --volname "Clearly" \
    --background scripts/dmg-background@2x.png \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 160 \
    --text-size 14 \
    --icon "Clearly.app" 170 180 \
    --hide-extension "Clearly.app" \
    --app-drop-link 490 180 \
    --no-internet-enable \
    --format UDZO \
    "$output_path" \
    build/export/Clearly.app || true

  if [[ ! -f "$output_path" ]]; then
    echo "❌ DMG creation failed"
    exit 1
  fi
}

echo "📦 Creating, notarizing, and stapling Clearly.dmg..."
create_clearly_dmg build/Clearly.dmg
xcrun notarytool submit \
  build/Clearly.dmg \
  "${notary_args[@]}" |
  tee build/notarization-dmg.json
if [[ "$(plutil -extract status raw build/notarization-dmg.json)" != "Accepted" ]]; then
  echo "❌ DMG notarization was not accepted"
  exit 1
fi
xcrun stapler staple build/Clearly.dmg
xcrun stapler validate build/Clearly.dmg

spctl --assess --type execute --verbose build/export/Clearly.app
hdiutil verify build/Clearly.dmg

SPARKLE_BIN="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update' \
  -type f \
  -print \
  -quit)"
if [[ -z "$SPARKLE_BIN" ]]; then
  echo "❌ Sparkle sign_update was not found in DerivedData"
  exit 1
fi

echo "✍️ Signing the DMG for Sparkle..."
signature_output="$(
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" |
    "$SPARKLE_BIN" --ed-key-file - build/Clearly.dmg
)"
ed_signature="$(
  printf '%s' "$signature_output" |
    sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p'
)"
signed_length="$(
  printf '%s' "$signature_output" |
    sed -n 's/.*length="\([^"]*\)".*/\1/p'
)"
actual_length="$(stat -f '%z' build/Clearly.dmg)"
if [[ -z "$ed_signature" || "$signed_length" != "$actual_length" ]]; then
  echo "❌ Sparkle signature metadata is invalid"
  exit 1
fi

extract_changelog_markdown() {
  awk -v version="$VERSION" '
    $0 ~ "^## \\[" version "\\]" { capture=1; next }
    capture && /^## / { exit }
    capture && /^- / { print }
  ' CHANGELOG.md
}

release_notes="$(extract_changelog_markdown)"
if [[ -z "$release_notes" ]]; then
  echo "❌ CHANGELOG.md has no release notes for v$VERSION"
  exit 1
fi
printf '%s\n' "$release_notes" > build/release-notes.md

html_notes="<ul>"
while IFS= read -r line; do
  item="${line#- }"
  item="${item//&/&amp;}"
  item="${item//</&lt;}"
  item="${item//>/&gt;}"
  html_notes+="<li>$item</li>"
done <<< "$release_notes"
html_notes+="</ul>"

existing_items="$(
  awk -v version="$VERSION" '
    /<item>/ { buffer=""; capture=1 }
    capture { buffer = buffer $0 "\n" }
    /<\/item>/ {
      capture=0
      marker="<sparkle:version>" version "</sparkle:version>"
      if (index(buffer, marker) == 0) {
        printf "%s", buffer
      }
    }
  ' website/appcast.xml
)"
pub_date="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
repository="${GITHUB_REPOSITORY:-limboy/clearly}"

cat > build/appcast.xml <<APPCAST
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0">
  <channel>
    <title>Clearly</title>
    <item>
      <title>Version $VERSION</title>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <pubDate>$pub_date</pubDate>
      <description><![CDATA[$html_notes]]></description>
      <enclosure
        url="https://github.com/$repository/releases/download/v$VERSION/Clearly.dmg"
        sparkle:edSignature="$ed_signature"
        length="$actual_length"
        type="application/octet-stream"
      />
    </item>
$existing_items
  </channel>
</rss>
APPCAST

plutil -lint build/export/Clearly.app/Contents/Info.plist
echo "✅ Clearly v$VERSION is ready at build/Clearly.dmg"
