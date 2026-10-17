#!/usr/bin/env bash
# Writes build/release/appcast.xml, the Sparkle feed for Reload's own updates
# (docs/app/updates.md), for the zip scripts/release.sh built, and signs both.
#
#   scripts/appcast.sh 0.2.0 [notes.md]
#
# The EdDSA key comes from $SPARKLE_ED_PRIVATE_KEY (CI) or, without it, the login keychain
# (account io.github.miotke.Reload, where generate_keys stored it). With a notes file, its
# "What's new" section becomes the update window's notes. $APPCAST_DOWNLOAD_URL overrides
# the zip's URL, for a local test feed.
set -euo pipefail

version=${1:?usage: scripts/appcast.sh <version> [notes.md]}
version=${version#v}
notes_file=${2:-}

root=$(cd "$(dirname "$0")/.." && pwd)
out=$root/build/release
zip=$out/Reload-$version.zip
plist=$out/Reload.app/Contents/Info.plist
feed=$out/appcast.xml
if [[ ! -f $zip || ! -f $plist ]]; then
  echo "error: $zip not found; run scripts/release.sh $version first" >&2
  exit 1
fi
bin=$("$root/scripts/sparkle-tools.sh")

sign() {
  if [[ -n ${SPARKLE_ED_PRIVATE_KEY:-} ]]; then
    printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$bin/sign_update" --ed-key-file - "$@"
  else
    "$bin/sign_update" --account io.github.miotke.Reload "$@"
  fi
}

# Sparkle compares CFBundleVersion, and shows the short version.
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
minimum=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")
url=${APPCAST_DOWNLOAD_URL:-https://github.com/miotke/reload/releases/download/v$version/Reload-$version.zip}
enclosure=$(sign "$zip")  # sparkle:edSignature="…" length="…"

notes=""
if [[ -n $notes_file ]]; then
  # From "## What's new…" up to the next heading of that level; CDATA can't hold "]]>".
  notes=$(awk '/^## What.s new/ { on = 1; next } /^## / { on = 0 } on' "$notes_file" | sed 's/]]>/]]]]><![CDATA[>/g')
fi

cat > "$feed" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Reload</title>
    <item>
      <title>Reload $version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown"><![CDATA[$notes]]></description>
      <enclosure url="$url" type="application/octet-stream" $enclosure/>
    </item>
  </channel>
</rss>
EOF

# Embeds the feed's own signature (the app sets SURequireSignedFeed).
sign "$feed"
echo "==> $feed"
