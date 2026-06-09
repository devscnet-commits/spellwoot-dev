# frozen_string_literal: true

class TeamInbox < ApplicationRecord
  belongs_to :team
  belongs_to :inbox

  validates :inbox_id, uniqueness: { scope: :team_id }
end
