#!/usr/bin/env ruby
# resolve.rb — resolve an app slug + env to a deploy-ready blob of shell assignments.
#
# Usage:
#   resolve.rb <homebase_root> <app_slug> <env_name>
#
# Emits shell assignments to stdout, Shellwords-escaped so callers can `eval`:
#
#   HB_PROJECT_PATH=/abs/path/to/project
#   HB_APP_PATH=/abs/path/to/project/apps/studio-web
#   HB_APP_NAME=studio-web
#   HB_ENV_NAME=production
#   HB_IMAGE=ghcr.io/acme-co/studio-web
#   HB_BRANCH=main
#   HB_VALIDATE=bin/ci
#   HB_VERSION_FILE_PATH=config/initializers/version.rb
#   HB_VERSION_FILE_LANGUAGE=ruby
#   HB_VERSION_FILE_SYMBOL=StudioWeb::VERSION
#   HB_KAMAL_CONFIG=config/deploy.production.yml
#   HB_SECRETS_FILE=.kamal/secrets.production
#   HB_TRAEFIK_HOST=studio-web.example.com
#   HB_HEALTH_URL=https://studio-web.example.com/up
#   HB_HOSTS='198.51.100.10 198.51.100.11'
#
# Resolution walks registry/projects.paths → each project's .homebase/project.yml,
# finding the app by name or alias (case-insensitive). Exits 2 on missing app,
# missing deploy stanza, or missing env.

require "yaml"
require "pathname"
require "shellwords"

def die(msg)
  warn "resolve: #{msg}"
  exit 2
end

die "usage: resolve.rb <homebase_root> <app_slug> <env_name>" unless ARGV.length == 3

homebase = Pathname.new(ARGV[0]).expand_path
slug = ARGV[1]
env_name = ARGV[2]

paths_file = homebase / "registry" / "projects.paths"
die "missing: #{paths_file}" unless paths_file.file?

paths = paths_file.each_line.map(&:strip).reject { |l| l.empty? || l.start_with?("#") }

match = nil

paths.each do |p|
  yml = Pathname.new(p) / ".homebase" / "project.yml"
  next unless yml.file?
  doc = YAML.safe_load(yml.read, permitted_classes: [], aliases: false)
  next unless doc.is_a?(Hash) && doc["apps"].is_a?(Array)

  doc["apps"].each do |app|
    next unless app.is_a?(Hash)
    aliases = app["aliases"].is_a?(Array) ? app["aliases"] : []
    names = [app["name"]] + aliases
    if names.any? { |n| n.to_s.downcase == slug.downcase }
      match = { project_path: Pathname.new(p).expand_path, app: app }
      break
    end
  end
  break if match
end

die "app '#{slug}' not found in any registered project" unless match

app = match[:app]
deploy = app["deploy"]
die "app '#{slug}' has no deploy: stanza — see standards/RAILS_PLAYBOOK.md" unless deploy.is_a?(Hash)

envs = deploy["envs"]
die "deploy.envs is missing for '#{slug}'" unless envs.is_a?(Hash) && !envs.empty?

env = envs[env_name]
die "env '#{env_name}' not in deploy.envs for '#{slug}' (have: #{envs.keys.join(', ')})" unless env.is_a?(Hash)

version_file = deploy["version_file"]
die "version_file missing for '#{slug}'" unless version_file.is_a?(Hash)

project_path = match[:project_path]
app_path = app["path"] == "." ? project_path : (project_path / app["path"]).expand_path

hosts = env["hosts"].is_a?(Array) ? env["hosts"].join(" ") : ""
secrets_file = env["secrets_file"] || ".kamal/secrets.#{env_name}"

out = {
  "HB_PROJECT_PATH"          => project_path.to_s,
  "HB_APP_PATH"              => app_path.to_s,
  "HB_APP_NAME"              => app["name"].to_s,
  "HB_ENV_NAME"              => env_name,
  "HB_IMAGE"                 => deploy["image"].to_s,
  "HB_BRANCH"                => deploy.fetch("branch", "main"),
  "HB_VALIDATE"              => deploy.fetch("validate", "bin/ci"),
  "HB_VERSION_FILE_PATH"     => version_file["path"].to_s,
  "HB_VERSION_FILE_LANGUAGE" => version_file["language"].to_s,
  "HB_VERSION_FILE_SYMBOL"   => version_file["symbol"].to_s,
  "HB_KAMAL_CONFIG"          => env["kamal_config"].to_s,
  "HB_SECRETS_FILE"          => secrets_file,
  "HB_TRAEFIK_HOST"          => env["traefik_host"].to_s,
  "HB_HEALTH_URL"            => env["health_url"].to_s,
  "HB_HOSTS"                 => hosts
}

out.each do |k, v|
  puts "#{k}=#{Shellwords.escape(v)}"
end
