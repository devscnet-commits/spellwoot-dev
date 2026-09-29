require 'rails_helper'

# Regras combinadas com a dona da conta:
#   R1 — IA desligada (sem IA ao vivo, atendimento automático/escopo desligado, desativa_ia, grupo): fluxo
#        normal — time padrão da caixa + distribuição automática.
#   R2 — destino da transferência vem dos campos do agente (times marcados + principal), não do prompt.
#   R3 — humano atribuído (à mão ou pelo sistema): a IA sai.
#   R4 — conversa mandada para um time (pessoa ou automação): a IA sai e a distribuição atribui alguém.
RSpec.describe Ai::ReplyPolicy, '.human_control_reason' do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, enable_auto_assignment: false) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:agent_user) { create(:user, account: account, role: :agent) }
  let(:team) { create(:team, account: account, name: 'Vendas') }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:ai_agent) do
    Ai::Agent.create!(account: account, name: 'Maya', status: 'active', ai_operation_profile_id: profile.id,
                      behavior: { 'reply_scope' => 'all', 'auto_attendance' => true })
  end

  before do
    account.enable_features!('ai_core')
    create(:inbox_member, inbox: inbox, user: agent_user)
    create(:team_member, team: team, user: agent_user)
  end

  def allowed?
    described_class.allowed?(mode: 'live', agent: ai_agent, conversation: conversation)
  end

  def reason
    described_class.skip_reason(mode: 'live', agent: ai_agent, conversation: conversation)
  end

  describe 'R3 — humano atribuído', type: :request do
    it 'pelo painel: a IA sai' do
      post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/assignments",
           headers: agent_user.create_new_auth_token, params: { assignee_id: agent_user.id }, as: :json

      expect(allowed?).to be(false)
      expect(reason).to eq('assigned_to_human')
    end

    it 'por API/integração: a IA também sai' do
      post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/assignments",
           headers: { api_access_token: agent_user.access_token.token }, params: { assignee_id: agent_user.id }, as: :json

      expect(allowed?).to be(false)
    end

    it 'a mensagem de encerramento do próprio handoff da IA ainda sai' do
      conversation.update!(assignee: agent_user)

      expect(described_class.allowed?(mode: 'live', agent: ai_agent, conversation: conversation, bypass_handoff: true)).to be(true)
    end
  end

  describe 'R4 — mandada para um time' do
    it 'pelo painel/API: a IA sai na hora' do
      conversation.route_to_team!(team.id)

      expect(conversation.reload.team_id).to eq(team.id)
      expect(allowed?).to be(false)
      expect(reason).to eq('handed_off')
    end

    it 'por automação (regra/macro): a IA sai' do
      ActionService.new(conversation).assign_team([team.id])

      expect(conversation.reload.additional_attributes['ai_handoff']).to be(true)
    end

    it 'e a distribuição deixa de ser segurada pela IA' do
      Ai::AgentInbox.create!(ai_agent_id: ai_agent.id, inbox_id: inbox.id, mode: 'live', active: true)
      expect(conversation.reload.ai_pending_handoff?).to be(true)

      conversation.route_to_team!(team.id)

      expect(conversation.reload.ai_pending_handoff?).to be(false)
    end
  end

  describe 'R1 — IA desligada segue o fluxo normal' do
    before { Ai::AgentInbox.create!(ai_agent_id: ai_agent.id, inbox_id: inbox.id, mode: 'live', active: true) }

    it 'IA ligada: segura a conversa (sem time padrão, fora da distribuição)' do
      expect(conversation.ai_assistant_active?).to be(true)
    end

    it 'atendimento automático desligado: conversa volta ao fluxo normal' do
      ai_agent.update!(behavior: { 'reply_scope' => 'all', 'auto_attendance' => false })

      expect(conversation.reload.ai_assistant_active?).to be(false)
    end

    it 'escopo de resposta desligado: fluxo normal' do
      ai_agent.update!(behavior: { 'reply_scope' => 'off' })

      expect(conversation.reload.ai_assistant_active?).to be(false)
    end

    it 'desativa_ia marcado: fluxo normal e a IA não responde (nem no handoff)' do
      conversation.update!(custom_attributes: { 'desativa_ia' => true })

      expect(conversation.ai_assistant_active?).to be(false)
      expect(described_class.allowed?(mode: 'live', agent: ai_agent, conversation: conversation, bypass_handoff: true)).to be(false)
      expect(reason).to eq('ai_disabled_attribute')
    end

    it 'IA desligada: conversa nova recebe o time padrão da caixa' do
      ai_agent.update!(behavior: { 'reply_scope' => 'all', 'auto_attendance' => false })
      inbox.update!(default_team_id: team.id)

      expect(create(:conversation, account: account, inbox: inbox).team_id).to eq(team.id)
    end
  end

  it 'lê o estado atual do banco, não o objeto carregado antes (janela do agrupamento)' do
    stale = Conversation.find(conversation.id)
    conversation.update!(assignee: agent_user)

    expect(described_class.allowed?(mode: 'live', agent: ai_agent, conversation: stale)).to be(false)
  end

  it 'sem nada disso: a IA responde' do
    expect(allowed?).to be(true)
  end

  describe 'opção "Humanos assumem" desligada no agente (empresas cuja automação atribui na chegada)' do
    before do
      ai_agent.update!(behavior: { 'reply_scope' => 'all', 'auto_attendance' => true, 'humans_take_over' => false })
      Ai::AgentInbox.create!(ai_agent_id: ai_agent.id, inbox_id: inbox.id, mode: 'live', active: true)
    end

    it 'humano atribuído não tira a IA' do
      conversation.update!(assignee: agent_user)

      expect(allowed?).to be(true)
    end

    it 'mandar para um time não tira a IA' do
      conversation.route_to_team!(team.id)

      expect(conversation.reload.additional_attributes['ai_handoff']).to be_nil
      expect(allowed?).to be(true)
    end

    it 'automação "atribuir agente" volta a ser ignorada enquanto a IA atende' do
      ActionService.new(conversation).assign_agent([agent_user.id])

      expect(conversation.reload.assignee_id).to be_nil
    end

    it 'humano que RESPONDE continua tirando a IA' do
      create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :outgoing,
                       sender: agent_user, private: false)

      expect(reason).to eq('human_engaged')
    end
  end

  it 'opção ausente no agente (agentes existentes) vale como ligada' do
    expect(described_class.humans_take_over?(ai_agent)).to be(true)
  end

  # Caixas com a distribuição antiga (sem assignment_v2): ela atribuía um humano na chegada sem olhar a IA — e
  # com R3 isso calaria a IA em toda conversa nova. Distribuição só depois do handoff/time/IA desligada.
  describe 'distribuição automática antiga (sem assignment_v2)' do
    let(:online_agent) { create(:user, account: account, role: :agent, auto_offline: false) }
    let(:auto_inbox) { create(:inbox, account: account, enable_auto_assignment: true) }

    before do
      create(:inbox_member, inbox: auto_inbox, user: online_agent)
      create(:team_member, team: team, user: online_agent)
      allow(Redis::Alfred).to receive(:rpoplpush).and_return(online_agent.id)
      Ai::AgentInbox.create!(ai_agent_id: ai_agent.id, inbox_id: auto_inbox.id, mode: 'live', active: true)
    end

    def new_conversation
      create(:conversation, account: account, inbox: auto_inbox, contact: create(:contact, account: account), assignee: nil)
    end

    it 'IA atendendo: conversa nova NÃO recebe humano e a IA responde' do
      conversation = new_conversation

      expect(conversation.reload.assignee).to be_nil
      expect(described_class.allowed?(mode: 'live', agent: ai_agent, conversation: conversation)).to be(true)
    end

    it 'IA desligada (atendimento automático off): conversa nova é distribuída normalmente (R1)' do
      ai_agent.update!(behavior: { 'reply_scope' => 'all', 'auto_attendance' => false })

      expect(new_conversation.reload.assignee).to eq(online_agent)
    end

    it 'troca de fila feita pela própria IA (automação de etapa) não puxa humano' do
      conversation = new_conversation
      conversation.update!(team_id: team.id)

      expect(conversation.reload.assignee).to be_nil
    end

    it 'mandada para um time por pessoa/automação: distribui para alguém do time e a IA sai (R4)' do
      team.update!(allow_auto_assign: true)
      conversation = new_conversation
      conversation.route_to_team!(team.id)

      expect(conversation.reload.assignee).to eq(online_agent)
      expect(described_class.allowed?(mode: 'live', agent: ai_agent, conversation: conversation)).to be(false)
    end
  end

  describe 'handoff da IA com atendente já na conversa' do
    it 'mantém o atendente em vez de devolver para a fila' do
      conversation.update!(assignee: agent_user)

      Ai::CapabilityRegistry.execute('conversation.transfer', conversation: conversation, input: { 'unassign' => true })

      expect(conversation.reload.assignee_id).to eq(agent_user.id)
    end
  end

  describe 'R2 — destino pelos campos do agente' do
    let(:coordinator) { Ai::HandoffCoordinator.new(conversation: conversation, account: account, agent: ai_agent, message: nil) }

    it 'um time só marcado: vai para ele, ignorando o nome que a IA escreveu (sem target_unmatched)' do
      ai_agent.update!(handoff_team_ids: [team.id])

      expect { expect(coordinator.human_team_id({ 'handoff_target' => 'vendas finalização' })).to eq(team.id) }
        .not_to(change { Ai::Event.where(event_type: 'handoff.target_unmatched').count })
    end

    it 'dois ou mais: a IA recebe os nomes na ordem configurada e o principal' do
      financeiro = create(:team, account: account, name: 'Financeiro')
      ai_agent.update!(handoff_team_ids: [team.id, financeiro.id], fallback_handoff_team_id: financeiro.id)
      client = Ai::PythonOrchestratorClient.new(conversation: conversation, content: 'oi', agent: ai_agent, mode: 'live')

      expect(client.send(:handoff_team_names)).to eq(%w[Vendas Financeiro])
      expect(client.send(:principal_team_name)).to eq('Financeiro')
    end
  end
end
