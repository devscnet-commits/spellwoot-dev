# Independent quality observer: watches its linked inboxes and audits human + AI handling,
# feeding the Validação screen. Configured with evaluation instructions (not a reply prompt).
# == Schema Information
#
# Table name: ai_shadows
#
#  id           :bigint           not null, primary key
#  data_signals :jsonb            not null
#  instructions :text
#  name         :string           not null
#  scope        :jsonb            not null
#  status       :string           default("active"), not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  account_id   :bigint           not null
#
# Indexes
#
#  index_ai_shadows_on_account_id  (account_id)
#
class Ai::Shadow < ApplicationRecord
  belongs_to :account, class_name: '::Account'
  has_many :shadow_inboxes, class_name: 'Ai::ShadowInbox', foreign_key: :ai_shadow_id, dependent: :delete_all
  has_many :inboxes, through: :shadow_inboxes

  validates :name, presence: true

  scope :active, -> { where(status: 'active') }
end
