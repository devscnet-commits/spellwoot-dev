# Independent quality observer: watches its linked inboxes and audits human + AI handling,
# feeding the Validação screen. Configured with evaluation instructions (not a reply prompt).
class Ai::Shadow < ApplicationRecord
  belongs_to :account, class_name: '::Account'
  has_many :shadow_inboxes, class_name: 'Ai::ShadowInbox', foreign_key: :ai_shadow_id, dependent: :delete_all
  has_many :inboxes, through: :shadow_inboxes

  validates :name, presence: true

  scope :active, -> { where(status: 'active') }
end
