#!/usr/bin/env ruby
# frozen_string_literal: true
#
# render-claudemd.rb — re-render marker-delimited regions of a project's
# root CLAUDE.md from the workflow contract.
#
# Usage:
#   render-claudemd.rb <project-path> [--check]
#
# Reads:
#   <project>/.homebase/workflow.yml
#   <project>/.homebase/project.yml
#   ~/code/homebase/governance/HARD_RULES.yml
#   ~/code/homebase/sops/HOMEBASE-SOP-*.md (for SOP numbers + titles)
#
# Writes:
#   <project>/CLAUDE.md  (only the content between <!-- BEGIN homebase:<id> -->
#                         and <!-- END homebase:<id> --> markers; prose
#                         outside the markers is sacred)
#
# Exit codes:
#   0 — rendered cleanly (or --check, no drift)
#   1 — --check mode, drift detected
#   2 — bad argv, missing files, parse error
#
# Standard: ~/code/homebase/standards/WORKFLOW_CONTRACT.md § Generation
#           pipeline.
# Schema:   ~/code/homebase/schemas/workflow.schema.json.

require "yaml"
require "pathname"
require "optparse"
require "shellwords"
require "tempfile"

# ── Paths ─────────────────────────────────────────────────────────────────────

HOMEBASE_DIR = Pathname.new(__dir__).expand_path.parent
HARD_RULES_PATH = HOMEBASE_DIR / "governance" / "HARD_RULES.yml"
SOPS_DIR = HOMEBASE_DIR / "sops"

# ── CLI ───────────────────────────────────────────────────────────────────────

check_mode = false
project_path = nil
opts = OptionParser.new do |o|
  o.banner = "usage: render-claudemd.rb <project-path> [--check]"
  o.on("--check", "Exit non-zero on drift; do not write") { check_mode = true }
end
remaining = opts.parse(ARGV)
project_path = remaining.shift
abort opts.to_s unless project_path
CHECK_MODE = check_mode

PROJECT_ROOT = Pathname.new(project_path).expand_path
abort "render-claudemd: #{PROJECT_ROOT} is not a directory" unless PROJECT_ROOT.directory?
WORKFLOW_PATH = PROJECT_ROOT / ".homebase" / "workflow.yml"
PROJECT_YML_PATH = PROJECT_ROOT / ".homebase" / "project.yml"
CLAUDEMD_PATH = PROJECT_ROOT / "CLAUDE.md"

abort "render-claudemd: #{WORKFLOW_PATH} not found" unless WORKFLOW_PATH.file?
abort "render-claudemd: #{PROJECT_YML_PATH} not found" unless PROJECT_YML_PATH.file?
abort "render-claudemd: #{CLAUDEMD_PATH} not found" unless CLAUDEMD_PATH.file?

WORKFLOW = YAML.load_file(WORKFLOW_PATH)
PROJECT  = YAML.load_file(PROJECT_YML_PATH)
HARD_RULES = YAML.load_file(HARD_RULES_PATH)

# ── SOP metadata (scanned from SOP file headers) ──────────────────────────────
#
# SOP files have the canonical naming HOMEBASE-SOP-NNN-DESCRIPTION.md and a
# first heading like `# HOMEBASE-SOP-NNN: Title`. Both are read at render time.

