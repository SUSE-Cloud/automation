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
#

ENV["CURRENT_GEMFILE"] ||= File.expand_path("Gemfile", __FILE__)

require "bundler"
Bundler.setup(:default)
require "trello"
require "byebug"

def configure
  Trello.configure do |config|
    config.developer_public_key = ENV["TRELLO_PUPLIC_KEY"]
    config.member_token = ENV["TRELLO_MEMBER_TOKEN"]
  end
end

def job_state
  # TODO some ENV
  "successful"
  #{}"failed"
end

def job_name
  # TODO some ENV
  "cloud-mkcloud6-job-backup-restore-x86_64"
end

def job_type
  if ENV["project"]
    :matrix
  else
    :trigger
  end
end

def notify(card)
  card.member_ids.each do |member_id|
    username = Trello::Member.find(member_id).username
    comment = card.add_comment("@#{username} card status changed")
    comment_id = JSON.parse(comment)["id"]
    card.comments.each do |comment|
      comment.delete if comment.action_id == comment_id
    end
  end
end

def update_label(card, state)
  return true if card.labels.include?(labels[state])
  labels.each {|label| card.remove_label(label.second)}
  card.add_label(labels[state])
  notify(card)
end

def board
  @trello_board ||= Trello::Board.find("ywSwlQpZ")
end

def labels
  @trello_labels ||= board.labels.map do |label|
    next unless ["successful", "failed"].include?(label.name)
    [label.name, label]
  end.compact.to_h
end

def lists
  @trello_lists ||= board.lists.map do |list|
    next unless ["Cloud 6", "Cloud 7", "OpenStack"].include?(list.name)
    [list.name, list.id]
  end.compact
end

def find_card_by_trigger
  cloud_version = job_name.split("-").second[-1,1]
  list = lists.select {|list| list.include?("Cloud #{cloud_version}")}.flatten.second
  cards.select { |card| card.name == job_name }.first
end

def find_card_by_matrix
  project = ENV["project"]
  #if project.include?("Cloud:6")

end

def card(cards)
  @trello_card ||= if job_type == :trigger
    find_card_by_trigger
  else
    find_card_by_matrix
  end
end

configure

lists.each do |list_name, list_id|
  cards = Trello::List.find(list_id).cards
  break unless card(cards)
  update_label(card, job_state)
  break
end
