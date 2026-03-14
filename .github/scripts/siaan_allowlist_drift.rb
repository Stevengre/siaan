#!/usr/bin/env ruby

require "json"
require "optparse"
require "pathname"
require "yaml"

options = {
  format: "json",
  repo_root: Dir.pwd
}

OptionParser.new do |parser|
  parser.banner = "Usage: siaan_allowlist_drift.rb [--repo-root PATH] [--format json|markdown]"

  parser.on("--repo-root PATH", "Repository root to inspect") do |path|
    options[:repo_root] = path
  end

  parser.on("--format FORMAT", "Output format: json or markdown") do |format|
    options[:format] = format
  end
end.parse!

def normalize_list(value)
  Array(value)
    .map { |entry| entry.to_s.strip.sub(/\A@+/, "").downcase }
    .reject(&:empty?)
    .uniq
    .sort
end

def relative_path(repo_root, path)
  return nil unless path

  Pathname.new(path).relative_path_from(Pathname.new(repo_root)).to_s
end

def split_front_matter(content)
  lines = content.split(/\R/, -1)
  return ["", content] unless lines.first == "---"

  closing_index = lines[1..].index("---")
  return ["", content] unless closing_index

  front_matter = lines[1, closing_index].join("\n")
  body = lines[(closing_index + 2)..] || []

  [front_matter, body.join("\n")]
end

def load_security_file(path)
  return { exists: false, maintainers: [] } unless File.file?(path)

  raw = YAML.safe_load_file(path, permitted_classes: [], aliases: false) || {}
  return { exists: true, error: "expected a top-level mapping, got #{raw.class}", maintainers: [] } unless raw.is_a?(Hash)

  {
    exists: true,
    maintainers: normalize_list(raw["maintainers"])
  }
rescue Psych::Exception => error
  {
    exists: true,
    error: error.message,
    maintainers: []
  }
end

def load_workflow(path)
  return { exists: false, allowlist: [] } unless path && File.file?(path)

  front_matter, = split_front_matter(File.read(path))
  config =
    if front_matter.strip.empty?
      {}
    else
      YAML.safe_load(front_matter, permitted_classes: [], aliases: false) || {}
    end

  security = config.is_a?(Hash) ? config["security"] : nil

  {
    exists: true,
    allowlist: normalize_list(security.is_a?(Hash) ? security["dispatch_allowlist"] : nil)
  }
rescue Psych::Exception => error
  {
    exists: true,
    error: error.message,
    allowlist: []
  }
end

def format_list(entries)
  return "missing" if entries.nil?
  return "empty" if entries.empty?

  entries.map { |entry| "`#{entry}`" }.join(", ")
end

repo_root = File.expand_path(options[:repo_root])
security_path = File.join(repo_root, ".github", "siaan-security.yml")
workflow_candidates = [
  File.join(repo_root, "WORKFLOW.md"),
  File.join(repo_root, "elixir", "WORKFLOW.md")
]
workflow_path = workflow_candidates.find { |candidate| File.file?(candidate) }

security = load_security_file(security_path)
workflow = load_workflow(workflow_path)

result =
  if security[:error]
    {
      "status" => "warn",
      "summary" => "Could not load #{relative_path(repo_root, security_path)}.",
      "details" => [
        "#{relative_path(repo_root, security_path)} load error: #{security[:error]}"
      ],
      "security_path" => relative_path(repo_root, security_path),
      "workflow_path" => relative_path(repo_root, workflow_path)
    }
  elsif workflow[:error]
    {
      "status" => "warn",
      "summary" => "Could not load #{relative_path(repo_root, workflow_path)}.",
      "details" => [
        "#{relative_path(repo_root, workflow_path)} load error: #{workflow[:error]}"
      ],
      "security_path" => relative_path(repo_root, security_path),
      "workflow_path" => relative_path(repo_root, workflow_path)
    }
  elsif !workflow[:exists]
    {
      "status" => "ok",
      "summary" => "No WORKFLOW.md file is present yet, so the allowlist consistency check is skipped.",
      "details" => [],
      "security_path" => relative_path(repo_root, security_path),
      "workflow_path" => nil
    }
  elsif !security[:exists] && !workflow[:allowlist].empty?
    {
      "status" => "warn",
      "summary" => ".github/siaan-security.yml is missing while #{relative_path(repo_root, workflow_path)} already defines security.dispatch_allowlist.",
      "details" => [
        "Add .github/siaan-security.yml by running mix siaan.install or by checking in the generated file.",
        "#{relative_path(repo_root, workflow_path)} security.dispatch_allowlist: #{format_list(workflow[:allowlist])}"
      ],
      "security_path" => relative_path(repo_root, security_path),
      "workflow_path" => relative_path(repo_root, workflow_path),
      "security_maintainers" => security[:maintainers],
      "workflow_allowlist" => workflow[:allowlist]
    }
  elsif security[:exists] && workflow[:allowlist].empty?
    {
      "status" => "warn",
      "summary" => "#{relative_path(repo_root, workflow_path)} is missing security.dispatch_allowlist.",
      "details" => [
        "#{relative_path(repo_root, security_path)} maintainers: #{format_list(security[:maintainers])}",
        "Add the same usernames under security.dispatch_allowlist in #{relative_path(repo_root, workflow_path)} once orchestrator allowlist support lands."
      ],
      "security_path" => relative_path(repo_root, security_path),
      "workflow_path" => relative_path(repo_root, workflow_path),
      "security_maintainers" => security[:maintainers],
      "workflow_allowlist" => workflow[:allowlist]
    }
  elsif security[:maintainers] != workflow[:allowlist]
    {
      "status" => "warn",
      "summary" => "Maintainer allowlists drifted between .github/siaan-security.yml and #{relative_path(repo_root, workflow_path)}.",
      "details" => [
        "#{relative_path(repo_root, security_path)} maintainers: #{format_list(security[:maintainers])}",
        "#{relative_path(repo_root, workflow_path)} security.dispatch_allowlist: #{format_list(workflow[:allowlist])}",
        "Update one side so both sorted lists match exactly."
      ],
      "security_path" => relative_path(repo_root, security_path),
      "workflow_path" => relative_path(repo_root, workflow_path),
      "security_maintainers" => security[:maintainers],
      "workflow_allowlist" => workflow[:allowlist]
    }
  else
    {
      "status" => "ok",
      "summary" => "Maintainer allowlists match between .github/siaan-security.yml and #{relative_path(repo_root, workflow_path)}.",
      "details" => [],
      "security_path" => relative_path(repo_root, security_path),
      "workflow_path" => relative_path(repo_root, workflow_path),
      "security_maintainers" => security[:maintainers],
      "workflow_allowlist" => workflow[:allowlist]
    }
  end

case options[:format]
when "json"
  puts JSON.pretty_generate(result)
when "markdown"
  details = Array(result["details"]).map { |detail| "- #{detail}" }.join("\n")

  puts <<~MARKDOWN.strip
    ## siaan allowlist consistency

    #{result.fetch("summary")}

    #{details.empty? ? "- No action needed." : details}

    This check is advisory and does not block the PR while the repository and orchestrator setup are converging.
  MARKDOWN
else
  warn "unsupported format: #{options[:format]}"
  exit 1
end
