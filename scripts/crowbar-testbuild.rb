#!/usr/bin/env ruby

# Copyright (c) 2017 SUSE LINUX GmbH, Nuernberg, Germany.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

require "yaml"
require "optparse"
require "fileutils"
require "tmpdir"

class CrowbarTestbuild
  def initialize(options, config)
    @config = config
    @options = options
    @repo = @options[:repo] || ""
    @org = @options[:org] || ""
    @pr = @options[:pr] || ""
  end

  def parameters(flavor="")
    p = @config["parameters_template"]["default"]
    p.merge(@config["parameters_template"][flavor] || {})
  end

  def pr_split
    @pr.split(":")
  end

  def pr_id
    pr_split[0]
  end

  def pr_sha1
    pr_split[1]
  end

  def pr_sha1_short
    pr_split[1][0,8]
  end

  def pr_branch
    pr_split[2]
  end

  def job_name
    "#{@org}/#{@repo} PR #{pr_id} #{pr_sha1_short}"
  end

  def mkcloud_target
    @config["mkcloud"]["target"]
  end

  def mkcloud_job_name
    @config["mkcloud"]["job_name"]
  end

  def branch_map
    @config["branches"][pr_branch]
  end

  def bs_project
    branch_map["bs_project"]
  end

  def bs_repo
    branch_map["bs_repo"]
  end

  def cloudsource
    branch_map["cloudsource"]
  end

  def pr_string
    [@org, @repo, @pr].join(":")
  end

  def ptf_dir
    unex = File.join(@config["infrastructure"]["htdocs_dir"], pr_string)
    File.expand_path(unex)
  end

  def ptf_url
    @config["infrastructure"]["htdocs_url"] + pr_string + "/"
  end

  def extra_build_parameters(mode)
    p = @config["parameters_template"]["default"]
    p.merge!(@config["parameters"]["#{@org}/#{@repo}"][mode]) if @config["parameters"].include?("#{@org}/#{@repo}")
    p
  end

  def trigger_jenkins_job(mode)
    j = @config["infrastructure"]["jenkins_job_trigger"]
    sub_context = mode == "standard" ? "":mode
    sub_context_suffix = sub_context.empty? ? "" : ":#{sub_context}"
    job_name = "#{@org}/#{@repo} PR #{pr_id} #{pr_sha1_short} #{sub_context}"
    cmd = j["cmd"]
    cmd = File.join(File.dirname(__FILE__), cmd) unless File.exists?(cmd)
    jcmd = [ cmd, mkcloud_job_name, "-p" ]
    para_default = {
      mkcloudtarget: mkcloud_target,
      cloudsource: cloudsource,
      github_pr: "#{@org}/#{@repo}:#{@pr}#{sub_context_suffix}",
      UPDATEREPOS: ptf_url,
      job_name: job_name
    }
    para_extra = extra_build_parameters(mode)
    p = para_default.merge(para_extra).map { |k,v| "#{k}=#{v}" }
    jcmd += p
    puts "Triggering jenkins job with url #{ptf_url} and directory #{ptf_dir}"
    system(*jcmd) or raise
  end

  def jenkins_jobs_scenarios
    if @config["parameters"].include?("#{@org}/#{@repo}")
      @config["parameters"]["#{@org}/#{@repo}"].keys
    else
      @config["parameters"]["default"].keys
    end
  end

  def trigger_jenkins_jobs
    jenkins_jobs_scenarios.each do |k|
      trigger_jenkins_job(k)
    end
  end

  def osc_cmd(subcommand)
    [ @config["infrastructure"]["osc"]["cmd"] ] +
      ( @config["infrastructure"]["osc"]["parameters"]["_global"] || [] ) +
      [ subcommand ] +
      ( @config["infrastructure"]["osc"]["parameters"][subcommand] || [] )
  end

  def package_name
    pack = @repo
    pack = "crowbar-" + pack unless pack.start_with?("crowbar")
    pack
  end

  def package_spec_file
    package_name + ".spec"
  end

  def add_pr_to_checkout(compare_method)
    puts "Start crowbar testbuild."
    puts "Github diff method: #{compare_method}"
    patch_diff = "prtest.#{compare_method}"
    patch_diff_url = "https://github.com/#{@org}/#{@repo}/compare/#{pr_branch}...#{pr_sha1}.#{compare_method}"
    puts "Fetching patch from this URL: #{patch_diff_url}"
    system(
      *[
        "curl", "-s", "-k", "-L", "-o", patch_diff, patch_diff_url
      ]
    )

    system(
      *[
        "sed", "-i",
        "-e", "s,Url:.*,%define _default_patch_fuzz 2,",
        "-e", "s,%patch[0-36-9].*,,", package_spec_file
      ]
    )

    system(
      *[
        "/usr/lib/build/spec_add_patch", package_spec_file, patch_diff
      ]
    )

    system(
      *(
        osc_cmd("vc") +
        [
          "-m",
          "added PR test patch from #{@org}/#{@repo}##{pr_id} (#{pr_sha1})"
        ]
      )
     )
  end

  def build(method)
    FileUtils.rm_rf(ptf_dir)
    FileUtils.mkdir_p(ptf_dir)
    work_dir = Dir.mktmpdir
    build_root = "BUILD"

    Dir.chdir(work_dir) do
      begin
        osc_co = osc_cmd("co") + [bs_project, package_name]
        system(*osc_co)
        Dir.chdir(package_name) do
          Dir.mkdir(build_root)
          add_pr_to_checkout(method)
          system(
            *(
              osc_cmd("build") +
              [
                "--root", File.join(Dir.pwd, build_root),
                '--noverify', '--noservice',
                bs_repo, "x86_64", package_spec_file
              ]
            )
          ) or raise SystemCallError, "Build failed."
        end
      rescue => e
        puts e.message
        puts e.backtrace
        return false
      else
        # copy rpms
        FileUtils.cp(
          Dir.glob(File.join(package_name, build_root, ".build.packages/RPMS/*/*.rpm")),
          ptf_dir, :preserve => true
        ) or raise
        return true
      ensure
        # copy log
        FileUtils.cp(
          File.join(package_name, build_root, ".build.log"),
          File.join(ptf_dir, "build.log")
        )
        FileUtils.rm_rf(work_dir)
      end
    end
  end

