# == Schema Information
#
# Table name: teams
#
#  id                :bigint           not null, primary key
#  allow_auto_assign :boolean          default(TRUE)
#  description       :text
#  name              :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  account_id        :bigint           not null
#
# Indexes
#
#  index_teams_on_account_id           (account_id)
#  index_teams_on_name_and_account_id  (name,account_id) UNIQUE
#
class Team < ApplicationRecord
  include AccountCacheRevalidator

  belongs_to :account
  # The closing flow conversations of this team follow; the caixa's flow is only a fallback.
  belongs_to :operational_flow, optional: true
  has_many :team_members, dependent: :destroy_async
  has_many :members, through: :team_members, source: :user
  # team_inboxes carries a NOT NULL foreign key to teams, so the async cleanup would leave
  # the team delete blocked by the constraint — delete the links in-line instead.
  has_many :team_inboxes, dependent: :delete_all
  has_many :inboxes, through: :team_inboxes
  has_many :conversations, dependent: :nullify
  # Reporting/outcome rows only reference the team for attribution and carry no FK constraint,
  # so deleting a team must keep the historical events but detach them instead of blocking.
  has_many :reporting_events, dependent: :nullify
  has_many :conversation_result_events, dependent: :nullify

  validates :name,
            presence: { message: I18n.t('errors.validations.presence') },
            uniqueness: { scope: :account_id, case_sensitive: false }

  before_validation do
    # Preserve the casing the user typed (e.g. "Mídia Paga"); only trim stray whitespace.
    # Uniqueness stays case-insensitive so "Vendas" and "vendas" still can't coexist.
    self.name = name.strip if attribute_present?('name')
  end

  # Adds multiple members to the team
  # @param user_ids [Array<Integer>] Array of user IDs to add as members
  # @return [Array<User>] Array of newly added members
  def add_members(user_ids, role: :member)
    team_members_to_create = user_ids.map { |user_id| { user_id: user_id, role: role } }
    created_members = team_members.create(team_members_to_create)
    update_account_cache
    created_members.filter_map(&:user)
  end

  # Full replacement of team members preserving roles.
  # members_data: [{user_id:, role:}]
  def sync_members_with_roles(members_data)
    incoming_ids = members_data.map { |m| m[:user_id].to_i }
    current_ids  = team_members.pluck(:user_id)

    add_ids    = incoming_ids - current_ids
    remove_ids = current_ids - incoming_ids
    keep_ids   = current_ids & incoming_ids

    team_members.where(user_id: remove_ids).destroy_all if remove_ids.any?

    add_ids.each do |uid|
      role = members_data.find { |m| m[:user_id].to_i == uid }&.fetch(:role, 'member') || 'member'
      team_members.create!(user_id: uid, role: role)
    end

    keep_ids.each do |uid|
      desired_role = members_data.find { |m| m[:user_id].to_i == uid }&.fetch(:role, nil)
      next unless desired_role

      team_members.find_by(user_id: uid)&.update!(role: desired_role)
    end

    update_account_cache
  end

  # Removes multiple members from the team
  def remove_members(user_ids)
    team_members.where(user_id: user_ids).destroy_all
    update_account_cache
  end

  def messages
    account.messages.where(conversation_id: conversations.pluck(:id))
  end

  def reporting_events
    account.reporting_events.where(conversation_id: conversations.pluck(:id))
  end

  def push_event_data
    {
      id: id,
      name: name
    }
  end
end

Team.include_mod_with('Audit::Team')
