#!/usr/bin/env ruby
# frozen_string_literal: true

# linear.rb — Ruby CLI for HOMEBASE-SOP-013 roadmap glue operations.
#
# Single entry point used by scripts/roadmap/*.sh wrappers.
# Canonical source: ~/code/homebase/scripts/roadmap/linear.rb
#
# Scope: only the operations homebase needs that the Linear MCP plugin and
# Linear's web UI don't naturally cover — bootstrap from canon, surgical
# writes into project.yml, snapshot rendering, canon-drift audit, plus the
# minimal issue read+move surface that `homebase work` (start/checkpoint/
# finish) consumes. Ad-hoc issue/team/project/initiative CRUD outside the
# `homebase work` flow stays in the Linear MCP plugin or the Linear UI.
#
# Usage:
#   linear.rb <verb> [args...]
#
# Read-only verbs (no LINEAR_TPM_AUTHORIZED required):
#   org                                Sanity check; prints org + viewer
#   team list                          List Teams
#   project list [--team KEY]          List Projects (optionally filtered)
#   portfolio [--json]                 Terminal summary of every Project
#   render                             Regenerate registry snapshots
#   audit                              Drift check vs canonical schema
#   issue get <KEY>                    Fetch one issue (id, identifier, state, team, project, labels)
#   issue states <KEY>                 List the team-workflow states for the issue's team
#
# Mutation verbs (LINEAR_TPM_AUTHORIZED=1 required):
#   bootstrap [--dry-run]              Idempotent workspace setup from canon
#   capture <app>                      Refresh Linear IDs into <project>/.homebase/project.yml
#   issue move <KEY> <STATE_NAME>      Transition an issue to a workflow state
#
# Credentials: LINEAR_API_KEY env var, or `LINEAR_API_KEY=...` line in
# ~/.config/homebase/env (chmod 600 recommended).

require "net/http"
require "uri"
require "json"
require "yaml"
require "pathname"
require "optparse"
require "time"
require "fileutils"

HOMEBASE_ROOT = Pathname.new(__dir__).expand_path.parent.parent
ENDPOINT = URI("https://api.linear.app/graphql")
ENV_FILE = Pathname.new("~/.config/homebase/env").expand_path
ENV_VAR = "LINEAR_API_KEY"
MUTATE_DELAY = 1.0
MAX_RETRIES = 3

CANONICAL_LABELS = %w[roadmap p0 p1 p2 p3 blocked].freeze

# ── Canonical topology ─────────────────────────────────────────────────────────
#
# MUST match standards/LINEAR_WORKSPACE.md § Teams and § Projects.
# Editing these requires updating the standards doc in the same commit.

CANONICAL_TEAMS = [
  { key: "TBL", name: "Studio",
    description: "Example holding company — several brands publishing distinct products." },
  { key: "TFD", name: "Field Suite",
    description: "Suite of apps for the scuba diving industry across iOS, Android, and web." },
  { key: "HMB", name: "Homebase",
    description: "The company itself — CLI, SOPs, standards, governance, agents, skills." }
].freeze

# One Linear Project per app, living inside its monorepo's Team.
CANONICAL_PROJECTS = {
  # Studio
  "studio-web"    => { team_key: "TBL", name: "StudioWeb",     owner: "example-product-pm" },
  "bookshelf"   => { team_key: "TBL", name: "Bookshelf",  owner: "example-product-pm" },
  "capture"         => { team_key: "TBL", name: "Capture",          owner: "example-product-pm" },
  "blog"          => { team_key: "TBL", name: "Blog",          owner: "example-product-pm" },
  "briefing"         => { team_key: "TBL", name: "Briefing",          owner: "example-product-pm" },
  "authoring"     => { team_key: "TBL", name: "Authoring",      owner: "example-product-pm" },
  # Field Suite
  "gascalc"       => { team_key: "TFD", name: "GasCalc",        owner: "diving-product-manager" },
  "logapp"        => { team_key: "TFD", name: "LogApp",         owner: "diving-product-manager" },
  "link-companion"   => { team_key: "TFD", name: "Link Companion",    owner: "diving-product-manager" },
  "photofix"        => { team_key: "TFD", name: "PhotoFix",         owner: "diving-product-manager" },
  "shopos"   => { team_key: "TFD", name: "ShopOS",    owner: "diving-product-manager" },
  "sitedb"    => { team_key: "TFD", name: "SiteDB",     owner: "diving-product-manager" },
  # Homebase
  "homebase"     => { team_key: "HMB", name: "Homebase",      owner: "technical-project-manager" }
}.freeze

