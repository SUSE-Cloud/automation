#!/usr/bin/ruby

require 'octokit'
require 'optparse'

class GHClientHandler

  def initialize(config = {})
    @comment_prefix = config[:comment_prefix] || 'CI mkcloud self gating '
    @repository = config[:repository] || 'SUSE-Cloud/automation'
    @context = config[:context] || 'ci.suse.de/openstack-mkcloud/self-gating'
    @client = Octokit::Client.new(:netrc => true)
    @client.auto_paginate = true
    @client.login
  end

  def create_status(commit, result, description = '', target_url = '')
    @client.create_status(
      @repository,
      commit,
      result,
      { :context => @context,
        :description => description,
        :target_url => target_url
      }
    )
  end

  def create_success_status(commit, target_url = '')
    create_status(commit, 'success', @comment_prefix + 'succeeded', target_url)
  end

  def create_failure_status(commit, target_url = '')
    create_status(commit, 'failure', @comment_prefix + 'failed', target_url)
  end

  def create_pending_status(commit, target_url = '')
    create_status(commit, 'pending', @comment_prefix + 'is pending', target_url)
  end

  def get_full_sha_status(sha)
    status = @client.status(@repository, sha)
    status.statuses.select{ |s| s.context == @context }.first rescue {}
  end

  def get_sha_status(sha)
    get_full_sha_status(sha).state rescue ''
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
      status.include? get_sha_status(p.head.sha)
    end
  end

  def print_pr_sha_info(pull)
    if pull.is_a? Array
      pull.each do |p|
        print_pr_sha_info(p)
      end
    else
      puts "#{pull.number}:#{pull.head.sha}"
    end
  end

  def show_unseen_pull_requests
    print_pr_sha_info(
      get_all_pull_requests('open', ['']))
  end

  def show_rebuild_pull_requests
    print_pr_sha_info(
      get_all_pull_requests('open', ['', 'pending']))
  end

  def show_forcerebuild_pull_requests
    print_pr_sha_info(
      get_all_pull_requests('open', ['', 'pending', 'error', 'failure']))
  end

end

options = {}
optparse = OptionParser.new do |opts|
  opts.banner = "Query github for pull request status"

  opts.on('-a', '--action ACTION', 'Action to perform') do |a|
    options[:action] = a
  end

  opts.on('-p', '--pullrequest PRID', 'Github Pull Request ID') do |pr|
    options[:pr] = pr
  end

  opts.on('-c', '--sha SHA1SUM', 'Github Commit SHA1 Sum') do |sha|
    options[:sha] = sha
  end

  opts.on('-t', '--targeturl URL', 'Target URL of a CI Build') do |url|
    options[:target_url] = url
  end

  opts.on('-s', '--status STATUS', 'Github Status of a CI Build [pending,success,failure,error]') do |status|
    options[:status] = status
  end

  opts.on('-h', '--help', 'Show usage') do |h|
    puts opts
    exit
  end

end

optparse.parse!

ghc=GHClientHandler.new()

case options[:action]
  when 'list-unseen-prs'
    ghc.show_unseen_pull_requests
  when 'list-rebuild-prs'
    ghc.show_rebuild_pull_requests
  when 'list-forcerebuild-prs'
    ghc.show_forcerebuild_pull_requests
  when 'is-latest-sha'
    raise if options[:sha].nil? || options[:sha].empty?
    raise if options[:pr].nil? || options[:pr].empty?
    exit ghc.is_latest_sha?(options[:pr], options[:sha]) ? 0 : 1
  when 'get-latest-sha'
    raise if options[:pr].nil? || options[:pr].empty?
    puts ghc.get_pr_latest_sha(options[:pr])
  when 'set-status'
    raise unless ['success', 'failure', 'error', 'pending'].include? options[:status]
    raise if options[:sha].nil? || options[:sha].empty?
    raise if options[:target_url].nil? || options[:target_url].empty?
    case options[:status]
      when 'success'
        ghc.create_success_status(options[:sha], options[:target_url])
      when 'failure', 'error'
        ghc.create_failure_status(options[:sha], options[:target_url])
      when 'pending'
        ghc.create_pending_status(options[:sha], options[:target_url])
    end
  else
    puts optparse
end
