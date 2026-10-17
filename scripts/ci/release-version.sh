#!/usr/bin/env bash
# Works out the release version, X.Y.Z without the v, and writes VERSION to $GITHUB_ENV:
# from the release branch's name (a merge to main), the input (a manual run) or the tag.
# release.sh then checks it against Info.plist, project.yml and AppInfo.
set -euo pipefail

if [[ -n ${HEAD_REF:-} ]]; then
  v=${HEAD_REF#release/}
elif [[ $GITHUB_EVENT_NAME == workflow_dispatch ]]; then
  v=$INPUT_VERSION
else
  v=$GITHUB_REF_NAME
fi
v=${v#v}
[[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::Not a version: $v"; exit 1; }
echo "VERSION=$v" >> "${GITHUB_ENV:-/dev/stdout}"
