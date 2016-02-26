#!/usr/bin/ruby

require 'octokit'
require 'optparse'
require 'json'

class GHClientHandler

  def initialize(config = {})
    @comment_prefix = config[:comment_prefix] || 'CI mkcloud gating '
    @repository = config[:repository] || 'SUSE-Cloud/automation'
    @context = config[:context] || 'ci.suse.de/openstack-mkcloud/gating'
    @branch = config[:branch] || ''
    @client = Octokit::Client.new(:netrc => true)
    @client.auto_paginate = true
    @client.login
  end

  def create_status(commit, result, description = nil, target_url = nil)
    description ||= @comment_prefix + case result
    when :success
      'succeeded'
    when :failure
      'failed'
    when :error
      'has an error'
    when :pending
      'is pending'
    else
      ''
    end

    @client.create_status(
      @repository,
      commit,
      result,
      { :context => @context,
        :description => description,
        :target_url => target_url.to_s
      }
    )
  end

  def get_full_sha_status(sha)
    status = @client.status(@repository, sha)
    status.statuses.select{ |s| s.context == @context }.first rescue {}
  end

  def get_sha_status(sha)
    get_full_sha_status(sha).state rescue ''
  end

  def get_pr_info(pr)
    pr_stat = @client.pull_request(@repository, pr)
    pr_stat.to_attrs
  end

  def get_pr_latest_sha(pr)
    pr_stat = @client.pull_request(@repository, pr)
    pr_stat.head.sha rescue ''
  end

  def is_latest_sha?(pr, sha)
    get_pr_latest_sha(pr) == sha
  end

  def get_all_pull_requests(state, status = [])
    pulls = @client.pull_requests(@repository, :state => state)
    pulls.select do |p|
      status.include?(get_sha_status(p.head.sha)) &&
        (@branch.to_s.empty? || @branch.to_s == p.base.ref)
    end
  end

  def get_own_pull_requests(state, status = [])
    # filter for our own PRs, as we do not want to build anybodys PR
    pulls = get_all_pull_requests(state, status)
    pulls.select do |p|
      user = p.head.repo.owner.login rescue ''
      return false unless user
      # team id 1541628 -> SUSE-Cloud/developers
      # team id 291046 -> crowbar/Owners
      # team id 159206 -> SUSE-Cloud/Owners
      user == "SUSE-Cloud" ||
        @client.team_member?(1541628, user) ||
        @client.team_member?(291046, user) ||
        @client.team_member?(159206, user)
    end
  end

  def print_pr_sha_info(pull)
    if pull.is_a? Array
      pull.each do |p|
        print_pr_sha_info(p)
      end
    else
      puts "#{pull.number}:#{pull.head.sha}:#{pull.base.ref}" if pull
    end
  end

  def show_unseen_pull_requests
    print_pr_sha_info(
      get_own_pull_requests('open', ['']))
  end

  def show_rebuild_pull_requests
    print_pr_sha_info(
      get_own_pull_requests('open', ['', 'pending']))
  end

  def show_forcerebuild_pull_requests
    print_pr_sha_info(
      get_own_pull_requests('open', ['', 'pending', 'error', 'failure']))
  end

  def show_open_pull_requests
    print_pr_sha_info(
      get_own_pull_requests('open', ['', 'pending', 'error', 'failure', 'success']))
  end

end

ACTIONS = %w(
  list-unseen-prs
  list-rebuild-prs
  list-forcerebuild-prs
  get-pr-info
  get-latest-sha
  is-latest-sha
  set-status
)

options = {}
optparse = OptionParser.new do |opts|
  opts.banner = "Query github for pull request status"

  actions = ACTIONS.join ', '
  opts.on('-a', '--action ACTION', "Action to perform (#{actions})") do |a|
    options[:action] = a
  end

  opts.on('-p', '--pullrequest PRID', 'Github Pull Request ID') do |pr|
    options[:pr] = pr
  end

  opts.on('-r', '--repository ORG/REPO', 'Github Organisation/Repository') do |repo|
    options[:repository] = repo
  end

  opts.on('-x', '--context context-string', 'Github Status Context String') do |ctx|
    options[:context] = ctx
  end

  opts.on('-c', '--sha SHA1SUM', 'Github Commit SHA1 Sum') do |sha|
    options[:sha] = sha
  end

  opts.on('-t', '--targeturl URL', 'Target URL of a CI Build') do |url|
    options[:target_url] = url
  end

  opts.on('-s', '--status STATUS', 'Github Status of a CI Build [pending,success,failure,error]') do |status|
    options[:status] = status.to_sym
  end

  opts.on('-m', '--message MSG', 'Message to show in github next to the status.') do |msg|
    options[:message] = msg
  end

  opts.on('-b', '--branch BRANCHNAME', 'Filters pull requests by target branch name.') do |br|
    options[:branch] = br
  end

  opts.on('-k', '--key KEY',
          'Dot-separated attribute path to extract from PR JSON, ' \
          'e.g. base.head.owner.  Optional, only for use with ' \
          'get-pr-info action.') do |key|
    options[:key] = key
  end

  opts.on('-h', '--help', 'Show usage') do |h|
    puts opts
    exit
  end

end

optparse.parse!

ghc=GHClientHandler.new(repository: options[:repository], branch: options[:branch], context: options[:context])

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

case options[:action]
  when 'list-open-prs'
    ghc.show_open_pull_requests
  when 'list-unseen-prs'
    ghc.show_unseen_pull_requests
  when 'list-rebuild-prs'
    ghc.show_rebuild_pull_requests
  when 'list-forcerebuild-prs'
    ghc.show_forcerebuild_pull_requests
  when 'is-latest-sha'
    require_parameter(options[:sha], 'Commit SHA1 sum undefined.')
    require_parameter(options[:pr], 'PullRequest ID undefined.')
    exit ghc.is_latest_sha?(options[:pr], options[:sha]) ? 0 : 1
  when 'get-pr-info'
    require_parameter(options[:pr], 'PullRequest ID undefined.')
    data = ghc.get_pr_info(options[:pr])
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
  when 'get-latest-sha'
    require_parameter(options[:pr], 'PullRequest ID undefined.')
    puts ghc.get_pr_latest_sha(options[:pr])
  when 'set-status'
    valid_status = [:success, :failure, :error, :pending]
    prevent_parameter(options[:pr], 'PullRequest ID should not be specified')
    require_parameter((valid_status & [options[:status]]).join(''),
                      "Unsupported status #{options[:status].to_s}.")
    require_parameter(options[:sha], 'Commit SHA1 sum undefined.')
    ghc.create_status(options[:sha], options[:status], options[:message], options[:target_url])
  else
    puts optparse
end
