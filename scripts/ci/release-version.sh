#!/usr/bin/env bash
# Works out the release version, X.Y.Z without the v, and writes VERSION to $GITHUB_ENV:
# from the release branch's name (a merged PR), the input (a manual run) or the tag (a push).
# release.sh then checks it against Info.plist, project.yml and AppInfo.
set -euo pipefail

case $GITHUB_EVENT_NAME in
  pull_request) v=${HEAD_REF#release/} ;;
  workflow_dispatch) v=$INPUT_VERSION ;;
  *) v=$GITHUB_REF_NAME ;;
esac
v=${v#v}
[[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::Not a version: $v"; exit 1; }
echo "VERSION=$v" >> "${GITHUB_ENV:-/dev/stdout}"
