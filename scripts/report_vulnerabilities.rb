#!/usr/bin/env ruby
# frozen_string_literal: true

# Turns scan findings into GitHub issues, one per vulnerability and package
# at or above $SEVERITY (default Critical), labelled "vulnerability":
# - new finding: open an issue (which notifies the repository's watchers);
# - already open: leave it;
# - closed by hand (dismissed): leave it closed;
# - gone from the published image: comment, label "resolved" and close;
#   it's reopened if the finding comes back.
# DRY_RUN=1 prints the gh commands instead; ISSUES_JSON stands in for the
# existing issues in tests. Needs gh (GH_TOKEN, GH_REPO).
#
# usage: scripts/report_vulnerabilities.rb <findings.json> [run url]

require "json"
require "open3"

module ReportVulnerabilities
  module_function

  LEVELS = { "Critical" => %w[Critical], "High" => %w[Critical High] }.freeze

  def title(finding)
    "#{finding["id"]} in #{finding["package"]}"
  end

  def body(finding, image:, digest:, run_url: "")
    fix = finding["fixVersions"].nil? || finding["fixVersions"].empty? ? "unknown" : finding["fixVersions"].join(", ")
    shipped = (finding["shipped"] || ["server"]).map do |s|
      s == "browser-bundle" ? "web UI bundle (compiled into `public/packs`, runs in visitors' browsers)" : "server"
    end.join(", ")
    where = if %w[gem npm].include?(finding["type"])
              "Mastodon's lockfiles pin this package, so the fix ships with a Mastodon release that updates it. " \
                "Patch releases of the pinned minor are picked up by the weekly run, or right away with `gh workflow run build.yml`; " \
                "a new minor needs `-f mastodon_version=...`. See Mastodon's " \
                "[security advisories](https://github.com/mastodon/mastodon/security/advisories) and " \
                "[releases](https://github.com/mastodon/mastodon/releases)."
            else
              "nixpkgs builds this package. Once a fix (a new version or a patch) reaches `nixos-unstable`, " \
                "`gh workflow run build.yml` publishes an image and chart with it; the weekly run does it otherwise. " \
                "Check for a fix in [nixpkgs](https://github.com/NixOS/nixpkgs/issues?q=#{finding["id"]}) " \
                "and whether it has landed with the [PR tracker](https://nixpk.gs/pr-tracker.html); " \
                "[status.nixos.org](https://status.nixos.org) shows how far the channel is."
            end
    description = finding["description"].to_s
    <<~MD.chomp + (run_url.empty? ? "" : "\n\nScan: #{run_url}")
      **#{finding["severity"]}** vulnerability in the published image, found by the daily scan.

      | | |
      |---|---|
      | Vulnerability | [#{finding["id"]}](#{finding["url"]}) |
      | Package | `#{finding["package"]}` #{finding["version"]} (#{finding["type"]}) |
      | Shipped | #{shipped} |
      | Fixed in | #{fix} |
      | Platforms | #{finding["arches"].join(", ")} |
      | Image | `#{image}` (`#{digest}`) |

      #{description.empty? ? "" : "> #{description.tr("\n", " ")}\n\n"}### Where the fix comes from

      #{where}

      If it doesn't apply to this image (scanners match Nix packages by name and version, so false positives happen), add it with a reason to `.grype.yaml` and close this issue.
    MD
  end

  # What to do, as gh argument lists, plus a log line each. Pure, for tests.
  def plan(result, issues, severity: "Critical", run_url: "")
    levels = LEVELS.fetch(severity) { raise ArgumentError, "SEVERITY must be Critical or High" }
    image = result["image"]
    digest = result["digest"]
    suffix = run_url.empty? ? "" : " Scan: #{run_url}"
    actions = []
    reported = result["findings"].select { |f| levels.include?(f["severity"]) }

    reported.each do |finding|
      t = title(finding)
      issue = issues.find { |i| i["title"] == t }
      if issue.nil?
        actions << { log: "New: #{t}",
                     gh: ["issue", "create", "--title", t, "--label", "vulnerability", "--body",
                          body(finding, image:, digest:, run_url:)] }
      elsif issue["state"] == "OPEN"
        actions << { log: "Already open: #{t} (##{issue["number"]})" }
      elsif issue["labels"].any? { |l| l["name"] == "resolved" }
        n = issue["number"].to_s
        actions << { log: "Back again: #{t} (##{n})",
                     gh: ["issue", "reopen", n, "--comment", "Found again in `#{image}` (`#{digest}`).#{suffix}"] }
        actions << { gh: ["issue", "edit", n, "--remove-label", "resolved"] }
      else
        actions << { log: "Dismissed, leaving closed: #{t} (##{issue["number"]})" }
      end
    end

    # Close issues whose finding is gone entirely (fixed, or added to .grype.yaml).
    present = result["findings"].map { |f| title(f) }.uniq
    issues.select { |i| i["state"] == "OPEN" && !present.include?(i["title"]) }.each do |issue|
      n = issue["number"].to_s
      actions << { log: "Resolved: #{issue["title"]} (##{n})", gh: ["issue", "edit", n, "--add-label", "resolved"] }
      actions << { gh: ["issue", "close", n, "--comment", "No longer found in `#{image}` (`#{digest}`).#{suffix}"] }
    end

    actions << { log: "#{reported.size} finding(s) at or above #{severity}." }
  end

  def gh(*args)
    out, status = Open3.capture2("gh", *args)
    raise "gh #{args.first(2).join(" ")} failed" unless status.success?

    out
  end

  def main(argv)
    path, run_url = argv
    abort "usage: #{$PROGRAM_NAME} <findings.json> [run url]" unless path
    $stdout.sync = true # keep dry-run lines and the stderr log in order
    dry_run = !ENV.fetch("DRY_RUN", "").empty?
    result = JSON.parse(File.read(path))

    unless dry_run
      gh("label", "create", "vulnerability", "--color", "B60205", "--description", "Found by the daily image scan", "--force")
      gh("label", "create", "resolved", "--color", "0E8A16", "--description", "No longer in the published image", "--force")
    end
    issues = JSON.parse(ENV.fetch("ISSUES_JSON", "").then do |stub|
      stub.empty? ? gh("issue", "list", "--label", "vulnerability", "--state", "all", "--limit", "1000",
                       "--json", "number,title,state,labels") : stub
    end)

    plan(result, issues, severity: ENV.fetch("SEVERITY", "Critical"), run_url: run_url.to_s).each do |action|
      warn action[:log] if action[:log]
      next unless action[:gh]

      if dry_run
        puts "DRY RUN: gh #{action[:gh].join(" ")}"[0, 200]
      else
        gh(*action[:gh])
      end
    end
  end
end

ReportVulnerabilities.main(ARGV) if $PROGRAM_NAME == __FILE__
