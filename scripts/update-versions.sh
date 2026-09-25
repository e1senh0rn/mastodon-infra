#!/usr/bin/env bash
# Regenerates versions.json for a given Mastodon release tag (or the latest
# stable release if none given). Invoked via `nix run .#update` - see
# flake.nix, which wraps this file with the tools on PATH (nix, curl, jq,
# skopeo) and exports NIXPKGS_PATH (the flake's pinned nixpkgs store path,
# used below to resolve fixed-output hashes against the exact same nixpkgs
# this flake builds with).
#
# Does not check that patches/status-length-validator-max-chars.patch still
# applies to the new tag - `nix build` does that for real (and fails loudly
# if not) the next time it's run, so it's not duplicated here.
set -euo pipefail

if [[ ! -f flake.nix ]] || [[ ! -f versions.json ]]; then
  echo "error: run this from the root of the repo (flake.nix and versions.json not found here)" >&2
  exit 1
fi

repo="ghcr.io/mastodon/mastodon"
fake_hash="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

# versions.json is only ever replaced by an atomic rename of a fully written
# temp file, so a failure at any step below leaves the working tree untouched.
tmp_out="versions.json.tmp"
trap 'rm -f "$tmp_out"' EXIT

tag="${1:-}"
if [[ -z "$tag" ]]; then
  echo "Resolving latest stable Mastodon release..." >&2
  tag=$(curl -sf https://api.github.com/repos/mastodon/mastodon/releases/latest | jq -r '.tag_name // empty')
fi
if [[ -z "$tag" || "$tag" == "null" ]]; then
  echo "error: could not resolve a Mastodon release tag (GitHub API rate limit?). Pass one explicitly: nix run .#update -- v4.7.0" >&2
  exit 1
fi
echo "Target version: $tag" >&2

echo "Inspecting $repo:$tag manifest..." >&2
manifest=$(skopeo inspect --raw "docker://$repo:$tag")

amd64_digest=$(jq -r '.manifests[] | select(.platform.os=="linux" and .platform.architecture=="amd64") | .digest' <<<"$manifest")
arm64_digest=$(jq -r '.manifests[] | select(.platform.os=="linux" and .platform.architecture=="arm64") | .digest' <<<"$manifest")

if [[ -z "$amd64_digest" || -z "$arm64_digest" ]]; then
  echo "error: could not find both amd64 and arm64 manifests for $repo:$tag" >&2
  echo "$manifest" >&2
  exit 1
fi
echo "amd64 manifest digest: $amd64_digest" >&2
echo "arm64 manifest digest: $arm64_digest" >&2

resolve_pullimage_hash() {
  local arch="$1" digest="$2" log got
  set +e
  log=$(nix build --impure --no-link --expr \
    "(import $NIXPKGS_PATH {}).dockerTools.pullImage { imageName = \"$repo\"; finalImageTag = \"$tag\"; os = \"linux\"; arch = \"$arch\"; imageDigest = \"$digest\"; sha256 = \"$fake_hash\"; }" 2>&1)
  set -e
  got=$(grep -oE 'got:[[:space:]]+sha256-[A-Za-z0-9+/=]+' <<<"$log" | awk '{print $2}' | head -n1)
  if [[ -z "$got" ]]; then
    echo "error: could not resolve pullImage hash for $arch:" >&2
    echo "$log" >&2
    exit 1
  fi
  echo "$got"
}

echo "Resolving amd64 image hash (pulls the image, no linux builder needed)..." >&2
amd64_sha256=$(resolve_pullimage_hash amd64 "$amd64_digest")
echo "Resolving arm64 image hash..." >&2
arm64_sha256=$(resolve_pullimage_hash arm64 "$arm64_digest")

# The base image's runtime config, captured mechanically rather than
# hand-copied from upstream's Dockerfile: dockerTools only auto-merges `Env`
# from `fromImage`, so every other Config field has to be passed to
# buildLayeredImage explicitly or it is silently dropped from the result.
# Keys are sorted (-S) for diff stability and null-valued keys dropped, so
# they don't end up as explicit nulls in the generated image config.
fetch_base_config() {
  skopeo inspect --config "docker://$repo@$1" |
    jq -S -c '.config | with_entries(select(.value != null))'
}

echo "Fetching base image config..." >&2
amd64_config=$(fetch_base_config "$amd64_digest")
arm64_config=$(fetch_base_config "$arm64_digest")

# Historically these are identical (nothing in the runtime config is
# arch-specific), so versions.json stores one shared baseConfig. If upstream
# ever diverges, fail here rather than silently applying one arch's config
# to both images.
if [[ "$amd64_config" != "$arm64_config" ]]; then
  echo "error: amd64 and arm64 base image configs differ, but versions.json stores a single shared baseConfig." >&2
  echo "amd64: $amd64_config" >&2
  echo "arm64: $arm64_config" >&2
  echo "Make baseConfig per-arch in versions.json and flake.nix to fix this." >&2
  exit 1
fi

validator_url="https://raw.githubusercontent.com/mastodon/mastodon/$tag/app/validators/status_length_validator.rb"
echo "Resolving status_length_validator.rb hash at $tag..." >&2
validator_sha256=$(nix store prefetch-file --json "$validator_url" | jq -r .hash)

jq -n \
  --arg version "$tag" \
  --arg validatorSha256 "$validator_sha256" \
  --argjson baseConfig "$amd64_config" \
  --arg amd64Digest "$amd64_digest" \
  --arg amd64Sha256 "$amd64_sha256" \
  --arg arm64Digest "$arm64_digest" \
  --arg arm64Sha256 "$arm64_sha256" \
  '{
    mastodonVersion: $version,
    validatorSha256: $validatorSha256,
    baseConfig: $baseConfig,
    archs: {
      "x86_64-linux": { arch: "amd64", imageDigest: $amd64Digest, sha256: $amd64Sha256 },
      "aarch64-linux": { arch: "arm64", imageDigest: $arm64Digest, sha256: $arm64Sha256 }
    }
  }' > "$tmp_out"

mv "$tmp_out" versions.json

echo "Updated versions.json to $tag." >&2
echo "Review the diff, then: nix build .#packages.<system>.default" >&2
echo "(patches/status-length-validator-max-chars.patch isn't checked here - if it no longer applies," >&2
echo "the build will fail loudly with a patch reject, and it'll need a manual update.)" >&2
