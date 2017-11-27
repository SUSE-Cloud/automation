#!/usr/bin/ruby

require 'octokit'
require 'optparse'
require 'yaml'
require 'json'

class GithubAPI
  def create_client
    client = Octokit::Client.new(netrc: true)
    client.auto_paginate = true
    client.login
    client
  end

  def client
    @@client ||= create_client
  end

  def current_rate_limit
    client.rate_limit.remaining
  end
end


class GithubClient
  RESULT_MESSAGES = {
    success: 'succeeded',
    failure: 'failed',
    error:   'has an error',
    pending: 'is pending',
  }

  def initialize(conf = {})
    @config = conf
  end

  def organization
    @config[:organization]
  end

  def repository
    @config[:repository]
  end

  def org_repo
    "#{organization}/#{repository}"
  end

  def context
    @config[:context]
  end

  def create_status(commit, details)
    result = details[:status].to_sym
    GithubAPI.new.client.create_status(
      org_repo,
      commit,
      result,
      { context: context,
        description: status_description(details[:message], result),
        target_url: details[:target_url].to_s
      }
    )
  end

  def status_description(description, status)
    description ||= RESULT_MESSAGES[status]
    description.to_s
  end

  def full_sha_status(sha)
    status = GithubAPI.new.client.status(org_repo, sha)
    status.statuses.select{ |s| s.context == context }.first rescue {}
  end

  def sha_status(sha)
    full_sha_status(sha).state rescue ''
  end

  def pull_request(pull)
    GithubAPI.new.client.pull_request(org_repo, pull)
  end

  def pull_info(pull)
    pull_request(pull).to_attrs
  end

  def pull_latest_sha(pull)
    pull_request(pull).head.sha rescue ''
  end

  def latest_sha?(pull, sha)
    pull_latest_sha(pull) == sha
  end

  # state = ["open"|"closed"]
  def all_pull_requests(state)
     GithubAPI.new.client.pull_requests(org_repo, state: state)
  end
end

class GithubPRWorker
  def initialize(base_parameters = {}, config = {})
    @base_parameters = base_parameters
    @config = config
  end

  # metadata for octokit
  def metadata(org, repo, context)
    {
      org_repo: org + "/" + repo,
      organization: org,
      repository: repo,
      context: context,
      config_base_path: File.dirname(@base_parameters[:config]),
    }
  end

  def process_list
    @config["pr_processing"] || []
  end

  def status_filter_config(config)
    # the config for the Status filter might be overridden via command line parameters
    if (@base_parameters.has_key?(:mode) && @base_parameters[:mode].to_s.size > 0) then
      config["status"] = @base_parameters[:mode]
    end
    config
  end

  def debug?
    @base_parameters.has_key?(:debugfilterchain) && \
      @base_parameters[:debugfilterchain] == true
  end

  def debug_filterchain(pulls, filter)
    return unless debug?
    return unless filter
    puts "=" * 25
    puts filter.inspect
    print_pulls(pulls)
    puts "-" * 25
  end

  def run_actions(pulls, actions)
    return unless actions.is_a?(Array)
    actions.each do |a|
      a.run(pulls)
    end
  end

  def repos(item)
    if (item["config"].has_key?("repositories") && item["config"]["repositories"].size > 0) then
      item["config"]["repositories"]
    elsif (item["config"].has_key?("repository_filter") && item["config"]["repository_filter"].size > 0) then
      c = GithubAPI.new.client
      c.repositories(item["config"]["organization"]).collect do |r|
        r.name if item["config"]["repository_filter"].find do |rf|
          r.name =~ rf
        end
      end.compact
    end
  end

  def run_filterchain(filterchain, mode, white)
    filterchain.each do |h|
      white, black = h[:filter].filter(white)
      debug_filterchain(white, h[:filter])
      if (mode == :process) then
         run_actions(black, h[:blacklist_handler])
         run_actions(white, h[:whitelist_handler])
      end
      debug_filterchain(black, h[:blacklist_handler])
      debug_filterchain(white, h[:whitelist_handler])
    end
    return white
  end

  def filter_pulls(mode = :get, state = :open)
    process_list.collect do |item|
      repos(item).collect do |repo|
        meta = metadata(item["config"]["organization"], repo, item["config"]["context"])
        filterchain=[]
        item["filter"].each do |pull_filter|
          handler = {}
          fname = "GithubPR::" + pull_filter["type"] + "Filter"
          filter_config = pull_filter["config"]
          filter_config = status_filter_config(filter_config) if pull_filter["type"] == "Status"
          handler[:filter] = Object.const_get(fname).new(meta, filter_config)

          ["black", "white"].each do |list|
            hname = "#{list}list_handler"
            next unless pull_filter[hname]

            handler[hname.to_sym] = pull_filter[hname].collect do |one_action|
              action_class = "GithubPR::" + one_action["type"] + "Action"
              Object.const_get(action_class).new(meta, one_action["parameters"])
            end
          end
          filterchain.push(handler)
        end

        white = GithubClient.new(meta).all_pull_requests(state)
        debug_filterchain(white, "unfiltered PR list")
        run_filterchain(filterchain, mode, white)
      end
    end
  end

  def print_pulls(pull)
    if pull.is_a?(Array)
      pull.each do |p|
        print_pulls(p)
      end
    else
      puts "#{pull.number}:#{pull.head.sha}:#{pull.base.ref}" if pull
    end
  end

  def trigger_pulls
    filter_pulls(:process, :open)
  end

  def list_pulls
    pulls = filter_pulls(:get, :open)
    print_pulls(pulls)
  end
