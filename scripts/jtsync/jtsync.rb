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

STATUS_MAPPING = {
  "0" => "successful",
  "1" => "failed"
}.freeze

module Job
  class Mapping
    attr_reader :name
    attr_reader :project
    attr_reader :type


    def initialize(job, return_code)
      @name = job.name
      @project = job.project
      @type = job.type
      @job = job
      @code = return_code
    end

    def status
      raise "Unknown returncode \"#{@code}\"" unless STATUS_MAPPING.key? @code
      STATUS_MAPPING[@code]
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

    def build_nr
      @job.build_nr.to_i
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

    def build_nr
      @job.build_nr.to_i
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

  def self.for(job, status)
    raise "No mapping provided for #{service}/#{jobtype}" unless MAPPING[job.service].key? job.type
    MAPPING[job.service][job.type].new(job, status)
  end
end

def credentials_from_netrc
  netrc = Netrc.read
  dev, member = netrc["api.trello.com"]

  raise "Could not find credentials!" if dev.nil? || member.nil?

  OpenStruct.new(developer_token: dev, member_token: member)
end

def parse_job_from_cli
  job = OpenStruct.new
  board_id = TRELLO_BOARD

  opts = OptionParser.new do |opt|
    opt.banner = "Usage: jtsync --ci SERVICE (--matrix|--job) JOB_STATUS"

    opt.on("--board BOARDID", "Board id to update") do |id|
      board_id = id
    end

    opt.on("--ci SERVICE", [:suse, :opensuse], "Which ci is used (suse or opensuse)") do |service|
      job.service = service
    end

    opt.on("--matrix NAME,PROJECT,BUILDNR", Array, "Set status of a matrix job") do |settings|
      raise "Invalid matrix job!" if settings.length != 3
      job.type = :matrix
      job.project = settings[1]
      job.name = settings[0]
      job.build_nr = settings[2]
    end

    opt.on("--job NAME", "Set status of a normal job") do |name|
      job.type = :normal
      job.name = name
    end
  end
  opts.order!
  raise "Either job or matrix is required" if job.type.nil?

  [board_id, Job.for(job, ARGV.pop)]
end

def board(board_id)
  @trello_board ||= Trello::Board.find(board_id)
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

def update_card_label(board_id, card, job)
  label = board(board_id).labels.select { |l| l.name == job.status }.first
  current_status = nil
  raise "Could not find label \"#{job.status}\"" if label.nil?

  return job.status if card.labels.include? label

  card.labels.each do |l|
    next unless STATUS_MAPPING.values.include? l.name
    card.remove_label(l)
    current_status = l.name
  end
  card.add_label(label)
  current_status
end

def find_card_for(board_id, job)
  list = board(board_id).lists.select { |l| l.name == job.list_name }.first
  raise "Could not find list #{job.list_name}" if list.nil?

  card = list.cards.select { |c| c.name == job.card_name }.first
  raise "Could not find card matching #{job.card_name} in #{job.list_name}" if card.nil?

  card
end

def fetch_build_nr(card)
  card.desc.split("\n").each do |line|
    matched = line.match(/^CurrentBuild: (\d+)$/)

    next if matched == nil || matched.length != 2
    return matched[1].to_i
  end
  nil
end


def need_update?(job, card)
  return true if job.type == :normal

  number = fetch_build_nr(card)
  #1 build nr is not the same / not set => set new number and update card
  if number == nil || number != job.build_nr
    if number == nil
      card.desc += "\nCurrentBuild: #{job.build_nr}"
    else
      card.desc = card.desc.gsub(/^CurrentBuild: (\d+)$/, "CurrentBuild: #{job.build_nr}")
    end
    card.save
    return true
  end

  #2 build nr is the same and status is failed => update the card
  return true if number == job.build_nr && job.status == "failed"

  # otherwise => no update
  false
end

#
# run the script
#
begin
  credentials = credentials_from_netrc
  board_id, job = parse_job_from_cli

  Trello.configure do |config|
    config.developer_public_key = credentials.developer_token
    config.member_token = credentials.member_token
  end

  card = find_card_for(board_id, job)

  # When job is a matrix job check the buildnumber in the description
  # in form of CurrentBuild: <build_nr>
  if need_update?(job, card)
      old_status = update_card_label(board_id, card, job)

      # only notify members if the status changes from failed to success or
      # vice versa.
      notify_card_members(card, job.status) if old_status != job.status
  end
rescue RuntimeError => err
  puts("Running jtsync failed: #{err}")
rescue Netrc::Error => err
  puts("Could not fetch credentials: #{err}")
rescue => err
  puts("Script failed err was: #{err}")
end
