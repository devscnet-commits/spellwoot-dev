# Structured playbook. The user fills structure (objetivo/steps/transfer_when/close_when/messages)
# and the system compiles it into the final prompt — the user never writes raw prompt.
# == Schema Information
#
# Table name: ai_playbooks
#
#  id               :bigint           not null, primary key
#  active           :boolean          default(TRUE), not null
#  close_when       :jsonb            not null
#  default_messages :jsonb            not null
#  lock_version     :integer          default(0), not null
#  objetivo         :text
#  steps            :jsonb            not null
#  transfer_when    :jsonb            not null
#  version          :integer          default(1), not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  ai_agent_id      :bigint           not null
#
# Indexes
#
#  index_ai_playbooks_on_ai_agent_id  (ai_agent_id)
#
class Ai::Playbook < ApplicationRecord
  belongs_to :agent, class_name: 'Ai::Agent', foreign_key: :ai_agent_id

  # O playbook não tem account_id próprio; vem do agent. Necessário para ser um `versionable`
  # válido do Ai::Version (snapshot! grava account_id lido do record). Antes o Ai::PlaybookVersion
  # resolvia isso manualmente via playbook.department.account_id.
  delegate :account_id, to: :agent

  # Campos versionados (histórico + rollback) via Ai::Version polimórfico. Colunas planas: o restore
  # SUBSTITUI o valor inteiro — inclusive steps (array) e default_messages (hash), que nunca são
  # mesclados com o estado atual. Antes viviam em Ai::PlaybookVersion::SNAPSHOT_FIELDS.
  SNAPSHOT_FIELDS = %w[objetivo steps transfer_when close_when default_messages].freeze

  # H6 — validação de ESCRITA do desfecho: o time do on_complete de cada etapa tem de estar na whitelist do
  # AGENTE (agent.handoff_team_ids). Antes só a UI gateava (select populado da whitelist); um save
  # por console/API/import gravava time fora da lista e só a LEITURA pegava (conclusion.team_unlisted).
  # Paridade com o fallback (H4) e o match_team_by_name (H2/#331): whitelist VAZIA = configuração ausente,
  # rejeita (não é permissão ampla). ISENTO no restore (:restoring) — rollback re-aplica estado JÁ persistido
  # e não deve ser barrado pela whitelist de HOJE (senão o usuário não consegue voltar atrás).
  attr_accessor :restoring

  validate :on_complete_teams_in_whitelist, unless: :restoring

  private

  def on_complete_teams_in_whitelist
    whitelist = Array(agent&.handoff_team_ids).map(&:to_i)
    Array(steps).each_with_index do |step, index|
      team_id = unlisted_conclusion_team(step, whitelist)
      next unless team_id

      errors.add(:steps, "etapa #{index + 1}: o time do desfecho (#{team_id}) não está na lista " \
                         '"Transferir para times" do agente (whitelist vazia = nenhum time permitido)')
    end
  end

  # O team_id do on_complete desta etapa QUANDO fora da whitelist (senão nil). Whitelist vazia => todo id
  # declarado é "fora" (config ausente, não permissão).
  def unlisted_conclusion_team(step, whitelist)
    return nil unless step.is_a?(Hash)

    on_complete = step['on_complete']
    return nil unless on_complete.is_a?(Hash)

    team_id = on_complete['team_id']
    return nil if team_id.blank? || whitelist.include?(team_id.to_i)

    team_id
  end
end
