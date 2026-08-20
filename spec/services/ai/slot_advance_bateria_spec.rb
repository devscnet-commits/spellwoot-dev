require 'rails_helper'

# BATERIA DE AVANÇO DE ETAPA — a matriz das combinações que decidem se a etapa AVANÇA (obrigatoriedade ×
# fonte do valor × veredito do gate), num arquivo só, cada exemplo NOMEADO e EXECUTADO (o padrão da matriz
# de roteamento). Documenta o comportamento REAL do item 5 (o avanço lê o VEREDITO do gate, não o cru do
# modelo). Onde um valor foi o BUG antes do item 5, o comentário marca. Prova de mutação por nome.
RSpec.describe 'Avanço de etapa — bateria (item 5)' do # rubocop:disable RSpec/DescribeClass
  subject(:manager) { Ai::StateManager.new(conversation: conversation, agent: agent) }

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }
  let(:run) do
    Ai::Run.create!(account_id: account.id, conversation_id: conversation.id, ai_agent_id: agent.id,
                    inbox_id: inbox.id, run_type: 'decision', mode: 'live', status: 'running')
  end
  let(:dispatcher) { Ai::ActionDispatcher.new(conversation: conversation, account: account, mode: 'live', acts_live: true) }

  def step_index
    conversation.reload.additional_attributes.to_h['ai_step_index']
  end

  def facts
    conversation.reload.additional_attributes.to_h['ai_collected_facts'].to_h
  end

  def turns
    conversation.reload.additional_attributes.to_h['ai_step_turns'].to_i
  end

  def set_index(idx)
    conversation.update!(additional_attributes: (conversation.additional_attributes || {}).merge('ai_step_index' => idx))
  end

  # agente com UM slot configurável (+ Fim). type: text/phone/choice; options p/ choice.
  def dept_with(slot:, type: 'text', required: true, options: nil)
    collect = { 'attribute' => slot, 'type' => type, 'required' => required }
    collect['options'] = options if options
    agent.update!(transfer_rules: { 'stuck_handoff_turns' => 3 })
    agent.create_playbook!(active: true, steps: [{ 'name' => 'Slot', 'collect' => collect }, { 'name' => 'Fim' }])
    agent
  end

  # Um turno: track_step com os attributes CRUS do modelo e/ou o texto do cliente.
  def turn(dept, attrs: {}, text: nil, message: nil)
    msg = message || create(:message, conversation: conversation, account: account, inbox: inbox,
                                      message_type: :incoming, content: text.to_s)
    manager.track_step(dept, { 'step_completed' => false, 'attributes' => attrs },
                       dispatcher: dispatcher, run: run, message_text: text, message: msg)
  end

  def incoming_attachment(attrs)
    msg = create(:message, conversation: conversation, account: account, inbox: inbox,
                           message_type: :incoming, content: '')
    msg.attachments.create!(attrs.merge(account_id: account.id))
    msg
  end

  # ===== 1) HAPPY PATH multi-etapa (representa "as 16 etapas" em unidade) =============================
  describe 'happy path — funil avança etapa a etapa com valores válidos' do
    let(:funnel) do
      agent.create_playbook!(active: true, steps: [
                               { 'name' => 'Nome', 'collect' => { 'attribute' => 'nome', 'type' => 'text', 'required' => true } },
                               { 'name' => 'Email', 'collect' => { 'attribute' => 'email_cliente', 'type' => 'email', 'required' => true } },
                               { 'name' => 'Fim' }
                             ])
      agent
    end

    it 'coleta os obrigatórios em sequência e avança 0 -> 1 -> 2 (conclusão)' do
      turn(funnel, attrs: { 'nome' => 'João' })
      expect(step_index).to eq(1) # avançou p/ Email
      turn(funnel, attrs: { 'email_cliente' => 'joao@x.com' })
      expect(step_index).to eq(2) # avançou p/ Fim
    end
  end

  # ===== 2) OBRIGATÓRIO × fonte/veredito do valor =====================================================
  describe 'slot OBRIGATÓRIO' do
    it 'valor VÁLIDO (model raw, gate aceita) -> AVANÇA' do
      expect { turn(dept_with(slot: 'telefone', type: 'phone'), attrs: { 'telefone' => '(49) 99856-4780' }) }
        .to change { step_index }.from(nil).to(1)
    end

    it 'valor REJEITADO pelo gate (invalid_value) -> NÃO avança e o teto por etapa CONTA' do
      # ANTES do item 5: 'dia 10' presente no cru -> AVANÇAVA sem persistir (o bug da conv 397).
      turn(dept_with(slot: 'telefone', type: 'phone'), attrs: { 'telefone' => 'dia 10' })
      aggregate_failures do
        expect(step_index).to eq(0)            # NÃO avançou
        expect(facts).not_to include('telefone') # e não persistiu (avanço e persistência concordam)
        expect(turns).to eq(1)                 # o teto improdutivo conta o turno (transfere ao chegar em 3)
      end
    end

    it 'token __sem_valor__ (a forma exata da conv 397) -> NÃO avança' do
      turn(dept_with(slot: 'telefone', type: 'phone'), attrs: { 'telefone' => Ai::StepSlot::ABSENT })
      expect(step_index).to eq(0)
    end

    it 'CHOICE com valor FORA das options -> gate rejeita -> NÃO avança (acoplamento #321)' do
      dept = dept_with(slot: 'plano', type: 'choice', options: ['Fibra 300', 'Fibra 600'])
      turn(dept, attrs: { 'plano' => 'Premium' }) # 'Premium' não é uma option
      expect(step_index).to eq(0)
    end

    it 'CHOICE com valor DENTRO das options -> AVANÇA' do
      dept = dept_with(slot: 'plano', type: 'choice', options: ['Fibra 300', 'Fibra 600'])
      expect { turn(dept, attrs: { 'plano' => 'Fibra 600' }) }.to change { step_index }.from(nil).to(1)
    end

    it 'valor JÁ PERSISTIDO (turno anterior) -> AVANÇA sem attributes (metade persistida preservada)' do
      conversation.update!(additional_attributes: { 'ai_step_index' => 0,
                                                     'ai_collected_facts' => { 'telefone' => '(49) 99856-4780' } })
      turn(dept_with(slot: 'telefone', type: 'phone'), attrs: {})
      expect(step_index).to eq(1)
    end
  end

  # ===== 3) OPCIONAL × declínio/veredito ==============================================================
  describe 'slot OPCIONAL' do
    it 'declinado (modelo devolve o token __sem_valor__ no slot) -> grava a sentinela e AVANÇA (opcional satisfaz)' do
      # O declínio EXPLÍCITO vem do token que o prompt instrui o modelo a devolver — NÃO de uma frase livre.
      dept = dept_with(slot: 'complemento', type: 'text', required: false)
      turn(dept, attrs: { 'complemento' => Ai::StepSlot::ABSENT })
      aggregate_failures do
        expect(step_index).to eq(1)                              # avançou
        expect(facts['complemento']).to eq(Ai::StepSlot::ABSENT) # sentinela gravada
      end
    end

    # ACHADO da bateria (execução, não análise): um slot de TEXTO NÃO é declinado por uma frase livre
    # "não tenho ..." — a captura determinística grava o TEXTO CRU como valor e a etapa avança PREENCHIDA
    # com a frase. O declínio de texto depende do token/Ai::SlotAbsence, não da linguagem natural.
    it 'ACHADO: opcional de TEXTO + "não tenho ..." grava a FRASE como valor (não vira sentinela)' do
      dept = dept_with(slot: 'complemento', type: 'text', required: false)
      turn(dept, attrs: {}, text: 'não tenho complemento')
      aggregate_failures do
        expect(step_index).to eq(1)                                   # avança (slot "preenchido")
        expect(facts['complemento']).to eq('não tenho complemento')   # ...com a FRASE CRUA — deveria ser sentinela?
      end
    end

    it 'valor REJEITADO pelo gate, SEM declínio -> NÃO avança (nem opcional avança sobre valor inválido)' do
      # cross-cell: opcional + telefone inválido + sem sinal de recusa -> o gate rejeita, não há sentinela,
      # não avança (o opcional só "satisfaz" pela recusa explícita, não por um valor que o gate joga fora).
      dept = dept_with(slot: 'telefone_extra', type: 'phone', required: false)
      turn(dept, attrs: { 'telefone_extra' => 'dia 10' }, text: 'meu fixo é dia 10')
      expect(step_index).to eq(0)
    end
  end

  # ===== 4) ANEXO ====================================================================================
  describe 'ANEXO' do
    it 'documento preenche o slot deterministicamente (persiste ANTES do resolve) -> AVANÇA' do
      dept = dept_with(slot: 'comprovante', type: 'text', required: true)
      msg = incoming_attachment(file_type: :file, fallback_title: 'comprovante.pdf')
      turn(dept, attrs: {}, message: msg)
      aggregate_failures do
        expect(facts['comprovante']).to eq('comprovante.pdf') # preenchido pelo anexo
        expect(step_index).to eq(1)                            # avançou
      end
    end
  end

  # ===== 5) CONFIRMAÇÃO ===============================================================================
  describe 'CONFIRMAÇÃO' do
    it 'slot já preenchido + turno sem valor novo -> NÃO trava (lê o persistido e avança)' do
      conversation.update!(additional_attributes: { 'ai_step_index' => 0,
                                                     'ai_collected_facts' => { 'nome' => 'João' } })
      turn(dept_with(slot: 'nome', type: 'text'), attrs: {}, text: 'isso mesmo')
      expect(step_index).to eq(1)
    end
  end
end
