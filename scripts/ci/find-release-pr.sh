#!/usr/bin/env bash
# After a push to main: writes the PR number and head branch to $GITHUB_OUTPUT when $SHA is
# the merge commit of a release/vX.Y.Z pull request from this repo, and nothing otherwise,
# so the release job runs only for release merges. Needs no secrets.
set -euo pipefail

# Right after a merge the commit's pull requests can take a moment to show up.
for attempt in 1 2 3; do
  found=$(gh api "repos/$GITHUB_REPOSITORY/commits/$SHA/pulls" --jq "
    [.[] | select(.merged_at != null
                  and .merge_commit_sha == \"$SHA\"
                  and (.head.ref | startswith(\"release/v\"))
                  and .head.repo.full_name == \"$GITHUB_REPOSITORY\")]
    | first // empty | \"\(.number) \(.head.ref)\"")
  [[ -n $found ]] && break
  sleep $((attempt * 5))
done

if [[ -z $found ]]; then
  echo "Not a release merge; nothing to publish."
  exit 0
fi
read -r number head_ref <<<"$found"
echo "Release PR #$number ($head_ref)"
{
  echo "number=$number"
  echo "head_ref=$head_ref"
} >> "$GITHUB_OUTPUT"
