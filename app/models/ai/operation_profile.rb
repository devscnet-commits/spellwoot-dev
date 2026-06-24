# Cost/quality profile. Provider-agnostic: points to a supervisor provider + model so we are
# never locked to a single vendor.
class Ai::OperationProfile < ApplicationRecord
  belongs_to :account, class_name: '::Account'
  has_many :agents, class_name: 'Ai::Agent', foreign_key: :ai_operation_profile_id

  validates :name, :supervisor_provider, :supervisor_model, presence: true
end
