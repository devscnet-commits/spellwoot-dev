# frozen_string_literal: true

class TeamInbox < ApplicationRecord
  # touch: the cached teams payload includes inbox_ids, so linking/unlinking a caixa must
  # bump the team's cache key — otherwise the frontend serves the stale list forever and
  # screens keep claiming the team has no caixas.
  belongs_to :team, touch: true
  belongs_to :inbox

  validates :inbox_id, uniqueness: { scope: :team_id }
end
