#!/usr/bin/env ruby
# bump_version.rb — read or write a SemVer constant in a version file.
#
# Usage:
#   bump_version.rb read  <path> <language>
#   bump_version.rb write <path> <language> <new_version>
#
# Languages:
#   ruby   — matches `VERSION = "X.Y.Z"` (with or without a containing module)
#   go     — matches `Version = "X.Y.Z"` (const or var; package-level)
#
# On `read`, prints the current version to stdout.
# On `write`, rewrites the file in place and prints the new version.
#
# Exits 2 on usage error, missing file, or unparseable version.

require "pathname"

SEMVER_RX = /\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?/

def die(msg)
  warn "bump_version: #{msg}"
  exit 2
end

def rx_for(language)
  case language
  when "ruby"
    /(VERSION\s*=\s*")(#{SEMVER_RX})(")/
  when "go"
    /(Version\s*=\s*")(#{SEMVER_RX})(")/
  else
    die "unsupported language: #{language}"
  end
end

mode = ARGV[0]
die "usage: bump_version.rb read|write <path> <language> [new_version]" unless %w[read write].include?(mode)

path = ARGV[1] or die "path required"
language = ARGV[2] or die "language required (ruby|go)"
new_version = ARGV[3] if mode == "write"

if mode == "write"
  die "new_version required for write" if new_version.nil? || new_version.empty?
  die "invalid new_version: #{new_version}" unless new_version =~ /\A#{SEMVER_RX}\z/
end

file = Pathname.new(path)
die "file not found: #{path}" unless file.file?
content = file.read

rx = rx_for(language)

if mode == "read"
  m = content.match(rx)
  die "no version found in #{path}" unless m
  puts m[2]
  exit 0
end

die "no version found in #{path} to replace" unless content.match(rx)

new_content = content.sub(rx) { "#{Regexp.last_match(1)}#{new_version}#{Regexp.last_match(3)}" }
die "version rewrite produced no change in #{path}" if new_content == content

file.write(new_content)
puts new_version
