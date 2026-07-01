# frozen_string_literal: true

# == Schema Information
#
# Table name: team_inboxes
#
#  id         :bigint           not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  inbox_id   :bigint           not null
#  team_id    :bigint           not null
#
# Indexes
#
#  index_team_inboxes_on_inbox_id              (inbox_id)
#  index_team_inboxes_on_team_id               (team_id)
#  index_team_inboxes_on_team_id_and_inbox_id  (team_id,inbox_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (inbox_id => inboxes.id)
#  fk_rails_...  (team_id => teams.id)
#
class TeamInbox < ApplicationRecord
  # touch: the cached teams payload includes inbox_ids, so linking/unlinking a caixa must
  # bump the team's cache key — otherwise the frontend serves the stale list forever and
  # screens keep claiming the team has no caixas.
  belongs_to :team, touch: true
  belongs_to :inbox

  validates :inbox_id, uniqueness: { scope: :team_id }
end
