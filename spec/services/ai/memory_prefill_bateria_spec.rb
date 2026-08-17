require 'rails_helper'

# BATERIA PR3 (Frente C) — PRÉ-PREENCHIMENTO DA MEMÓRIA, promoção validada pelo GATE. Decisão (D): só slot
# de FORMATO (cpf/email/phone/number/choice), onde o gate valida a promoção; TEXTO LIVRE é DEFERIDO (volta
# como juiz com status próprio, NUNCA lista de frases). Cobre o caminho de AVANÇO inteiro + os ramos, não só
# o caso novo — o avanço foi mexido 3× esta semana e cada vez quebrou algo diferente.
RSpec.describe 'Ai memory prefill (Frente C PR3)' do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'p', supervisor_provider: 'openai',
                                 supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }
  let(:cpf_dept) do
    d = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Cadastro', status: 'active',
                               behavior: {}, transfer_rules: { 'stuck_handoff_turns' => 3 })
    d.create_playbook!(active: true, steps: [
                         { 'name' => 'CPF', 'collect' => { 'attribute' => 'documento_cpf', 'type' => 'cpf', 'required' => true } },
                         { 'name' => 'Endereço', 'collect' => { 'attribute' => 'endereco_completo', 'type' => 'text', 'required' => true } }
                       ])
    d
  end
  let(:cpf_step) { cpf_dept.playbook.steps[0] }
  let(:endereco_step) { cpf_dept.playbook.steps[1] }
  let(:manager) { Ai::StateManager.new(conversation: conversation, agent: agent) }
  let(:run) do
    Ai::Run.create!(account_id: account.id, conversation_id: conversation.id, ai_agent_id: agent.id,
                    inbox_id: inbox.id, run_type: 'decision', mode: 'live', status: 'running')
  end
  let(:dispatcher) do
    Ai::ActionDispatcher.new(conversation: conversation, account: account, mode: 'live', acts_live: true)
  end

  def remember(facts)
    Ai::CustomerMemory.create!(account: account, contact: contact, key_facts: facts)
  end

  def attrs
    conversation.reload.additional_attributes
  end

  def facts
    attrs['ai_collected_facts'] || {}
  end

  def events(type)
    Ai::Event.where(conversation_id: conversation.id, event_type: type)
  end

  def incoming(text)
    create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :incoming, content: text)
  end

  # ===== 1. A DIRETIVA (item 2 — o MOTOR dirige, não a instrução do usuário) ========================
  describe 'PromptCompiler.memory_prefill_line — dirige a proposta só em slot de FORMATO' do
    let(:steps) { cpf_dept.playbook.steps }
    let(:cm) { Ai::CustomerMemory.new(key_facts: { 'documento_cpf' => '110.336.369-75', 'endereco_completo' => 'Rua X, 100' }) }

    it 'slot de FORMATO com valor lembrado -> diretiva propõe o valor e exige devolver em attributes' do
      line = Ai::PromptCompiler.memory_prefill_line(steps, 0, 'documento_cpf', cm)

      expect(line).to include('DADO LEMBRADO DE ATENDIMENTO ANTERIOR', '110.336.369-75')
      expect(line).to include('SEMPRE devolva em "attributes"', 'documento_cpf')
    end

    it 'slot de TEXTO LIVRE com valor lembrado -> NÃO propõe (deferido); mas o valor SEGUE visível no bloco de memória' do
      expect(Ai::PromptCompiler.memory_prefill_line(steps, 1, 'endereco_completo', cm)).to be_nil # não pré-preenche

      # não regride: o endereço lembrado continua no bloco de memória — a IA pode mencioná-lo, e coleta normal
      expect(Ai::PromptCompiler.customer_memory_lines(cm).join("\n")).to include('endereco_completo', 'Rua X, 100')
    end

    it 'slot de formato SEM valor na memória -> nil' do
      empty = Ai::CustomerMemory.new(key_facts: {})
      expect(Ai::PromptCompiler.memory_prefill_line(steps, 0, 'documento_cpf', empty)).to be_nil
    end

    it 'sem memória do contato -> nil (degrada, não quebra)' do
      expect(Ai::PromptCompiler.memory_prefill_line(steps, 0, 'documento_cpf', nil)).to be_nil
    end
  end

  # ===== 2. O SEMEIO (habilita a promoção sem depender do modelo ecoar proposed_value) ==============
  describe 'StateManager — semeia ai_last_proposed_value da memória (só formato)' do
    it 'slot de FORMATO vazio + valor lembrado + modelo não propôs -> semeia; e NÃO escreve o slot (AVANÇO intocado)' do
      remember('documento_cpf' => '110.336.369-75')

      manager.send(:persist_step_state, cpf_step, 0, { 'asked_slot' => 'documento_cpf' })

      expect(attrs['ai_last_proposed_value']).to eq('110.336.369-75') # semeado -> substitute terá o valor
      expect(facts).not_to have_key('documento_cpf')                  # slot VAZIO: slot_filled?/conclude_ready? intocados
    end

    it 'slot de TEXTO LIVRE com valor lembrado -> NÃO semeia (deferido)' do
      remember('endereco_completo' => 'Rua X, 100')

      manager.send(:persist_step_state, endereco_step, 1, { 'asked_slot' => 'endereco_completo' })

      expect(attrs['ai_last_proposed_value']).to be_nil
    end

    it 'modelo JÁ propôs -> usa o do modelo, a memória não sobrepõe' do
      remember('documento_cpf' => '110.336.369-75')

      manager.send(:persist_step_state, cpf_step, 0, { 'asked_slot' => 'documento_cpf', 'proposed_value' => '222.222.222-22' })

      expect(attrs['ai_last_proposed_value']).to eq('222.222.222-22')
    end

    it 'slot JÁ preenchido -> não semeia (nada a propor)' do
      remember('documento_cpf' => '110.336.369-75')
      conversation.update!(additional_attributes: { 'ai_collected_facts' => { 'documento_cpf' => '999.999.999-99' } })

      manager.send(:persist_step_state, cpf_step, 0, { 'asked_slot' => 'documento_cpf' })

      expect(attrs['ai_last_proposed_value']).to be_nil
    end
  end

  # ===== 3. A PROMOÇÃO + o EVENTO de medição (item 3) — o GATE valida, não o palpite =================
  describe 'TurnCapture — promoção validada pelo gate + proposal.echo_missing' do
    let(:capture) do
      Ai::TurnCapture.new(conversation: conversation,
                          persister: Ai::StateManager.new(conversation: conversation, agent: agent), agent: agent)
    end

    # estado do turno anterior: perguntou o cpf e (o motor) propôs o valor lembrado.
    def proposed(value = '110.336.369-75')
      conversation.update!(additional_attributes: { 'ai_last_asked_slot' => 'documento_cpf',
                                                    'ai_last_proposed_value' => value })
    end

    it '"sim" (inválido p/ cpf) + proposta pendente -> grava o VALOR PROPOSTO, validado pelo gate' do
      proposed

      capture.capture(cpf_step, { 'attributes' => { 'documento_cpf' => 'sim' } }, 'sim', nil, cpf_dept)

      expect(facts['documento_cpf']).to eq('110.336.369-75') # o proposto, não "sim"
      expect(events('slot.captured').last.payload).to include('attribute' => 'documento_cpf', 'status' => 'confirmed')
    end

    it 'cliente CORRIGE (cpf válido novo) -> NÃO substitui: o fluxo normal grava o novo, não o lembrado' do
      proposed

      capture.capture(cpf_step, { 'attributes' => { 'documento_cpf' => '111.444.777-35' } }, 'é 111.444.777-35', nil, cpf_dept)

      expect(facts['documento_cpf']).not_to eq('110.336.369-75') # a proposta não venceu a correção
      expect(events('slot.captured').where("payload->>'status' = 'confirmed'")).to be_empty
    end

    it 'modelo MUDO (attributes vazio) + cliente respondeu -> emite proposal.echo_missing e NÃO promove (item 3)' do
      proposed

      capture.capture(cpf_step, { 'attributes' => {} }, 'sim', nil, cpf_dept)

      expect(events('proposal.echo_missing').last.payload).to include('attribute' => 'documento_cpf')
      expect(facts).not_to have_key('documento_cpf') # sem valor no attributes, não há o que promover
    end

    it 'modelo mudo mas mensagem VAZIA (não é resposta do cliente) -> NÃO conta echo_missing' do
      proposed

      capture.capture(cpf_step, { 'attributes' => {} }, '', nil, cpf_dept)

      expect(events('proposal.echo_missing')).to be_empty
    end
  end

  # ===== 4. O CORTE NO TETO (item 3 — o loop leve é SEGURO: nunca infinito) ==========================
  describe 'o loop "sim"->repergunta é limitado pelo teto absoluto (stuck_handoff_turns)' do
    it 'modelo mudo repetido: emite echo_missing, NUNCA promove, e corta no teto com stuck_handoff/max_turns' do
      remember('documento_cpf' => '110.336.369-75')
      conversation.update!(additional_attributes: { 'ai_step_index' => 0,
                                                    'ai_last_asked_slot' => 'documento_cpf',
                                                    'ai_last_proposed_value' => '110.336.369-75' })
      sig = nil
      3.times do # teto = 3 (transfer_rules deste dept)
        sig = manager.track_step(cpf_dept, { 'asked_slot' => 'documento_cpf', 'attributes' => {}, 'step_completed' => false },
                                 dispatcher: dispatcher, run: run, message_text: 'sim', message: incoming('sim'))
      end

      aggregate_failures do
        expect(events('proposal.echo_missing')).to be_present            # medido em produção
        expect(facts).not_to have_key('documento_cpf')                   # modelo mudo: nunca promoveu
        expect(sig).to include(stuck_handoff: hash_including(reason: 'max_turns')) # cortou no teto (seguro)
      end
    end
  end
end
