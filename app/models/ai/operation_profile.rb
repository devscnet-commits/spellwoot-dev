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
  # Achado ao vivo (18/08): sem isso, clicar "Novo nível" -> "Máxima Qualidade" -> Salvar repetidas
  # vezes (sem editar o nome, que o preset já preenche com "Premium") criava vários perfis IDÊNTICOS
  # no nome, sem nenhum aviso — indistinguíveis na hora de escolher qual usar num agente. Sem índice
  # único no banco (tela de admin, baixa concorrência — o risco de corrida é aceitável aqui).
  validates :name, uniqueness: {
    scope: :account_id, case_sensitive: false, message: 'já está em uso — escolha um nome diferente'
  }
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

  # Pedido do usuário (18/08): o campo "Orçamento" (budget.monthly_usd/on_limit) era só decorativo —
  # nada no backend lia. O teto é do PERFIL, não de um agente isolado — um perfil pode ser reaproveitado
  # por vários agentes (has_many :agents acima) — então soma o gasto de TODOS eles. Usa Ai::Run#cost (o
  # valor GRAVADO por Ai::ModelRouter.estimate_cost no momento da chamada), não um recálculo pelo preço
  # atual — isso é o que a tela "Custo de IA" já faz (Ai::ModelRouter.price_for); aqui só decide se
  # estourou o teto ou não, com o mesmo custo que o próprio Ai::Run já registrou.
  def month_to_date_cost
    Ai::Run.where(ai_agent_id: agents.select(:id), created_at: Time.current.beginning_of_month..).sum(:cost).to_f
  end

  def budget_monthly_usd
    budget.to_h['monthly_usd'].to_f
  end

  def budget_on_limit
    budget.to_h['on_limit'].presence || 'downgrade'
  end

  # Sem teto configurado (0/ausente) => nunca estourado. Ver Ai::Gateway#budget_exceeded? (ponto de uso).
  def budget_exceeded?
    budget_monthly_usd.positive? && month_to_date_cost >= budget_monthly_usd
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
