#!/usr/bin/env bash
# Boots an image against throwaway Postgres/Redis and checks web, streaming,
# sidekiq, the character limit, static files, uploads and media tooling.
# Needs only docker.
#
# usage: scripts/smoke-test.sh <image> [expected max_characters]
set -euo pipefail

image="${1:?usage: $0 <image> [expected max_characters]}"
expected_max_chars="${2:-5000}"

net="mastodon-smoke-$$"
db="$net-db"
redis="$net-redis"
web="$net-web"
streaming="$net-streaming"
sidekiq="$net-sidekiq"

cleanup() {
  status=$?
  if [[ $status -ne 0 ]]; then
    for c in "$web" "$streaming" "$sidekiq"; do
      echo "--- logs: $c" >&2
      docker logs --tail 50 "$c" >&2 2>&1 || true
    done
  fi
  docker rm -f "$db" "$redis" "$web" "$streaming" "$sidekiq" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  exit $status
}
trap cleanup EXIT

rand() { head -c 48 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

env_args=(
  -e LOCAL_DOMAIN=mastodon.test
  -e DB_HOST="$db" -e DB_USER=mastodon -e DB_PASS=mastodon -e DB_NAME=mastodon
  -e REDIS_HOST="$redis"
  -e SECRET_KEY_BASE="$(rand)$(rand)"
  -e OTP_SECRET="$(rand)$(rand)"
  -e ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY="$(rand)"
  -e ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT="$(rand)"
  -e ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY="$(rand)"
  # Throwaway database; lets db:setup load the schema under RAILS_ENV=production.
  -e DISABLE_DATABASE_ENVIRONMENT_CHECK=1
)

run() { docker run --rm --network "$net" "${env_args[@]}" "$image" "$@"; }
curl_in_net() { docker run --rm --network "$net" curlimages/curl:latest -sS --max-time 10 "$@"; }

wait_for() {
  local what="$1"
  shift
  for _ in $(seq 1 60); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  echo "FAIL: timed out waiting for $what" >&2
  return 1
}

step() { echo "==> $*" >&2; }

docker network create "$net" >/dev/null
docker run -d --name "$db" --network "$net" \
  -e POSTGRES_USER=mastodon -e POSTGRES_PASSWORD=mastodon -e POSTGRES_DB=mastodon \
  postgres:17-alpine >/dev/null
docker run -d --name "$redis" --network "$net" redis:7-alpine >/dev/null
wait_for postgres docker exec "$db" pg_isready -U mastodon

step "toolchain"
ruby_version=$(run ruby -v)
echo "$ruby_version" >&2
[[ "$ruby_version" == "ruby 4."* ]] || { echo "FAIL: expected Ruby 4.x" >&2; exit 1; }
run node --version >&2
run ffmpeg -hide_banner -version | sed -n 1p >&2

step "db:setup"
run bin/rails db:setup >/dev/null

step "rails boots, libvips loads"
run bin/tootctl version >&2
run bin/rails runner 'require "vips"; puts "libvips #{Vips::LIBRARY_VERSION}"' >&2

step "media: the conversions Mastodon runs"
run ffmpeg -hide_banner -loglevel error \
  -f lavfi -i testsrc=duration=1:size=320x240 -f lavfi -i sine=duration=1 \
  -c:v h264 -preset veryfast -pix_fmt yuv420p -c:a aac -b:a 192k -movflags faststart \
  -f mp4 /tmp/out.mp4
run ffmpeg -hide_banner -loglevel error -f lavfi -i sine=duration=1 -f mp3 -q:a 2 /tmp/out.mp3
run ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc=duration=1 -frames:v 1 -f image2 -c:v png /tmp/out.png
loaders=$(run bin/rails runner '
  require "vips"
  %w(jpegload pngload gifload webpload heifload jpegsave pngsave webpsave).each do |op|
    puts "#{op}=#{Vips.type_find("VipsOperation", op) != 0}"
  end')
echo "$loaders" | tr '\n' ' ' >&2
echo >&2
if grep -q '=false' <<<"$loaders"; then
  echo "FAIL: libvips is missing an operation Mastodon needs" >&2
  exit 1
fi

step "web (default command)"
docker run -d --name "$web" --network "$net" "${env_args[@]}" "$image" >/dev/null
wait_for "web /health" curl_in_net -f "http://$web:3000/health"

# As if through the TLS-terminating proxy for LOCAL_DOMAIN.
web_get() { curl_in_net -f -H 'Host: mastodon.test' -H 'X-Forwarded-Proto: https' "$@"; }

pid1=$(docker exec "$web" ruby -e 'print File.read("/proc/1/comm").strip')
if [[ "$pid1" != tini ]]; then
  echo "FAIL: PID 1 is '$pid1', expected tini" >&2
  exit 1
fi

max_chars=$(web_get "http://$web:3000/api/v2/instance" |
  sed -n 's/.*"max_characters":\([0-9]*\).*/\1/p' | head -1)
if [[ "$max_chars" != "$expected_max_chars" ]]; then
  echo "FAIL: /api/v2/instance reports max_characters=$max_chars, expected $expected_max_chars" >&2
  exit 1
fi
echo "max_characters = $max_chars" >&2

step "web serves static files (RAILS_SERVE_STATIC_FILES)"
web_get -o /dev/null "http://$web:3000/sw.js"
asset=$(web_get "http://$web:3000/about" | grep -oE '/packs/[^"]+\.js' | head -1 || true)
if [[ -z "$asset" ]]; then
  echo "FAIL: no /packs/*.js asset referenced from /about" >&2
  exit 1
fi
web_get -o /dev/null "http://$web:3000$asset"
echo "served /sw.js and $asset" >&2

step "web serves local uploads (public/system symlink)"
docker exec "$web" ruby -rfileutils -e '
  dir = File.join(ENV.fetch("PAPERCLIP_ROOT_PATH"), "smoke")
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "hello.txt"), "hello from uploads")'
upload=$(web_get -D - "http://$web:3000/system/smoke/hello.txt")
if ! grep -q 'hello from uploads' <<<"$upload"; then
  echo "FAIL: upload in PAPERCLIP_ROOT_PATH not served under /system" >&2
  exit 1
fi
if ! grep -qi "^content-security-policy: default-src 'none'" <<<"$upload"; then
  echo "FAIL: upload served without the restrictive CSP header" >&2
  exit 1
fi
echo "served /system/smoke/hello.txt with upload headers" >&2

step "streaming (node ./streaming)"
docker run -d --name "$streaming" --network "$net" "${env_args[@]}" "$image" node ./streaming >/dev/null
wait_for "streaming health" curl_in_net -f "http://$streaming:4000/api/v1/streaming/health"

step "sidekiq (bundle exec sidekiq)"
docker run -d --name "$sidekiq" --network "$net" "${env_args[@]}" "$image" bundle exec sidekiq >/dev/null
wait_for "sidekiq boot" sh -c "docker logs '$sidekiq' 2>&1 | grep -q 'Booted Rails'"
sleep 5
if [[ "$(docker inspect -f '{{.State.Running}}' "$sidekiq")" != true ]]; then
  echo "FAIL: sidekiq exited" >&2
  exit 1
fi

echo "OK: all smoke checks passed for $image" >&2
