# == Schema Information
#
# Table name: custom_roles
#
#  id                        :bigint           not null, primary key
#  can_view_unassigned_queue :boolean          default(TRUE), not null
#  description               :string
#  name                      :string
#  permissions               :text             default([]), is an Array
#  scope_ids                 :integer          default([]), is an Array
#  scope_type                :string           default("all"), not null
#  visibility_scope          :string
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  account_id                :bigint           not null
#
# Indexes
#
#  index_custom_roles_on_account_id  (account_id)
#

# Available permissions for custom roles:
# - 'conversation_manage': Can manage all conversations.
# - 'conversation_unassigned_manage': Can manage unassigned conversations and assign to self.
# - 'conversation_participating_manage': Can manage conversations they are participating in (assigned to or a participant).
# - 'contact_manage': Can manage contacts.
# - 'report_manage': Can manage reports.
# - 'knowledge_base_manage': Can manage knowledge base portals.

class CustomRole < ApplicationRecord
  belongs_to :account
  has_many :account_users, dependent: :nullify

  PERMISSIONS = %w[
    conversation_manage
    conversation_unassigned_manage
    conversation_participating_manage
    contact_manage
    report_manage
    knowledge_base_manage
  ].freeze

  SCOPE_TYPES = %w[all inboxes teams].freeze

  validates :name, presence: true
  validates :permissions, inclusion: { in: PERMISSIONS }
  validates :scope_type, inclusion: { in: SCOPE_TYPES }

  def scoped_inboxes(account)
    return account.inboxes if scope_type == 'all'
    return account.inboxes.where(id: scope_ids) if scope_type == 'inboxes'
    return account.teams.where(id: scope_ids).includes(:inboxes).flat_map(&:inboxes) if scope_type == 'teams'

    account.inboxes
  end
end
