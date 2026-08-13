# Cost/quality profile. Provider-agnostic: points to a supervisor provider + model so we are
# never locked to a single vendor.
# == Schema Information
#
# Table name: ai_operation_profiles
#
#  id                     :bigint           not null, primary key
#  budget                 :jsonb            not null
#  name                   :string           not null
#  routing_strategy       :jsonb            not null
#  supervisor_model       :string           not null
#  supervisor_provider    :string           not null
#  supervisor_temperature :decimal(3, 2)    default(0.3), not null
#  temperature_position   :integer          default(20), not null
#  tier                   :string           default("customizado"), not null
#  worker_overrides       :jsonb            not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  account_id             :bigint           not null
#
# Indexes
#
#  index_ai_operation_profiles_on_account_id  (account_id)
#
class Ai::OperationProfile < ApplicationRecord
  # Modelos Groq APROVADOS para resposta ao cliente. Restrição de SEGURANÇA (não só qualidade): no
  # smoke test, o llama-3.1-8b-instant recomendou CONCORRENTES da empresa numa resposta de teste —
  # risco de negócio. Só o gpt-oss-120b passou (manteve personagem, não alucinou). A UI já restringe
  # (dropdown fechado só para groq); esta lista + a validação abaixo são a defesa em profundidade
  # contra save por API direta. Manter em sincronia com GROQ_APPROVED_MODELS de AiProfiles.vue.
  GROQ_APPROVED_MODELS = ['openai/gpt-oss-120b'].freeze

  belongs_to :account, class_name: '::Account'
  has_many :agents, class_name: 'Ai::Agent', foreign_key: :ai_operation_profile_id

  validates :name, :supervisor_provider, :supervisor_model, presence: true
  validate :groq_supervisor_model_approved
  # Posição abstrata do slider (0-100). O Ai::TemperatureMapper traduz para a temperatura real de
  # cada provider — é este o valor de fato usado no fluxo hoje.
  validates :temperature_position, numericality: {
    only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100
  }
  # LEGADO: supervisor_temperature (cru, 0-2) não é mais usado no fluxo (substituído por
  # temperature_position + TemperatureMapper). Mantido por ora; dropar em limpeza futura.
  validates :supervisor_temperature, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 2 }

  # Config do worker auxiliar `key` (ex.: 'ocr', 'summary', 'translation', 'rag'). worker_overrides é
  # SEMPRE aninhado (a UI salva { key => { 'provider'=>, 'model'=> } }). Centralizado aqui porque ler
  # flat (ex.: worker_overrides['summary_provider']) foi um bug recorrente — Summary e OCR usam este
  # método. Retorna {} quando não configurado; o caller decide o fallback (OCR = opt-in, sem
  # supervisor; Summary = cai no supervisor).
  def worker(key)
    worker_overrides&.dig(key.to_s) || {}
  end

  private

  # Bloqueia salvar um modelo Groq FORA da allowlist (só o supervisor — o modelo que responde o
  # cliente). Outros providers seguem livres. Ver GROQ_APPROVED_MODELS.
  def groq_supervisor_model_approved
    return unless supervisor_provider == 'groq'
    return if GROQ_APPROVED_MODELS.include?(supervisor_model)

    errors.add(:supervisor_model,
               "não é um modelo Groq aprovado (permitidos: #{GROQ_APPROVED_MODELS.join(', ')})")
  end
end
