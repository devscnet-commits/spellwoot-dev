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

    it 'asked_slot desconhecido (chave fantasma) é IGNORADO: NÃO escreve a chave, cai no slot da etapa e emite slot.asked_slot_unknown' do
      conversation.update!(additional_attributes: { 'ai_last_asked_slot' => 'chave_fantasma' })

      capture.capture(step, { 'attributes' => {} }, 'valor qualquer', nil, department)

      expect(facts).not_to have_key('chave_fantasma')           # NÃO envenena ai_collected_facts
      expect(facts['campo_a']).to eq('valor qualquer')          # fallback: slot da etapa corrente
      expect(events('slot.asked_slot_unknown').last.payload).to include('asked_slot' => 'chave_fantasma')
      expect(events('slot.asked_desync')).to be_empty           # foi ignorado, não é dessincronia
    end
  end

  # Adjustment #2 (versão MÍNIMA) — slot já preenchido = turno de CONFIRMAÇÃO. Quando asked_slot aponta para
  # um slot que já tem valor REAL em ai_collected_facts, capture só SINALIZA (slot.asked_confirmation_turn) e
  # SAI: NÃO escreve por cima, NÃO limpa, NÃO toca no espelho custom_attributes. A semântica afirmativa/
  # negativa fica para PR próprio (detector = juiz estruturado). O token de ausência não é confirmável.
  describe '#capture — turno de confirmação (asked_slot já preenchido)' do
    let(:step_a) { department.playbook.steps.first } # campo_a
    let(:step_b) { department.playbook.steps[1] }    # campo_b (etapa corrente no cenário de confirmação)

    it 'asked_slot já preenchido: emite slot.asked_confirmation_turn e NÃO escreve, NÃO captura' do
      conversation.update!(additional_attributes: {
                             'ai_step_index' => 1,
                             'ai_collected_facts' => { 'campo_a' => 'valor original' },
                             'ai_last_asked_slot' => 'campo_a'
                           })

      expect(capture.capture(step_b, { 'attributes' => {} }, 'sim, pode ser', nil, department)).to be_nil

      expect(facts['campo_a']).to eq('valor original') # intacto (não sobrescreveu)
      expect(facts).not_to have_key('campo_b')         # não escreveu no slot da etapa corrente
      expect(events('slot.asked_confirmation_turn').last.payload).to include('attribute' => 'campo_a')
      expect(events('slot.captured')).to be_empty
    end

    it 'NÃO limpa a memória nem o espelho custom_attributes, mesmo com resposta negativa (preserva correção do atendente)' do
      conversation.update!(additional_attributes: {
                             'ai_step_index' => 1,
                             'ai_collected_facts' => { 'campo_a' => 'valor original' },
                             'ai_last_asked_slot' => 'campo_a'
                           }, custom_attributes: { 'campo_a' => 'corrigido pelo humano' })

      capture.capture(step_b, { 'attributes' => {} }, 'não, está errado', nil, department)

      expect(facts['campo_a']).to eq('valor original')                                        # NÃO limpou a memória
      expect(conversation.reload.custom_attributes['campo_a']).to eq('corrigido pelo humano') # NÃO tocou o espelho
      expect(events('slot.asked_confirmation_turn').last.payload).to include('attribute' => 'campo_a')
    end

    it 'token de ausência (__sem_valor__) NÃO é confirmável: não emite slot.asked_confirmation_turn' do
      conversation.update!(additional_attributes: {
                             'ai_step_index' => 0,
                             'ai_collected_facts' => { 'campo_a' => Ai::StepSlot::ABSENT },
                             'ai_last_asked_slot' => 'campo_a'
                           })

      capture.capture(step_a, { 'attributes' => {} }, 'qualquer', nil, department)

      expect(events('slot.asked_confirmation_turn')).to be_empty
    end
  end
end
