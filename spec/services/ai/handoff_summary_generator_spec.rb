require 'rails_helper'

RSpec.describe Ai::HandoffSummaryGenerator do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }

  # Stuba call_model (entrada LIVRE, TEXTO CRU) — NÃO decide. call_model devolve o texto do provider; o
  # generator faz o próprio parse de {"summary"}. Regra: o teste tem que exercitar a chamada REAL, não
  # stubar o método acima do bug (decide) com a resposta já pronta.
  def stub_call_model(text:, status: 'recorded')
    allow(Ai::ModelRouter).to receive(:call_model)
      .and_return({ text: text, status: status, tokens_in: 10, tokens_out: 5 })
  end

  before do
    Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: 'live', active: true)
    create(:message, account: account, inbox: inbox, conversation: conversation,
                     message_type: 'incoming', content: 'quero cancelar meu plano agora')
    stub_call_model(text: '{"summary":"Cliente quer cancelar o plano."}')
  end

  it 'gera o resumo e cria Ai::HandoffSummary + Ai::Run, SEM consumir crédito' do
    balance = AiCreditBalance.create!(account_id: account.id, plan_credits: 5, extra_credits: 0)

    summary = described_class.new(conversation: conversation, reason: 'loop').generate

    expect(summary).to be_a(Ai::HandoffSummary)
    expect(summary.content).to eq('Cliente quer cancelar o plano.')
    expect(summary.reason).to eq('loop')
    expect(summary.run).to be_present

    run = Ai::Run.find_by(conversation_id: conversation.id, run_type: 'handoff_summary')
    expect(run).to be_present
    expect(run.mode).to eq('assistant')
    expect(run.cost).to be_a(Numeric) # custo COMPUTADO (call_model não devolve; estimate_cost + clock)

    expect(balance.reload.total).to eq(5) # crédito NÃO foi consumido
  end

  # A PROVA do conserto do fluxo (bug 394): o generator usa call_model (LIVRE, sem schema), NUNCA decide
  # (schema de decisão strict -> summary IMPOSSÍVEL). FALHA com o código antigo (decide), PASSA com o conserto.
  it 'usa call_model SEM schema de decisão e NUNCA decide (senão o summary é impossível)' do
    expect(Ai::ModelRouter).not_to receive(:decide)
    captured = nil
    allow(Ai::ModelRouter).to receive(:call_model) do |**kwargs|
      captured = kwargs
      { text: '{"summary":"Resumo real."}', status: 'recorded', tokens_in: 3, tokens_out: 7 }
    end

    summary = described_class.new(conversation: conversation, reason: 'loop').generate

    expect(summary.content).to eq('Resumo real.')
    expect(captured).not_to have_key(:schema) # reforço: entrada livre, sem contrato de decisão
    expect(captured[:json]).to be(true)
  end

  it 'mapeia o token de ausência para "não informado" — NUNCA vaza o token cru no resumo (humano lê)' do
    conversation.update!(additional_attributes: {
                           'ai_collected_facts' => { 'email_cliente' => Ai::StepSlot::ABSENT, 'cidade' => 'Chapecó' }
                         })
    captured = nil
    allow(Ai::ModelRouter).to receive(:call_model) do |**kwargs|
      captured = kwargs[:system_prompt]
      { text: '{"summary":"ok"}', status: 'recorded', tokens_in: 1, tokens_out: 1 }
    end

    described_class.new(conversation: conversation, reason: 'loop').generate

    expect(captured).to include('email_cliente: não informado')
    expect(captured).not_to include(Ai::StepSlot::ABSENT)
  end

  it 'inclui o motivo do handoff e o transcript no prompt, e pede json' do
    captured = nil
    allow(Ai::ModelRouter).to receive(:call_model) do |**kwargs|
      captured = kwargs
      { text: '{"summary":"ok"}', status: 'recorded', tokens_in: 1, tokens_out: 1 }
    end

    described_class.new(conversation: conversation, reason: 'credit_exhausted').generate

    expect(captured[:system_prompt]).to include('créditos de IA da conta se esgotaram')
    expect(captured[:user_message]).to include('quero cancelar meu plano')
    expect(captured[:json]).to be(true)
  end

  # COEXISTÊNCIA com o fallback (rede de segurança): LLM bom -> resumo rico; LLM falha -> determinístico.
  describe 'fallback determinístico coexiste com o LLM' do
    it 'LLM bom -> usa o resumo do LLM (não cai no fallback)' do
      stub_call_model(text: '{"summary":"Resumo rico do LLM."}')
      conversation.update!(additional_attributes: { 'ai_collected_facts' => { 'nome_cliente' => 'Fulano' } })

      summary = described_class.new(conversation: conversation, reason: 'loop').generate

      expect(summary.content).to eq('Resumo rico do LLM.') # não é o determinístico
    end

    it 'JSON inválido do LLM -> fallback determinístico com os fatos' do
      stub_call_model(text: 'isso não é json {quebrado')
      conversation.update!(additional_attributes: { 'ai_collected_facts' => { 'nome_cliente' => 'Fulano' } })

      summary = described_class.new(conversation: conversation, reason: 'loop').generate

      expect(summary.content).to include('nome_cliente: Fulano', 'Transferido por:')
    end

    it 'summary vazio do LLM -> fallback determinístico' do
      stub_call_model(text: '{"summary":""}')
      conversation.update!(additional_attributes: { 'ai_collected_facts' => { 'cidade' => 'Chapecó' } })

      summary = described_class.new(conversation: conversation, reason: 'loop').generate

      expect(summary.content).to include('cidade: Chapecó', 'Transferido por:')
    end

    it 'status error do LLM -> fallback (nunca vazio)' do
      stub_call_model(text: nil, status: 'error')

      summary = described_class.new(conversation: conversation, reason: 'credit_exhausted').generate

      expect(summary.content).to include('créditos de IA da conta se esgotaram')
    end

    it 'NÃO cria resumo só quando a geração LEVANTA exceção (rescue -> nil)' do
      allow(Ai::ModelRouter).to receive(:call_model).and_raise(StandardError, 'boom')

      expect { expect(described_class.new(conversation: conversation, reason: 'loop').generate).to be_nil }
        .not_to change(Ai::HandoffSummary, :count)
    end
  end

  # O atendente humano lê "Transferido por: <label>" no card. Antes destes 3, as redes de "travou"
  # (Ai::StepResolver) caíam cruas: "Transferido por: max_turns". Prova de mutação por nome: cada reason
  # renderiza o texto legível E não vaza o token técnico. Some (volta ao cru) se a chave sair de REASON_LABELS.
  describe 'REASON_LABELS — motivos de give-up legíveis no card' do
    before { stub_call_model(text: 'json quebrado {') } # força o fallback determinístico (onde o label aparece)

    it 'max_turns -> "a conversa passou muitas mensagens sem avançar" (não o token cru)' do
      content = described_class.new(conversation: conversation, reason: 'max_turns').generate.content
      expect(content).to include('a conversa passou muitas mensagens sem avançar')
      expect(content).not_to include('max_turns')
    end

    # (b)-core: o desfecho declarado pela etapa transfere com reason 'conclusao' — sem esta label, o card
    # mostraria "Transferido por: conclusao".
    it 'conclusao -> "o atendimento da IA foi concluído e encaminhado para seguimento humano"' do
      content = described_class.new(conversation: conversation, reason: 'conclusao').generate.content
      expect(content).to include('o atendimento da IA foi concluído e encaminhado para seguimento humano')
      expect(content).not_to include('Transferido por: conclusao.')
    end

    it 'max_questions -> "o cliente fez muitas perguntas seguidas sem fechar o atendimento"' do
      content = described_class.new(conversation: conversation, reason: 'max_questions').generate.content
      expect(content).to include('o cliente fez muitas perguntas seguidas sem fechar o atendimento')
      expect(content).not_to include('max_questions')
    end

    it 'declined -> "o cliente preferiu não informar um dado necessário para continuar"' do
      content = described_class.new(conversation: conversation, reason: 'declined').generate.content
      expect(content).to include('o cliente preferiu não informar um dado necessário para continuar')
      expect(content).not_to include('declined')
    end
  end

  describe 'linha "Dados já coletados" (collected_attributes)' do
    def prompt_for(reason: 'loop')
      captured = nil
      allow(Ai::ModelRouter).to receive(:call_model) do |**kwargs|
        captured = kwargs[:system_prompt]
        { text: '{"summary":"ok"}', status: 'recorded', tokens_in: 1, tokens_out: 1 }
      end
      described_class.new(conversation: conversation, reason: reason).generate
      captured
    end

    it 'inclui todas as chaves de ai_collected_facts quando custom_attributes está vazio' do
      conversation.update!(custom_attributes: {},
                           additional_attributes: { 'ai_collected_facts' => {
                             'nome_cliente' => 'Fulano', 'telefone_secundario' => '49985671245'
                           } })

      prompt = prompt_for
      expect(prompt).to include('Dados já coletados do cliente:')
      expect(prompt).to include('nome_cliente: Fulano')
      expect(prompt).to include('telefone_secundario: 49985671245')
    end

    it 'quando a mesma chave existe nos dois, vence o valor de custom_attributes' do
      conversation.update!(custom_attributes: { 'cidade' => 'Maravilha' },
                           additional_attributes: { 'ai_collected_facts' => {
                             'cidade' => 'Chapecó', 'plano_escolhido' => 'Fibra 500'
                           } })

      prompt = prompt_for
      expect(prompt).to include('cidade: Maravilha')
      expect(prompt).not_to include('cidade: Chapecó')
      expect(prompt).to include('plano_escolhido: Fibra 500')
    end

    it 'descarta valores em branco vindos dos facts' do
      conversation.update!(custom_attributes: {},
                           additional_attributes: { 'ai_collected_facts' => {
                             'nome_cliente' => 'Fulano', 'email_cliente' => '', 'documento_cpf' => nil
                           } })

      prompt = prompt_for
      expect(prompt).to include('nome_cliente: Fulano')
      expect(prompt).not_to include('email_cliente:')
      expect(prompt).not_to include('documento_cpf:')
    end

    it 'não quebra quando additional_attributes é nulo ou sem ai_collected_facts' do
      conversation.update!(custom_attributes: { 'cidade' => 'Maravilha' }, additional_attributes: {})

      prompt = prompt_for
      expect(prompt).to include('cidade: Maravilha')
    end

    it 'omite a linha "Dados já coletados" quando não há nenhum dado' do
      conversation.update!(custom_attributes: {}, additional_attributes: {})
      allow(conversation.contact).to receive(:custom_attributes).and_return({}) if conversation.contact

      prompt = prompt_for
      expect(prompt).not_to include('Dados já coletados do cliente:')
    end
  end
end
