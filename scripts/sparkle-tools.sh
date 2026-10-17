#!/usr/bin/env bash
# Downloads Sparkle's command-line tools (sign_update) into build/ once, checks the archive
# against a pinned SHA-256, and prints the folder holding them (docs/app/updates.md).
# Keep SPARKLE_VERSION in step with the Sparkle package in App/project.yml.
set -euo pipefail

SPARKLE_VERSION=2.10.0
SPARKLE_SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c

root=$(cd "$(dirname "$0")/.." && pwd)
dir=$root/build/sparkle-$SPARKLE_VERSION
if [[ ! -x $dir/bin/sign_update ]]; then
  mkdir -p "$dir"
  archive=$dir/Sparkle-$SPARKLE_VERSION.tar.xz
  curl -fsSL -o "$archive" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  echo "$SPARKLE_SHA256  $archive" | shasum -a 256 -c - >/dev/null
  tar -xf "$archive" -C "$dir" bin
fi
echo "$dir/bin"
