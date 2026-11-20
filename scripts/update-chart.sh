#!/usr/bin/env bash
# Pins charts/mastodon to a published image and bumps the chart version:
# minor when the Mastodon minor (or major) version changes, patch otherwise.
# A no-op if the chart already pins that image. Run from the repo root.
#
# usage: scripts/update-chart.sh <immutable tag, e.g. v4.7.6-20261120.1> <sha256:digest>
set -euo pipefail

tag="${1:?usage: $0 <tag> <digest>}"
digest="${2:?usage: $0 <tag> <digest>}"
chart=charts/mastodon/Chart.yaml
values=charts/mastodon/values.yaml

[[ "$tag" =~ ^v([0-9]+\.[0-9]+)\.[0-9]+-[0-9]{8}\.[0-9]+$ ]] || { echo "error: unexpected tag '$tag'" >&2; exit 1; }
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "error: unexpected digest '$digest'" >&2; exit 1; }
app="${tag#v}"
app="${app%%-*}"

# Reads (and with a replacement, rewrites) the single line `<pattern>"value"`.
field() {
  local file="$1" pattern="$2"
  [[ $(grep -c "^$pattern\"" "$file") == 1 ]] || { echo "error: expected one '$pattern' line in $file" >&2; exit 1; }
  if [[ $# == 3 ]]; then
    sed -i.bak "s|^$pattern\".*\"\$|$pattern\"$3\"|" "$file" && rm "$file.bak"
  else
    sed -n "s|^$pattern\"\(.*\)\"\$|\1|p" "$file"
  fi
}

if [[ "$(field "$values" '  tag: ')" == "$tag" && "$(field "$values" '  digest: ')" == "$digest" ]]; then
  echo "Chart already pins $tag." >&2
  exit 0
fi

old_version=$(field "$chart" 'version: ')
old_app=$(field "$chart" 'appVersion: ')
IFS=. read -r major minor patch <<<"$old_version"
if [[ "${old_app%.*}" != "${app%.*}" ]]; then
  version="$major.$((minor + 1)).0"
else
  version="$major.$minor.$((patch + 1))"
fi

field "$chart" 'version: ' "$version"
field "$chart" 'appVersion: ' "$app"
field "$values" '  tag: ' "$tag"
field "$values" '  digest: ' "$digest"
echo "Chart $old_version -> $version (image $tag)" >&2
