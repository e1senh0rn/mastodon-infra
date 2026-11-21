#!/usr/bin/env ruby
# frozen_string_literal: true

# Scans a published multi-arch image for known vulnerabilities: for each
# platform, matches the CycloneDX SBOM attached to the image (made by
# `nix run .#sbom` when it was built) with grype. Findings a nixpkgs patch
# resolves (the SBOM's pedigree.patches) are set aside, and .grype.yaml holds
# reviewed exceptions. Writes <out>/findings.json, one entry per
# vulnerability and package with the platforms it affects, and
# <out>/summary.md. Needs grype and oras. ORAS_FLAGS=--plain-http for a local
# test registry.
#
# With --sbom it scans given SBOM files instead, e.g. one of the current
# checkout (that's what `nix run .#cve-report` does).
#
# usage: scripts/scan_image.rb <image, e.g. ghcr.io/e1senh0rn/mastodon:latest> <out dir>
#        scripts/scan_image.rb --sbom <arch>=<sbom.cdx.json>... <out dir>

require "json"
require "open3"
require "fileutils"
require "shellwords"

module ScanImage
  module_function

  SBOM_TYPE = "application/vnd.cyclonedx+json"
  SEVERITY_RANK = { "Critical" => 0, "High" => 1, "Medium" => 2, "Low" => 3 }.freeze
  GROUPS = {
    "server" => "Server: Nix packages, gems, streaming's npm packages",
    "browser-bundle" => "Web UI bundle: npm packages compiled into public/packs, run in visitors' browsers"
  }.freeze

  def run(*cmd)
    out, status = Open3.capture2(*cmd)
    raise "#{cmd.first} failed: #{cmd.join(" ")}" unless status.success?

    out
  end

  def oras(*args)
    run("oras", *args, *Shellwords.split(ENV.fetch("ORAS_FLAGS", "")))
  end

  # "name@version" => [vulnerability ids its nixpkgs patches resolve]
  def patched_ids(sbom)
    sbom["components"].select { |c| c["pedigree"]&.key?("patches") }.to_h do |c|
      ["#{c["name"]}@#{c["version"]}", c["pedigree"]["patches"].flat_map { |p| (p["resolves"] || []).map { |r| r["id"] } }]
    end
  end

  # purl => where it's shipped ("server", "browser-bundle"); "server" unless
  # the component says otherwise.
  def shipped_groups(sbom)
    sbom["components"].select { |c| c["purl"] }.group_by { |c| c["purl"] }.transform_values do |cs|
      cs.map { |c| (c["properties"] || []).find { |p| p["name"] == "mastodon:shipped" }&.fetch("value") || "server" }.uniq.sort
    end
  end

  # One entry per grype match for a platform.
  def matches(grype, sbom, arch)
    patched = patched_ids(sbom)
    shipped = shipped_groups(sbom)
    grype["matches"].map do |m|
      vuln = m["vulnerability"]
      art = m["artifact"]
      related = m["relatedVulnerabilities"] || []
      ids = [vuln["id"]] + related.map { |r| r["id"] }
      {
        "id" => vuln["id"],
        "severity" => vuln["severity"],
        "package" => art["name"],
        "version" => art["version"],
        "type" => art["type"],
        "purl" => art["purl"],
        "fixState" => vuln.dig("fix", "state"),
        "fixVersions" => vuln.dig("fix", "versions"),
        "url" => vuln["dataSource"] || "",
        "description" => (vuln["description"] || related.map { |r| r["description"] }.first || "")[0, 500],
        "match" => m.dig("matchDetails", 0, "type"),
        "shipped" => shipped.fetch(art["purl"].to_s, ["server"]),
        "patched" => ids.intersect?(patched.fetch("#{art["name"]}@#{art["version"]}", [])),
        "arch" => arch
      }
    end
  end

  # One entry per vulnerability and package version, across platforms; the
  # ones a nixpkgs patch resolves separately.
  def findings(per_arch, image:, digest:)
    merged = per_arch.flatten.group_by { |f| [f["id"], f["package"], f["version"]] }.sort_by { |k, _| k.map(&:to_s) }.map do |_, fs|
      fs.first.merge("arches" => fs.map { |f| f["arch"] }.uniq.sort, "shipped" => fs.flat_map { |f| f["shipped"] }.uniq.sort)
        .except("arch")
    end
    merged = merged.each_with_index.sort_by { |f, i| [SEVERITY_RANK.fetch(f["severity"], 4), f["id"], i] }.map(&:first)
    patched, open = merged.partition { |f| f["patched"] }
    { "image" => image, "digest" => digest,
      "findings" => open.map { |f| f.except("patched") }, "patched" => patched.map { |f| f.except("patched") } }
  end

  def counts(findings)
    findings.group_by { |f| f["severity"] }.sort.map { |sev, fs| [sev, fs.size] }
  end

  def summary(result)
    fixed_in = ->(f) { f["fixVersions"].nil? || f["fixVersions"].empty? ? "–" : f["fixVersions"].join(", ") }
    lines = ["### Vulnerabilities in `#{result["image"]}`", "", "Digest `#{result["digest"]}`", ""]
    lines += counts(result["findings"]).map { |sev, n| "- #{sev}: #{n}" }
    lines << ""
    GROUPS.each do |group, title|
      lines += ["#### #{title}", "", "| Severity | Vulnerability | Package | Fixed in | Platforms |", "|---|---|---|---|---|"]
      result["findings"].select { |f| %w[Critical High].include?(f["severity"]) && f["shipped"].include?(group) }.each do |f|
        lines << "| #{f["severity"]} | [#{f["id"]}](#{f["url"]}) | #{f["package"]} #{f["version"]} (#{f["type"]}) | " \
                 "#{fixed_in.(f)} | #{f["arches"].join(", ")} |"
      end
      lines << ""
    end
    patched = result["patched"].map { |f| "#{f["id"]} (#{f["package"]} #{f["version"]})" }.uniq.sort.join(", ")
    lines << "Patched in nixpkgs, so not counted: #{patched.empty? ? "none" : patched}"
    "#{lines.join("\n")}\n"
  end

  # The report for a terminal: critical and high findings as aligned columns
  # per group, coloured unless NO_COLOR is set or it's not a terminal.
  def text_report(result, findings_path, color: $stdout.tty? && !ENV.key?("NO_COLOR"))
    paint = lambda do |text, severity|
      next text unless color

      code = { "Critical" => "1;31", "High" => "31", "Medium" => "33", "Low" => "2" }.fetch(severity, "0")
      "\e[#{code}m#{text}\e[0m"
    end
    bold = ->(text) { color ? "\e[1m#{text}\e[0m" : text }
    clip = ->(text, width) { text.length > width ? "#{text[0, width - 1]}…" : text }
    shown = %w[Critical High]
    counts = counts(result["findings"]).sort_by { |sev, _| SEVERITY_RANK.fetch(sev, 4) }

    # With one platform scanned, it goes in the title instead of a column.
    arches = (result["findings"] + result["patched"]).flat_map { |f| f["arches"] }.uniq.sort
    title = "Vulnerabilities in #{result["image"]}"
    title += " (#{result["digest"]})" if result["digest"].start_with?("sha256:")
    title += ", #{arches.first}" if arches.size == 1
    lines = [bold.(title)]
    lines << counts.map { |sev, n| paint.("#{n} #{sev.downcase}", sev) }.join(", ")
    GROUPS.each do |group, title|
      rows = result["findings"].select { |f| shown.include?(f["severity"]) && f["shipped"].include?(group) }.map do |f|
        fixed = f["fixVersions"].nil? || f["fixVersions"].empty? ? "–" : f["fixVersions"].join(", ")
        row = [f["severity"], f["id"], clip.("#{f["package"]} #{f["version"]} (#{f["type"]})", 42), clip.(fixed, 24)]
        arches.size > 1 ? row + [f["arches"].join(", ")] : row
      end
      lines += ["", bold.(title)]
      if rows.empty?
        lines << "  none critical or high"
        next
      end
      header = ["SEVERITY", "VULNERABILITY", "PACKAGE", "FIXED IN"]
      header << "PLATFORMS" if arches.size > 1
      widths = header.each_index.map { |i| ([header] + rows).map { |r| r[i].length }.max }
      format = ->(row) { row.each_with_index.map { |cell, i| cell.ljust(widths[i]) }.join("  ").rstrip }
      lines << "  #{bold.(format.(header))}"
      rows.each { |row| lines << "  #{paint.(format.(row), row[0])}" }
    end

    hidden = counts.reject { |sev, _| shown.include?(sev) }.map { |sev, n| "#{n} #{sev.downcase}" }
    lines += ["", "Not shown: #{hidden.join(", ")}." ] unless hidden.empty?
    patched = result["patched"].group_by { |f| "#{f["package"]} #{f["version"]}" }
    unless patched.empty?
      lines << "Patched in nixpkgs, not counted: " +
               patched.sort.map { |pkg, fs| "#{pkg} (#{fs.map { |f| f["id"] }.uniq.size})" }.join(", ")
    end
    lines << "Details and descriptions: #{findings_path}"
    "#{lines.join("\n")}\n"
  end

  def grype(sbom_path, arch, out)
    config = ENV.fetch("GRYPE_CONFIG") { File.expand_path("../.grype.yaml", __dir__) }
    system("grype", "sbom:#{sbom_path}", "-c", config, "-q", "-o", "json", "--file", "#{out}/grype-#{arch}.json",
           exception: true)
    matches(JSON.parse(File.read("#{out}/grype-#{arch}.json")), JSON.parse(File.read(sbom_path)), arch)
  end

  # The SBOMs attached to a published image's platform images.
  def published(image, out)
    repo = image.sub(/:[^:]*\z/, "")
    index = JSON.parse(oras("manifest", "fetch", image))
    digest = JSON.parse(oras("manifest", "fetch", "--descriptor", image))["digest"]
    platforms = index.fetch("manifests", []).select { |m| m.dig("platform", "os") == "linux" }
    abort "error: #{image} is not a multi-arch index" if platforms.empty?

    sboms = platforms.to_h do |m|
      arch = m.dig("platform", "architecture")
      referrers = JSON.parse(oras("discover", "--format", "json", "--artifact-type", SBOM_TYPE, "#{repo}@#{m["digest"]}"))
      attached = (referrers["referrers"] || []).max_by { |r| r.dig("annotations", "org.opencontainers.image.created").to_s }
      unless attached
        # It's generated from the exact build, so it can't be made up afterwards.
        abort "error: #{repo}@#{m["digest"]} (#{arch}) has no SBOM attached. Images published before SBOMs " \
              "existed need a rebuild: gh workflow run build.yml -f force=true"
      end
      warn "#{arch}: attached SBOM #{attached["digest"]}"
      pull = "#{out}/pull-#{arch}"
      oras("pull", "--output", pull, "#{repo}@#{attached["digest"]}")
      FileUtils.mv(Dir.glob("#{pull}/**/*.json").first, "#{out}/sbom-#{arch}.cdx.json")
      FileUtils.rm_rf(pull)
      [arch, "#{out}/sbom-#{arch}.cdx.json"]
    end
    [digest, sboms]
  end

  def main(argv)
    usage = "usage: #{$PROGRAM_NAME} [--print] <image> <out dir>\n" \
            "       #{$PROGRAM_NAME} [--print] --sbom <arch>=<sbom.cdx.json>... <out dir>   (an SBOM from nix run .#sbom)\n" \
            "--print: also print a report for the terminal"
    print_report = argv.first == "--print"
    argv = argv.drop(1) if print_report
    if argv.first == "--sbom"
      *specs, out = argv.drop(1)
      abort usage if specs.empty? || out.nil? || specs.any? { |s| !s.include?("=") }
      sboms = specs.to_h { |spec| spec.split("=", 2) }
      image = "local build"
      digest = "not published"
    else
      image, out = argv
      abort usage unless image && out
    end
    FileUtils.mkdir_p(out)
    digest, sboms = published(image, out) unless sboms

    system("grype", "db", "update", out: $stderr, exception: true)
    per_arch = sboms.map { |arch, path| grype(path, arch, out) }

    result = findings(per_arch, image:, digest:)
    File.write("#{out}/findings.json", JSON.pretty_generate(result))
    File.write("#{out}/summary.md", summary(result))
    $stdout.write(text_report(result, "#{out}/findings.json")) if print_report
    browser = result["findings"].count { |f| f["shipped"].include?("browser-bundle") }
    warn "#{counts(result["findings"]).map { |sev, n| "#{sev}: #{n}" }.join(", ")}; " \
         "in the web UI bundle: #{browser}; patched in nixpkgs: #{result["patched"].size}"
  end
end

ScanImage.main(ARGV) if $PROGRAM_NAME == __FILE__
