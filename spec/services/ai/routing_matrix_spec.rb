require 'rails_helper'

# BATERIA DE ROTEAMENTO — a matriz dos 5 eixos que interagem (team_id, whitelist, fallback, on_complete,
# motivo) e nunca foram testados juntos. Cada exemplo EXECUTA a combinação e trava o comportamento REAL
# (Ai::HandoffCoordinator#human_team_id p/ give-up e cliente-pediu; #conclusion_team_id p/ funil; validação
# do Ai::Agent p/ a escrita do fallback). Onde o comportamento é errado/inconsistente, o exemplo documenta o
# REAL e um comentário marca o que DEVERIA ser — NÃO conserta nada.
# A bateria cruza vários métodos (human_team_id/conclusion_team_id + validação do Ai::Agent), não uma classe.
RSpec.describe 'Roteamento de handoff — matriz (bateria)' do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: 'open') }
  let(:message) do
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: 'incoming')
  end
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }
  let(:coordinator) do
    Ai::HandoffCoordinator.new(conversation: conversation, account: account, agent: agent, message: message)
  end

  # dois times na whitelist (ordem: comercial 1º), um FORA (existe na conta, não declarado)
  let(:t_comercial) { create(:team, account: account, name: 'Comercial') }
  let(:t_suporte) { create(:team, account: account, name: 'Suporte') }
  let(:t_posvenda) { create(:team, account: account, name: 'Pos Venda') }

  def ev(type)
    Ai::Event.where(conversation_id: conversation.id, event_type: type)
  end

  # ---------------------------------------------------------------------------------------------------
  describe 'H1 — agent.team_id curto-circuita TUDO (issue registrada, nunca provada)' do
    it 'team_id setado + cliente pede "Suporte" (na whitelist) -> vai para o team_id, IGNORA a intenção' do
      agent.update!(team_id: t_posvenda.id, handoff_team_ids: [t_comercial.id, t_suporte.id],
                    fallback_handoff_team_id: nil)
      result = coordinator.human_team_id({ 'handoff_target' => 'Suporte' })
      # REAL: team_id vence a intenção do cliente, a whitelist e o fallback.
      expect(result).to eq(t_posvenda.id)
      # DEVERIA: a intenção "Suporte" deveria vencer. team_id sobrepõe whitelist+intenção+fallback (issue).
    end
  end

  # ---------------------------------------------------------------------------------------------------
  describe 'H2 — whitelist VAZIA NÃO abre para qualquer time da conta (CONSERTADO)' do
    it 'whitelist vazia + target "Pos Venda" (existe na conta, fora da whitelist) -> NÃO casa; cai no configured (nil)' do
      agent.update!(team_id: nil, handoff_team_ids: [])
      t_posvenda # existe na conta, mas NÃO marcado
      result = coordinator.human_team_id({ 'handoff_target' => 'Pos Venda' })
      # H2 CONSERTADO: whitelist vazia = configuração ausente, não casa nada (alinha com a regra do fallback).
      # PROVA DE MUTAÇÃO: FALHA se a whitelist vazia voltar a varrer a conta e casar um time NÃO declarado.
      expect(result).to be_nil
    end
  end

  # ---------------------------------------------------------------------------------------------------
  describe 'H3 — whitelist vazia + give-up: para onde vai?' do
    it 'give-up (decision {}) com whitelist vazia -> nil (configured_handoff_team_id devolve nil)' do
      agent.update!(team_id: nil, handoff_team_ids: [])
      # REAL: nil. O Gateway trata nil como "sem time configurado" (alerta ao dono). Correto.
      expect(coordinator.human_team_id({})).to be_nil
    end
  end

  # ---------------------------------------------------------------------------------------------------
  describe 'H4 — fallback fora da whitelist' do
    before { agent.update!(team_id: nil, handoff_team_ids: [t_comercial.id]) }

    it 'ESCRITA: fallback fora da whitelist é REJEITADO (Ai::Agent inválido)' do
      agent.fallback_handoff_team_id = t_posvenda.id
      expect(agent.valid?).to be(false)
    end

    it 'LEITURA: fallback gravado por fora (bypass) emite handoff.fallback_unlisted e cai no configured' do
      # rubocop:disable Rails/SkipsModelValidations -- de propósito: simula fallback gravado por FORA da validação
      agent.update_column(:fallback_handoff_team_id, t_posvenda.id)
      # rubocop:enable Rails/SkipsModelValidations
      result = nil
      expect { result = coordinator.human_team_id({}) }.to change { ev('handoff.fallback_unlisted').count }.by(1)
      expect(result).to eq(t_comercial.id) # configured (whitelist), NÃO o não-listado
    end
  end

  # ---------------------------------------------------------------------------------------------------
  describe 'H5 — fallback válido + whitelist esvaziada depois: NÃO honrado' do
    it 'give-up NÃO usa o fallback (whitelist vazia = config ausente), sem fallback_unlisted, cai no atual (nil)' do
      agent.update!(team_id: nil, handoff_team_ids: [t_comercial.id], fallback_handoff_team_id: t_comercial.id)
      # rubocop:disable Rails/SkipsModelValidations -- de propósito: esvazia a whitelist DEPOIS (out-of-band)
      agent.update_column(:handoff_team_ids, [])
      # rubocop:enable Rails/SkipsModelValidations
      result = nil
      expect { result = coordinator.human_team_id({}) }.not_to(change { ev('handoff.fallback_unlisted').count })
      expect(result).to be_nil # não honra o fallback; whitelist vazia -> configured nil
    end
  end

  # ---------------------------------------------------------------------------------------------------
  describe 'H6 — on_complete com time fora da whitelist' do
    before { agent.update!(team_id: nil, handoff_team_ids: [t_comercial.id]) }

    it 'LEITURA (conclusion_team_id): time fora da whitelist -> conclusion.team_unlisted e cai no configured' do
      result = nil
      expect { result = coordinator.conclusion_team_id({ 'team_id' => t_posvenda.id }) }
        .to change { ev('conclusion.team_unlisted').count }.by(1)
      expect(result).to eq(t_comercial.id)
    end

    it 'LEITURA: time DENTRO da whitelist -> roteia direto, sem evento' do
      result = nil
      expect { result = coordinator.conclusion_team_id({ 'team_id' => t_comercial.id }) }
        .not_to(change { ev('conclusion.team_unlisted').count })
      expect(result).to eq(t_comercial.id)
    end
    # ESCRITA: NÃO há validação backend do on_complete.team_id contra a whitelist (só a UI gateia pelo select).
    # O ai_departments_controller valida automations[], não on_complete -> um save por console/API com time
    # fora da whitelist é ARMAZENADO e só é pego na LEITURA acima. (H6 "bloqueado na escrita" = parcialmente
    # falso: bloqueio é só de UI, não de backend.) Ver tabela.
  end

  # ---------------------------------------------------------------------------------------------------
  describe 'H7 — conclusion_team_id (funil) vs human_team_id (give-up) concordam?' do
    before { agent.update!(team_id: nil, handoff_team_ids: [t_comercial.id, t_suporte.id]) }

    it 'sem team_id: give-up sem destino E conclusão sem team_id -> AMBOS caem no configured (concordam)' do
      expect(coordinator.human_team_id({})).to eq(coordinator.conclusion_team_id({}))
    end

    it 'com team_id override: human_team_id retorna o override; conclusion_team_id NÃO o consulta -> DISCORDAM' do
      agent.update!(team_id: t_posvenda.id)
      aggregate_failures do
        expect(coordinator.human_team_id({})).to eq(t_posvenda.id)       # respeita o override
        expect(coordinator.conclusion_team_id({})).to eq(t_comercial.id) # IGNORA o override -> configured
      end
      # INCONSISTENTE: os dois caminhos DISCORDAM com team_id setado — a conclusão não respeita o override.
    end
  end

  # ---------------------------------------------------------------------------------------------------
  describe 'Matriz — motivo × whitelist × fallback (células principais)' do
    it 'give-up + 1 time na whitelist, sem fallback -> aquele time' do
      agent.update!(team_id: nil, handoff_team_ids: [t_suporte.id])
      expect(coordinator.human_team_id({})).to eq(t_suporte.id)
    end

    it 'give-up + vários, sem fallback -> o 1º da ORDEM marcada (comercial), não por id' do
      agent.update!(team_id: nil, handoff_team_ids: [t_comercial.id, t_suporte.id])
      expect(coordinator.human_team_id({})).to eq(t_comercial.id)
    end

    it 'give-up + vários + fallback declarado (2º) -> o FALLBACK, não o 1º (acidente de ordenação corrigido)' do
      agent.update!(team_id: nil, handoff_team_ids: [t_comercial.id, t_suporte.id], fallback_handoff_team_id: t_suporte.id)
      expect(coordinator.human_team_id({})).to eq(t_suporte.id)
    end

    it 'cliente pediu (target CASADO na whitelist) -> o time pedido, IGNORA o fallback' do
      agent.update!(team_id: nil, handoff_team_ids: [t_comercial.id, t_suporte.id], fallback_handoff_team_id: t_comercial.id)
      expect(coordinator.human_team_id({ 'handoff_target' => 'Suporte' })).to eq(t_suporte.id)
    end

    it 'cliente pediu (target NÃO casado) + fallback declarado -> usa o FALLBACK (H8), mantendo target_unmatched' do
      agent.update!(team_id: nil, handoff_team_ids: [t_comercial.id, t_suporte.id], fallback_handoff_team_id: t_suporte.id)
      result = nil
      expect { result = coordinator.human_team_id({ 'handoff_target' => 'Jurídico' }) }
        .to change { ev('handoff.target_unmatched').count }.by(1) # telemetria PRESERVADA
      # H8: intenção-falha (setor inexistente) vai para o FALLBACK (suporte), NÃO o 1º da lista (comercial).
      # PROVA DE MUTAÇÃO: falha se voltar a cair no configured (o acidente de ordenação).
      expect(result).to eq(t_suporte.id)
    end

    it 'cliente pediu (target NÃO casado) SEM fallback -> configured (1º) + target_unmatched (H8 "senão configured")' do
      agent.update!(team_id: nil, handoff_team_ids: [t_comercial.id, t_suporte.id])
      result = nil
      expect { result = coordinator.human_team_id({ 'handoff_target' => 'Jurídico' }) }
        .to change { ev('handoff.target_unmatched').count }.by(1)
      expect(result).to eq(t_comercial.id) # sem fallback declarado: cai no 1º da whitelist
    end

    it 'funil concluiu (on_complete team_id na whitelist) -> aquele time' do
      agent.update!(team_id: nil, handoff_team_ids: [t_comercial.id, t_suporte.id])
      expect(coordinator.conclusion_team_id({ 'team_id' => t_suporte.id })).to eq(t_suporte.id)
    end
  end
end
