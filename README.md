# mastodon-custom-charlimit

Nix flake that builds a Mastodon container image with the post character
limit raised from 500 to 5000, patched at build time — no Mastodon source
checkout, no gem/yarn build, no asset rebuild.

## How it works

Mastodon exposes the character limit from a single source of truth:
`app/validators/status_length_validator.rb`'s `MAX_CHARS` constant. That
constant is what enforces the limit server-side, and it's also what
`/api/v2/instance` reports as `configuration.statuses.max_characters` — the
value the frontend compose UI fetches at runtime and uses for the counter
and submit-button gating. So patching that one file is sufficient; the
prebuilt static JS/CSS assets don't need to change at all.

This flake:

1. Pulls the official `ghcr.io/mastodon/mastodon:v4.6.6` image (pinned by
   per-arch OCI manifest digest + Nix's fixed-output hash, for both
   `amd64` and `arm64`).
2. Fetches the real `status_length_validator.rb` from the Mastodon source
   at the same pinned tag (pinned by URL + sha256).
3. Applies `patches/status-length-validator-max-chars.patch` — a 1-line
   diff, not a full-file replacement — so a future version bump fails
   loudly (`patch` reject) instead of silently reintroducing stale
   validation logic if upstream ever changes that file's surroundings.
4. Layers the patched file on top of the pulled image via
   `dockerTools.buildLayeredImage`, carrying forward the base image's
   runtime `Entrypoint`/`User`/`WorkingDir`/`ExposedPorts` explicitly
   (`fromImage` only auto-merges `Env`; everything else in `config` would
   otherwise silently replace, not extend, the base image's config).

## Changing the character limit

Edit `maxChars` in `flake.nix` (currently `5000`) and rebuild. It's the
only value that needs to change.

## Dev shell

`.envrc` runs `use flake . --no-pure-eval`, so `direnv allow` drops you into
a shell with `skopeo`, `jq`, and `patch` on `PATH` — the tools used above
for resolving digests/hashes and for testing the patch by hand. Works on
darwin too (`devShells` is built separately from the linux-only image
`packages`).

## Building

```
nix build .#packages.aarch64-linux.default   # arm64
nix build .#packages.x86_64-linux.default    # amd64
```

Each produces a `result` symlink to a `.tar.gz` docker-loadable image.
Load and tag it:

```
docker load -i result
docker tag mastodon-custom-charlimit:v4.6.6-maxchars5000 <your-registry>/mastodon:v4.6.6-maxchars5000
docker push <your-registry>/mastodon:v4.6.6-maxchars5000
```

For a multi-arch manifest, build both, push both under arch-suffixed tags,
then `docker manifest create`/`push` (or `skopeo`) to combine them.

### amd64 hash not yet resolved

This flake was authored on an Apple Silicon Mac with no x86_64-linux
builder. The `arm64` build was fully built and verified natively; the
`x86_64-linux.sha256` in `flake.nix` is still a fake placeholder (Nix's
build-setup seccomp filter doesn't work under qemu-user emulation, so it
can't be resolved via Docker's `--platform linux/amd64` emulation either).

Resolve it on any real x86_64-linux machine, or in CI (e.g. a GitHub
Actions `ubuntu-latest` runner):

```
nix build .#packages.x86_64-linux.default
```

It will fail with `hash mismatch ... got: sha256-...` — paste that value
into `archInfo.x86_64-linux.sha256` in `flake.nix`.

## Bumping the Mastodon version

1. Update `mastodonVersion` in `flake.nix`.
2. Get the new per-arch manifest digests:
   `skopeo inspect --raw docker://ghcr.io/mastodon/mastodon:<new-tag>`
   and update `archInfo.*.imageDigest`.
3. Reset both `archInfo.*.sha256` fields and `originalValidator.sha256` to
   fake placeholders, then rebuild on each arch to TOFU-resolve the real
   hashes (see above).
4. Check `status_length_validator.rb` at the new tag still matches the
   patch's context lines — if upstream changed the file, `patch` will
   reject at build time and the diff needs a manual update.
5. Check upstream's `Dockerfile` final stage hasn't changed
   `USER`/`WorkingDir`/`ExposedPorts`/`Entrypoint` — those are hand-copied
   into `flake.nix`'s `config` since `dockerTools` doesn't inherit them
   from `fromImage` automatically.

## Verified

The `aarch64-linux` image was built and checked end-to-end: `docker
inspect` shows the same `Entrypoint`/`User`/`WorkingDir`/`ExposedPorts`/`Env`
as upstream, `status_length_validator.rb` inside the image has
`MAX_CHARS = 5000`, and `ruby -c` on that file reports valid syntax.
