# Cost/quality profile. Provider-agnostic: points to a supervisor provider + model so we are
# never locked to a single vendor.
# == Schema Information
#
# Table name: ai_operation_profiles
#
#  id                  :bigint           not null, primary key
#  budget              :jsonb            not null
#  name                :string           not null
#  routing_strategy    :jsonb            not null
#  supervisor_model       :string           not null
#  supervisor_provider    :string           not null
#  supervisor_temperature :decimal(3, 2)    default(0.3), not null
#  tier                :string           default("customizado"), not null
#  worker_overrides    :jsonb            not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  account_id          :bigint           not null
#
# Indexes
#
#  index_ai_operation_profiles_on_account_id  (account_id)
#
class Ai::OperationProfile < ApplicationRecord
  belongs_to :account, class_name: '::Account'
  has_many :agents, class_name: 'Ai::Agent', foreign_key: :ai_operation_profile_id

  validates :name, :supervisor_provider, :supervisor_model, presence: true
  # Faixa aceita pelos provedores (OpenAI/Anthropic/Gemini): 0 (determinístico) a 2 (criativo).
  validates :supervisor_temperature, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 2 }
end
