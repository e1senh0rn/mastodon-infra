#!/usr/bin/env bash
# Static checks: helm lint, schema validation of the rendered manifests
# (CRDs included) for the main value combinations, the required-value
# errors, and that the pinned image matches appVersion. Needs helm and
# kubeconform (nix develop).
set -euo pipefail

cd "$(dirname "$0")/.."
crds="https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
base=(--set mastodon.localDomain=social.example --set mastodon.existingSecret=mastodon
  --set postgresql.host=postgres --set redis.host=redis)
fail() { echo "FAIL: $*" >&2; exit 1; }

app=$(sed -n 's/^appVersion: "\(.*\)"$/\1/p' Chart.yaml)
tag=$(sed -n 's/^  tag: "\(.*\)"$/\1/p' values.yaml)
[[ -z "$tag" || "$tag" == "v$app"-* ]] || fail "image.tag $tag doesn't match appVersion $app"

helm lint --strict . "${base[@]}"

render() {
  echo "==> $*" >&2
  helm template mastodon . "${base[@]}" "$@" |
    kubeconform -strict -summary -schema-location default -schema-location "$crds"
}
render
render --set s3.enabled=true --set s3.bucket=media
render --set ingress.enabled=true --set ingress.tlsSecretName=tls
render --set httpRoute.enabled=true --set "httpRoute.parentRefs[0].name=gateway"
render --set metrics.enabled=true --set metrics.podMonitor.enabled=true
render --set networkPolicy.enabled=false --set persistence.existingClaim=media

expect_error() {
  local message="$1"; shift
  out=$(helm template mastodon . "$@" 2>&1) && fail "rendered despite: $message"
  grep -qF "$message" <<<"$out" || fail "expected '$message', got: $out"
}
expect_error "mastodon.localDomain is required"
expect_error "sidekiq.replicas must be 1" "${base[@]}" --set sidekiq.replicas=2
expect_error "httpRoute.parentRefs is required" "${base[@]}" --set httpRoute.enabled=true
expect_error "metrics.podMonitor.enabled needs metrics.enabled" "${base[@]}" --set metrics.podMonitor.enabled=true
echo "OK: chart lint passed" >&2
