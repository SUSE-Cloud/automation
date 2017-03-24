#!/usr/bin/env ruby
#
# Copyright 2016, SUSE Linux GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


require "trello"
require "netrc"
require "optparse"

TRELLO_BOARD = "ywSwlQpZ".freeze
BUILD_REGEXP = /^CurrentBuild: (\d+)$/
BUILD_STR = "CurrentBuild: %d"

module Job
  class Mapping
    attr_reader :name
    attr_reader :project
    attr_reader :type
    attr_reader :build_nr
    attr_reader :status

    def initialize(options)
      @name = options.name
      @project = options.project
      @type = options.type
      @status = options.status
      @build_nr = options.build_nr
    end
  end

  class SuseNormal < Mapping
    def card_name
      name
    end

    def list_name
      version = name.split("-")[1]
      "Cloud #{version[-1, 1]}"
    end
  end

  class SuseMatrix < Mapping
    def version
      project.split(":")[2]
    end

    def card_name
      "C#{version} #{name}"
    end

    def list_name
      "Cloud #{version}"
    end
  end

  class OpenSuseMatrix < Mapping
    def card_name
      card = name.gsub("openstack-", "")
      "#{card}: #{project}"
    end

    def list_name
      "OpenStack"
    end
  end

  MAPPING = {
    suse: {
      normal: SuseNormal,
      matrix: SuseMatrix
    },
    opensuse: {
      matrix: OpenSuseMatrix
    }
  }.freeze

  def self.for(options)
    unless MAPPING[options.service].key? options.type
      raise "No mapping provided for #{service}/#{jobtype}"
    end
    MAPPING[options.service][options.type].new(options)
  end
end

def credentials_from_netrc
  netrc = Netrc.read
  dev, member = netrc["api.trello.com"]

  raise "Could not find credentials!" if dev.nil? || member.nil?

  OpenStruct.new(developer_token: dev, member_token: member)
end

def options_from_cli
  options = OpenStruct.new
  options.board_id = TRELLO_BOARD
  options.build_nr = 0

  opts = OptionParser.new do |opt|
    opt.banner = "Usage: jtsync --ci SERVICE (--matrix|--job) JOB_STATUS"

    opt.on("--board BOARDID", "Board id to update") do |id|
      options.board_id = id
    end

    opt.on("--ci SERVICE", [:suse, :opensuse], "Which ci is used (suse or opensuse)") do |service|
      options.service = service
    end

    opt.on("--matrix NAME,PROJECT,BUILDNR", Array, "Set status of a matrix job") do |settings|
      raise "Invalid matrix job!" if settings.length != 3
      options.type = :matrix
      options.project = settings[1]
      options.name = settings[0]
      options.build_nr = settings[2].to_i
    end

    opt.on("--job NAME", "Set status of a normal job") do |name|
      options.type = :normal
      options.name = name
    end
  end
  opts.order!
  options.status = ARGV.pop == "0" ? "successful" : "failed"

  raise "Either job or matrix is required" if options.type.nil?
  options
end

def notify_card_members(card, new_status)
  members = card.members.map do |m|
    "@" + Trello::Member.find(m.id).username
  end

  msg = "#{members.join(" ")}: card status changed to #{new_status}"
  comment = card.add_comment(msg)
  comment_id = JSON.parse(comment)["id"]

  card.comments.select do |c|
    c.action_id == comment_id
  end.map(&:delete)
end

def update_card_label(board, card, job)
  label = board.labels.select { |l| l.name == job.status }.first
  current_status = nil
  raise "Could not find label \"#{job.status}\"" if label.nil?

  return job.status if card.labels.include? label

  card.labels.each do |l|
    next unless ["successful", "failed"].include? l.name
    card.remove_label(l)
    current_status = l.name
  end
  card.add_label(label)
  current_status
end

def find_card_for(board, job)
  list = board.lists.select { |l| l.name == job.list_name }.first
  raise "Could not find list #{job.list_name}" if list.nil?

  card = list.cards.select { |c| c.name == job.card_name }.first
  raise "Could not find card matching #{job.card_name} in #{job.list_name}" if card.nil?

  card
end

def fetch_build_nr(card)
  card.desc.split("\n").each do |line|
    matched = line.match(BUILD_REGEXP)

    next if matched == nil || matched.length != 2
    return matched[1].to_i
  end
  nil
end

def need_card_update?(job, card)
  return true if job.type == :normal
  number = fetch_build_nr(card)

  #1 build nr is not the same / not set => set new number and update card
  if number == nil || number != job.build_nr
    update_card_build_nr(job, card)
    return true
  end
  #2 build nr is the same and status is failed => update the card
  return true if number == job.build_nr && job.status == "failed"
  # otherwise => no update
  false
end

def update_card_build_nr(job, card)
  return if job.type != :matrix

  build = BUILD_STR % job.build_nr
  if card.desc.match(BUILD_REGEXP)
    card.desc = card.desc.gsub(BUILD_REGEXP, build)
  else
    card.desc += "\n#{build}"
  end
  card.save
end

#
# run the script
#
begin
  credentials = credentials_from_netrc
  Trello.configure do |config|
    config.developer_public_key = credentials.developer_token
    config.member_token = credentials.member_token
  end

  options = options_from_cli

  job = Job.for(options)
  board = Trello::Board.find(options.board_id)
  card = find_card_for(board, job)

  # When job is a matrix job check the buildnumber in the description
  # in form of CurrentBuild: <build_nr>
  if need_card_update?(job, card)
    old_status = update_card_label(board, card, job)

    # only notify members if the status changes from failed to success or
    # vice versa.
    notify_card_members(card, job.status) if old_status != job.status
  end
rescue RuntimeError => err
  puts("Running jtsync failed: #{err}")
rescue Netrc::Error => err
  puts("Could not fetch credentials: #{err}")
rescue => err
  puts("Script failed err was: #{err} #{err.backtrace}")
end
