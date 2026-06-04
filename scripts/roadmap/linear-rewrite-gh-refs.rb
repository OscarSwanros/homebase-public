#!/usr/bin/env ruby
# frozen_string_literal: true

# scripts/roadmap/linear-rewrite-gh-refs.rb — HMB-25.
#
# Two-phase script for replacing GitHub `#N`, full GitHub-issue URLs,
# and pre-existing Linear chip remnants (`<issue id="UUID">…</issue>`)
# inside Linear issue bodies with the corresponding Linear keys as
# *plain text*. The descriptionData (ProseMirror) write path is used
# on apply so Linear's markdown chip-resolver doesn't reverse-resolve
# our plain text back to GitHub-labelled chips.
#
# Phase 1 — `scan`: read-only. Builds two maps:
#   - `<owner/repo> -> {gh_num => linear_key}` from attachments.
#   - `<linear-uuid> -> linear_key` for de-chipping prior saves.
# Then scans every open body and writes:
#
#   tmp/linear-gh-rewrite-report.md          — human review surface
#   tmp/linear-gh-rewrite-state.json         — machine-readable per-
#                                              issue (id, current,
#                                              proposed, replacements,
#                                              flags)
#
# The operator reads the report and adds `# SKIP` under any `## <KEY>`
# section they want to exclude. Phase 2 honors those skips.
#
# Phase 2 — `apply`: reads the state JSON + the report. For each
# non-skipped entry, parses the proposed markdown to ProseMirror via
# the in-script `Md2Pm` module and POSTs `issueUpdate(input: {
# descriptionData: $json })` via the same GraphQL plumbing as
# `linear.rb`. Writes a summary.
#
# Usage:
#   linear-rewrite-gh-refs.rb scan  [--team HMB|TBL|TFD]
#   linear-rewrite-gh-refs.rb apply [--team HMB|TBL|TFD] [--dry-run]
#
# Authorisation:
#   - `scan` is read-only; needs LINEAR_API_KEY but not
#     LINEAR_TPM_AUTHORIZED.
#   - `apply` mutates Linear and requires LINEAR_TPM_AUTHORIZED=1
#     (matches the hard-rule on `homebase roadmap` mutations).
#
# Canonical source: ~/code/homebase/scripts/roadmap/linear-rewrite-gh-refs.rb
# Spec: HMB-25.

require "fileutils"
require "json"
require "optparse"
require "pathname"
require "time"

require_relative "linear"

# REPO_MAP gives the team -> owner/repo. Used to disambiguate bare
# `#N` references (no repo on the line, so we assume the team's repo).
# Full URL replacements honor whatever owner/repo the URL specifies
# (cross-team refs work).
REPO_MAP = {
  "HMB" => { owner: "acme-co", repo: "homebase" },
  "TBL" => { owner: "acme-co", repo: "studio" },
  "TFD" => { owner: "acme-co", repo: "field-suite" },
}.freeze

REPORT_PATH = Pathname.new(__dir__).join("../../tmp/linear-gh-rewrite-report.md").expand_path
STATE_PATH  = Pathname.new(__dir__).join("../../tmp/linear-gh-rewrite-state.json").expand_path
SUMMARY_PATH = Pathname.new(__dir__).join("../../tmp/linear-gh-rewrite-summary.md").expand_path

# ── Linear queries + helpers ──────────────────────────────────────────────────

OPEN_ISSUES_QUERY = <<~GQL
  query OpenIssues($filter: IssueFilter!, $after: String) {
    issues(filter: $filter, first: 100, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes {
        id
        identifier
        description
        team { key }
        attachments { nodes { url } }
      }
    }
  }
GQL

# Apply via `descriptionData` (ProseMirror JSON), not `description`
# (markdown). Linear's markdown resolver runs on the markdown path and
# reverse-resolves Linear keys back to chips bearing the GitHub-attachment
# label — defeating the rewrite. The descriptionData path skips the resolver:
# whatever ProseMirror nodes we send are stored as-is. See HMB-25 thread.
ISSUE_UPDATE_MUTATION = <<~GQL
  mutation UpdateIssueDescription($id: String!, $data: JSON!) {
    issueUpdate(id: $id, input: { descriptionData: $data }) {
      success
      issue { id identifier }
    }
  }
GQL

OPEN_STATE_TYPES = %w[backlog unstarted started].freeze