end


# MAIN ========================================================

## options
base_para = {}
options = {}

optparse = OptionParser.new do |opts|
  opts.banner = "Tool to trigger mkcloud builds for open pull requests and set the pull request status"
  opts.on("-h", "--help", "Show usage") do
    puts opts
    exit
  end
  opts.separator ""
  opts.separator "Parameters to process PR list"
  opts.on("-c", "--config CONFIG_FILE", "File with configuration and filter specification") do |c|
    base_para[:config] = c
  end
  opts.on("-a", "--action TYPE", "Action to perform, processing: [trigger-prs list-prs] ; " \
          "single PR: [set-status get-latest-sha is-latest-sha pr-info]"
         ) do |a|
    base_para[:action] = a
  end
  opts.on("-m", "--mode MODE", "Override the 'Status' filter definition(s) in the config file: [unseen rebuild forcerebuild all]") do |o|
    base_para[:mode] = o
  end
  opts.on("-i", "--interaction_dirs DIR1,DIR2,DIR3", "Directories with interaction files to require. All files 'ia_*.rb' are included from these directories.") do |i|
    base_para[:interaction_dirs] = i.split(",")
  end
  opts.on("-d", "--debugfilterchain", "Debug the filterchain of the config file. Lists PRs after each filter step.") do
    base_para[:debugfilterchain] = true
  end
  opts.on("-l", "--debugratelimit", "Debugging API rate limit. Print the Github API rate limit to STDERR before and after processing the action.") do
    base_para[:debugratelimit] = true
  end

  opts.separator ""
  opts.separator "Parameters to set/query a github status"
  opts.on("-o", "--org ORG", "Github Organisation/Repository") do |o|
    options[:organization] = o
  end
  opts.on("-r", "--repo REPO", "Github Organisation/Repository") do |r|
    options[:repository] = r
  end
  opts.on("-x", "--context context-string", "Github Status Context String") do |x|
    options[:context] = x
  end
  opts.on("-p", "--pr PRID", "Github Status Context String") do |p|
    options[:pr] = p
  end
  opts.on("-u", "--sha SHA1SUM", "Github Commit SHA1 Sum") do |u|
    options[:sha] = u
  end
  opts.on("-t", "--targeturl URL", "Target URL of a CI Build; optional.") do |t|
    options[:target_url] = t
  end
  opts.on("-s", "--status STATUS", "Github Status of a CI Build [pending,success,failure,error]") do |s|
    options[:status] = s
  end
  opts.on("-e", "--message MSG", "Message to show in github next to the status; optional.") do |e|
    options[:message] = e
  end

  opts.separator ""
  opts.separator "Parameter for JSON query"
  opts.on('-k', '--key KEY',
          'Dot-separated attribute path to extract from PR JSON, e.g. base.head.owner. ' \
          'Only for use with pr-info action.') do |k|
    options[:key] = k
  end
