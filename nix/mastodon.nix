# nixpkgs' Mastodon recipe, built from the version pinned in ../mastodon/.
{
  pkgs,
  maxChars,
  uploadsDir,
  ruby,
  nodejs,
  yarn-berry,
}:
let
  pins = pkgs.callPackage ../mastodon/source.nix {
    patches = [
      (pkgs.replaceVars ../patches/status-length-validator-max-chars.patch {
        MAX_CHARS = toString maxChars;
      })
    ];
  };

  src = pins.overrideAttrs {
    # No fuzz: a version bump that moves the patched code must fail loudly.
    patchFlags = [
      "-p1"
      "-F0"
    ];

    postPatch = ''
      grep -q '^  MAX_CHARS = ${toString maxChars}$' app/validators/status_length_validator.rb
    '';
  };

  # Like upstream's `without "development test"`; matched by BUNDLE_WITHOUT
  # in nix/image.nix.
  bundlerGroups = [
    "default"
    "production"
    "opentelemetry"
  ];

  # The recipe's toolchain arguments are versioned (ruby_3_4, ...) and get
  # renamed, so look up the current names.
  recipeArgs = builtins.attrNames (
    builtins.functionArgs (import "${pkgs.path}/pkgs/by-name/ma/mastodon/package.nix")
  );
  recipeArg =
    pattern:
    let
      matches = builtins.filter (name: builtins.match pattern name != null) recipeArgs;
    in
    if builtins.length matches == 1 then
      builtins.head matches
    else
      throw "nixpkgs' mastodon recipe has ${toString (builtins.length matches)} arguments matching ${pattern} (${toString matches}), expected 1; update nix/mastodon.nix";

  base = pkgs.mastodon.override {
    srcOverride = src;
    gemset = ../mastodon/gemset.nix;
    ${recipeArg "ruby_[0-9_]+"} = ruby;
    ${recipeArg "nodejs-slim_[0-9]+"} = nodejs;
    ${recipeArg "yarn-berry_[0-9]+"} = yarn-berry;
  };

  # The recipe's bundlerEnv plus `groups`; the asset build keeps the full set.
  runtimeGems = pkgs.bundlerEnv {
    name = "${base.pname}-gems-${base.version}";
    inherit (base) version;
    inherit ruby;
    gemset = ../mastodon/gemset.nix;
    gemdir = base.src;
    groups = bundlerGroups;
  };
in
base.overrideAttrs (old: {
  mastodonGems = runtimeGems;
  buildInputs = [
    runtimeGems
    nodejs
  ];
  propagatedBuildInputs = [ runtimeGems.wrappedRuby ];

  # public/system is where Mastodon's static file server looks for uploads.
  postInstall = (old.postInstall or "") + ''
    ln -s ${uploadsDir} $out/public/system
  '';
})
