#!/usr/bin/env bash
# Deploys the chart into a fresh namespace of a local OrbStack cluster with
# throwaway PostgreSQL, Redis and Garage, and checks it end to end through
# the Ingress, then again after an upgrade that switches to an HTTPRoute.
# Leaves everything running; clean up with `kubectl delete ns mastodon-test`.
#
# Needs: kubectl (OrbStack context), helm, docker, openssl, curl, jq, python3,
# and an ingress/Gateway controller (Traefik, see the chart README).
#
# usage: charts/mastodon/test/run.sh [image tag, instead of the chart's pinned image]
set -euo pipefail

cd "$(dirname "$0")"
ns=mastodon-test
release=mastodon
host=mastodon.k8s.orb.local
image=ghcr.io/e1senh0rn/mastodon
if [[ $# -gt 0 ]]; then
  ref="$image:$1"
  image_args=(--set image.tag="$1" --set image.digest=)
else
  ref="$image:$(sed -n 's/^  tag: "\(.*\)"$/\1/p' ../values.yaml)@$(sed -n 's/^  digest: "\(.*\)"$/\1/p' ../values.yaml)"
  image_args=()
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

k() { kubectl -n "$ns" "$@"; }
step() { echo "==> $*" >&2; }
fail() { echo "FAIL: $*" >&2; exit 1; }
api() { curl -fsSk -H "Authorization: Bearer $token" "$@"; }

step "fresh namespace $ns"
kubectl delete namespace "$ns" --ignore-not-found --wait
kubectl create namespace "$ns"

step "every pod template meets the restricted Pod Security Standard"
kubectl delete namespace "$ns-pss" --ignore-not-found --wait
kubectl create namespace "$ns-pss" >/dev/null
kubectl label namespace "$ns-pss" pod-security.kubernetes.io/enforce=restricted >/dev/null
pss=$(helm template "$release" .. -f values.yaml "${image_args[@]}" |
  kubectl -n "$ns-pss" apply --dry-run=server -f - 2>&1)
kubectl delete namespace "$ns-pss" --wait=false >/dev/null
grep -i 'violate' <<<"$pss" && fail "pod templates violate the restricted Pod Security Standard"
grep -q 'deployment.apps/mastodon-web created (server dry run)' <<<"$pss" || fail "dry run failed: $pss"

step "TLS certificate and dependency secrets"
openssl req -x509 -newkey rsa:2048 -nodes -days 7 \
  -subj "/CN=*.k8s.orb.local" -addext "subjectAltName=DNS:*.k8s.orb.local" \
  -keyout "$work/tls.key" -out "$work/tls.crt" 2>/dev/null
k create secret tls test-tls --cert "$work/tls.crt" --key "$work/tls.key"
pg_pass=$(openssl rand -hex 24)
redis_pass=$(openssl rand -hex 24)
k create secret generic test-deps \
  --from-literal=postgres-password="$pg_pass" \
  --from-literal=redis-password="$redis_pass" \
  --from-literal=garage-rpc-secret="$(openssl rand -hex 32)"

step "PostgreSQL, Redis, Garage"
k apply -f deps.yaml >/dev/null
k rollout status deploy/postgres deploy/redis deploy/garage --timeout 5m

step "Garage bucket and key"
garage() { k exec deploy/garage -- /garage "$@"; }
node=$(garage node id -q | cut -d@ -f1)
garage layout assign -z dc1 -c 1G "$node" >/dev/null
garage layout apply --version 1 >/dev/null
garage bucket create media >/dev/null
garage key create mastodon >"$work/key"
key_id=$(awk '/Key ID:/ {print $3}' "$work/key")
key_secret=$(awk '/Secret key:/ {print $3}' "$work/key")
[[ -n "$key_id" && -n "$key_secret" ]] || fail "could not parse garage key output: $(cat "$work/key")"
garage bucket allow --read --write --owner media --key mastodon >/dev/null
garage bucket website --allow media >/dev/null

step "Mastodon secret (generated with the image, as in the chart README)"
docker pull -q "$ref" >/dev/null
run() { docker run --rm -e SECRET_KEY_BASE=unused "$ref" bundle exec rails "$@"; }
{
  echo "SECRET_KEY_BASE=$(run secret | tail -n 1)"
  run mastodon:webpush:generate_vapid_key | grep '^VAPID_'
  run db:encryption:init | grep '^ACTIVE_RECORD_ENCRYPTION_'
  echo "DB_PASS=$pg_pass"
  echo "REDIS_PASSWORD=$redis_pass"
  echo "AWS_ACCESS_KEY_ID=$key_id"
  echo "AWS_SECRET_ACCESS_KEY=$key_secret"
} >"$work/mastodon.env"
k create secret generic mastodon --from-env-file="$work/mastodon.env"

step "helm install (Ingress)"
helm upgrade --install "$release" .. -n "$ns" -f values.yaml \
  "${image_args[@]}" --wait --timeout 10m

# Not tootctl accounts create: it requires the email domain to have MX records.
step "owner account and API token"
token=$(k exec deploy/mastodon-web -- bundle exec rails runner '
  user = User.new(email: "alice@example.com", password: SecureRandom.hex(16), agreement: true,
                  approved: true, confirmed_at: Time.now.utc, role: UserRole.find_by!(name: "Owner"),
                  account: Account.new(username: "alice"))
  user.save!(validate: false)
  user.update_columns(approved: true) # a create callback resets it from the registration mode
  app = Doorkeeper::Application.create!(name: "chart-test", redirect_uri: "urn:ietf:wg:oauth:2.0:oob", scopes: "read write")
  puts Doorkeeper::AccessToken.create!(application: app, resource_owner_id: user.id, scopes: "read write").token
' | tail -n 1)

check_routing() {
  step "[$1] web, streaming and the character limit through the route"
  [[ "$(curl -fsSk "https://$host/health")" == OK ]] || fail "web /health"
  [[ "$(curl -fsSk "https://$host/api/v1/streaming/health")" == OK ]] || fail "streaming health"
  max=$(curl -fsSk "https://$host/api/v2/instance" | jq .configuration.statuses.max_characters)
  [[ "$max" == 5000 ]] || fail "max_characters = $max"
  # Server-sent events: the connection stays open, so time out after 3s.
  code=$(curl -sk -N --max-time 3 -o /dev/null -w '%{http_code}' \
    "https://$host/api/v1/streaming/public?access_token=$token" || true)
  [[ "$code" == 200 ]] || fail "streaming event stream returned $code"
}

check_routing ingress

step "media upload to S3 (Garage), served from the media host"
python3 - "$work/test.png" <<'EOF'
import struct, sys, zlib
w = h = 64
raw = b"".join(b"\0" + b"".join(bytes((x * 4, y * 4, 128)) for x in range(w)) for y in range(h))
chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                              + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
EOF
media=$(api -F "file=@$work/test.png" "https://$host/api/v2/media")
media_id=$(jq -r .id <<<"$media")
for _ in $(seq 30); do
  url=$(api "https://$host/api/v1/media/$media_id" | jq -r '.url // empty')
  [[ -n "$url" ]] && break
  sleep 2
done
[[ "$url" == https://media.k8s.orb.local/* ]] || fail "media url '$url'"
curl -fsSk "$url" -o "$work/fetched"
[[ "$(head -c 4 "$work/fetched" | od -An -c | tr -d ' ')" == *PNG* ]] || fail "fetched media isn't a PNG"

step "statuses: 5000 characters allowed, 5001 rejected"
long=$(printf 'a%.0s' $(seq 5000))
api -o /dev/null --data-urlencode "status=$long" -d "media_ids[]=$media_id" "https://$host/api/v1/statuses" ||
  fail "5000-character status rejected"
code=$(curl -sk -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" \
  --data-urlencode "status=${long}b" "https://$host/api/v1/statuses")
[[ "$code" == 422 ]] || fail "5001-character status returned $code, expected 422"

step "sidekiq processes jobs"
processed=0
for _ in $(seq 30); do
  processed=$(k exec deploy/mastodon-sidekiq -- bundle exec rails runner 'puts Sidekiq::Stats.new.processed' | tail -n 1)
  [[ "$processed" -gt 0 ]] && break
  sleep 2
done
[[ "$processed" -gt 0 ]] || fail "sidekiq processed no jobs"

step "Prometheus metrics: web (sidecar, incl. Puma workers), sidekiq, streaming"
pod_ip() { k get pod -l "app.kubernetes.io/component=$1" -o jsonpath='{.items[0].status.podIP}'; }
# Sidekiq reports its process stats periodically, so retry for a while.
for attempt in $(seq 6); do
  metrics=$(k run "metrics-probe-$attempt" --rm -i --quiet --restart=Never --image=curlimages/curl:8.17.0 --command -- sh -c "
    curl -fsS http://$(pod_ip web):9394/metrics | grep -c '^ruby_rss{type=\"puma\"'
    curl -fsS http://$(pod_ip sidekiq):9394/metrics | grep -cE '^(ruby_)?sidekiq_process_concurrency'
    curl -fsS http://$(pod_ip streaming):4000/metrics | grep -c '^connected_channels'
  " 2>/dev/null | tr '\n' ' ')
  # Only the first three numbers: kubectl may print the output twice.
  read -r web_rss sidekiq_conc streaming_chan _ <<<"$metrics"
  [[ "${web_rss:-0}" -ge 1 && "${sidekiq_conc:-0}" -ge 1 && "${streaming_chan:-0}" -ge 1 ]] && break
  [[ $attempt == 6 ]] &&
    fail "metrics missing (web puma rss: ${web_rss:-none}, sidekiq: ${sidekiq_conc:-none}, streaming: ${streaming_chan:-none})"
  sleep 10
done

step "helm upgrade: Ingress off, HTTPRoute on"
helm upgrade "$release" .. -n "$ns" -f values.yaml "${image_args[@]}" \
  --set ingress.enabled=false --set httpRoute.enabled=true --wait --timeout 10m
k get ingress "$release" >/dev/null 2>&1 && fail "Ingress still exists"
for _ in $(seq 15); do
  [[ "$(k get httproute "$release" -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}')" == True ]] && break
  sleep 2
done
check_routing httproute

echo "OK: chart works on $host (Ingress and HTTPRoute); clean up with: kubectl delete ns $ns" >&2