end

conf_dirs = [ "/etc/mkcloud", Dir.pwd, File.dirname(__FILE__) ]
conf_file_name = "crowbar-testbuild.yaml"
## options
options = {}
optparse = OptionParser.new do |opts|
  opts.banner = "Build a testpackage for a crowbar pull request"
  opts.on("-o", "--org GITHUB_ORG", "Github Organisation") do |org|
    options[:org] = org
  end
  opts.on("-r", "--repo GITHUB_REPO", "Github Repository") do |repo|
    options[:repo] = repo
  end
  opts.on("-p", "--pr PR_STRING", "Github PR string='PRID:SHA1:DESTINATION_BRANCH'") do |pr|
    options[:pr] = pr
  end
  opts.on("-t", "--trigger-gating", "Trigger gating job run with jenkins-job-trigger") do
    options[:trigger_gating] = true
  end
  opts.on("-c", "--config CONFIG_FILE", "Config file or directory to search for file: #{conf_file_name}") do |c|
    conf_dirs = [c]
  end
end
optparse.parse!

## config
begin
  c = conf_dirs.shift
  c = File.join(c, conf_file_name) if File.directory?(c)
  puts "Trying config file: #{c}"
  config = YAML.load_file(c)
rescue Psych::SyntaxError
  puts "Error: Invalid YAML syntax in config file: #{c}"
  exit 2
rescue
  retry if conf_dirs.size > 0
  puts "Error: Could not find a config file: #{conf_file_name}"
  exit 3
end

## main
ctb = CrowbarTestbuild.new(options, config)
methods = [ "diff", "patch" ]
begin
  m = methods.shift
  puts "Building with method #{m}."
  ctb.build(m) or raise "Buidling with method #{m} failed."
  ctb.trigger_jenkins_jobs or raise "Could not trigger gating job" if options[:trigger_gating]
rescue => e
  puts e.message
  puts e.backtrace
  retry if methods.size > 0
  exit 1
else
  puts "Building with method #{m} successful."
end