end
optparse.parse!

## config
yaml_config = {}
begin
  yaml_config = YAML.load_file(base_para[:config]) if base_para.has_key?(:config)
rescue Psych::SyntaxError
  puts "Error: Invalid YAML syntax in config file: #{base_para[:config]}"
  exit 2
end


## include interaction files
rel_ia_dir = File.join(File.dirname(__FILE__), "interactions")
require File.join(rel_ia_dir, "default.rb")

interaction_dirs = [ rel_ia_dir ]
interaction_dirs += base_para[:interaction_dirs] if base_para[:interaction_dirs].is_a?(Array)
interaction_dirs += yaml_config["interaction_dirs"] if yaml_config["interaction_dirs"].is_a?(Array)

interaction_dirs.collect{ |d| d.gsub(/\/+$/, "") rescue next}.compact.uniq.each do |dir|
  begin
    onedir = Dir.new(dir)
    Dir.glob(File.expand_path(File.join(onedir, 'ia_*.rb'))).each do |f|
      require f
    end
  rescue Errno::ENOENT
    raise "Could not find directory: #{dir}"
  end
end

## helpers for parameter checks
def require_parameter(param, message)
  if param.to_s.empty?
    abort message
  end
end

def prevent_parameter(param, message)
  unless param.to_s.empty?
    abort message
  end
end

def debug_api_rate_limit(base_para)
  return unless base_para.has_key?(:debugratelimit) && base_para[:debugratelimit] == true
  STDERR.puts "API rate limit: " + GithubAPI.new.current_rate_limit.to_s
end

## main
debug_api_rate_limit(base_para)
case base_para[:action]
  when "list-prs"
    require_parameter(base_para[:config], 'Config file not defined.')
    GithubPRWorker.new(base_para, yaml_config).list_pulls
  when "trigger-prs"
    require_parameter(base_para[:config], 'Config file not defined.')
    GithubPRWorker.new(base_para, yaml_config).trigger_pulls
  when "set-status"
    prevent_parameter(base_para[:config], 'Config file should not be defined for this action.')
    require_parameter(options[:organization], 'Organization undefined.')
    require_parameter(options[:repository], 'Repository undefined.')
    require_parameter(options[:context], 'Context undefined.')
    require_parameter(options[:sha], 'SHA1 sum undefined.')
    require_parameter(options[:status], 'Status undefined.')
    GithubClient.new(options).create_status(options[:sha], {
      status: options[:status],
      message: options[:message],
      target_url: options[:target_url]
    })
  when "pr-info"
    prevent_parameter(base_para[:config], 'Config file should not be defined for this action.')
    require_parameter(options[:organization], 'Organization undefined.')
    require_parameter(options[:repository], 'Repository undefined.')
    require_parameter(options[:pr], 'PullRequest ID undefined.')
    data = GithubClient.new(options).pull_info(options[:pr])
    if options[:key]
      options[:key].split(/(?<!\\)\./).each do |key|
        key = key.to_sym
        if data.has_key? key
          data = data[key]
        else
          abort "No key '#{key}' in PR JSON:\n#{JSON.pretty_generate(data)}"
        end
      end
    end
    puts data.is_a?(Hash) ? JSON.pretty_generate(data) : data
  when "is-latest-sha"
    prevent_parameter(base_para[:config], 'Config file should not be defined for this action.')
    require_parameter(options[:sha], 'Commit SHA1 sum undefined.')
    require_parameter(options[:pr], 'PullRequest ID undefined.')
    require_parameter(options[:organization], 'Organization undefined.')
    require_parameter(options[:repository], 'Repository undefined.')
    exit GithubClient.new(options).latest_sha?(options[:pr], options[:sha]) ? 0 : 1
  when "get-latest-sha"
    prevent_parameter(base_para[:config], 'Config file should not be defined for this action.')
    require_parameter(options[:pr], 'PullRequest ID undefined.')
    require_parameter(options[:organization], 'Organization undefined.')
    require_parameter(options[:repository], 'Repository undefined.')
    puts GithubClient.new(options).pull_latest_sha(options[:pr])
end
debug_api_rate_limit(base_para)

__END__

