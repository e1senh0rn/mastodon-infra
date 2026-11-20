{
  description = "Mastodon container image built from source with Nix, with a build-time patched max post character limit (github.com/mastodon/mastodon/issues/12265)";

  inputs = {
    # Toolchain and every runtime library.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nix2container = {
      url = "github:nlewo/nix2container";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      nix2container,
    }:
    let
      # StatusLengthValidator::MAX_CHARS; the web UI reads it from the API.
      maxChars = 5000;

      imageName = "mastodon";

      # Local media uploads. public/system links here, so Mastodon serves them;
      # mount a volume at this path rather than changing PAPERCLIP_ROOT_PATH.
      uploadsDir = "/tmp/mastodon/public-system";

      sourceUrl = "https://github.com/e1senh0rn/mastodon-infra";

      imageSystems = {
        x86_64-linux = "amd64";
        aarch64-linux = "arm64";
      };

      # Not eachDefaultSystem: nixpkgs no longer evaluates on x86_64-darwin.
      toolingSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Checked against upstream's requirements by checks.toolchain.
      toolchain = pkgs: {
        ruby = pkgs.ruby_4_0;
        nodejs = pkgs.nodejs-slim_26;
        yarn-berry = pkgs.yarn-berry_4;
      };

      images = flake-utils.lib.eachSystem (builtins.attrNames imageSystems) (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          inherit (toolchain pkgs) ruby nodejs yarn-berry;

          mastodon = import ./nix/mastodon.nix {
            inherit
              pkgs
              maxChars
              uploadsDir
              ruby
              nodejs
              yarn-berry
              ;
          };

          image = import ./nix/image.nix {
            inherit pkgs mastodon nodejs;
            ffmpeg = pkgs.ffmpeg-headless;
            inherit (nix2container.packages.${system}) nix2container;
            inherit sourceUrl uploadsDir;
            name = imageName;
          };
        in
        {
          packages = {
            inherit mastodon image;
            default = image;
          };

          checks = {
            patched-syntax = pkgs.runCommand "check-patched-ruby-syntax" { } ''
              ${ruby}/bin/ruby -c ${mastodon.src}/app/validators/status_length_validator.rb
              touch "$out"
            '';

            toolchain = pkgs.runCommand "check-mastodon-toolchain" { nativeBuildInputs = [ pkgs.jq ]; } ''
              want_ruby=$(cut -d. -f1,2 ${mastodon.src}/.ruby-version)
              have_ruby=$(echo ${ruby.version} | cut -d. -f1,2)
              if [ "$want_ruby" != "$have_ruby" ]; then
                echo "Mastodon wants Ruby $want_ruby, flake builds with $have_ruby (see toolchain in flake.nix)" >&2
                exit 1
              fi

              have_node=$(echo ${nodejs.version} | cut -d. -f1)
              for pkg in package.json streaming/package.json; do
                engines=$(jq -r '.engines.node // ""' ${mastodon.src}/$pkg)
                case "$engines" in
                  ">="[0-9]*) min_node=''${engines#>=}; min_node=''${min_node%%[!0-9]*} ;;
                  *) echo "$pkg: unrecognised engines.node '$engines', update checks.toolchain" >&2; exit 1 ;;
                esac
                if [ "$have_node" -lt "$min_node" ]; then
                  echo "$pkg requires Node $engines, flake builds with $have_node (see toolchain in flake.nix)" >&2
                  exit 1
                fi
              done

              want_yarn=$(jq -r '.packageManager // ""' ${mastodon.src}/package.json)
              want_yarn=''${want_yarn#yarn@}
              want_yarn=''${want_yarn%%+*}
              have_yarn=${yarn-berry.version}
              if [ -z "$want_yarn" ] || [ "$(printf '%s\n%s\n' "$want_yarn" "$have_yarn" | sort -V | head -n 1)" != "$want_yarn" ]; then
                echo "Mastodon pins Yarn '$want_yarn', flake builds with $have_yarn (override yarn-berry in flake.nix's toolchain)" >&2
                exit 1
              fi
              touch "$out"
            '';
          };
        }
      );

      tooling = flake-utils.lib.eachSystem toolingSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };

          # Host-side skopeo, so load/push work from a Mac too (nix2container's
          # own copyTo* scripts are built for Linux).
          skopeo = nix2container.packages.${system}.skopeo-nix2container;

          copyApps = nixpkgs.lib.concatMapAttrs (imageSystem: arch: {
            "push-${arch}" = flake-utils.lib.mkApp {
              drv = pkgs.writeShellApplication {
                name = "push-${arch}";
                runtimeInputs = [ skopeo ];
                text = ''
                  if [[ $# -lt 1 ]]; then
                    echo "usage: nix run .#push-${arch} -- <registry/repo:tag> [extra skopeo copy flags]" >&2
                    exit 1
                  fi
                  ref="$1"
                  shift
                  skopeo --insecure-policy copy "$@" \
                    nix:${self.packages.${imageSystem}.image} "docker://$ref"
                '';
              };
            };

            "load-${arch}" = flake-utils.lib.mkApp {
              drv = pkgs.writeShellApplication {
                name = "load-${arch}";
                runtimeInputs = [ skopeo ];
                text = ''
                  ref="''${1:-${imageName}:${self.packages.${imageSystem}.mastodon.version}-${arch}}"
                  # Follow the active docker context unless DOCKER_HOST is set.
                  host="''${DOCKER_HOST:-}"
                  if [[ -z "$host" ]] && command -v docker >/dev/null; then
                    host=$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)
                  fi
                  skopeo --insecure-policy copy ''${host:+--dest-daemon-host "$host"} \
                    nix:${self.packages.${imageSystem}.image} "docker-daemon:$ref"
                  echo "Loaded $ref" >&2
                '';
              };
            };
          }) imageSystems;

          # No `nix` in runtimeInputs: use the caller's Nix and config.
          updateBase = pkgs.writeShellApplication {
            name = "update-base";
            runtimeInputs = with pkgs; [
              jq
              coreutils
            ];
            text = builtins.readFile ./scripts/update-base.sh;
          };

          updateMastodon = pkgs.writeShellApplication {
            name = "update-mastodon";
            runtimeInputs = with pkgs; [
              nix
              curl
              jq
              coreutils
              bundix
              nix-prefetch-github
              yarn-berry_4.yarn-berry-fetcher
            ];
            text = ''
              export NIXPKGS_PATH="${nixpkgs}"
            ''
            + builtins.readFile ./scripts/update-mastodon.sh;
          };
        in
        {
          devShells.default = pkgs.mkShell {
            packages = [
              skopeo
              pkgs.jq
              pkgs.gnupatch
              pkgs.layerx
              pkgs.dive
            ];
          };

          apps = copyApps // {
            update-base = flake-utils.lib.mkApp { drv = updateBase; };
            update-mastodon = flake-utils.lib.mkApp { drv = updateMastodon; };
          };
        }
      );
    in
    nixpkgs.lib.recursiveUpdate images tooling;
}
