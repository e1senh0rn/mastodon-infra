# Mastodon's runtime closure plus a few files; no distro base or shell.
# Runs web (default), sidekiq or streaming depending on the command.
{
  pkgs,
  nix2container,
  mastodon,
  nodejs,
  ffmpeg,
  name,
  sourceUrl,
  uploadsDir,
}:
let
  uid = 991;
  gid = 991;

  # The package links log/ to /var/log/mastodon and tmp/ to /tmp.
  dataDir = "/var/lib/mastodon";
  logDir = "/var/log/mastodon";

  # Same set the NixOS module puts on PATH.
  runtimePath = pkgs.lib.makeBinPath [
    mastodon
    mastodon.mastodonGems.wrappedRuby
    nodejs
    ffmpeg
    pkgs.file
  ];

  etc = pkgs.runCommand "mastodon-image-etc" { } ''
    mkdir -p $out/etc
    cat > $out/etc/passwd <<EOF
    root:x:0:0:root:/root:/sbin/nologin
    mastodon:x:${toString uid}:${toString gid}:mastodon:${dataDir}:/sbin/nologin
    nobody:x:65534:65534:nobody:/nonexistent:/sbin/nologin
    EOF
    cat > $out/etc/group <<EOF
    root:x:0:
    mastodon:x:${toString gid}:
    nogroup:x:65534:
    EOF
    cat > $out/etc/nsswitch.conf <<EOF
    passwd: files
    group: files
    hosts: files dns
    EOF
  '';

  dirs = pkgs.runCommand "mastodon-image-dirs" { } ''
    mkdir -p $out${dataDir} $out${logDir} $out${uploadsDir} $out/tmp $out/opt
    # Upstream's image path.
    ln -s ${mastodon} $out/opt/mastodon
  '';
in
nix2container.buildImage {
  inherit name;
  tag = mastodon.version;

  copyToRoot = [
    etc
    dirs
    pkgs.cacert
  ];

  # Regexes match store paths, not paths inside the image.
  perms = [
    {
      path = dirs;
      regex = "${dirs}${dataDir}(/.*)?$";
      mode = "0750";
      inherit uid gid;
      uname = "mastodon";
      gname = "mastodon";
    }
    {
      path = dirs;
      regex = "${dirs}${logDir}$";
      mode = "0750";
      inherit uid gid;
      uname = "mastodon";
      gname = "mastodon";
    }
    {
      path = dirs;
      regex = "${dirs}/tmp$";
      mode = "1777";
    }
    {
      path = dirs;
      regex = "${dirs}/tmp/.+";
      mode = "0750";
      inherit uid gid;
      uname = "mastodon";
      gname = "mastodon";
    }
  ];

  maxLayers = 100;

  config = {
    User = "${toString uid}:${toString gid}";
    Entrypoint = [
      "${pkgs.tini}/bin/tini"
      "--"
    ];
    WorkingDir = "${mastodon}";
    Cmd = [
      "${mastodon}/bin/puma"
      "-C"
      "config/puma.rb"
    ];
    ExposedPorts = {
      "3000/tcp" = { };
      "4000/tcp" = { };
    };
    Env = [
      "PATH=${runtimePath}"
      "RAILS_ENV=production"
      "BUNDLE_WITHOUT=development:test"
      "NODE_ENV=production"
      "BIND=0.0.0.0"
      "HOME=${dataDir}"
      "TZ=Etc/UTC"
      # public/ is in the store, out of a reverse proxy's reach.
      "RAILS_SERVE_STATIC_FILES=true"
      # The real path, not public/system: Paperclip creates it if missing
      # (e.g. under an emptyDir /tmp).
      "PAPERCLIP_ROOT_PATH=${uploadsDir}"
      "PAPERCLIP_ROOT_URL=/system"
      "MASTODON_SIDEKIQ_READY_FILENAME=sidekiq_process_has_started_and_will_begin_processing_jobs"
      "LD_PRELOAD=${pkgs.jemalloc}/lib/libjemalloc.so"
      "MALLOC_CONF=narenas:2,background_thread:true,thp:never,dirty_decay_ms:1000,muzzy_decay_ms:0"
      "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      "TZDIR=${pkgs.tzdata}/share/zoneinfo"
    ];
    # Nothing that varies independently of the contents (commit, date,
    # nixpkgs rev), or CI can't detect unchanged images; CI annotates those.
    Labels = {
      "org.opencontainers.image.title" = "mastodon";
      "org.opencontainers.image.version" = mastodon.version;
      "org.opencontainers.image.source" = sourceUrl;
      "org.opencontainers.image.licenses" = "AGPL-3.0-or-later";
    };
  };
}
