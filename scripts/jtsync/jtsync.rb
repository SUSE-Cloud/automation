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
    attr_reader :retcode


    def initialize(name, project, retcode)
      @name = name
      @project = project
      @retcode = retcode
    end

    def status
      raise "Unknown returncode \"#{retcode}\"" unless STATUS_MAPPING.key? retcode
      STATUS_MAPPING[retcode]
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

  def self.for(service, jobtype, name, project, status)
    raise "No mapping provided for #{service}/#{jobtype}" unless MAPPING[service].key? jobtype
    MAPPING[service][jobtype].new(name, project, status)
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
  opts = OptionParser.new do |opt|
    opt.banner = "Usage: jtsync --ci SERVICE (--matrix|--job) JOB_STATUS"
    opt.on("--ci SERVICE", [:suse, :opensuse], "Which ci is used (suse or opensuse)") do |service|
      job.service = service
    end

    opt.on("--matrix NAME,PROJECT", Array, "Set status of a matrix job") do |settings|
      job.type = :matrix
      job.project = settings[1]
      job.name = settings[0]
    end

    opt.on("--job NAME", "Set status of a normal job") do |name|
      job.type = :normal
      job.name = name
    end
  end
  opts.order!
  raise "Either job or matrix is required" if job.type.nil?

  Job.for(job.service, job.type, job.name, job.project, ARGV.pop)
end

def board
  @trello_board ||= Trello::Board.find(TRELLO_BOARD)
end

def notify_card_members(card)
  members = card.members.map do |m|
    "@" + Trello::Member.find(m.id).username
  end

  comment = card.add_comment("#{members.join(" ")}: card status changed")
  comment_id = JSON.parse(comment)["id"]

  card.comments.select do |c|
    c.action_id == comment_id
  end.map(&:delete)
end

def update_card_label(card, job)
  label = board.labels.select { |l| l.name == job.status }.first
  raise "Could not find label \"#{job.status}\"" if label.nil?

  return if card.labels.include? label

  card.labels.each do |l|
    next unless STATUS_MAPPING.values.include? l.name
    card.remove_label(l) 
  end
  card.add_label(label)
end

def find_card_for(job)
  list = board.lists.select { |l| l.name == job.list_name }.first
  raise "Could not find list #{job.list_name}" if list.nil?

  card = list.cards.select { |c| c.name == job.card_name }.first
  raise "Could not find card matching #{job.card_name} in #{job.list_name}" if card.nil?

  card
end

#
# run the script
#
begin
  credentials = credentials_from_netrc
  job = parse_job_from_cli

  Trello.configure do |config|
    config.developer_public_key = credentials.developer_token
    config.member_token = credentials.member_token
  end

  card = find_card_for(job)
  update_card_label(card, job)
  notify_card_members(card)

rescue RuntimeError => err
  puts("Running jtsync failed: #{err}")
rescue Netrc::Error => err
  puts("Could not fetch credentials: #{err}")
rescue => err
  puts("Script failed err was: #{err}")
end