# ── Helpers ────────────────────────────────────────────────────────────────────

def die(msg, code = 2)
  warn msg
  exit code
end

def info(msg)
  warn "[linear] #{msg}"
end

def require_authorization!(verb_path)
  return if ENV["LINEAR_TPM_AUTHORIZED"] == "1"

  die <<~MSG, 3
    #{verb_path} is a mutation; refusing to run without LINEAR_TPM_AUTHORIZED=1.
    Route through technical-project-manager per HOMEBASE-SOP-013.
  MSG
end

# ── Linear client ──────────────────────────────────────────────────────────────

class Linear
  def initialize
    @api_key = load_key
    @last_mutation = 0.0
    @verbose = ENV["LINEAR_VERBOSE"] == "1"
  end

  def call(query, variables = {}, mutation: false)
    if mutation
      elapsed = Time.now.to_f - @last_mutation
      sleep(MUTATE_DELAY - elapsed) if elapsed < MUTATE_DELAY
    end

    attempt = 0
    loop do
      response = do_post(query, variables)
      body = response.body
      parsed = (JSON.parse(body) rescue nil)

      if response.code == "200" && parsed
        errors = parsed["errors"]
        if errors && errors.any? { |e| (e.dig("extensions", "code") || "").to_s.upcase.include?("RATELIMITED") }
          attempt += 1
          die("Linear rate-limited after #{MAX_RETRIES} retries") if attempt > MAX_RETRIES
          sleep(2 ** attempt)
          next
        end
        if errors && !errors.empty?
          die "Linear GraphQL error: #{errors.inspect}"
        end
        @last_mutation = Time.now.to_f if mutation
        return parsed["data"]
      end

      if response.code == "429"
        attempt += 1
        die("Linear 429 after #{MAX_RETRIES} retries") if attempt > MAX_RETRIES
        sleep(2 ** attempt)
        next
      end

      die "Linear HTTP #{response.code}: #{body[0..400]}"
    end
  end

  private

  def do_post(query, variables)
    body = { query: query, variables: variables }.to_json
    http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port)
    http.use_ssl = true
    http.read_timeout = 30
    http.open_timeout = 10

    req = Net::HTTP::Post.new(ENDPOINT)
    req["Authorization"] = @api_key
    req["Content-Type"] = "application/json"
    req.body = body

    warn "[linear] POST #{ENDPOINT} (#{body.bytesize}B)" if @verbose
    http.request(req)
  end

  def load_key
    env_val = ENV[ENV_VAR]
    return env_val if env_val && !env_val.empty?

    unless ENV_FILE.file?
      die <<~MSG
        Linear API key not found.
          - ENV[#{ENV_VAR}] is empty, and
          - #{ENV_FILE} does not exist.
        Create #{ENV_FILE} with a line `#{ENV_VAR}=<your-key>` (chmod 600).
      MSG
    end

    ENV_FILE.each_line do |line|
      line = line.strip
      next if line.empty? || line.start_with?("#")
      next unless line =~ /\A#{Regexp.escape(ENV_VAR)}\s*=\s*(.+)\z/
      value = $1.strip
      value = value.sub(/\A"(.*)"\z/, '\1').sub(/\A'(.*)'\z/, '\1')
      return value unless value.empty?
    end

    die "#{ENV_VAR} not found in #{ENV_FILE}. Add a line `#{ENV_VAR}=<your-key>`."
  end
end

# ── Queries + the two mutations we still own ───────────────────────────────────

module LinearQ
  def self.organization
    "query { organization { id name urlKey } viewer { id name email } }"
  end

  def self.teams
    "query { teams(first: 100) { nodes { id key name description } } }"
  end

  def self.team_labels
    "query($teamId: String!) { team(id: $teamId) { labels(first: 200) { nodes { id name } } } }"
  end

  def self.team_projects
    "query($teamId: String!) { team(id: $teamId) { projects(first: 200) { nodes { id name description state } } } }"
  end

  def self.projects_all
    "query { projects(first: 500) { nodes { id name description state teams(first: 5) { nodes { id key } } } } }"
  end

  def self.project_milestones
    "query($projectId: String!) { project(id: $projectId) { projectMilestones(first: 200) { nodes { id name description targetDate sortOrder } } } }"
  end

  def self.initiatives
    "query { initiatives(first: 100) { nodes { id name description } } }"
  end

  # Bootstrap-only mutations (the one time we care about creating Linear
  # entities from the canon). Everything else is MCP / UI.
  def self.team_create
    <<~G
      mutation($name: String!, $key: String!, $description: String) {
        teamCreate(input: { name: $name, key: $key, description: $description }) {
          success
          team { id key name description }
        }
      }
    G
  end

  def self.label_create
    <<~G
      mutation($teamId: String!, $name: String!) {
        issueLabelCreate(input: { teamId: $teamId, name: $name }) {
          success
          issueLabel { id name }
        }
      }
    G
  end

  def self.project_create
    <<~G
      mutation($teamIds: [String!]!, $name: String!, $description: String, $state: String) {
        projectCreate(input: { teamIds: $teamIds, name: $name, description: $description, state: $state }) {
          success
          project { id name state }
        }
      }
    G
  end

  # Issue queries — Linear's issue(id:) accepts both UUID and identifier
  # (e.g. "HMB-8"), so callers pass the human-readable form.
  def self.issue_by_identifier
    <<~G
      query($id: String!) {
        issue(id: $id) {
          id
          identifier
          title
          url
          state { id name type }
          team { id key name }
          project { id name }
          labels(first: 50) { nodes { id name } }
          description
        }
      }
    G
  end

  def self.team_workflow_states
    <<~G
      query($teamId: String!) {
        team(id: $teamId) {
          id key name
          states(first: 100) { nodes { id name type position } }
        }
      }
    G
  end

  # Issue mutation — move to a named workflow state. Resolution of state
  # name → state id happens in the command (cmd_issue_move) so we can fail
  # with a list of valid names.
  def self.issue_state_update
    <<~G
      mutation($id: String!, $stateId: String!) {
        issueUpdate(id: $id, input: { stateId: $stateId }) {
          success
          issue { id identifier state { id name } }
        }
      }
    G
  end
end

# ── Read-only commands ─────────────────────────────────────────────────────────

def cmd_org(linear)
  puts JSON.pretty_generate(linear.call(LinearQ.organization))
end

def cmd_team_list(linear)
  nodes = linear.call(LinearQ.teams).dig("teams", "nodes") || []
  if nodes.empty?
    puts "(no teams yet)"
    return
  end
  printf("%-5s %-24s %s\n", "KEY", "NAME", "ID")
  nodes.sort_by { |t| t["key"] }.each do |t|
    printf("%-5s %-24s %s\n", t["key"], t["name"], t["id"])
  end
end

def cmd_project_list(linear, team_key: nil)
  nodes = (linear.call(LinearQ.projects_all).dig("projects", "nodes") || [])
  if team_key
    nodes = nodes.select { |p| (p["teams"]["nodes"] || []).any? { |t| t["key"] == team_key } }
  end
  if nodes.empty?
    puts "(no projects#{team_key ? " in team #{team_key}" : ""})"
    return
  end
  printf("%-5s %-26s %-10s %s\n", "TEAM", "NAME", "STATE", "ID")
  nodes.sort_by { |p| [(p["teams"]["nodes"].first || {})["key"] || "", p["name"]] }.each do |p|
    team = (p["teams"]["nodes"].first || {})["key"] || "—"
    printf("%-5s %-26s %-10s %s\n", team, p["name"], p["state"] || "—", p["id"])
  end
end

def cmd_portfolio(linear, json: false)
  teams = linear.call(LinearQ.teams).dig("teams", "nodes") || []
  rows = teams.sort_by { |t| t["key"] }.flat_map do |t|
    projects = linear.call(LinearQ.team_projects, { "teamId" => t["id"] }).dig("team", "projects", "nodes") || []
    if projects.empty?
      [{ "team" => t["key"], "name" => t["name"], "project" => "(no projects)", "state" => "—", "active_milestones" => 0 }]
    else
      projects.sort_by { |p| p["name"] }.map do |p|
        ms = linear.call(LinearQ.project_milestones, { "projectId" => p["id"] }).dig("project", "projectMilestones", "nodes") || []
        { "team" => t["key"], "name" => t["name"], "project" => p["name"], "state" => p["state"], "active_milestones" => ms.size }
      end
    end
  end

  if json
    puts JSON.pretty_generate(rows)
    return
  end

  printf("%-5s %-22s %-22s %-10s %s\n", "TEAM", "MONOREPO", "PROJECT", "STATE", "MILESTONES")
  rows.each do |r|
    printf("%-5s %-22s %-22s %-10s %d\n", r["team"], r["name"], r["project"], r["state"] || "—", r["active_milestones"])
  end
end

# ── Bootstrap (canon-driven; idempotent) ───────────────────────────────────────

def cmd_bootstrap(linear, dry_run:)
  require_authorization!("bootstrap") unless dry_run

  live_teams = linear.call(LinearQ.teams).dig("teams", "nodes") || []
  by_key = live_teams.each_with_object({}) { |t, h| h[t["key"]] = t }

  plan = []
  CANONICAL_TEAMS.each do |t|
    live = by_key[t[:key]]
    step = { kind: :team, key: t[:key], name: t[:name], description: t[:description], actions: [] }

    if live
      step[:team_id] = live["id"]
      step[:actions] << { type: :team_skip }

      existing_labels = (linear.call(LinearQ.team_labels, { "teamId" => live["id"] }).dig("team", "labels", "nodes") || []).map { |l| l["name"] }
      CANONICAL_LABELS.each do |label|
        step[:actions] << (existing_labels.include?(label) ? { type: :label_skip, name: label } : { type: :label_create, name: label })
      end

      existing_projects = (linear.call(LinearQ.team_projects, { "teamId" => live["id"] }).dig("team", "projects", "nodes") || [])
      existing_project_names = existing_projects.map { |p| p["name"] }
      CANONICAL_PROJECTS.select { |_, p| p[:team_key] == t[:key] }.each do |slug, p|
        if existing_project_names.include?(p[:name])
          step[:actions] << { type: :project_skip, slug: slug, name: p[:name] }
        else
          step[:actions] << { type: :project_create, slug: slug, name: p[:name] }
        end
      end
    else
      step[:actions] << { type: :team_create, name: t[:name], key: t[:key], description: t[:description] }
      CANONICAL_LABELS.each { |label| step[:actions] << { type: :label_create, name: label } }
      CANONICAL_PROJECTS.select { |_, p| p[:team_key] == t[:key] }.each do |slug, p|
        step[:actions] << { type: :project_create, slug: slug, name: p[:name] }
      end
    end

    plan << step
  end

  if dry_run
    print_plan(plan)
    puts
    puts "dry-run complete. Re-run without --dry-run to execute."
    return
  end

  plan.each do |step|
    team_id = step[:team_id]
    step[:actions].each do |action|
      case action[:type]
      when :team_create
        info "teamCreate: #{action[:name]} (#{action[:key]})"
        r = linear.call(LinearQ.team_create,
                        { "name" => action[:name], "key" => action[:key], "description" => action[:description] },
                        mutation: true).dig("teamCreate")
        die "teamCreate failed for #{action[:key]}: #{r.inspect}" unless r && r["success"]
        team_id = r["team"]["id"]
        step[:team_id] = team_id
      when :label_create
        info "labelCreate: #{step[:key]} / #{action[:name]}"
        r = linear.call(LinearQ.label_create, { "teamId" => team_id, "name" => action[:name] }, mutation: true).dig("issueLabelCreate")
        die "labelCreate failed: #{action.inspect}" unless r && r["success"]
      when :project_create
        info "projectCreate: #{step[:key]} / #{action[:name]} (#{action[:slug]})"
        r = linear.call(LinearQ.project_create,
                        { "teamIds" => [team_id], "name" => action[:name],
                          "description" => "Long-lived Project for the #{action[:name]} app. Releases tracked as Milestones inside this Project.",
                          "state" => "started" },
                        mutation: true).dig("projectCreate")
        die "projectCreate failed: #{action.inspect}" unless r && r["success"]
      when :team_skip, :label_skip, :project_skip
        # no-op
      end
    end
  end

  puts
  puts "Bootstrap complete. Next steps:"
  puts "  1. `homebase roadmap capture <app>` for each registered app."
  puts "  2. `homebase roadmap render` to regenerate the registry snapshots."
end

def print_plan(plan)
  puts "─── HOMEBASE-SOP-013 Bootstrap Plan ───────────────────────────────────────"
  puts
  plan.each do |step|
    puts "TEAM  #{step[:key].ljust(4)} #{step[:name]}"
    puts "      #{step[:description]}" if step[:description]
    step[:actions].each do |a|
      case a[:type]
      when :team_create    then puts "  + create team"
      when :team_skip      then puts "  ✓ team exists"
      when :label_create   then puts "  + label    #{a[:name]}"
      when :label_skip     then puts "  ✓ label    #{a[:name]}"
      when :project_create then puts "  + project  #{a[:name]} (#{a[:slug]})"
      when :project_skip   then puts "  ✓ project  #{a[:name]} (#{a[:slug]})"
      end
    end
    puts
  end
  puts "──────────────────────────────────────────────────────────────────────────"
end

# ── Capture (writes Linear IDs into project.yml via surgical text insert) ──────

def cmd_capture(linear, app_slug)
  require_authorization!("capture")

  canon = CANONICAL_PROJECTS[app_slug]
  die "'#{app_slug}' is not in CANONICAL_PROJECTS (see standards/LINEAR_WORKSPACE.md)" unless canon

  teams = linear.call(LinearQ.teams).dig("teams", "nodes") || []
  team = teams.find { |t| t["key"] == canon[:team_key] }
  die "no Linear team with key=#{canon[:team_key]}; run `homebase roadmap bootstrap` first" unless team

  projects = linear.call(LinearQ.team_projects, { "teamId" => team["id"] }).dig("team", "projects", "nodes") || []
  project = projects.find { |p| p["name"] == canon[:name] }
  die "no Linear project '#{canon[:name]}' under team #{canon[:team_key]}; run `homebase roadmap bootstrap` first" unless project

  paths = find_project_yamls_containing_app(app_slug)
  if paths.empty?
    info "no project.yml declares app='#{app_slug}' (fine for unregistered apps like homebase)"
    return
  end

  paths.each do |path|
    doc = YAML.load_file(path)
    app_entry = doc["apps"].find { |a| a["name"] == app_slug }
    die "#{path}: apps[] entry for '#{app_slug}' not found" unless app_entry

    data = {
      "enabled" => true,
      "linear_team_key" => team["key"],
      "linear_team_id" => team["id"],
      "linear_project_id" => project["id"],
      "owner_agent" => canon[:owner]
    }
    surgical_insert_roadmap(path, app_slug, data)
    info "updated #{path}: roadmap.linear_project_id = #{project['id']}"
  end
end

# Insert/replace the `roadmap:` block inside the named app's entry without
# rewriting the rest of the YAML file. Preserves quoting, inline arrays,
# comments, and indentation style.
def surgical_insert_roadmap(path, app_slug, data)
  lines = File.read(path).split("\n", -1)

  start_idx = lines.index { |l| l =~ /\A\s*-\s+name:\s*["']?#{Regexp.escape(app_slug)}["']?\s*\z/ }
  die "#{path}: could not find `- name: #{app_slug}` line" unless start_idx

  entry_dash_indent = lines[start_idx][/\A(\s*)-/, 1]

  field_indent = nil
  (start_idx + 1...lines.size).each do |i|
    next if lines[i].strip.empty?
    if lines[i] =~ /\A(\s+)\S/
      field_indent = Regexp.last_match(1)
      break
    end
  end
  field_indent ||= entry_dash_indent + "  "

  end_idx = lines.size
  (start_idx + 1...lines.size).each do |i|
    line = lines[i]
    next if line.strip.empty?
    m = line.match(/\A(\s*)(\S)/)
    next unless m
    if m[1].length <= entry_dash_indent.length
      end_idx = i
      break
    end
  end

  roadmap_idx = nil
  (start_idx + 1...end_idx).each do |i|
    if lines[i] =~ /\A#{Regexp.escape(field_indent)}roadmap:\s*\z/
      roadmap_idx = i
      break
    end
  end

  replace_end = roadmap_idx
  if roadmap_idx
    replace_end = end_idx
    (roadmap_idx + 1...end_idx).each do |i|
      next if lines[i].strip.empty?
      m = lines[i].match(/\A(\s*)\S/)
      next unless m
      if m[1].length <= field_indent.length
        replace_end = i
        break
      end
    end
  end

  new_block = format_roadmap_block(field_indent, data)

  if roadmap_idx
    lines[roadmap_idx...replace_end] = new_block
  else
    insert_at = end_idx
    insert_at -= 1 while insert_at > start_idx + 1 && lines[insert_at - 1].strip.empty?
    lines.insert(insert_at, *new_block)
  end

  File.write(path, lines.join("\n"))
end

def format_roadmap_block(indent, data)
  sub = indent + "  "
  subsub = sub + "  "
  [
    "#{indent}roadmap:",
    "#{sub}enabled: #{data['enabled']}",
    "#{sub}linear_team_key: #{data['linear_team_key']}",
    "#{sub}linear_team_id: #{data['linear_team_id']}",
    "#{sub}linear_project_id: #{data['linear_project_id']}",
    "#{sub}owner_agent: #{data['owner_agent']}",
    "#{sub}github_sync:",
    "#{subsub}auto_create_issues: true",
    "#{subsub}auto_close_on_pr_merge: true"
  ]
end

def find_project_yamls_containing_app(app_slug)
  paths_file = HOMEBASE_ROOT / "registry" / "projects.paths"
  die "missing #{paths_file}" unless paths_file.file?
  out = []
  paths_file.each_line do |line|
    line = line.strip
    next if line.empty? || line.start_with?("#")
    ymlfile = Pathname.new(line).expand_path / ".homebase" / "project.yml"
    next unless ymlfile.file?
    doc = YAML.load_file(ymlfile)
    next unless doc.is_a?(Hash) && doc["apps"].is_a?(Array)
    out << ymlfile if doc["apps"].any? { |a| a["name"] == app_slug }
  end
  out
end

# ── Render ─────────────────────────────────────────────────────────────────────

def cmd_render(linear)
  teams = linear.call(LinearQ.teams).dig("teams", "nodes") || []
  initiatives = linear.call(LinearQ.initiatives).dig("initiatives", "nodes") || []

  team_snapshots = teams.sort_by { |t| t["key"] }.map do |t|
    projects = linear.call(LinearQ.team_projects, { "teamId" => t["id"] }).dig("team", "projects", "nodes") || []
    project_rows = projects.sort_by { |p| p["name"] }.map do |p|
      milestones = linear.call(LinearQ.project_milestones, { "projectId" => p["id"] }).dig("project", "projectMilestones", "nodes") || []
      {
        "id" => p["id"],
        "name" => p["name"],
        "state" => p["state"],
        "milestones" => milestones.sort_by { |m| [m["sortOrder"] || 0, m["name"]] }.map do |m|
          { "id" => m["id"], "name" => m["name"], "target_date" => m["targetDate"] }
        end
      }
    end
    { "key" => t["key"], "name" => t["name"], "id" => t["id"], "projects" => project_rows }
  end

  snapshot = {
    "generated_at" => Time.now.utc.iso8601,
    "teams" => team_snapshots,
    "initiatives" => initiatives.sort_by { |i| i["name"] }.map do |i|
      { "id" => i["id"], "name" => i["name"], "description" => i["description"] }
    end
  }

  snap_path = HOMEBASE_ROOT / "registry" / "roadmap-snapshot.yml"
  FileUtils.mkdir_p(snap_path.parent)
  File.write(snap_path, snapshot.to_yaml)
  info "wrote #{snap_path}"

  File.write(HOMEBASE_ROOT / "registry" / "ROADMAP.md", render_markdown(snapshot))
  info "wrote #{HOMEBASE_ROOT / 'registry' / 'ROADMAP.md'}"
end

def render_markdown(snap)
  lines = []
  lines << "# Roadmap Portfolio"
  lines << ""
  lines << "Generated by `homebase roadmap render` from the canonical Linear workspace."
  lines << "Do not hand-edit — edit Linear and re-run the render."
  lines << ""
  lines << "Last updated: `#{snap['generated_at']}`"
  lines << ""

  snap["teams"].each do |team|
    lines << "## #{team['name']} (`#{team['key']}`)"
    lines << ""
    if team["projects"].empty?
      lines << "_No Projects._"
      lines << ""
      next
    end
    team["projects"].each do |project|
      lines << "### #{project['name']}"
      lines << ""
      lines << "State: `#{project['state']}`"
      lines << ""
      if project["milestones"].any?
        lines << "Releases:"
        project["milestones"].each do |m|
          tgt = m["target_date"] ? " — target #{m['target_date']}" : ""
          lines << "- #{m['name']}#{tgt}"
        end
        lines << ""
      else
        lines << "_No releases planned yet._"
        lines << ""
      end
    end
  end

  if snap["initiatives"].any?
    lines << "## Initiatives"
    lines << ""
    snap["initiatives"].each do |i|
      lines << "- **#{i['name']}**#{ i['description'] ? " — #{i['description']}" : '' }"
    end
    lines << ""
  end

  lines.join("\n") + "\n"
end

# ── Audit ──────────────────────────────────────────────────────────────────────

def cmd_audit(linear)
  errors = []
  warnings = []

  live_teams = linear.call(LinearQ.teams).dig("teams", "nodes") || []
  live_keys = live_teams.map { |t| t["key"] }.sort
  canon_keys = CANONICAL_TEAMS.map { |t| t[:key] }.sort

  (canon_keys - live_keys).each { |k| errors << "missing canonical team: #{k}" }
  (live_keys - canon_keys).each { |k| warnings << "live team off-canon: #{k}" }

  live_teams.each do |t|
    labels = (linear.call(LinearQ.team_labels, { "teamId" => t["id"] }).dig("team", "labels", "nodes") || []).map { |l| l["name"] }
    (CANONICAL_LABELS - labels).each { |l| errors << "team #{t['key']} missing label: #{l}" }

    projects = (linear.call(LinearQ.team_projects, { "teamId" => t["id"] }).dig("team", "projects", "nodes") || []).map { |p| p["name"] }
    expected = CANONICAL_PROJECTS.select { |_, p| p[:team_key] == t["key"] }.map { |_, p| p[:name] }
    (expected - projects).each { |p| errors << "team #{t['key']} missing project: #{p}" }
    (projects - expected).each { |p| warnings << "team #{t['key']} has off-canon project: #{p}" }
  end

  puts "=== SOP-013 Audit ==="
  puts errors.empty? ? "errors:   (none)" : "errors:"
  errors.each { |e| puts "  ✗ #{e}" }
  if warnings.any?
    puts "warnings:"
    warnings.each { |w| puts "  ! #{w}" }
  end
  exit(errors.empty? ? 0 : 1)
end

# ── Issue commands ─────────────────────────────────────────────────────────────

def cmd_issue_get(linear, key)
  data = linear.call(LinearQ.issue_by_identifier, { "id" => key })
  issue = data["issue"]
  die("issue #{key} not found", 1) unless issue
  puts JSON.generate(issue)
end

def cmd_issue_states(linear, key)
  issue_data = linear.call(LinearQ.issue_by_identifier, { "id" => key })
  issue = issue_data["issue"]
  die("issue #{key} not found", 1) unless issue
  team_id = issue.dig("team", "id")
  die("issue #{key} has no team — Linear returned a malformed response", 1) unless team_id
  team_data = linear.call(LinearQ.team_workflow_states, { "teamId" => team_id })
  nodes = team_data.dig("team", "states", "nodes") || []
  nodes.sort_by! { |n| n["position"].to_f }
  nodes.each do |n|
    puts JSON.generate(n)
  end
end

def cmd_issue_move(linear, key, target_state_name)
  require_authorization!("issue move")
  issue_data = linear.call(LinearQ.issue_by_identifier, { "id" => key })
  issue = issue_data["issue"]
  die("issue #{key} not found", 1) unless issue
  team_id = issue.dig("team", "id")
  die("issue #{key} has no team", 1) unless team_id
  team_data = linear.call(LinearQ.team_workflow_states, { "teamId" => team_id })
  states = team_data.dig("team", "states", "nodes") || []
  match = states.find { |s| s["name"] == target_state_name }
  unless match
  available = states.map { |s| s["name"] }.join(", ")
    die("state '#{target_state_name}' not found in team #{issue.dig("team", "key")}. Available: #{available}", 1)
  end
  if issue.dig("state", "id") == match["id"]
    info "issue #{key} already in state '#{target_state_name}' — no-op"
    puts JSON.generate(issue)
    return
  end
  resp = linear.call(LinearQ.issue_state_update, { "id" => issue["id"], "stateId" => match["id"] }, mutation: true)
  result = resp["issueUpdate"]
  die("issueUpdate returned no success", 1) unless result && result["success"]
  puts JSON.generate(result["issue"])
end

# ── Dispatch ───────────────────────────────────────────────────────────────────

# Only run the top-level dispatcher when this file is the entrypoint.
# When required by another script (e.g. linear-rewrite-gh-refs.rb,
# HMB-25), we just want to load the `Linear` client class without
# consuming ARGV or exiting.
if $PROGRAM_NAME == __FILE__

verb = ARGV.shift || "help"
args = ARGV

case verb
when "org"
  cmd_org(Linear.new)
when "team"
  sub = args.shift || "help"
  if sub == "list"
    cmd_team_list(Linear.new)
  else
    die "unknown: team #{sub} (individual team mutations live in Linear MCP / Linear UI)"
  end
when "project"
  sub = args.shift
  if sub == "list"
    team_key = nil
    OptionParser.new { |o| o.on("--team KEY") { |v| team_key = v } }.parse!(args)
    cmd_project_list(Linear.new, team_key: team_key)
  else
    die "unknown: project #{sub} (individual project mutations live in Linear MCP / Linear UI)"
  end
when "bootstrap"
  dry_run = false
  OptionParser.new { |o| o.on("--dry-run") { dry_run = true } }.parse!(args)
  cmd_bootstrap(Linear.new, dry_run: dry_run)
when "capture"
  app = args.shift
  die "usage: linear capture <app>" unless app
  cmd_capture(Linear.new, app)
when "render"
  cmd_render(Linear.new)
when "audit"
  cmd_audit(Linear.new)
when "portfolio"
  json = args.include?("--json")
  cmd_portfolio(Linear.new, json: json)
when "issue"
  sub = args.shift
  case sub
  when "get"
    key = args.shift
    die "usage: linear issue get <KEY>" unless key
    cmd_issue_get(Linear.new, key)
  when "states"
    key = args.shift
    die "usage: linear issue states <KEY>" unless key
    cmd_issue_states(Linear.new, key)
  when "move"
    key = args.shift
    state_name = args.shift
    die "usage: linear issue move <KEY> <STATE_NAME>" unless key && state_name
    cmd_issue_move(Linear.new, key, state_name)
  else
    die "unknown: issue #{sub} (subverbs: get | states | move)"
  end
when "help", "-h", "--help"
  puts File.read(__FILE__).lines.select { |l| l.start_with?("#") }.take(45).join
else
  die "unknown verb: #{verb} (for individual mutations: use Linear MCP plugin or Linear web UI)"
end

end  # if $PROGRAM_NAME == __FILE__
