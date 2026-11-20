#!/usr/bin/env bash
# Publishes charts/mastodon to an OCI registry unless its version is already
# there, and tags the commit it was released from as chart-v<version>. Also
# completes an earlier release whose tag push failed. Needs helm, logged in
# to the registry, and the full git history. Run from the repo root.
#
# usage: scripts/release-chart.sh <oci://registry/path> <commit> [--fail-if-published]
#   --fail-if-published: for pushes that changed the chart, where an already
#   published version means someone forgot to bump it.
set -euo pipefail

registry="${1:?usage: $0 <oci://registry/path> <commit> [--fail-if-published]}"
ref="${2:?usage: $0 <oci://registry/path> <commit> [--fail-if-published]}"
fail_if_published="${3:-}"

version=$(git show "$ref:charts/mastodon/Chart.yaml" | sed -n 's/^version: "\(.*\)"$/\1/p')
[[ -n "$version" ]] || { echo "error: no version in charts/mastodon/Chart.yaml at $ref" >&2; exit 1; }
tag="chart-v$version"
# The packaged chart excludes test/. Any later change would need a new version,
# so this is the commit whose chart is (or will be) published as $version.
released_from=$(git log -1 --format=%H "$ref" -- charts/mastodon ':!charts/mastodon/test')

# OCI tags can be overwritten, so publish only on an explicit "not found".
if out=$(helm show chart "$registry/mastodon" --version "$version" 2>&1); then
  if [[ "$fail_if_published" == --fail-if-published ]]; then
    echo "::error file=charts/mastodon/Chart.yaml::Chart $version is already published; bump the version."
    exit 1
  fi
  echo "Chart $version is already published."
  published=false
elif grep -q ': not found$' <<<"$out"; then
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  git archive "$released_from" charts/mastodon | tar -x -C "$work"
  helm package "$work/charts/mastodon" -d "$work" >/dev/null
  helm push "$work/mastodon-$version.tgz" "$registry"
  published=true
else
  echo "$out" >&2
  exit 1
fi

# Fetching a tag that doesn't exist fails; so does a network error, but then
# pushing a tag that does exist is rejected below, so nothing is overwritten.
git fetch --quiet origin "refs/tags/$tag:refs/tags/$tag" 2>/dev/null || true
if tagged=$(git rev-parse --quiet --verify "refs/tags/$tag^{commit}"); then
  if [[ "$tagged" != "$released_from" ]]; then
    echo "::error::Git tag $tag points to $tagged, but chart $version was released from $released_from."
    exit 1
  fi
  echo "Git tag $tag is in place."
else
  # Lightweight, whatever tag.gpgSign says (it would require a message).
  git tag --no-sign "$tag" "$released_from"
  git push origin "refs/tags/$tag"
  echo "Tagged $released_from as $tag."
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    if [[ "$published" == true ]]; then echo "### Published chart $version"; else echo "### Chart $version (already published)"; fi
    echo
    echo '```'
    echo "helm install mastodon $registry/mastodon --version $version"
    echo '```'
    echo
    echo "Git tag \`$tag\` ($released_from)"
  } >>"$GITHUB_STEP_SUMMARY"
fi
