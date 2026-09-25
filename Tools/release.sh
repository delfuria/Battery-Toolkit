#!/bin/bash
#
# Builds, notarizes and packages a Battery Toolkit Next release.
#
# Usage: Tools/release.sh [keychain-profile]
#
# The keychain profile (default: BatteryToolkit-notary) must have been
# created with:
#   xcrun notarytool store-credentials BatteryToolkit-notary \
#       --apple-id <apple-id> --team-id VZWMBQL256
#
set -euo pipefail
cd "$(dirname "$0")/.."

profile="${1:-BatteryToolkit-notary}"
app_name="Battery Toolkit Next"
derived="build/release-dd"
products="$derived/Build/Products/Release"
dist="build/dist"

xcodebuild -project "Battery Toolkit.xcodeproj" -scheme "Battery Toolkit" \
    -configuration Release -derivedDataPath "$derived" clean build

app="$products/$app_name.app"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
    "$app/Contents/Info.plist")
base="Battery-Toolkit-Next-$version"

codesign --verify --deep --strict "$app"
if codesign -d --entitlements - "$app" 2>/dev/null | grep -q get-task-allow; then
    echo "error: release build contains get-task-allow" >&2
    exit 1
fi

mkdir -p "$dist"
rm -f "$dist/$base.zip" "$dist/$base-dSYM.zip" "$dist/SHA256SUMS.txt"

# Submit a temporary archive, then staple the ticket to the app itself.
ditto -c -k --sequesterRsrc --keepParent "$app" "$dist/$base-notarize.zip"
xcrun notarytool submit "$dist/$base-notarize.zip" \
    --keychain-profile "$profile" --wait
rm -f "$dist/$base-notarize.zip"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl -a -vv "$app"

ditto -c -k --sequesterRsrc --keepParent "$app" "$dist/$base.zip"
dsyms="$dist/$base-dSYM"
rm -rf "$dsyms"
mkdir -p "$dsyms"
cp -R "$products"/*.dSYM "$dsyms/"
ditto -c -k --sequesterRsrc "$dsyms" "$dist/$base-dSYM.zip"
rm -rf "$dsyms"
(cd "$dist" && shasum -a 256 "$base.zip" "$base-dSYM.zip" > SHA256SUMS.txt)

printf 'Release artifacts in %s:\n' "$dist"
cat "$dist/SHA256SUMS.txt"
