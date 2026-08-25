#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "optparse"
require "pathname"
require_relative "lib/config"

options = {}
OptionParser.new do |parser|
  parser.on("--config PATH") { |value| options[:config] = value }
  parser.on("--profile-map PATH") { |value| options[:profile_map] = value }
  parser.on("--identity SHA1") { |value| options[:identity] = value }
  parser.on("--workspace PATH") { |value| options[:workspace] = value }
end.parse!

class SigningPreparationError < StandardError; end

def plist_json(path)
  stdout, stderr, status = Open3.capture3("/usr/bin/plutil", "-convert", "json", "-o", "-", "--", path)
  raise SigningPreparationError, "unable to parse Xcode project #{path}: #{stderr.strip}" unless status.success?

  JSON.parse(stdout)
end

def project_files(config, workspace)
  relative_container = IOSBuild::Config.dig(config, "build.container_path")
  container = File.expand_path(relative_container, workspace)
  type = IOSBuild::Config.dig(config, "build.container_type")
  candidates = if type == "project"
                 [File.join(container, "project.pbxproj")]
               else
                 root = File.dirname(container)
                 Dir.glob(File.join(root, "**", "*.xcodeproj", "project.pbxproj"))
               end

  candidates.select { |path| File.file?(path) && !Pathname.new(path).each_filename.include?("Pods") }.uniq.sort
end

def openstep_key(key)
  key.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/) ? key : key.inspect
end

def replace_build_settings(text, configuration_id, updates)
  lines = text.lines
  object_pattern = /^\s*#{Regexp.escape(configuration_id)} \/\* .* \*\/ = \{\s*$/
  object_indexes = lines.each_index.select { |index| lines.fetch(index).match?(object_pattern) }
  raise SigningPreparationError, "unable to locate build configuration #{configuration_id}" unless object_indexes.length == 1

  object_index = object_indexes.first
  settings_index = ((object_index + 1)...lines.length).find do |index|
    lines.fetch(index).match?(/^(\s*)buildSettings = \{\s*$/)
  end
  raise SigningPreparationError, "build configuration #{configuration_id} has no buildSettings" unless settings_index

  settings_indent = lines.fetch(settings_index).match(/^(\s*)/).captures.first
  settings_end = ((settings_index + 1)...lines.length).find do |index|
    lines.fetch(index).match?(/^#{Regexp.escape(settings_indent)}\};\s*$/)
  end
  raise SigningPreparationError, "build configuration #{configuration_id} has unterminated buildSettings" unless settings_end

  updates.each do |key, value|
    rendered_key = openstep_key(key)
    setting_pattern = /^\s*#{Regexp.escape(rendered_key)} = .*;\s*$/
    matches = ((settings_index + 1)...settings_end).select { |index| lines.fetch(index).match?(setting_pattern) }
    raise SigningPreparationError, "build configuration #{configuration_id} repeats #{key}" if matches.length > 1

    rendered = "#{settings_indent}\t#{rendered_key} = #{value.inspect};\n"
    if matches.empty?
      lines.insert(settings_end, rendered)
      settings_end += 1
    else
      lines[matches.first] = rendered
    end
  end

  lines.join
end

def write_verified_project(path, text, expected)
  temporary_path = "#{path}.signing-#{Process.pid}"
  File.open(temporary_path, "w", File.stat(path).mode & 0o777) { |file| file.write(text) }
  _stdout, stderr, status = Open3.capture3("/usr/bin/plutil", "-lint", "--", temporary_path)
  raise SigningPreparationError, "updated Xcode project is invalid: #{stderr.strip}" unless status.success?

  parsed = plist_json(temporary_path).fetch("objects")
  expected.each do |configuration_id, settings|
    actual = parsed.fetch(configuration_id).fetch("buildSettings")
    settings.each do |key, value|
      raise SigningPreparationError, "failed to set #{key} for #{configuration_id}" unless actual[key] == value
    end
  end
  File.rename(temporary_path, path)
ensure
  File.delete(temporary_path) if temporary_path && File.exist?(temporary_path)
end

begin
  missing = %i[config profile_map identity workspace].reject { |key| options[key] && !options[key].empty? }
  raise SigningPreparationError, "missing options: #{missing.join(', ')}" unless missing.empty?
  raise SigningPreparationError, "identity must be a SHA-1 fingerprint" unless options.fetch(:identity).match?(/\A[0-9A-Fa-f]{40}\z/)

  config = IOSBuild::Config.load_file(options.fetch(:config))
  profile_map = JSON.parse(File.read(options.fetch(:profile_map), encoding: "UTF-8"))
  team_id = IOSBuild::Config.dig(config, "app.team_id")
  configuration_name = IOSBuild::Config.dig(config, "build.configuration")
  requested_targets = IOSBuild::Config.dig(config, "app.bundle_ids").to_h do |entry|
    profile = profile_map.fetch(entry.fetch("bundle_id"))
    [entry.fetch("target"), profile.fetch("uuid")]
  end
  projects = project_files(config, options.fetch(:workspace))
  raise SigningPreparationError, "no Xcode projects were found for the configured container" if projects.empty?

  matches = Hash.new { |hash, key| hash[key] = [] }
  project_objects = {}
  projects.each do |project|
    objects = plist_json(project).fetch("objects")
    project_objects[project] = objects
    objects.each do |object_id, object|
      target_name = object["name"]
      matches[target_name] << [project, object_id, object] if object["isa"] == "PBXNativeTarget" && requested_targets.key?(target_name)
    end
  end

  changes = Hash.new { |hash, key| hash[key] = {} }
  requested_targets.each do |target_name, profile_uuid|
    target_matches = matches.fetch(target_name)
    raise SigningPreparationError, "configured target #{target_name.inspect} was not found exactly once" unless target_matches.length == 1

    project, _target_id, target = target_matches.first
    objects = project_objects.fetch(project)
    configuration_list = objects.fetch(target.fetch("buildConfigurationList"))
    configuration_ids = configuration_list.fetch("buildConfigurations").select do |configuration_id|
      objects.fetch(configuration_id)["name"] == configuration_name
    end
    unless configuration_ids.length == 1
      raise SigningPreparationError, "target #{target_name.inspect} does not have exactly one #{configuration_name.inspect} configuration"
    end

    changes[project][configuration_ids.first] = {
      "CODE_SIGN_STYLE" => "Manual",
      "DEVELOPMENT_TEAM" => team_id,
      "CODE_SIGN_IDENTITY" => options.fetch(:identity).upcase,
      "CODE_SIGN_IDENTITY[sdk=iphoneos*]" => options.fetch(:identity).upcase,
      "PROVISIONING_PROFILE" => profile_uuid,
      "PROVISIONING_PROFILE_SPECIFIER" => profile_uuid
    }
  end

  changes.each do |project, configurations|
    updated = configurations.reduce(File.read(project, encoding: "UTF-8")) do |text, (configuration_id, settings)|
      replace_build_settings(text, configuration_id, settings)
    end
    write_verified_project(project, updated, configurations)
  end

  puts "Configured manual signing for targets: #{requested_targets.keys.sort.join(', ')}"
rescue SigningPreparationError, IOSBuild::ConfigError, JSON::ParserError, KeyError, Errno::ENOENT => e
  warn e.message
  exit 1
end