# When `state_types` is nil, no state filter — fetches every issue in the
# team. Used for mapping (we need closed issues' GH attachments to resolve
# references to issues that have already shipped).
def list_issues(linear, team_key, state_types: nil)
  issues = []
  cursor = nil
  filter = { team: { key: { eq: team_key } } }
  filter[:state] = { type: { in: state_types } } if state_types
  loop do
    data = linear.call(OPEN_ISSUES_QUERY, { filter: filter, after: cursor })
    page = data["issues"]
    issues.concat(page["nodes"])
    break unless page.dig("pageInfo", "hasNextPage")
    cursor = page.dig("pageInfo", "endCursor")
  end
  issues
end

# Build { "<owner>/<repo>" => { gh_num => "<LINEAR-KEY>" } } from
# every issue's attachments. One issue can have multiple attachments;
# we only care about /issues/<N> URLs.
def build_mapping(all_issues)
  mapping = Hash.new { |h, k| h[k] = {} }
  all_issues.each do |issue|
    attachments = issue.dig("attachments", "nodes") || []
    attachments.each do |a|
      url = a["url"].to_s
      m = url.match(%r{\Ahttps?://github\.com/([^/]+)/([^/]+)/issues/(\d+)}) or next
      mapping["#{m[1]}/#{m[2]}"][m[3].to_i] = issue["identifier"]
    end
  end
  mapping
end

# Build { "<linear-uuid>" => "<LINEAR-KEY>" } from every issue. Used to
# de-chip existing `<issue id="UUID">label</issue>` markers — these appear
# when an earlier mass save let Linear's resolver convert a `TFD-N` into
# a chip. We strip the chip back to plain text since plain text is what
# we want stored (and what descriptionData preserves verbatim).
def build_id_to_key(all_issues)
  all_issues.each_with_object({}) { |issue, h| h[issue["id"]] = issue["identifier"] }
end

# ── Md2Pm: markdown → Linear ProseMirror JSON ────────────────────────────────
#
# Focused converter for the markdown features that actually appear in Linear
# issue bodies in this workspace. NOT a general-purpose CommonMark engine.
# Handles: ATX headings, paragraphs, fenced code blocks, bullet/ordered/todo
# lists, blockquotes, horizontal rules, inline strong/em/code/link, Linear
# `<issue id="…">…</issue>` chips, hard breaks (two trailing spaces).
# Anything unrecognised falls through to a plain text node — never raises.
#
# Linear's ProseMirror schema uses snake_case node names (`bullet_list`,
# `list_item`, `todo_list`, `todo_item`, `code_block`, `hard_break`,
# `horizontal_rule`) and `strong`/`em`/`code`/`link` marks. Chips are
# `issueMention` (camelCase) with `id` + `label` attrs.
module Md2Pm
  module_function

  def parse(text)
    text = text.to_s.gsub("\r\n", "\n")
    lines = text.split("\n", -1)
    {"type" => "doc", "content" => parse_blocks(lines, 0, lines.length)}
  end

  def parse_blocks(lines, start_i, end_i)
    blocks = []
    i = start_i
    while i < end_i
      line = lines[i]
      if line.strip.empty?
        i += 1
        next
      end

      # Fenced code block (``` or ~~~)
      if (m = line.match(/\A(```|~~~)(.*)\z/))
        fence = m[1]
        lang = m[2].strip
        code = []
        i += 1
        while i < end_i && !lines[i].start_with?(fence)
          code << lines[i]
          i += 1
        end
        i += 1 # closing fence (skipped even if missing)
        node = {"type" => "code_block"}
        node["attrs"] = {"language" => lang} unless lang.empty?
        node["content"] = [{"type" => "text", "text" => code.join("\n")}] unless code.empty?
        blocks << node
        next
      end

      # ATX heading
      if (m = line.match(/\A(\#{1,6})\s+(.+?)\s*\z/))
        blocks << {"type" => "heading", "attrs" => {"level" => m[1].length},
                   "content" => parse_inline(m[2])}
        i += 1
        next
      end

      # Task list (must precede plain bullet list — `- [ ]` would also match)
      if line.match?(/\A[*\-+]\s+\[[ xX]\]/)
        items = []
        while i < end_i && (m = lines[i].match(/\A[*\-+]\s+\[([ xX])\]\s*(.*)\z/))
          items << {"type" => "todo_item",
                    "attrs" => {"checked" => m[1].downcase == "x"},
                    "content" => [{"type" => "paragraph", "content" => parse_inline(m[2])}]}
          i += 1
        end
        blocks << {"type" => "todo_list", "content" => items}
        next
      end

      # Bullet list
      if line.match?(/\A[*\-+]\s+/) && !line.match?(/\A[*\-+]\s+\[[ xX]\]/)
        items = []
        while i < end_i && (m = lines[i].match(/\A[*\-+]\s+(.+)\z/)) &&
              !lines[i].match?(/\A[*\-+]\s+\[[ xX]\]/)
          items << {"type" => "list_item",
                    "content" => [{"type" => "paragraph", "content" => parse_inline(m[1])}]}
          i += 1
        end
        blocks << {"type" => "bullet_list", "content" => items}
        next
      end

      # Ordered list
      if line.match?(/\A\d+\.\s+/)
        items = []
        while i < end_i && (m = lines[i].match(/\A\d+\.\s+(.+)\z/))
          items << {"type" => "list_item",
                    "content" => [{"type" => "paragraph", "content" => parse_inline(m[1])}]}
          i += 1
        end
        blocks << {"type" => "ordered_list", "attrs" => {"order" => 1}, "content" => items}
        next
      end

      # Blockquote
      if line.start_with?(">")
        quote = []
        while i < end_i && lines[i].start_with?(">")
          quote << lines[i].sub(/\A>\s?/, "")
          i += 1
        end
        inner = parse_blocks(quote, 0, quote.length)
        inner = [{"type" => "paragraph"}] if inner.empty?
        blocks << {"type" => "blockquote", "content" => inner}
        next
      end

      # Horizontal rule
      if line.match?(/\A\s*([\*\-_])(\s*\1){2,}\s*\z/)
        blocks << {"type" => "horizontal_rule"}
        i += 1
        next
      end

      # GFM table: `| a | b |` followed by `| --- | --- |` divider
      if line.match?(/\A\s*\|.+\|\s*\z/) &&
         i + 1 < end_i &&
         lines[i + 1].match?(/\A\s*\|[\s:|\-]+\|\s*\z/)
        header_cells = split_table_row(line)
        i += 2 # skip header + divider
        rows = []
        while i < end_i && lines[i].match?(/\A\s*\|.+\|\s*\z/)
          rows << split_table_row(lines[i])
          i += 1
        end
        blocks << build_table(header_cells, rows)
        next
      end

      # Paragraph (collect contiguous non-blank, non-block-starter lines)
      para = [line]
      i += 1
      while i < end_i && !lines[i].strip.empty? && !block_starter?(lines[i])
        para << lines[i]
        i += 1
      end
      blocks << {"type" => "paragraph", "content" => parse_inline(para.join("\n"))}
    end
    blocks
  end

  def block_starter?(line)
    return true if line.match?(/\A\#{1,6}\s/)
    return true if line.match?(/\A[*\-+]\s/)
    return true if line.match?(/\A\d+\.\s/)
    return true if line.start_with?("```") || line.start_with?("~~~")
    return true if line.start_with?(">")
    return true if line.match?(/\A\s*[\*\-_]{3,}\s*\z/)
    return true if line.match?(/\A\s*\|.+\|\s*\z/)
    false
  end

  # Split a `| a | b | c |` row into trimmed cell strings. Drops the
  # leading/trailing empty fields produced by the bordering pipes.
  def split_table_row(line)
    cells = line.strip.sub(/\A\|/, "").sub(/\|\z/, "").split("|", -1)
    cells.map(&:strip)
  end

  def build_table(header_cells, rows)
    header_row = {"type" => "table_row",
                  "content" => header_cells.map { |c| cell("table_header", c) }}
    body_rows = rows.map do |row|
      {"type" => "table_row",
       "content" => row.map { |c| cell("table_cell", c) }}
    end
    {"type" => "table", "content" => [header_row, *body_rows]}
  end

  def cell(type, text)
    inner = parse_inline(text)
    inner = [{"type" => "text", "text" => " "}] if inner.empty?
    {"type" => type, "content" => [{"type" => "paragraph", "content" => inner}]}
  end

  def parse_inline(text)
    nodes = []
    pending = +""
    flush = lambda do
      next if pending.empty?
      nodes << {"type" => "text", "text" => pending.dup}
      pending.clear
    end

    i = 0
    n = text.length
    while i < n
      ch = text[i]
      rest = text[i..]

      # Linear chip: <issue id="UUID">label</issue>
      if (m = rest.match(/\A<issue id="([^"]+)">([^<]*)<\/issue>/))
        flush.call
        nodes << {"type" => "issueMention",
                  "attrs" => {"id" => m[1], "label" => m[2]}}
        i += m[0].length
        next
      end

      # Autolink <https://...> or <http://...>
      if (m = rest.match(/\A<(https?:\/\/[^>\s]+)>/))
        flush.call
        href = m[1]
        nodes << {"type" => "text", "text" => href, "marks" => [{"type" => "link", "attrs" => {"href" => href}}]}
        i += m[0].length
        next
      end

      # Inline code: `text`
      if ch == "`" && (m = rest.match(/\A(`+)([\s\S]+?)\1/)) && !m[2].empty?
        flush.call
        nodes << {"type" => "text", "text" => m[2], "marks" => [{"type" => "code"}]}
        i += m[0].length
        next
      end

      # Link: [text](url) (optionally <url>)
      if ch == "[" && (m = rest.match(/\A\[([^\]]*)\]\(<?([^)\s>]+)>?\)/))
        flush.call
        link_text, href = m[1], m[2]
        inner = parse_inline(link_text)
        inner.each do |x|
          (x["marks"] ||= []) << {"type" => "link", "attrs" => {"href" => href}} if x["type"] == "text"
        end
        nodes.concat(inner)
        i += m[0].length
        next
      end

      # Bold: **text** or __text__
      if (rest.start_with?("**") || rest.start_with?("__"))
        delim = rest[0..1]
        m = rest.match(/\A#{Regexp.escape(delim)}(.+?)#{Regexp.escape(delim)}/m)
        if m && !m[1].empty?
          flush.call
          inner = parse_inline(m[1])
          inner.each do |x|
            (x["marks"] ||= []) << {"type" => "strong"} if x["type"] == "text"
          end
          nodes.concat(inner)
          i += m[0].length
          next
        end
      end

      # Italic: *text* or _text_  (single delimiter, not part of **)
      if (ch == "*" || ch == "_") && text[i + 1] != ch
        m = rest.match(/\A#{Regexp.escape(ch)}([^\n]+?)#{Regexp.escape(ch)}/)
        if m
          flush.call
          inner = parse_inline(m[1])
          inner.each do |x|
            (x["marks"] ||= []) << {"type" => "em"} if x["type"] == "text"
          end
          nodes.concat(inner)
          i += m[0].length
          next
        end
      end

      pending << ch
      i += 1
    end

    flush.call
    coalesce_text(nodes)
  end

  def coalesce_text(nodes)
    out = []
    nodes.each do |n|
      if !out.empty? && out.last["type"] == "text" && n["type"] == "text" &&
         (out.last["marks"] || []) == (n["marks"] || [])
        out.last["text"] += n["text"]
      else
        out << n
      end
    end
    out
  end
end

# ── Body rewriter ─────────────────────────────────────────────────────────────

# Walk a Linear body line by line. Inside fenced ``` blocks, copy
# verbatim. Outside, split each line into prose and inline-code (`x`)
# segments and run replacement passes only on prose. Tracks flags
# when an `#N` pattern can't be resolved (no matching attachment).
#
# Returns [new_body, replacements, flags] where replacements/flags
# are arrays of hashes for the report. `id_to_key` is used to de-chip
# pre-existing `<issue id="UUID">…</issue>` markers from earlier saves.
def rewrite_body(body, team_key, mapping, id_to_key = {})
  return [body, [], []] if body.nil? || body.empty?

  team_repo = "#{REPO_MAP[team_key][:owner]}/#{REPO_MAP[team_key][:repo]}"
  replacements = []
  flags = []
  out_lines = []
  fence_open = false

  body.each_line do |line|
    # Fenced code block (```): toggle and pass through verbatim.
    if line.strip.start_with?("```")
      fence_open = !fence_open
      out_lines << line
      next
    end
    if fence_open
      # Inside a fence — never replace, but flag any `#N` so the
      # operator can decide whether to hand-edit it.
      line.scan(/#\d+/) { |m| flags << { kind: "code-fence", num: m[1..].to_i, context: line.chomp } }
      out_lines << line
      next
    end

    # Outside fences: split by inline-code (`...`). Backticked sections
    # are left alone; non-backticked sections are processed.
    rebuilt = +""
    segments = line.split(/(`[^`\n]*`)/)
    segments.each do |seg|
      if seg.start_with?("`") && seg.end_with?("`") && seg.length >= 2
        # Inline code — flag if it contains a #N (operator decides).
        seg.scan(/#(\d+)/) { |m| flags << { kind: "inline-code", num: m[0].to_i, context: seg } }
        rebuilt << seg
        next
      end

      # Replacement passes on prose:

      # 0) Linear chip remnants `<issue id="UUID">label</issue>` left over
      #    from a previous markdown-path save. Replace with the chip's
      #    plain text identifier so the descriptionData re-save lands
      #    plain text.
      seg = seg.gsub(/<issue id="([^"]+)">([^<]*)<\/issue>/) do
        uuid, label = $1, $2
        target = id_to_key[uuid]
        if target
          replacements << { kind: "chip", uuid: uuid, label: label, to: target }
          target
        else
          flags << { kind: "chip-unmapped", uuid: uuid, label: label, context: $&[0..120] }
          $&
        end
      end

      # 1) Markdown links of the form [text](https://github.com/owner/repo/issues/N)
      seg = seg.gsub(/\[([^\]]*)\]\(<?(https?:\/\/github\.com\/([\w.-]+)\/([\w.-]+)\/issues\/(\d+))>?\)/) do
        link_text, _full, owner, repo, num = $1, $2, $3, $4, $5.to_i
        repo_key = "#{owner}/#{repo}"
        target = mapping.dig(repo_key, num)
        if target
          replacements << { kind: "md-link", num: num, repo: repo_key, to: target, link_text: link_text }
          target
        else
          flags << { kind: "md-link-unmapped", num: num, repo: repo_key, context: $&[0..120] }
          $&
        end
      end

      # 2) Bare full URL https://github.com/owner/repo/issues/N (optionally <...> wrapped)
      seg = seg.gsub(/<?https?:\/\/github\.com\/([\w.-]+)\/([\w.-]+)\/issues\/(\d+)>?/) do
        owner, repo, num = $1, $2, $3.to_i
        repo_key = "#{owner}/#{repo}"
        target = mapping.dig(repo_key, num)
        if target
          replacements << { kind: "bare-url", num: num, repo: repo_key, to: target }
          target
        else
          flags << { kind: "bare-url-unmapped", num: num, repo: repo_key, context: $&[0..120] }
          $&
        end
      end

      # 3) Bare `#N` — assume team's own repo. Negative lookbehind on
      #    word chars and `/` keeps us from matching things like
      #    `URL/path/v1#42`, `name#tag`, etc.
      seg = seg.gsub(/(?<![\w\/])#(\d+)\b/) do
        num = $1.to_i
        target = mapping.dig(team_repo, num)
        if target
          replacements << { kind: "bare-hash", num: num, repo: team_repo, to: target }
          target
        else
          flags << { kind: "bare-hash-unmapped", num: num, context: line.chomp[0..120] }
          $&
        end
      end

      rebuilt << seg
    end

    out_lines << rebuilt
  end

  [out_lines.join, replacements, flags]
end

# ── scan ──────────────────────────────────────────────────────────────────────

def cmd_scan(opts)
  linear = Linear.new
  teams_to_report = opts[:team] ? [opts[:team]] : %w[HMB TBL TFD]

  # Two passes:
  #   - mapping_issues: every issue in every team (all states), used to
  #     build the GH→Linear lookup. Includes closed/done issues so bodies
  #     that cite already-shipped issues still resolve.
  #   - open_issues: open-only, scoped to teams_to_report. These are
  #     the ones we'll actually rewrite.
  warn "[scan] fetching ALL issues across HMB+TBL+TFD for mapping (includes closed)..."
  mapping_issues = []
  %w[HMB TBL TFD].each do |t|
    set = list_issues(linear, t, state_types: nil)
    mapping_issues.concat(set)
    warn "[scan]   #{t}: #{set.size} total"
  end

  mapping = build_mapping(mapping_issues)
  id_to_key = build_id_to_key(mapping_issues)
  warn "[scan] mapping built: #{mapping.values.map(&:size).sum} attachments across #{mapping.size} repos"
  warn "[scan] uuid lookup built: #{id_to_key.size} issues"

  warn "[scan] fetching OPEN issues for rewrite..."
  all_team_issues = {}
  %w[HMB TBL TFD].each do |t|
    all_team_issues[t] = list_issues(linear, t, state_types: OPEN_STATE_TYPES)
    warn "[scan]   #{t}: #{all_team_issues[t].size} open"
  end

  FileUtils.mkdir_p(REPORT_PATH.dirname)
  state = []
  total_changed = 0
  total_flags = 0

  File.open(REPORT_PATH, "w") do |out|
    out.puts "# Linear GH-ref rewrite report"
    out.puts
    out.puts "Generated: #{Time.now.utc.iso8601}"
    out.puts "Teams scanned: #{teams_to_report.join(', ')}"
    out.puts
    out.puts "Add a `# SKIP` line under any `## <KEY>` section to exclude that issue during apply."
    out.puts "Flagged matches are NOT replaced even when the issue is applied."
    out.puts
    out.puts "---"
    out.puts

    teams_to_report.each do |team|
      issues = all_team_issues[team]
      team_changed = 0

      issues.each do |issue|
        original = issue["description"].to_s
        new_body, repls, flags = rewrite_body(original, team, mapping, id_to_key)
        next if repls.empty? && flags.empty?
        next if new_body == original

        total_changed += 1
        team_changed += 1
        total_flags += flags.size

        state << {
          "key"          => issue["identifier"],
          "id"           => issue["id"],
          "team"         => team,
          "original"     => original,
          "proposed"     => new_body,
          "replacements" => repls,
          "flags"        => flags,
        }

        out.puts "## #{issue['identifier']}"
        out.puts
        out.puts "url: https://linear.app/your-workspace/issue/#{issue['identifier']}"
        out.puts "replacements: #{repls.size}"
        out.puts "flags: #{flags.size}"
        out.puts
        out.puts "### Replacements"
        if repls.empty?
          out.puts "(none)"
        else
          repls.each do |r|
            label = case r[:kind]
                    when "md-link"  then "markdown link [text](url)"
                    when "bare-url" then "bare URL"
                    when "bare-hash" then "bare #N"
                    when "chip"     then "Linear chip <issue id>"
                    else r[:kind]
                    end
            ref = r[:kind] == "chip" ? "chip(#{r[:label]})" : "##{r[:num]} (#{r[:repo]})"
            out.puts "- #{label}: #{ref} → #{r[:to]}"
          end
        end
        out.puts
        out.puts "### Flags"
        if flags.empty?
          out.puts "(none)"
        else
          flags.each do |f|
            ctx = (f[:context] || "").gsub(/\s+/, " ").strip
            out.puts "- #{f[:kind]} (##{f[:num]}): `#{ctx[0..120]}`"
          end
        end
        out.puts
        out.puts "---"
        out.puts
      end

      warn "[scan] #{team}: #{team_changed} issues with replacements"
    end
  end

  File.write(STATE_PATH, JSON.pretty_generate({
    "generated_at" => Time.now.utc.iso8601,
    "teams"        => teams_to_report,
    "issues"       => state,
  }))

  puts ""
  puts "report:  #{REPORT_PATH}"
  puts "state:   #{STATE_PATH}"
  puts "issues:  #{total_changed} with replacements"
  puts "flags:   #{total_flags} raised"
end

# ── apply ─────────────────────────────────────────────────────────────────────

# Recursive: sum the length of every `text` node's content in the doc.
# Used as a sanity check before sending descriptionData — if Md2Pm dropped
# a chunk silently, the visible-text length will fall well below the
# source markdown length.
def visible_text_length(node)
  return 0 if node.nil?
  return node["text"].to_s.length if node["type"] == "text"
  Array(node["content"]).sum { |c| visible_text_length(c) }
end

def parse_skips(report_text)
  # Walk sections (`## TBL-…`) and check for a `# SKIP` line within
  # the section before the next `## ` heading.
  skips = []
  current_key = nil
  report_text.each_line do |line|
    if (m = line.match(/\A## (\w{2,4}-\d+)\b/))
      current_key = m[1]
    elsif current_key && line.strip.start_with?("# SKIP")
      skips << current_key
      current_key = nil
    end
  end
  skips.uniq
end

def cmd_apply(opts)
  unless ENV["LINEAR_TPM_AUTHORIZED"] == "1"
    abort <<~MSG
      apply mutates Linear; refusing to run without LINEAR_TPM_AUTHORIZED=1.
      Route through technical-project-manager per HOMEBASE-SOP-013.
    MSG
  end
  unless STATE_PATH.file?
    abort "state file missing: #{STATE_PATH} — run scan first."
  end
  unless REPORT_PATH.file?
    abort "report file missing: #{REPORT_PATH} — run scan first."
  end

  state = JSON.parse(STATE_PATH.read)
  skip_set = parse_skips(REPORT_PATH.read)
  warn "[apply] honoring #{skip_set.size} # SKIP marker(s) in report" if skip_set.any?

  linear = Linear.new
  applied = []
  skipped = []
  failed = []

  state["issues"].each_with_index do |entry, i|
    key = entry["key"]
    team = entry["team"]
    if opts[:team] && team != opts[:team]
      next
    end
    if skip_set.include?(key)
      skipped << { key: key, reason: "operator SKIP" }
      next
    end
    if opts[:dry_run]
      puts "[dry-run] would update #{key} (#{entry['replacements'].size} replacements)"
      applied << key
      next
    end

    begin
      doc = Md2Pm.parse(entry["proposed"])
      # Defensive: if Md2Pm produced a doc whose visible text is
      # dramatically shorter than the input (likely a parser bug
      # silently dropped a block), refuse to mutate that issue.
      ratio = visible_text_length(doc).to_f / entry["proposed"].length
      raise "Md2Pm output too short (#{(ratio * 100).round}% of input) — likely parser miss" if ratio < 0.5

      result = linear.call(ISSUE_UPDATE_MUTATION,
        { id: entry["id"], data: doc },
        mutation: true)
      success = result.dig("issueUpdate", "success")
      raise "issueUpdate returned success=false" unless success
      applied << key
      puts "[ok] #{key} (#{entry['replacements'].size} replacements applied)"
    rescue => e
      failed << { key: key, error: e.message }
      warn "[fail] #{key}: #{e.message}"
    end

    sleep 0.1 if (i + 1) % 10 == 0  # gentle pacing for the API
  end

  File.write(SUMMARY_PATH, <<~MD)
    # Linear GH-ref rewrite — apply summary

    Run: #{Time.now.utc.iso8601}
    Team filter: #{opts[:team] || 'all'}
    Mode: #{opts[:dry_run] ? 'dry-run' : 'live'}

    ## Applied (#{applied.size})

    #{applied.empty? ? '(none)' : applied.map { |k| "- #{k}" }.join("\n")}

    ## Skipped (#{skipped.size})

    #{skipped.empty? ? '(none)' : skipped.map { |s| "- #{s[:key]} — #{s[:reason]}" }.join("\n")}

    ## Failed (#{failed.size})

    #{failed.empty? ? '(none)' : failed.map { |f| "- #{f[:key]} — #{f[:error]}" }.join("\n")}
  MD

  puts ""
  puts "summary: #{SUMMARY_PATH}"
  puts "applied: #{applied.size}  skipped: #{skipped.size}  failed: #{failed.size}"
  exit 1 if failed.any?
end

# ── dispatcher ────────────────────────────────────────────────────────────────

def parse_options(argv, allowed)
  opts = {}
  parser = OptionParser.new do |o|
    o.on("--team KEY", "Restrict to one team (HMB|TBL|TFD)") { |v| opts[:team] = v.upcase }
    o.on("--dry-run", "apply: don't mutate Linear, just report what would happen") { opts[:dry_run] = true }
    o.on("-h", "--help", "Print usage") do
      puts <<~HELP
        Usage:
          linear-rewrite-gh-refs.rb scan  [--team HMB|TBL|TFD]
          linear-rewrite-gh-refs.rb apply [--team HMB|TBL|TFD] [--dry-run]

        Files:
          tmp/linear-gh-rewrite-report.md   — human review, mark sections with `# SKIP`
          tmp/linear-gh-rewrite-state.json  — machine-readable per-issue state (do not edit)
          tmp/linear-gh-rewrite-summary.md  — post-apply summary
      HELP
      exit 0
    end
  end
  parser.parse!(argv)
  opts.select { |k, _| allowed.include?(k) }
end

verb = ARGV.shift
case verb
when "scan"
  cmd_scan(parse_options(ARGV, %i[team]))
when "apply"
  cmd_apply(parse_options(ARGV, %i[team dry_run]))
when nil, "-h", "--help"
  puts "Usage: linear-rewrite-gh-refs.rb {scan|apply} [opts]"
  exit(verb.nil? ? 1 : 0)
else
  warn "unknown verb: #{verb}"
  exit 2
end
