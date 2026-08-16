{
  description = "Mastodon container image with a build-time patched max post character limit (github.com/mastodon/mastodon/issues/12265)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self, nixpkgs, flake-utils }:
    let
      # Image builds are linux-only (dockerTools needs a linux pkgs set).
      images = flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        mastodonVersion = "v4.6.6";

        # The one knob this flake exists to expose. Backed by a single source
        # of truth in Mastodon itself (app/validators/status_length_validator.rb:
        # MAX_CHARS), which is also what /api/v2/instance reports as
        # configuration.statuses.max_characters - the frontend compose UI reads
        # that at runtime over the API, so no asset/JS rebuild is required for
        # this to take effect.
        maxChars = 5000;

        # Per-arch OCI manifest digests for ghcr.io/mastodon/mastodon:${mastodonVersion},
        # resolved via: skopeo inspect --raw docker://ghcr.io/mastodon/mastodon:${mastodonVersion}
        # sha256 below is nix's fixed-output hash of the pulled image contents,
        # resolved via `nix build` (TOFU: build once, nix reports the correct
        # hash on mismatch, paste it in).
        archInfo = {
          x86_64-linux = {
            arch = "amd64";
            imageDigest = "sha256:14ab012144b7962ee223f0958bf136530c3917bde2f1c7ccb50267b8408728b6";
            # UNRESOLVED (fake hash placeholder): this machine has no x86_64-linux
            # builder (native or via qemu - Nix's build-setup seccomp filter isn't
            # supported under qemu-user emulation). Resolve on any real/native
            # x86_64-linux machine (or CI, e.g. a GitHub Actions ubuntu-latest
            # runner) with:
            #   nix build .#packages.x86_64-linux.default
            # it will fail with "hash mismatch ... got: sha256-...", paste that
            # value in below.
            sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
          };
          aarch64-linux = {
            arch = "arm64";
            imageDigest = "sha256:15706533ec560d33b41b70679d92e4bf56e455e2c33a2b9170a92dd8cb7ab673";
            sha256 = "sha256-ce3UBf9W0NmW7y+mKp9kfx9LSMmYqj4F7HG9z3kTUXA=";
          };
        };

        thisArch = archInfo.${system};

        baseImage = pkgs.dockerTools.pullImage {
          imageName = "ghcr.io/mastodon/mastodon";
          finalImageTag = mastodonVersion;
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
          url = "https://raw.githubusercontent.com/mastodon/mastodon/${mastodonVersion}/app/validators/status_length_validator.rb";
          sha256 = "sha256-/TZWZkGnW1a/M6njOmwo714I9O4qYtobBoySTUpu8L8=";
        };

        patchedValidator =
          pkgs.runCommand "status_length_validator.rb"
            {
              nativeBuildInputs = [ pkgs.gnupatch ];
            }
            ''
              cp ${originalValidator} status_length_validator.rb
              patch status_length_validator.rb < ${./patches/status-length-validator-max-chars.patch}
              substituteInPlace status_length_validator.rb --replace-fail '@MAX_CHARS@' '${toString maxChars}'
              cp status_length_validator.rb "$out"
            '';

        patchedLayer = pkgs.runCommand "mastodon-status-length-validator-layer" { } ''
          mkdir -p "$out/opt/mastodon/app/validators"
          cp ${patchedValidator} "$out/opt/mastodon/app/validators/status_length_validator.rb"
        '';
      in
      {
        packages.default = pkgs.dockerTools.buildLayeredImage {
          name = "mastodon-custom-charlimit";
          tag = "${mastodonVersion}-maxchars${toString maxChars}";
          fromImage = baseImage;
          contents = [ patchedLayer ];

          # dockerTools only auto-merges `Env` from `fromImage`; every other
          # Config field below is otherwise silently dropped, so it's copied
          # here verbatim from upstream's Dockerfile final stage.
          config = {
            Entrypoint = [
              "/usr/bin/tini"
              "--"
            ];
            User = "mastodon";
            WorkingDir = "/opt/mastodon";
            ExposedPorts = {
              "3000/tcp" = { };
            };
          };
        };
      }
      );

      # devShell is separate and covers darwin too, so `direnv`/`nix develop`
      # works on the machine you're authoring the flake from, not just on
      # the linux systems the image itself builds for.
      shells = flake-utils.lib.eachDefaultSystem (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              skopeo
              jq
              gnupatch
            ];
          };
        }
      );
    in
    nixpkgs.lib.recursiveUpdate images shells;
}
