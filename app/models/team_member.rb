# == Schema Information
#
# Table name: team_members
#
#  id         :bigint           not null, primary key
#  role       :integer          default("member"), not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  team_id    :bigint           not null
#  user_id    :bigint           not null
#
# Indexes
#
#  index_team_members_on_role                 (role)
#  index_team_members_on_team_id              (team_id)
#  index_team_members_on_team_id_and_user_id  (team_id,user_id) UNIQUE
#  index_team_members_on_user_id              (user_id)
#
class TeamMember < ApplicationRecord
  belongs_to :user
  belongs_to :team

  enum role: { member: 0, coordinator: 1, manager: 2 }

  scope :coordinators, -> { where(role: :coordinator) }
  scope :managers, -> { where(role: :manager) }
  scope :with_elevated_access, -> { where(role: [:coordinator, :manager]) }

  validates :user_id, uniqueness: { scope: :team_id }
  # An agent belongs to a single team: the team reveals which closing flow the conversations
  # they receive should follow, so double membership would make the flow ambiguous.
  validate :single_team_per_account, on: :create

  private

  def single_team_per_account
    return if team.blank? || user_id.blank?

    conflict = TeamMember.joins(:team)
                         .where(teams: { account_id: team.account_id }, user_id: user_id)
                         .where.not(team_id: team_id)
                         .first
    errors.add(:user_id, "já pertence ao time #{conflict.team.name}") if conflict
  end
end

TeamMember.include_mod_with('Audit::TeamMember')
