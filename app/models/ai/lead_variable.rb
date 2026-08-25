# A lead variable the agent collects during the conversation (Instruções tab). Per agent.
# == Schema Information
#
# Table name: ai_lead_variables
#
#  id                    :bigint           not null, primary key
#  description           :text
#  name                  :string           not null
#  position              :integer          default(0), not null
#  values                :jsonb            not null
#  var_type              :string           default("texto"), not null
#  visible_in_first_chat :boolean          default(FALSE), not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  account_id            :bigint           not null
#  ai_agent_id           :bigint           not null
#
# Indexes
#
#  index_ai_lead_variables_on_ai_agent_id  (ai_agent_id)
#
class Ai::LeadVariable < ApplicationRecord
  VAR_TYPES = %w[texto numero booleano lista].freeze
  # Formato da CHAVE (não do vocabulário): a chave vai para ai_collected_facts e CustomerMemory.key_facts e é
  # comparada por string em vários pontos (gate, prompt) — acento/espaço/símbolo é frágil. Regra de FORMATO,
  # agnóstica de idioma: minúsculas, [a-z0-9_], começando por letra.
  NAME_FORMAT = /\A[a-z][a-z0-9_]*\z/

  belongs_to :account, class_name: '::Account'
  belongs_to :agent, class_name: 'Ai::Agent', foreign_key: :ai_agent_id, inverse_of: :lead_variables

  # SÓ on: :create — normalizar/validar no update RENOMEARIA uma variável existente, orfanando o dado já
  # coletado nas conversas em andamento (ai_collected_facts) e na memória do contato (key_facts, imutável e
  # cross-conversa). As antigas fora do padrão ficam como estão; só as NOVAS nascem normalizadas.
  before_validation :normalize_name, on: :create

  validates :name, presence: true
  validates :name, format: { with: NAME_FORMAT, message: I18n.t('errors.messages.invalid') },
                   length: { maximum: 60 }, on: :create
  # rubocop:disable Rails/UniqueValidationWithoutIndex -- índice único exigiria migração de dados (pode haver
  # dup legado); a validação é on: :create e best-effort — impede NOVA duplicata pela UI, sem tocar as existentes
  validates :name, uniqueness: { scope: :ai_agent_id, case_sensitive: false }, on: :create
  # rubocop:enable Rails/UniqueValidationWithoutIndex
  validates :var_type, inclusion: { in: VAR_TYPES }

  # Transliteração ASCII (I18n.transliterate: "número" -> "numero"; escrita não-latina -> "?") + só [a-z0-9_].
  # Resultado vazio (ex.: só caracteres não-latinos/símbolos) cai na validação de formato com mensagem clara —
  # NÃO grava chave vazia. O front espelha esta função para o preview (o usuário vê o que vai virar).
  def normalize_name
    return if name.blank?

    n = I18n.transliterate(name.to_s).downcase
    self.name = n.gsub(/[^a-z0-9_]+/, '_').squeeze('_').gsub(/\A_+|_+\z/, '')
  end
end