def sop_metadata
  meta = {}
  Dir.glob(SOPS_DIR / "HOMEBASE-SOP-*.md").sort.each do |path|
    basename = File.basename(path, ".md")
    # e.g. HOMEBASE-SOP-001-DEVELOPMENT_WORKFLOW
    next unless basename =~ /\AHOMEBASE-SOP-(\d{3})-(.+)\z/
    number = $1.to_i
    slug = "HOMEBASE-SOP-#{$1}"
    # Read first '# ' line for display title.
    title = nil
    File.foreach(path) do |line|
      line = line.strip
      next unless line.start_with?("# ")
      title = line.sub(/\A#\s+/, "")
      break
    end
    title ||= basename.sub(/\AHOMEBASE-SOP-\d{3}-/, "").tr("_", " ").split.map(&:capitalize).join(" ")
    # Strip "HOMEBASE-SOP-NNN:" prefix if present in the heading.
    title = title.sub(/\AHOMEBASE-SOP-\d{3}:?\s*/, "")
    meta[slug] = { number: number, title: title, path: path, basename: basename }
  end
  meta
end

SOP_META = sop_metadata.freeze

# ── Renderers ────────────────────────────────────────────────────────────────

def adopted_slugs
  WORKFLOW["hard_rules"] || []
end

def adopted_sops
  # Distinct SOPs referenced by adopted hard rules. Sort by SOP number.
  slugs = adopted_slugs.map { |slug| HARD_RULES.dig(slug, "sop") }.compact.uniq
  slugs.select! { |s| SOP_META.key?(s) }
  slugs.sort_by { |s| SOP_META[s][:number] }
end

def render_adopted_sops
  return "_(no hard_rules adopted; nothing to render)_" if adopted_sops.empty?
  lines = adopted_sops.map do |slug|
    meta = SOP_META[slug]
    relpath = "@~/code/homebase/sops/#{meta[:basename]}.md"
    "- [#{slug} #{meta[:title]}](#{relpath})"
  end
  lines.join("\n")
end

def render_hard_rules
  rules = adopted_slugs.map { |slug| HARD_RULES[slug] }.compact
  return "_(no hard_rules adopted)_" if rules.empty?
  rules.sort_by! { |r| r["number"] }
  rules.map do |r|
    "#{r["number"]}. **#{r["short"]}** — #{r["body"]} (Enforced by `#{r["enforced_by"]}`; rationale in #{r["sop"]})"
  end.join("\n")
end

def render_required_checks
  apps_block = WORKFLOW["apps"] || {}
  rows = []
  (PROJECT["apps"] || []).each do |app|
    name = app["name"]
    overrides = apps_block[name] || {}
    project_checks = WORKFLOW["required_checks"] || []
    app_checks = overrides["required_checks"] || project_checks
    app_checks.each do |c|
      rows << [
        name,
        c["name"],
        "`#{c["command"]}`",
        c["when"] || "on_finish",
        (c["blocking"].nil? ? "true" : c["blocking"].to_s),
      ]
    end
  end
  return "_(no required_checks declared)_" if rows.empty?
  header = "| App | Check | Command | When | Blocking |\n|---|---|---|---|---|"
  body = rows.map { |r| "| " + r.join(" | ") + " |" }.join("\n")
  [header, body].join("\n")
end

def render_required_agents
  ra = WORKFLOW["required_agents"] || {}
  by_platform = ra["by_platform"] || {}
  by_change_kind = ra["by_change_kind"] || {}
  parts = []
  unless by_platform.empty?
    parts << "**By platform**\n"
    parts << "| Platform | Required agents |\n|---|---|"
    by_platform.keys.sort.each do |k|
      parts << "| `#{k}` | #{by_platform[k].map { |a| "`#{a}`" }.join(", ")} |"
    end
  end
  unless by_change_kind.empty?
    parts << "" unless parts.empty?
    parts << "**By change kind**\n"
    parts << "| Change kind | Required agents |\n|---|---|"
    by_change_kind.keys.sort.each do |k|
      parts << "| `#{k}` | #{by_change_kind[k].map { |a| "`#{a}`" }.join(", ")} |"
    end
  end
  return "_(no required_agents declared)_" if parts.empty?
  parts.join("\n")
end

# ── Renderer dispatch ─────────────────────────────────────────────────────────

RENDERERS = {
  "homebase:adopted-sops"     => method(:render_adopted_sops),
  "homebase:hard-rules"       => method(:render_hard_rules),
  "homebase:required-checks"  => method(:render_required_checks),
  "homebase:required-agents"  => method(:render_required_agents),
}.freeze

# ── Marker rewrite ────────────────────────────────────────────────────────────

def rewrite(content, marker_id, body)
  begin_marker = "<!-- BEGIN #{marker_id} -->"
  end_marker   = "<!-- END #{marker_id} -->"
  pattern = /(#{Regexp.escape(begin_marker)}\s*\n).*?(\n\s*#{Regexp.escape(end_marker)})/m
  if content =~ pattern
    replacement = "#{Regexp.last_match(1)}#{body}#{Regexp.last_match(2)}"
    content.sub(pattern, replacement)
  else
    nil
  end
end

# ── Main ──────────────────────────────────────────────────────────────────────

original = CLAUDEMD_PATH.read
updated = original.dup

unfound = []
RENDERERS.each do |id, renderer|
  body = renderer.call
  result = rewrite(updated, id, body)
  if result.nil?
    unfound << id
  else
    updated = result
  end
end

if !unfound.empty?
  warn "render-claudemd: #{CLAUDEMD_PATH}: missing markers: #{unfound.join(', ')}"
  warn "  Add the marker pairs to CLAUDE.md:"
  unfound.each do |id|
    warn "    <!-- BEGIN #{id} --> ... <!-- END #{id} -->"
  end
  exit 2
end

if CHECK_MODE
  if updated == original
    exit 0
  else
    warn "render-claudemd: drift detected in #{CLAUDEMD_PATH}"
    warn "  Run 'bin/homebase render-claudemd #{PROJECT_ROOT}' and commit the result."
    Tempfile.create("claudemd-rendered") do |tmp|
      tmp.write(updated)
      tmp.flush
      diff = `diff -u #{Shellwords.escape(CLAUDEMD_PATH.to_s)} #{Shellwords.escape(tmp.path)}`
      warn diff
    end
    exit 1
  end
else
  if updated == original
    puts "render-claudemd: #{CLAUDEMD_PATH} unchanged"
    exit 0
  else
    CLAUDEMD_PATH.write(updated)
    puts "render-claudemd: #{CLAUDEMD_PATH} updated"
    exit 0
  end
end
