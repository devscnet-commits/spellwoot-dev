require 'rails_helper'

RSpec.describe Ai::TurnCapture do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:message) do
    create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :incoming, content: 'oi')
  end

  def build_capture(conv = conversation)
    described_class.new(conversation: conv, persister: Ai::StateManager.new(conversation: conv, agent: nil))
  end

  describe '#claim — semantica already-won' do
    it 'claim 2x na MESMA instancia, mesmo id -> true nas duas; o UPDATE atomico roda 1x so' do
      capture = build_capture
      expect(capture).to receive(:atomic_claim).once.and_call_original

      expect(capture.claim(message)).to be(true)
      expect(capture.claim(message)).to be(true) # already-won: no-op-true, sem 2o atomic_claim
    end

    it 'instancia DIFERENTE, mesmo id -> segunda claim retorna false (protecao entre processos)' do
      expect(build_capture.claim(message)).to be(true) # 1a instancia vence e grava a coluna (persistido)

      # 2o binding / re-run: objeto de conversa FRESCO do banco, @claimed vazio -> perde no atomic_claim
      other_conv = Conversation.find(conversation.id)
      expect(build_capture(other_conv).claim(message)).to be(false)
    end

    it 'sem message id (follow-up/teste) -> true (sem idempotencia)' do
      expect(build_capture.claim(Object.new)).to be(true)
    end

    it 'grava ai_last_captured_message_id no primeiro claim vencedor' do
      build_capture.claim(message)

      expect(conversation.reload.additional_attributes['ai_last_captured_message_id']).to eq(message.id.to_s)
    end
  end

  # Fixtures NEUTRAS (campo_a/campo_b): o contrato é agnóstico de tenant. A evidência de produção (conv 395/
  # 396) mora na descrição do PR, nunca no dado do teste.
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'p',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }
  let(:department) do
    dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Fluxo', status: 'active', behavior: {})
    dept.create_playbook!(active: true, steps: [
                            { 'name' => 'Etapa A',
                              'collect' => { 'attribute' => 'campo_a', 'type' => 'text', 'required' => true } },
                            { 'name' => 'Etapa B',
                              'collect' => { 'attribute' => 'campo_b', 'type' => 'text', 'required' => true } }
                          ])
    dept
  end
  let(:capture) do
    described_class.new(conversation: conversation,
                        persister: Ai::StateManager.new(conversation: conversation, agent: agent), agent: agent)
  end

  def facts
    conversation.reload.additional_attributes['ai_collected_facts'] || {}
  end

  def events(type)
    Ai::Event.where(conversation_id: conversation.id, event_type: type)
  end

  # Contrato pergunta↔etapa (itens 3/4): a CAPTURA segue a PERGUNTA. O destino do dado passa a ser o slot
  # que a reply_text do turno ANTERIOR pediu (ai_last_asked_slot) quando presente; cai para o slot da etapa
  # corrente quando ausente (fallback). O AVANÇO NÃO muda (segue o slot da etapa — item 5).
  describe '#capture — asked_slot dirige o destino' do
    let(:step) { department.playbook.steps.first } # etapa CORRENTE = Etapa A (slot campo_a)

    it 'asked_slot ≠ slot da etapa: grava no slot PERGUNTADO (campo_b), NÃO no da etapa (campo_a), e emite slot.asked_desync' do
      conversation.update!(additional_attributes: { 'ai_last_asked_slot' => 'campo_b' })

      capture.capture(step, { 'attributes' => {} }, 'valor do campo b', nil, department)

      expect(facts['campo_b']).to eq('valor do campo b') # destino = a PERGUNTA
      expect(facts).not_to have_key('campo_a')           # NÃO caiu no slot da etapa
      expect(events('slot.asked_desync').last.payload).to include('asked_slot' => 'campo_b', 'expected_slot' => 'campo_a')
    end

    it 'declined_turn? é avaliado para o slot PERGUNTADO (campo_b), não o da etapa (campo_a)' do
      conversation.update!(additional_attributes: { 'ai_last_asked_slot' => 'campo_b' })
      # O with(_, "campo_b", ...) QUEBRA por mutação se a origem do slot voltar a ser o da etapa (campo_a).
      expect(capture).to receive(:declined_turn?).with(step, 'campo_b', anything, 'x').and_return(true)

      expect(capture.capture(step, { 'attributes' => {} }, 'x', nil, department)).to eq({ declined: true })
    end

    it 'FALLBACK: sem ai_last_asked_slot, a captura segue o slot da ETAPA (campo_a) e NÃO emite desync' do
      capture.capture(step, { 'attributes' => {} }, 'valor do campo a', nil, department)

      expect(facts['campo_a']).to eq('valor do campo a') # destino = slot da etapa (comportamento anterior)
      expect(facts).not_to have_key('campo_b')
      expect(events('slot.asked_desync')).to be_empty
    end

    it 'turno saudável (asked_slot == slot da etapa): NÃO emite slot.asked_desync' do
      conversation.update!(additional_attributes: { 'ai_last_asked_slot' => 'campo_a' })

      capture.capture(step, { 'attributes' => {} }, 'valor do campo a', nil, department)

      expect(events('slot.asked_desync')).to be_empty
      expect(facts).to include('campo_a' => 'valor do campo a')
    end
  end

  # Adjustment #2 — slot já preenchido = turno de CONFIRMAÇÃO. Quando asked_slot aponta para um slot que já
  # tem valor em ai_collected_facts, o turno confirma o valor proposto (substitui a Peça 4/proposed_value no
  # caso comum): afirmativa MANTÉM, negativa LIMPA e mantém a etapa. Sempre emite evento. A etapa CORRENTE
  # (Etapa B/campo_b) é diferente do slot perguntado (campo_a, de uma etapa anterior, já cheio) — como na
  # sequência da conv 396 (endereço confirmado enquanto o motor já está na etapa do documento).
  describe '#capture — confirmação de valor proposto (asked_slot já preenchido)' do
    let(:step_b) { department.playbook.steps[1] } # etapa CORRENTE = Etapa B (campo_b)

    before do
      conversation.update!(additional_attributes: {
                             'ai_step_index' => 1,
                             'ai_collected_facts' => { 'campo_a' => 'valor original' },
                             'ai_last_asked_slot' => 'campo_a'
                           })
    end

    it 'afirmativa: MANTÉM o valor (não sobrescreve) e emite slot.confirmed' do
      capture.capture(step_b, { 'attributes' => {} }, 'sim', nil, department)

      expect(facts['campo_a']).to eq('valor original') # intacto
      expect(facts).not_to have_key('campo_b')         # não escreveu no slot da etapa corrente
      expect(events('slot.confirmed').last.payload).to include('attribute' => 'campo_a')
    end

    it 'negativa: LIMPA o valor, mantém a etapa e emite slot.confirmation_rejected' do
      capture.capture(step_b, { 'attributes' => {} }, 'não', nil, department)

      expect(facts).not_to have_key('campo_a')                                    # limpou
      expect(conversation.reload.additional_attributes['ai_step_index']).to eq(1) # etapa mantida
      expect(events('slot.confirmation_rejected').last.payload).to include('attribute' => 'campo_a')
    end

    it 'negativa também limpa o espelho em custom_attributes (valor rejeitado não sobra no painel)' do
      conversation.update!(custom_attributes: { 'campo_a' => 'valor original' })

      capture.capture(step_b, { 'attributes' => {} }, 'não', nil, department)

      expect(conversation.reload.custom_attributes).not_to have_key('campo_a')
    end

    it 'confirmação NÃO conta como dessincronia (slot cheio é confirmação, não misquestion)' do
      capture.capture(step_b, { 'attributes' => {} }, 'sim', nil, department)

      expect(events('slot.asked_desync')).to be_empty
    end
  end
end
