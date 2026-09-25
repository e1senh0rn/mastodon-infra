# mastodon-custom-charlimit

Nix flake that builds a Mastodon container image with the post character
limit raised from 500 to 5000, patched at build time — no Mastodon source
checkout, no gem/yarn build, no asset rebuild.

## How it works

Mastodon exposes the character limit from a single source of truth:
`app/validators/status_length_validator.rb`'s `MAX_CHARS` constant. That
constant is what enforces the limit server-side, and it's also what
`/api/v2/instance` (and `/api/v1/instance`) report as
`configuration.statuses.max_characters` — the value the frontend compose UI
fetches at runtime and uses for the counter and submit-button gating. So
patching that one file is sufficient; the prebuilt static JS/CSS assets
don't need to change at all.

This flake:

1. Pulls the official `ghcr.io/mastodon/mastodon:<version>` image (pinned by
   per-arch OCI manifest digest + Nix's fixed-output hash, for both
   `amd64` and `arm64`).
2. Fetches the real `status_length_validator.rb` from the Mastodon source
   at the same pinned tag (pinned by URL + sha256).
3. Applies `patches/status-length-validator-max-chars.patch` — a 1-line
   diff, not a full-file replacement, applied at `--fuzz=0` — so a future
   version bump fails loudly (`patch` reject) instead of silently
   reintroducing stale validation logic if upstream ever changes that
   file's surroundings. The build then asserts the end state
   (`MAX_CHARS = 5000`) rather than trusting the steps composed.
4. Layers the patched file on top of the pulled image via
   `dockerTools.buildLayeredImage`, carrying forward the base image's
   entire runtime config (`config = pins.baseConfig`, captured
   mechanically — see below) since `fromImage` only auto-merges `Env` and
   would otherwise silently drop everything else.

All version-specific pins (Mastodon tag, per-arch image digests, per-arch
Nix fixed-output hashes, the source file's hash, the base image's runtime
config) live in `versions.json`, not inline in `flake.nix` — `nix run
.#update` (see below) regenerates it with `jq -n`, a real structured-data
tool, rather than pattern-matching or splicing Nix source text.

### Two dockerTools sharp edges this works around

**`contents` would place a symlink, not a file.** `buildLayeredImage`'s
`contents` routes through `symlinkJoin`, so the patched file would land in
the image as a symlink into `/nix/store`, dragging the store path in as an
extra layer. This flake uses `extraCommands` instead, which runs in the
layer root and writes a real file.

**Directory metadata in an upper layer overrides the base image's.** Every
directory the new layer contains is emitted as a tar entry, and those
entries restamp ownership and mode over whatever the base image had.
`/opt`, `/opt/mastodon/app` and `/opt/mastodon/app/validators` are all
`root:root 0755` upstream and come out that way already, but
`/opt/mastodon` is the mastodon user's home — `991:991 0700` — and would
otherwise be silently reset to `root:root 0755`, taking write access to it
away from the app and making it world-readable. `fakeRootCommands` restores
it. Note that neither this nor the symlink issue is visible to `docker
inspect` or to reading the patched file back out of the image.

## Changing the character limit

Edit `maxChars` in `flake.nix` (currently `5000`) and rebuild. It's the
only value that needs to change.

Two caveats worth knowing, neither of which this flake can do anything
about:

- Remote servers won't reject your longer posts — `StatusLengthValidator`
  early-returns on non-local statuses, so they federate and display in
  full.
- Third-party clients that hardcode 500 rather than reading
  `max_characters` from the instance API will still cap you at 500 in their
  own UI.

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

Mastodon's image is over a gigabyte, and `buildLayeredImage` materialises
the whole tarball in the nix store before you load it. To skip that, stream
it straight into Docker instead:

```
nix run .#stream | docker load
```

`nix flake check` builds the patched validator and runs `ruby -c` on it —
the one property the build-time `grep` assertion can't cover. (It needs to
build for a linux system, so it wants a linux builder if you're on darwin.)

## Bumping the Mastodon version

```
nix run .#update                # latest stable release
nix run .#update -- v4.7.0      # a specific tag
```

Run from the repo root. The logic lives in `scripts/update-versions.sh`;
the `apps.update` entry in `flake.nix` just puts its runtime dependencies
(`nix`, `curl`, `jq`, `skopeo`) on `PATH` and points it at the flake's own
pinned nixpkgs. It regenerates `versions.json` in place:

1. Resolves the target tag (queries GitHub's "latest release" API if none
   given).
2. `skopeo inspect`s the image manifest to get the amd64 and arm64 OCI
   digests.
3. Resolves both per-arch Nix fixed-output hashes by attempting
   `dockerTools.pullImage` with a fake hash and parsing the real one out of
   the mismatch error (standard Nix TOFU). This runs entirely on whatever
   machine invokes it — `pullImage` turns out to be just `skopeo copy`
   under the hood, not something that needs a matching/linux builder, so
   this works fine from a Mac.
4. Captures the base image's runtime config with `skopeo inspect --config`,
   so the `Entrypoint`/`User`/`WorkingDir`/`ExposedPorts`/`Shell` that
   `dockerTools` refuses to inherit from `fromImage` are never hand-copied
   out of upstream's `Dockerfile`, and a future `Cmd`/`Labels`/`Healthcheck`
   comes along for free. The two arches' configs have historically been
   identical, so one shared `baseConfig` is stored; if they ever diverge the
   script fails rather than applying one arch's config to both images.
5. Resolves `status_length_validator.rb`'s hash at the new tag via
   `nix store prefetch-file` and writes the whole new `versions.json` with
   `jq -n`.

`versions.json` is only ever replaced by an atomic rename of a fully
written temp file, so a failed run (bad tag, network error, GitHub rate
limit) leaves the working tree untouched.

It does *not* check that `patches/status-length-validator-max-chars.patch`
still applies to the new tag — `nix build` does that for real the next
time it's run, and fails loudly (a patch reject) if upstream changed the
file enough that it no longer does, rather than silently building on stale
validation logic. If that happens, the patch needs a manual update.

Once you're happy with the `versions.json` diff (and the patch still
applies), run `nix build .#packages.<system>.default` yourself.

## Verified

Enforced on every build, so it can't regress:

- The patch applies with no fuzz, and the result contains
  `MAX_CHARS = 5000` (asserted in the builder).
- `nix flake check` runs `ruby -c` on the patched file.

Checked by hand against `v4.6.6` (against the pulled image itself, not just
upstream's source tree):

- `validatorSha256` hashes byte-for-byte identical to
  `/opt/mastodon/app/validators/status_length_validator.rb` inside the
  published image — the raw.githubusercontent pin fetches exactly the file
  being replaced.
- `MAX_CHARS` really is the only source of truth: it is a bare literal in
  the validator, and both `app/serializers/rest/instance_serializer.rb` and
  `rest/v1/instance_serializer.rb` derive `max_characters` from it. Nothing
  else in the image defines it, and there is no env-var override.
- The base image's runtime config is byte-identical across `amd64` and
  `arm64`, which is what lets `versions.json` store a single `baseConfig`.
- `/opt/mastodon` is `991:991 0700` in the base image (every layer that
  touches it), which is what `fakeRootCommands` restores.
- Both per-arch fixed-output hashes reproduce against the already-pinned
  `v4.6.6`, and the `jq -n` generation step reproduces `versions.json`
  byte-for-byte offline from the same known-good values.
