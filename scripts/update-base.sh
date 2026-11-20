#!/usr/bin/env bash
# Bumps nixpkgs (every base component) to the latest nixos-unstable. Extra
# arguments go to `nix flake update`. Gems and npm packages move with
# update-mastodon instead.
set -euo pipefail

if [[ ! -f flake.nix ]] || [[ ! -f flake.lock ]]; then
  echo "error: run this from the root of the repo (flake.nix and flake.lock not found here)" >&2
  exit 1
fi

locked() {
  jq -r '.nodes.nixpkgs.locked | "\(.rev[0:12]) (\(.lastModified | todate | .[0:10]))"' flake.lock
}

before=$(locked)
nix flake update nixpkgs "$@"
after=$(locked)

if [[ "$before" == "$after" ]]; then
  echo "nixpkgs already up to date: $before" >&2
  exit 0
fi

echo "nixpkgs: $before -> $after" >&2
echo "Next: nix build .#packages.<system>.image, then scripts/smoke-test.sh." >&2
echo "To see which packages changed, compare closures before and after:" >&2
echo "  nix store diff-closures <old image or mastodon path> <new one>" >&2
