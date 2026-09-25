{
  description = "Mastodon container image with a build-time patched max post character limit (github.com/mastodon/mastodon/issues/12265)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self, nixpkgs, flake-utils }:
    let
      # Everything version-specific and hash-pinned lives in versions.json,
      # not inline here, so `nix run .#update` (scripts/update-versions.sh) can
      # regenerate it with `jq -n` - a real structured-data tool, rather
      # than pattern-matching/splicing Nix source text.
      pins = builtins.fromJSON (builtins.readFile ./versions.json);

      # The one knob this flake exists to expose. Backed by a single source
      # of truth in Mastodon itself (app/validators/status_length_validator.rb:
      # MAX_CHARS), which is also what /api/v2/instance reports as
      # configuration.statuses.max_characters - the frontend compose UI reads
      # that at runtime over the API, so no asset/JS rebuild is required for
      # this to take effect.
      maxChars = 5000;

      # Upstream's Dockerfile defaults (ARG UID=991 / GID=991). Only needed
      # to restore /opt/mastodon's metadata - see fakeRootCommands below.
      mastodonUid = 991;
      mastodonGid = 991;

      # Not flake-utils' eachDefaultSystem, which includes x86_64-darwin:
      # nixpkgs 26.11 has dropped it, so merely evaluating that system is a
      # hard error (and `nix flake check --all-systems` trips over it).
      toolingSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Image builds are linux-only (dockerTools needs a linux pkgs set).
      images = flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (
        system:
        let
          pkgs = import nixpkgs { inherit system; };

          thisArch = pins.archs.${system};

          baseImage = pkgs.dockerTools.pullImage {
            imageName = "ghcr.io/mastodon/mastodon";
            finalImageTag = pins.mastodonVersion;
            os = "linux";
            arch = thisArch.arch;
            imageDigest = thisArch.imageDigest;
            sha256 = thisArch.sha256;
          };

          # Fetch the exact upstream source file at the pinned tag and apply a
          # small diff to it, rather than vendoring a full replacement copy, so
          # a future version bump fails loudly (patch reject) instead of
          # silently reintroducing stale validation logic.
          originalValidator = pkgs.fetchurl {
            url = "https://raw.githubusercontent.com/mastodon/mastodon/${pins.mastodonVersion}/app/validators/status_length_validator.rb";
            sha256 = pins.validatorSha256;
          };

          patchedValidator =
            pkgs.runCommand "status_length_validator.rb"
              {
                nativeBuildInputs = [ pkgs.gnupatch ];
              }
              ''
                cp ${originalValidator} status_length_validator.rb

                # -F0: `patch` defaults to fuzz factor 2, which lets a hunk
                # apply against only partially-matching context - exactly the
                # silent success this patch-instead-of-vendor approach exists
                # to avoid.
                patch -F0 --no-backup-if-mismatch status_length_validator.rb \
                  < ${./patches/status-length-validator-max-chars.patch}

                substituteInPlace status_length_validator.rb --replace-fail '@MAX_CHARS@' '${toString maxChars}'

                # Assert the end state rather than trusting that the two steps
                # above composed as intended.
                grep -q '^  MAX_CHARS = ${toString maxChars}$' status_length_validator.rb

                cp status_length_validator.rb "$out"
              '';

          imageArgs = {
            name = "mastodon-custom-charlimit";
            tag = "${pins.mastodonVersion}-maxchars${toString maxChars}";
            fromImage = baseImage;

            # Deliberately not `contents`: that routes through symlinkJoin, so
            # the file would land in the image as a symlink into /nix/store
            # (dragging the store path in as an extra layer). extraCommands
            # runs in the layer root and writes a real file instead.
            extraCommands = ''
              mkdir -p opt/mastodon/app/validators
              install -m 0644 ${patchedValidator} \
                opt/mastodon/app/validators/status_length_validator.rb
            '';

            # Every directory this layer contains is emitted as a tar entry,
            # and an upper layer's directory metadata overrides the base
            # image's. /opt, /opt/mastodon/app and /opt/mastodon/app/validators
            # are all root:root 0755 upstream and come out that way already;
            # /opt/mastodon is the mastodon user's home (991:991 0700) and
            # would otherwise be silently reset to root:root 0755, taking write
            # access to it away from the app and making it world-readable.
            fakeRootCommands = ''
              chown ${toString mastodonUid}:${toString mastodonGid} opt/mastodon
              chmod 0700 opt/mastodon
            '';

            # dockerTools only auto-merges `Env` from `fromImage`; every other
            # Config field is otherwise silently dropped, so the base image's
            # whole runtime config is carried through here. It's captured
            # mechanically by `nix run .#update` (skopeo inspect --config)
            # rather than hand-copied from upstream's Dockerfile, so a future
            # Cmd/Labels/Healthcheck upstream comes along for free.
            config = pins.baseConfig;
          };
        in
        {
          packages.default = pkgs.dockerTools.buildLayeredImage imageArgs;

          # Same image, streamed straight to `docker load` instead of
          # materialising a multi-GB tarball in the nix store first:
          #   nix run .#stream | docker load
          apps.stream = {
            type = "app";
            program = "${pkgs.dockerTools.streamLayeredImage imageArgs}";
          };

          # The one property the build-time grep can't check: that the result
          # is still valid Ruby. Kept out of the image build path so it costs
          # nothing there.
          checks.validator-syntax =
            pkgs.runCommand "check-status-length-validator-syntax"
              {
                nativeBuildInputs = [ pkgs.ruby ];
              }
              ''
                ruby -c ${patchedValidator}
                touch "$out"
              '';
        }
      );

      # devShell and the update app are separate from `images` and cover
      # darwin too, so `direnv`/`nix develop`/`nix run .#update` all work on
      # the machine you're authoring the flake from - dockerTools.pullImage
      # turns out to be just `skopeo copy` under the hood and doesn't
      # actually need a linux builder, only buildLayeredImage does.
      tooling = flake-utils.lib.eachSystem toolingSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };

          # The actual logic lives in scripts/update-versions.sh, a plain,
          # separately-editable/shellcheckable bash script. This just puts
          # its runtime dependencies on PATH and hands it the flake's own
          # pinned nixpkgs store path (needed to resolve fixed-output
          # hashes against the exact nixpkgs this flake builds with).
          updateScript = pkgs.writeShellApplication {
            name = "update-mastodon-versions";
            runtimeInputs = with pkgs; [
              nix
              curl
              jq
              skopeo
              coreutils
            ];
            text = ''
              export NIXPKGS_PATH="${nixpkgs}"
            ''
            + builtins.readFile ./scripts/update-versions.sh;
          };
        in
        {
          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              skopeo
              jq
              gnupatch
            ];
          };

          apps.update = flake-utils.lib.mkApp {
            drv = updateScript;
            name = "update-mastodon-versions";
          };
        }
      );
    in
    nixpkgs.lib.recursiveUpdate images tooling;
}
