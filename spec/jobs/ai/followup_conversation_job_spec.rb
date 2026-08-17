require 'rails_helper'

# Unit coverage for the follow-up engine's decision helpers (no DB / HTTP).
# These helpers used to live on Ai::FollowupSweepJob; the dispatcher refactor MOVED them
# (verbatim) to the per-conversation job, so the unit coverage moved with them.
# The full sweep -> per-conversation pipeline is integration-tested in
# followup_sweep_job_integration_spec.rb.
RSpec.describe Ai::FollowupConversationJob do
  let(:job) { described_class.new }

  # BUG FIX: run() usa DepartmentResolver em vez de .departments.active.first.
  # Prova que o departamento CORRETO é resolvido — override e inbox_mapping vencendo .first.
  describe '#run — resolução de departamento via DepartmentResolver' do
    let(:account) { create(:account) }
    let(:inbox)   { create(:inbox, account: account) }
    let(:profile) do
      Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                   supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
    end
    # :ai_agent/:ai_department/:ai_agent_inbox NÃO são factories registradas (achado ao investigar
    # esta rodada — a versão anterior deste teste usava create(:ai_agent, ...) e nunca rodava de
    # verdade, KeyError "Factory not registered"). Modelos reais direto, mesmo padrão comprovado de
    # spec/jobs/ai/followup_sweep_job_integration_spec.rb / spec/services/ai/department_resolver_spec.rb.
    let(:agent) do
      Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id)
    end
    let(:conversation) { create(:conversation, account: account, inbox: inbox, status: 'open', assignee_id: nil) }

    before { account.enable_features!('ai_core') }

    it 'usa o departamento indicado por ai_department_override em vez do primeiro' do
      dept_first = Ai::Department.create!(
        account: account, ai_agent_id: agent.id, name: 'Primeiro', status: 'active', behavior: {},
        follow_up: { 'behaviors' => [{ 'context' => 'inbox_hours', 'attempts' => [{ 'message' => 'vamos seguir?', 'delay_minutes' => 1 }] }] }
      )
      dept_correct = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Correto',
                                            status: 'active', behavior: {}, follow_up: {})
      conversation.update!(additional_attributes: { 'ai_department_override' => dept_correct.id })
      Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: 'live', active: true)

      # dept_correct não tem follow-up → job retorna sem enviar mensagem. dept_first existir (com
      # follow-up configurado) e NÃO ser usado é a prova de que o override venceu.
      expect(dept_first.follow_up['behaviors']).to be_present # sanity: dept_first não é um dummy vazio
      expect { job.perform(conversation.id) }.not_to(change { conversation.messages.count })
    end

    # Bug real ao vivo (2026-08): DepartmentResolver chamava .classify com message_content: nil pra
    # QUALQUER agente multi-department sem override/mapeamento único — LLM "chutava" um índice sem
    # sinal nenhum, então o follow-up podia cair não-deterministicamente num department SEM nada
    # configurado (ou ignorando as regras do department certo). Corrigido no resolver (classify só
    # roda com message_content presente); aqui provamos o efeito ponta-a-ponta pelo job de follow-up.
    it 'agente com MÚLTIPLOS departments, SEM override/mapeamento: resolve por is_default (não chama o classificador)' do
      dept_default = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Padrão',
                                            status: 'active', is_default: true, behavior: {}, follow_up: {})
      Ai::Department.create!(
        account: account, ai_agent_id: agent.id, name: 'Vendas', status: 'active', is_default: false,
        behavior: {},
        follow_up: { 'behaviors' => [{ 'context' => 'inbox_hours', 'attempts' => [{ 'message' => 'vamos seguir?', 'delay_minutes' => 1 }] }] }
      )
      Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: 'live', active: true)
      # Nenhum ai_department_override, nenhum Ai::DepartmentInbox mapeado -> SEM o fix, cairia no
      # classificador de verdade (Ai::ModelRouter.call_model, HTTP real, WebMock bloquearia e
      # estouraria NetConnectNotAllowedError se chamado). O guard abaixo é a prova de que NÃO roda.
      expect(Ai::ModelRouter).not_to receive(:call_model)

      # dept_default (is_default: true, é quem o resolver escolhe sem classificador) não tem
      # follow-up configurado -> job não envia nada, mesmo o OUTRO department tendo um attempt pronto.
      expect { job.perform(conversation.id) }.not_to(change { conversation.messages.count })
      expect(dept_default.reload.follow_up['behaviors']).to be_blank # sanity: o escolhido é o vazio
    end

    # Bug real ao vivo (isolamento): "o follow-up... está puxando a mensagem de OUTROS departamentos".
    # Mesmo cenário multi-department acima, mas agora existe um Ai::Run PROVANDO qual department de
    # fato conduziu esta conversa — a fonte de verdade real deve VENCER o palpite is_default/primeiro
    # do resolver, mesmo esse department não sendo o default.
    it 'existindo Ai::Run desta conversa, usa o department REAL que a atendeu (não o is_default/palpite)' do
      Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Padrão',
                             status: 'active', is_default: true, behavior: {}, follow_up: {})
      dept_vendas = Ai::Department.create!(
        account: account, ai_agent_id: agent.id, name: 'Vendas', status: 'active', is_default: false,
        behavior: { 'auto_attendance' => true, 'reply_scope' => 'all' }, # Ai::ReplyPolicy exige isso pra enviar
        follow_up: { 'behaviors' => [{ 'context' => 'inbox_hours', 'attempts' => [{ 'message' => 'vamos seguir?', 'delay_minutes' => 1 }] }] }
      )
      Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: 'live', active: true)
      allow_any_instance_of(::Inbox).to receive(:available_now?).and_return(true)
      # A conversa foi REALMENTE atendida pelo department de Vendas (Ai::Gateway grava isso a cada
      # turno real — ver app/services/ai/gateway.rb:59).
      Ai::Run.create!(account_id: account.id, conversation_id: conversation.id, ai_department_id: dept_vendas.id,
                      status: 'recorded')
      create(:message, account: account, inbox: inbox, conversation: conversation, message_type: 'incoming',
                       content: 'oi', created_at: 20.minutes.ago)
      create(:message, account: account, inbox: inbox, conversation: conversation, message_type: 'outgoing',
                       content: 'como posso ajudar?', created_at: 15.minutes.ago)
      conversation.update!(last_activity_at: 15.minutes.ago)

      expect(Ai::ModelRouter).not_to receive(:call_model) # nem chega a precisar do classificador

      expect { job.perform(conversation.id) }.to change { conversation.messages.count }.by(1)
      expect(conversation.messages.last.content).to eq('vamos seguir?')
    end
  end

  describe '#effective_message' do
    it 'reuses the previous non-empty message when the current is blank' do
      attempts = [{ 'message' => 'oi' }, { 'message' => '' }, { 'message' => 'voltei' }]
      expect(job.send(:effective_message, attempts, 1)).to eq('oi')
      expect(job.send(:effective_message, attempts, 2)).to eq('voltei')
    end

    it 'is blank when no message exists up to the index' do
      expect(job.send(:effective_message, [{ 'message' => '' }], 0)).to eq('')
    end
  end

  describe '#active_behavior' do
    let(:behaviors) do
      [{ 'context' => 'inbox_hours' }, { 'context' => 'outside_hours' }]
    end

    it 'picks inbox_hours when the inbox is open' do
      inbox = instance_double(Inbox, available_now?: true)
      expect(job.send(:active_behavior, behaviors, inbox)).to eq(behaviors[0])
    end

    it 'picks outside_hours when the inbox is closed' do
      inbox = instance_double(Inbox, available_now?: false)
      expect(job.send(:active_behavior, behaviors, inbox)).to eq(behaviors[1])
    end

    it 'returns nil when no context matches' do
      inbox = instance_double(Inbox, available_now?: true)
      custom = [{ 'context' => 'outside_hours' }]
      expect(job.send(:active_behavior, custom, inbox)).to be_nil
    end
  end

  describe '#within_custom_window?' do
    let(:inbox) { instance_double(Inbox, timezone: 'UTC') }

    it 'matches a normal daytime window' do
      travel_to(Time.utc(2026, 1, 1, 10, 0)) do
        expect(job.send(:within_custom_window?, [{ 'start' => '08:00', 'end' => '18:00' }], inbox)).to be(true)
        expect(job.send(:within_custom_window?, [{ 'start' => '12:00', 'end' => '18:00' }], inbox)).to be(false)
      end
    end

    it 'matches an overnight window' do
      travel_to(Time.utc(2026, 1, 1, 23, 0)) do
        expect(job.send(:within_custom_window?, [{ 'start' => '20:00', 'end' => '07:00' }], inbox)).to be(true)
      end
    end

    it 'is false when there are no windows' do
      expect(job.send(:within_custom_window?, [], inbox)).to be(false)
    end
  end

  describe '#inactivity_minutes' do
    it 'falls back to the default when unset' do
      expect(job.send(:inactivity_minutes, instance_double(Ai::Department, close_rules: {}))).to eq(30)
    end

    it 'uses the configured value' do
      dept = instance_double(Ai::Department, close_rules: { 'inactivity_minutes' => 15 })
      expect(job.send(:inactivity_minutes, dept)).to eq(15)
    end
  end

  describe '#fallback_actions' do
    it 'reads the ordered no_followup_actions list (order = priority)' do
      dept = instance_double(Ai::Department,
                             close_rules: { 'no_followup_actions' => ['transfer_human', 'finalize'] })
      expect(job.send(:fallback_actions, dept)).to eq(%w[transfer_human finalize])
    end

    it 'drops blanks and is empty when unset' do
      dept = instance_double(Ai::Department, close_rules: { 'no_followup_actions' => ['', 'wait'] })
      expect(job.send(:fallback_actions, dept)).to eq(['wait'])
      expect(job.send(:fallback_actions, instance_double(Ai::Department, close_rules: {}))).to eq([])
    end
  end
end
