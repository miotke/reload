#!/bin/zsh
# Builds a release of Reload.app (with the bundled `reload` CLI) and zips it for GitHub
# Releases (docs/app/releases.md).
#
#   scripts/release.sh 0.2.0
#
# Unsigned by default (ad-hoc, like a Debug build). Signing and notarization switch on when
# their environment variables are set:
#
#   RELOAD_TEAM_ID            Apple team ID; signs with the "Developer ID Application" certificate
#   RELOAD_NOTARY_PROFILE     a `xcrun notarytool store-credentials` profile name, or
#   RELOAD_NOTARY_KEY_PATH    an App Store Connect API key (.p8) with
#   RELOAD_NOTARY_KEY_ID      its key ID and
#   RELOAD_NOTARY_ISSUER_ID   issuer ID
#   RELOAD_KEYCHAIN           keychain holding the certificate (CI uses a temporary one)
#
# Output goes to build/release/: Reload-<version>.zip and its .sha256.
set -euo pipefail

version=${1:-}
if [[ -z $version ]]; then
    echo "usage: scripts/release.sh <version>   e.g. 0.2.0" >&2
    exit 2
fi
version=${version#v}

root=${0:A:h:h}
out=$root/build/release
archive=$out/Reload.xcarchive
app=$out/Reload.app
zip=$out/Reload-$version.zip

# One version in three places; the script checks rather than edits them, so a release
# always matches a commit.
plist_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$root/App/Reload/Info.plist")
core_version=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$root/Sources/AddonKit/Sources/Source.swift")
spec_version=$(sed -n 's/.*CFBundleShortVersionString: "\(.*\)".*/\1/p' "$root/App/project.yml")
for found in $plist_version $core_version $spec_version; do
    if [[ $found != "$version" ]]; then
        echo "error: version mismatch. Asked for $version; Info.plist has $plist_version," >&2
        echo "       AppInfo.version has $core_version, project.yml has $spec_version." >&2
        exit 1
    fi
done

signing=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
if [[ -n ${RELOAD_TEAM_ID:-} ]]; then
    signing=(
        CODE_SIGN_STYLE=Manual
        "CODE_SIGN_IDENTITY=Developer ID Application"
        DEVELOPMENT_TEAM=$RELOAD_TEAM_ID
        "OTHER_CODE_SIGN_FLAGS=--timestamp${RELOAD_KEYCHAIN:+ --keychain $RELOAD_KEYCHAIN}"
    )
fi

rm -rf "$out"
mkdir -p "$out"

echo "==> Archiving Reload $version"
xcodebuild -project "$root/App/Reload.xcodeproj" -scheme Reload -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$archive" \
    "${signing[@]}" archive -quiet
ditto "$archive/Products/Applications/Reload.app" "$app"

echo "==> Verifying the signature"
codesign --verify --deep --strict "$app"
codesign --verify --strict "$app/Contents/Helpers/reload"

notarize=()
if [[ -n ${RELOAD_NOTARY_PROFILE:-} ]]; then
    notarize=(--keychain-profile "$RELOAD_NOTARY_PROFILE")
elif [[ -n ${RELOAD_NOTARY_KEY_PATH:-} ]]; then
    notarize=(--key "$RELOAD_NOTARY_KEY_PATH" --key-id "$RELOAD_NOTARY_KEY_ID" --issuer "$RELOAD_NOTARY_ISSUER_ID")
fi

if (( ${#notarize} )); then
    if [[ -z ${RELOAD_TEAM_ID:-} ]]; then
        echo "error: notarization needs a Developer ID signature; set RELOAD_TEAM_ID" >&2
        exit 1
    fi
    echo "==> Notarizing (usually a few minutes)"
    ditto -c -k --keepParent "$app" "$out/notarize.zip"
    xcrun notarytool submit "$out/notarize.zip" "${notarize[@]}" --wait
    rm "$out/notarize.zip"
    xcrun stapler staple "$app"
    spctl --assess --type execute "$app"
else
    echo "==> Skipping notarization (no credentials). Gatekeeper will block this build on other Macs."
fi

ditto -c -k --keepParent "$app" "$zip"
(cd "$out" && shasum -a 256 "${zip:t}" > "${zip:t}.sha256")
echo "==> $zip"
