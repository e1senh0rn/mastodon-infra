#!/usr/bin/env ruby
# frozen_string_literal: true

# CycloneDX SBOM of an image's runtime closure, from Nix rather than by
# inspecting files: sbomnix lists every store path with its derivation's
# name, version, nixpkgs CPE and licence, and the CVEs nixpkgs patches
# (pedigree.patches). On top of that, as pkg:gem / pkg:npm components that
# match their ecosystems' advisories:
# - gems: the gem derivations in the closure;
# - npm, server: streaming's production dependency tree in yarn.lock, which
#   is what the image installs (yarn workspaces focus --production
#   @mastodon/streaming);
# - npm, browser bundle: the packages compiled into public/packs (the web UI):
#   the root workspace's production tree in yarn.lock, limited to the names
#   in the packs' source maps (so no build tools).
# The property mastodon:shipped tells the npm groups apart. sbomnix builds
# the image first if it isn't built yet. Needs sbomnix (and Nix) on PATH; the
# flake app provides it:
#
# usage: nix run .#sbom -- <flake ref of the image, e.g. .#packages.x86_64-linux.image> <out.cdx.json> [image name] [image version]

require "json"
require "psych"
require "tmpdir"

module Sbom
  module_function

  # buildRubyGem derivations are named ruby<version>-<gem>.
  GEM_DERIVATION = /\Aruby[0-9.]+-(?=.)/

  def output_path(sbom, name)
    sbom["components"].each do |c|
      next unless c["name"] == name

      prop = (c["properties"] || []).find { |p| p["name"] == "nix:output_path" }
      return prop["value"] if prop
    end
    nil
  end

  def gem_component(component)
    return component unless component["name"].match?(GEM_DERIVATION) && component["purl"].to_s.start_with?("pkg:nix/")

    gem = component["name"].sub(GEM_DERIVATION, "")
    component.merge("name" => gem, "purl" => "pkg:gem/#{gem}@#{component["version"]}").except("cpe")
  end

  # The names under node_modules/ in the packs' source maps: exactly what Vite
  # bundled, without build tools.
  def bundled_names(packs)
    Dir.glob("#{File.realpath(packs)}/**/*.map").flat_map do |map|
      JSON.parse(File.read(map))["sources"].to_a.flat_map do |source|
        source.scan(%r{node_modules/((?:@[^/]+/)?[^/]+)}).flatten
      end
    end.uniq.sort
  end

  # yarn.lock as plain data, every scalar as the string it's written as (a
  # YAML parser would read "version: 1.10" as the number 1.1).
  def parse_lock(text)
    to_data = lambda do |node|
      case node
      when Psych::Nodes::Mapping then node.children.each_slice(2).to_h { |k, v| [to_data.(k), to_data.(v)] }
      when Psych::Nodes::Sequence then node.children.map(&to_data)
      when Psych::Nodes::Scalar then node.value
      when Psych::Nodes::Document then to_data.(node.root)
      else raise "unexpected YAML node #{node.class}"
      end
    end
    to_data.(Psych.parse(text))
  end

  def descriptor(name, range)
    range.match?(/\A[a-z]+:/) ? "#{name}@#{range}" : "#{name}@npm:#{range}"
  end

  def descriptor_names(key)
    key.split(", ").map { |d| d[/\A(@?[^@]+)@/, 1] }
  end

  # A workspace's production dependency tree (no devDependencies), one entry
  # per package and version, sorted. `only` limits it to packages installed
  # under one of those names, which differ from their own for aliases
  # (emoji-mart -> npm:emoji-mart-lazyload); several versions of a name are
  # all listed.
  def production_tree(lock, package_json, only: nil)
    entries = lock.except("__metadata")
    by_descriptor = entries.keys.flat_map { |key| key.split(", ").map { |d| [d, key] } }.to_h
    resolve = ->(deps) { (deps || {}).filter_map { |name, range| by_descriptor[descriptor(name, range)] } }

    seen = resolve.(package_json["dependencies"]).uniq
    todo = seen
    until todo.empty?
      todo = todo.flat_map { |key| resolve.(entries[key]["dependencies"]) }.uniq - seen
      seen += todo
    end

    only = only&.to_set
    seen.filter_map do |key|
      entry = entries[key]
      next if only && descriptor_names(key).none? { |n| only.include?(n) }
      # Workspaces and links aren't packages.
      next unless entry["resolution"].to_s.match?(/@(npm|patch):/)

      { "name" => entry["resolution"][/\A(@?[^@]+)@/, 1], "version" => entry["version"].to_s }
    end.uniq.sort_by { |p| [p["name"], p["version"]] }
  end

  def npm_component(pkg, shipped, modules)
    purl = "pkg:npm/#{pkg["name"].sub(/\A@/, "%40")}@#{pkg["version"]}"
    {
      "type" => "library",
      "bom-ref" => shipped == "server" ? purl : "#{shipped}:#{purl}",
      "name" => pkg["name"],
      "version" => pkg["version"],
      "purl" => purl,
      "properties" => [
        { "name" => "mastodon:shipped", "value" => shipped },
        { "name" => "nix:output_path", "value" => modules }
      ]
    }
  end

  def build(nix_sbom, server:, browser:, modules:, name: "", version: "")
    sbom = nix_sbom.merge(
      "components" => nix_sbom["components"].map { |c| gem_component(c) } +
        server.map { |p| npm_component(p, "server", modules) } +
        browser.map { |p| npm_component(p, "browser-bundle", modules) }
    )
    component = sbom.dig("metadata", "component")
    component["name"] = name unless name.empty?
    component["version"] = version unless version.empty?
    sbom
  end

  def summary(sbom)
    kinds = sbom["components"].group_by do |c|
      kind = c["purl"].to_s[%r{\Apkg:([^/]+)/}, 1] || "none"
      shipped = (c["properties"] || []).find { |p| p["name"] == "mastodon:shipped" }
      shipped ? "#{kind} (#{shipped["value"]})" : kind
    end
    patched = sbom["components"].flat_map { |c| (c.dig("pedigree", "patches") || []).flat_map { |p| (p["resolves"] || []).map { |r| r["id"] } } }
    "SBOM: #{kinds.sort.map { |k, v| "#{k} #{v.size}" }.join(", ")}, CVEs patched in nixpkgs: #{patched.uniq.size}"
  end

  def main(argv)
    usage = "usage: nix run .#sbom -- <flake ref of the image> <out.cdx.json> [image name] [image version]"
    ref, out, name, version = argv
    abort usage unless ref && out

    Dir.mktmpdir do |work|
      system("sbomnix", ref, "--cdx", "#{work}/nix.cdx.json", "--spdx", "#{work}/nix.spdx.json",
             "--csv", "#{work}/nix.csv", out: $stderr, exception: true)
      nix_sbom = JSON.parse(File.read("#{work}/nix.cdx.json"))

      modules = output_path(nix_sbom, "mastodon-modules")
      app = output_path(nix_sbom, "mastodon")
      paths = ["#{modules}/public/packs", "#{app}/yarn.lock", "#{app}/package.json", "#{app}/streaming/package.json"]
      paths.each { |f| abort "error: #{f} not found (closure changed?)" unless modules && app && File.exist?(f) }

      package_json = JSON.parse(File.read("#{app}/package.json"))
      lock = parse_lock(File.read("#{app}/yarn.lock"))
      server = production_tree(lock, JSON.parse(File.read("#{app}/streaming/package.json")))
      bundled = bundled_names("#{modules}/public/packs")
      browser = production_tree(lock, package_json, only: bundled)

      aliases = lock.keys.flat_map { |k| k.split(", ") }.filter_map { |d| d[/\A(@?[^@]+)@npm:/, 1] }.to_set
      missing = bundled - browser.map { |p| p["name"] } - package_json.fetch("dependencies", {}).keys
      missing = missing.reject { |n| aliases.include?(n) }
      warn "warning: bundled but not found in yarn.lock's production tree: #{missing.join(" ")}" unless missing.empty?

      sbom = build(nix_sbom, server:, browser:, modules:,
                             name: name.to_s, version: version.to_s)
      File.write(out, JSON.pretty_generate(sbom))
      warn summary(sbom)
    end
  end
end

Sbom.main(ARGV) if $PROGRAM_NAME == __FILE__
