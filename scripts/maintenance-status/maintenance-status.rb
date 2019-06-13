#!/usr/bin/ruby

require "optparse"
require "open3"
require "active_support/core_ext/hash/conversions"

class ObsHandler
  def initialize(config = {})
    @group = config[:group] || "cloud-maintenance"
  end

  def requests()
    result = obs_api_call("/search/request?match=review[@by_group='#{@group}'+and+(@state='new')]")
    requests = result["request"]
    open_requests = []
    requests.each do |request|
      if request["state"]["name"] = "review" && request["id"]
        id = request["id"].to_i
        status = request_status?(request["id"])
        source = request["action"][1]["source"]["project"].split(":").last
        products = filter_products(request)
        open_requests.push(
          {
            id: id,
            source: source,
            status: status,
            products: products
          }
        )
      end
    end
    open_requests
  end

  def request_status?(id)
    comments = obs_api_call("/comments/request/#{id}")["comment"] || ""
    comments = [comments].flatten
    if comments.select{|comment| comment.match(/^SUSE OpenStack Cloud Jenkins run triggered!.*/)}.any?
      return :running
    elsif comments.select{|comment| comment.match(/^SUSE OpenStack Cloud Jenkins run failed!.*/)}.any?
      return :failure
    elsif comments.select{|comment| comment.match(/^SUSE OpenStack Cloud Jenkins run succeeded!.*/)}.any?
      return :success
    else
      return :pending
    end
  end

  def request_status(id, status, message = "")
    unless message == ""
      message = " (#{message})"
    end
    if status == :running
      obs_api_call(
        "/comments/request/#{id}",
        "POST",
        "SUSE OpenStack Cloud Jenkins run triggered!#{message}"
      )
    elsif status == :failure
      obs_api_call(
        "/comments/request/#{id}",
        "POST",
        "SUSE OpenStack Cloud Jenkins run failed!#{message}"
      )
    elsif status == :success
      obs_api_call(
        "/comments/request/#{id}",
        "POST",
        "SUSE OpenStack Cloud Jenkins run succeeded!#{message}"
      )
    else
      puts "No valid status gived!"
    end
  end

  def open_requests()
    requests = requests()
    print_rr_info(requests)
  end

  def unseen_requests()
    requests = requests()
    filter_requests(requests, [:pending])
    print_rr_info(requests)
  end

  def forcerebuild_requests()
    requests = requests()
    filter_requests(requests, [:running, :pending, :failure])
    print_rr_info(requests)
  end

  def filter_requests(requests, filter)
    requests.select! do |request|
      filter.include?(request[:status])
    end
  end

  def filter_products(request)
    products = []
    request["action"].each do |product|
      if product["target"]["project"] =~ /(SUSE:Updates:(HPE-Helion-OpenStack|OpenStack-Cloud|OpenStack-Cloud-Crowbar):[0-9](-LTSS)?:x86_64)|(SUSE:Updates:SLE-SERVER:[0-9]{2}-SP[0-9]:x86_64)/
        project = product["target"]["project"]
        project.gsub!(":x86_64", "")
        project.gsub!("SUSE:Updates:OpenStack-Cloud:", "SOC")
        project.gsub!("SUSE:Updates:OpenStack-Cloud-Crowbar:", "SOCC")
        project.gsub!("SUSE:Updates:HPE-Helion-OpenStack:", "HOS")
        project.gsub!("SUSE:Updates:SLE-SERVER:", "SLES")
        products.push(project)
      end
    end
    products.uniq.join("/")
  end

  def print_rr_info(requests)
    requests.each do |request|
      puts "#{request[:id]}:#{request[:source]}:#{request[:products]}:#{request[:status]}"
    end
  end

  def obs_api_call(api_call, method = "GET", content = "")
    base_cmd = "osc -A https://api.suse.de api -X #{method}"
    cmd = "#{base_cmd} \"#{api_call}\" -d \"#{content}\""
    xml = Open3.popen3(cmd) do |stdin, stdout, stderr, wait_thr|
      stdout.read
    end
    Hash.from_xml(xml).values.first
  end
end

options = {}
optparse = OptionParser.new do |opts|
  opts.banner = "Query maintenance for review status"

  opts.on("-a", "--action ACTION", "Action to perform (list-unseen, list-rebuild, list-forcerebuild, set-status)") do |a|
    options[:action] = a
  end

  opts.on("-g", "--group GROUP", "Maintenance Group") do |group|
    options[:group] = group
  end

  opts.on("-r", "--review NUMBER", "Maintenance Review Number") do |review|
    options[:review] = review
  end

  opts.on("-s", "--status STATUS", "Maintenance Status of a CI Build [running,success,failure]") do |status|
    options[:status] = status.to_sym
  end

  opts.on("-m", "--message MSG", "Message to show in review") do |msg|
    options[:message] = msg
  end

  opts.on("-h", "--help", "Show usage") do |h|
    puts opts
    exit
  end
end

optparse.parse!

obsh=ObsHandler.new(group: options[:group])

case options[:action]
  when "list-open"
    obsh.open_requests()
  when "list-unseen"
    obsh.unseen_requests()
  when "list-forcerebuild"
    obsh.forcerebuild_requests()
  when "set-status"
    obsh.request_status(options[:review], options[:status], options[:message])
  else
    puts optparse
end
