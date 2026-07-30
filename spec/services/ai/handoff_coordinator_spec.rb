require 'rails_helper'

RSpec.describe Ai::HandoffCoordinator do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: 'open') }
  let(:message) { create(:message, account: account, inbox: inbox, conversation: conversation, message_type: 'incoming') }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }
  let(:coordinator) do
    described_class.new(conversation: conversation, account: account, agent: agent, message: message)
  end

  describe '#assign_human — enqueue do resumo de handoff' do
    it 'enfileira Ai::HandoffSummaryJob com o reason quando o handoff é automático (reason presente)' do
      expect { coordinator.assign_human(nil, reason: 'loop') }
        .to have_enqueued_job(Ai::HandoffSummaryJob).with(conversation.id, 'loop')
    end

    it 'propaga qualquer reason recebido (ex.: credit_exhausted)' do
      expect { coordinator.assign_human(nil, reason: 'credit_exhausted') }
        .to have_enqueued_job(Ai::HandoffSummaryJob).with(conversation.id, 'credit_exhausted')
    end

    it 'NÃO enfileira quando não há reason (handoff não-automático / chamada sem reason)' do
      expect { coordinator.assign_human(nil, reason: nil) }
        .not_to have_enqueued_job(Ai::HandoffSummaryJob)
    end
  end

  describe '#assign_human — sem membro atribuível (visibilidade)' do
    let(:empty_team) { create(:team, account: account) } # criado sem membros

    before { allow(OnlineStatusTracker).to receive(:get_available_users).and_return({}) }

    it 'aplica a tag "sem-agente-disponivel" na conversa' do
      allow(Ai::CapabilityRegistry).to receive(:execute)

      coordinator.assign_human(empty_team.id, reason: 'modelo_pediu_transferencia')

      expect(Ai::CapabilityRegistry).to have_received(:execute)
        .with('conversation.add_label', hash_including(input: { 'label' => 'sem-agente-disponivel' }))
    end

    it 'notifica o admin da conta por e-mail' do
      allow(Ai::CapabilityRegistry).to receive(:execute)

      expect { coordinator.assign_human(empty_team.id, reason: 'loop') }
        .to have_enqueued_mail(AdministratorNotifications::AccountNotificationMailer, :handoff_no_agent_available)
    end

    it 'emite handoff.assign_failed com reason no_assignable_member' do
      allow(Ai::CapabilityRegistry).to receive(:execute)

      coordinator.assign_human(empty_team.id, reason: 'loop')

      event = Ai::Event.where(conversation_id: conversation.id, event_type: 'handoff.assign_failed').last
      expect(event).to be_present
      expect(event.payload['reason']).to eq('no_assignable_member')
      expect(event.status).to eq('error')
    end

    it 'não duplica a notificação para o mesmo time dentro da janela de throttle' do
      allow(Ai::CapabilityRegistry).to receive(:execute)
      # null_store (teste) não persiste; um MemoryStore real exercita o throttle
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)

      expect do
        coordinator.assign_human(empty_team.id, reason: 'loop')
        described_class.new(conversation: conversation, account: account, agent: agent, message: message)
                       .assign_human(empty_team.id, reason: 'loop')
      end.to have_enqueued_mail(AdministratorNotifications::AccountNotificationMailer, :handoff_no_agent_available).once
    end
  end

  describe '#assign_human — caminho feliz (há membro no time)' do
    let(:team) { create(:team, account: account) }
    let(:member) { create(:inbox_member, inbox: inbox) }

    before do
      create(:account_user, account: account, user: member.user)
      create(:team_member, team: team, user: member.user)
      allow(OnlineStatusTracker).to receive(:get_available_users).and_return({})
    end

    it 'atribui um membro do time e NÃO aplica tag nem notifica' do
      allow(Ai::CapabilityRegistry).to receive(:execute)

      expect { coordinator.assign_human(team.id, reason: 'loop') }
        .not_to have_enqueued_mail(AdministratorNotifications::AccountNotificationMailer, :handoff_no_agent_available)

      expect(conversation.reload.assignee_id).to eq(member.user_id)
      expect(Ai::CapabilityRegistry).not_to have_received(:execute)
        .with('conversation.add_label', hash_including(input: { 'label' => 'sem-agente-disponivel' }))
    end
  end

  # === Mudanças 1 + 2: o roteamento passa a LER a lista handoff_team_ids ==========================
  describe '#human_team_id — ordem de resolução (team_id -> nome[allowlist] -> lista -> nil)' do
    let(:t_comercial) { create(:team, account: account, name: 'Comerciais') }
    let(:t_midia) { create(:team, account: account, name: 'Comercial Mídia Paga') }
    let(:t_outro) { create(:team, account: account, name: 'Financeiro') }

    it 'usa @agent.team_id quando presente (primário, mantido)' do
      agent.update!(team_id: t_outro.id)
      expect(coordinator.human_team_id({ 'handoff_target' => 'Comerciais' })).to eq(t_outro.id)
    end

    it 'sem team_id e com handoff_team_ids: resolve pela lista mesmo SEM handoff_target (caso do loop)' do
      agent.update!(team_id: nil, handoff_team_ids: [t_comercial.id, t_midia.id])
      expect([t_comercial.id, t_midia.id]).to include(coordinator.human_team_id({}))
    end

    it 'casa handoff_target quando ele ESTÁ na allowlist (acento/caixa tolerados)' do
      agent.update!(team_id: nil, handoff_team_ids: [t_comercial.id, t_midia.id])
      expect(coordinator.human_team_id({ 'handoff_target' => 'comercial midia paga' })).to eq(t_midia.id)
    end

    it 'handoff_target FORA da allowlist não casa; segue para um time da lista' do
      agent.update!(team_id: nil, handoff_team_ids: [t_comercial.id, t_midia.id])
      result = coordinator.human_team_id({ 'handoff_target' => 'Financeiro' })
      expect([t_comercial.id, t_midia.id]).to include(result)
      expect(result).not_to eq(t_outro.id)
    end

    # Ajuste (a) — o fallback silencioso agora é MEDIDO. Prova de mutação: o evento carrega o
    # handoff_target recebido ('Financeiro') e o time escolhido (um da whitelist). Some se a emissão sair.
    it 'emite handoff.target_unmatched quando o target não casa e cai no configured' do
      agent.update!(team_id: nil, handoff_team_ids: [t_comercial.id, t_midia.id])
      expect { coordinator.human_team_id({ 'handoff_target' => 'Financeiro' }) }
        .to change { Ai::Event.where(event_type: 'handoff.target_unmatched').count }.by(1)
      ev = Ai::Event.where(event_type: 'handoff.target_unmatched').last
      expect(ev.payload['handoff_target']).to eq('Financeiro')
      expect([t_comercial.id, t_midia.id]).to include(ev.payload['chosen_team_id'])
    end

    it 'NÃO emite handoff.target_unmatched quando o target CASA (comercial midia paga)' do
      agent.update!(team_id: nil, handoff_team_ids: [t_comercial.id, t_midia.id])
      expect { coordinator.human_team_id({ 'handoff_target' => 'comercial midia paga' }) }
        .not_to change { Ai::Event.where(event_type: 'handoff.target_unmatched').count }
    end

    it 'NÃO emite handoff.target_unmatched no loop (decision sem handoff_target)' do
      agent.update!(team_id: nil, handoff_team_ids: [t_comercial.id, t_midia.id])
      expect { coordinator.human_team_id({}) }
        .not_to change { Ai::Event.where(event_type: 'handoff.target_unmatched').count }
    end

    it 'sem team_id, sem allowlist e sem match -> nil' do
      agent.update!(team_id: nil, handoff_team_ids: [])
      expect(coordinator.human_team_id({})).to be_nil
    end
  end

  # (b)-core — destino do desfecho DECLARADO pela etapa (step['on_complete']): team_id direto, validado
  # contra a whitelist na LEITURA (defesa em profundidade); nome como fallback de config antiga.
  describe '#conclusion_team_id — team_id direto validado na whitelist' do
    let(:t_comercial) { create(:team, account: account, name: 'Comerciais') }
    let(:t_suporte) { create(:team, account: account, name: 'Suporte') }
    let(:t_fora) { create(:team, account: account, name: 'Financeiro') } # NÃO marcado na whitelist

    before { agent.update!(team_id: nil, handoff_team_ids: [t_comercial.id, t_suporte.id]) }

    it 'team_id DENTRO da whitelist -> devolve ele, sem evento' do
      result = coordinator.conclusion_team_id({ 'team_id' => t_suporte.id })

      expect(result).to eq(t_suporte.id)
      expect(Ai::Event.where(event_type: 'conclusion.team_unlisted')).not_to exist
    end

    it 'team_id FORA da whitelist -> emite conclusion.team_unlisted e cai no configured (não no id pedido)' do
      result = nil
      expect { result = coordinator.conclusion_team_id({ 'team_id' => t_fora.id }) }
        .to change { Ai::Event.where(event_type: 'conclusion.team_unlisted').count }.by(1)

      expect([t_comercial.id, t_suporte.id]).to include(result)
      expect(result).not_to eq(t_fora.id)
      expect(Ai::Event.where(event_type: 'conclusion.team_unlisted').last.payload['team_id']).to eq(t_fora.id)
    end

    it 'sem team_id, com NOME (config antiga) -> match_team_by_name restrito à whitelist' do
      expect(coordinator.conclusion_team_id({ 'team' => 'suporte' })).to eq(t_suporte.id)
    end

    it 'sem team_id e nome FORA da whitelist -> não casa; cai no configured' do
      result = coordinator.conclusion_team_id({ 'team' => 'Financeiro' })

      expect([t_comercial.id, t_suporte.id]).to include(result)
      expect(result).not_to eq(t_fora.id)
    end
  end

  describe '#configured_handoff_team_id — respeita a ORDEM marcada (array), não o id (Ajuste 1)' do
    let(:t1) { create(:team, account: account, name: 'T1') } # criado 1º => id MENOR
    let(:t2) { create(:team, account: account, name: 'T2') } # id MAIOR
    let(:u1) { create(:user) } # membro de t1
    let(:u2) { create(:user) } # membro de t2

    # Capacidade é determinística via stub (no ambiente de teste ela depende de online/v2). Stuba na
    # instância memoizada de conversation.inbox (a MESMA que o coordinator lê em @conversation.inbox).
    def stub_capacity(user_ids)
      allow(conversation.inbox).to receive(:member_ids_with_assignment_capacity).and_return(user_ids)
    end

    before do
      create(:account_user, account: account, user: u1)
      create(:account_user, account: account, user: u2)
      create(:team_member, team: t1, user: u1)
      create(:team_member, team: t2, user: u2)
    end

    it 'ambos com capacidade: escolhe o PRIMEIRO do array (t2), não o de menor id (t1)' do
      stub_capacity([u1.id, u2.id])
      agent.update!(handoff_team_ids: [t2.id, t1.id]) # t2 marcado 1º

      expect(coordinator.send(:configured_handoff_team_id)).to eq(t2.id)
    end

    it 'só o SEGUNDO do array (t1) tem membro com capacidade: escolhe t1' do
      stub_capacity([u1.id]) # só u1 (de t1)
      agent.update!(handoff_team_ids: [t2.id, t1.id]) # t2 marcado 1º, mas sem capacidade

      expect(coordinator.send(:configured_handoff_team_id)).to eq(t1.id)
    end

    it 'ninguém com capacidade: cai no PRIMEIRO do array (t2), não no menor id' do
      stub_capacity([])
      agent.update!(handoff_team_ids: [t2.id, t1.id])

      expect(coordinator.send(:configured_handoff_team_id)).to eq(t2.id)
    end

    it 'lista vazia -> nil' do
      agent.update!(handoff_team_ids: [])
      expect(coordinator.send(:configured_handoff_team_id)).to be_nil
    end
  end

  # === Mudança 3: aponta a conversa ao time resolvido ANTES da atribuição =========================
  # É o que faz o caminho v2 (perform_bulk_assignment -> filter_agents_by_team) restringir aos membros
  # do time, e o legado via team_assignable_ids. Aqui basta provar que conversation.team_id é setado.
  describe '#assign_human — fixa o time na conversa antes de atribuir' do
    let(:team) { create(:team, account: account) }

    before { allow(Ai::CapabilityRegistry).to receive(:execute) }

    it 'seta conversation.team_id = time resolvido' do
      coordinator.assign_human(team.id, reason: 'loop')
      expect(conversation.reload.team_id).to eq(team.id)
    end
  end

  # === Mudança 4: sem time nenhum -> alerta, NÃO atribui aleatório =================================
  describe '#assign_human — sem time configurado (nem team_id, nem allowlist)' do
    let(:member) { create(:inbox_member, inbox: inbox) } # a CAIXA tem membro (senão viraria assign_failed)

    before do
      create(:account_user, account: account, user: member.user)
      agent.update!(team_id: nil, handoff_team_ids: [])
      allow(Ai::CapabilityRegistry).to receive(:execute)
    end

    it 'emite handoff.no_team_configured e NÃO atribui um membro aleatório' do
      coordinator.assign_human(nil, reason: 'loop')

      expect(conversation.reload.assignee_id).to be_nil
      ev = Ai::Event.where(conversation_id: conversation.id, event_type: 'handoff.no_team_configured').last
      expect(ev).to be_present
      expect(ev.payload).to include('inbox_id' => inbox.id, 'conversation_id' => conversation.id)
      expect(ev.status).to eq('error')
    end

    it 'aplica a tag "sem-time-configurado" (visibilidade para o dono)' do
      coordinator.assign_human(nil, reason: 'loop')

      expect(Ai::CapabilityRegistry).to have_received(:execute)
        .with('conversation.add_label', hash_including(input: { 'label' => 'sem-time-configurado' }))
    end

    # Ajuste 2: o motivo VAI no "Resumo da transferência" (campo visível = HandoffSummary.content).
    it 'grava o motivo no Resumo da transferência (content visível na UI)' do
      coordinator.assign_human(nil, reason: 'loop')

      summary = Ai::HandoffSummary.latest_for(conversation.id)
      expect(summary).to be_present
      expect(summary.content).to include('Nenhum time de atendimento configurado')
      expect(summary.reason).to eq('no_team_configured')
    end

    it 'NÃO enfileira o resumo async genérico e é IDEMPOTENTE (sem resumo duplicado no retry)' do
      expect { coordinator.assign_human(nil, reason: 'loop') }
        .not_to have_enqueued_job(Ai::HandoffSummaryJob)

      coordinator.assign_human(nil, reason: 'loop') # reexecução (retry)
      expect(Ai::HandoffSummary.where(conversation_id: conversation.id).count).to eq(1)
    end
  end

  # === Reprodução do caso real (user 15): loop com allowlist e sem team_id ========================
  describe 'reprodução: loop forçado com handoff_team_ids e @agent.team_id vazio' do
    let(:t_comercial) { create(:team, account: account, name: 'Comerciais') }
    let(:t_midia) { create(:team, account: account, name: 'Comercial Mídia Paga') }
    let(:member) { create(:inbox_member, inbox: inbox) }

    before do
      create(:account_user, account: account, user: member.user)
      create(:team_member, team: t_comercial, user: member.user) # comerciais tem gente
      agent.update!(team_id: nil, handoff_team_ids: [t_comercial.id, t_midia.id])
      allow(Ai::CapabilityRegistry).to receive(:execute)
      allow(OnlineStatusTracker).to receive(:get_available_users).and_return({})
    end

    it 'a conversa vai para um time comercial (membro do time), NÃO para membro aleatório da caixa' do
      team_id = coordinator.human_team_id({}) # loop: decision vazio
      expect(team_id).to eq(t_comercial.id)

      coordinator.assign_human(team_id, reason: 'loop')

      expect(conversation.reload.team_id).to eq(t_comercial.id)
      expect(conversation.assignee_id).to eq(member.user_id) # membro do comercial, não um qualquer
      expect(Ai::Event.where(conversation_id: conversation.id, event_type: 'handoff.no_team_configured')).to be_empty
    end
  end

  # (3) Motivo 3 do handoff: a IA DESISTIU sem destino declarado (give-up: loop/stuck/credit/provider/
  # confiança baixa; o breaker herda pelo force_provider_handoff). Roteia pelo default DECLARADO no agente
  # (fallback_handoff_team_id) em vez do 1º da whitelist por acidente de ordenação. Prova de mutação por nome.
  describe '#human_team_id — (3) fallback_handoff_team_id (give-up sem destino declarado)' do
    let(:t_first) { create(:team, account: account, name: 'Comercial') }
    let(:t_fallback) { create(:team, account: account, name: 'Retenção') }
    let(:t_outside) { create(:team, account: account, name: 'Financeiro') }

    before { agent.update!(team_id: nil, handoff_team_ids: [t_first.id, t_fallback.id]) }

    it 'give-up (decision {}) com fallback declarado roteia para o FALLBACK, não o 1º da whitelist' do
      agent.update!(fallback_handoff_team_id: t_fallback.id)
      # sem o fallback cairia em t_first (1º marcado); com ele vai para t_fallback (2º) -> prova o roteamento
      expect(coordinator.human_team_id({})).to eq(t_fallback.id)
    end

    it 'SEM fallback declarado mantém o comportamento atual (um time da whitelist, 1º com capacidade)' do
      expect([t_first.id, t_fallback.id]).to include(coordinator.human_team_id({}))
    end

    it 'fallback fora da whitelist é REJEITADO na ESCRITA (validação do Ai::Agent)' do
      agent.fallback_handoff_team_id = t_outside.id
      aggregate_failures do
        expect(agent.valid?).to be(false)
        expect(agent.errors[:fallback_handoff_team_id]).to be_present
      end
    end

    it 'fallback que caiu fora da whitelist (esvaziada depois) NÃO é honrado: emite handoff.fallback_unlisted e cai no configured' do
      # simula "whitelist mudou depois": grava o id sem passar pela validação
      agent.update_column(:fallback_handoff_team_id, t_outside.id)
      result = nil
      expect { result = coordinator.human_team_id({}) }
        .to change { Ai::Event.where(event_type: 'handoff.fallback_unlisted').count }.by(1)
      aggregate_failures do
        expect(result).not_to eq(t_outside.id)          # NÃO roteia para o não-listado
        expect([t_first.id, t_fallback.id]).to include(result) # cai no configured (whitelist)
        expect(Ai::Event.where(event_type: 'handoff.fallback_unlisted').last.payload['team_id']).to eq(t_outside.id)
      end
    end

    it 'fallback declarado + whitelist VAZIA: NÃO usa o fallback (config ausente ≠ autorização), cai no comportamento atual' do
      agent.update_columns(handoff_team_ids: [], fallback_handoff_team_id: t_fallback.id)
      result = nil
      expect { result = coordinator.human_team_id({}) }
        .not_to change { Ai::Event.where(event_type: 'handoff.fallback_unlisted').count } # não é "unlisted", é config ausente
      aggregate_failures do
        expect(result).to be_nil                 # configured_handoff_team_id com whitelist vazia = nil (comportamento atual)
        expect(result).not_to eq(t_fallback.id)  # o fallback NÃO foi honrado
      end
    end

    it 'um setor PEDIDO mas fora da whitelist (target presente) NÃO usa o fallback: segue medido por target_unmatched' do
      agent.update!(fallback_handoff_team_id: t_fallback.id)
      # target presente (cliente pediu) e não casa -> é INTENÇÃO, não give-up: mantém target_unmatched, não fallback
      expect { coordinator.human_team_id({ 'handoff_target' => 'Jurídico' }) }
        .to change { Ai::Event.where(event_type: 'handoff.target_unmatched').count }.by(1)
    end
  end
end
