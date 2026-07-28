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

  # Contrato pergunta↔etapa (itens 3/4): a CAPTURA segue a PERGUNTA. O destino do dado passa a ser o slot
  # que a reply_text do turno ANTERIOR pediu (ai_last_asked_slot) quando presente; cai para o slot da
  # etapa corrente quando ausente (fallback). O AVANÇO NÃO muda (segue o slot da etapa — item 5). Reproduz
  # a conv 395: a IA perguntou telefone enquanto o motor estava em vencimento.
  describe '#capture — asked_slot dirige o destino (contrato pergunta↔etapa)' do
    let(:profile) do
      Ai::OperationProfile.create!(account_id: account.id, name: 'p',
                                   supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
    end
    let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }
    let(:department) do
      dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Cadastro', status: 'active', behavior: {})
      dept.create_playbook!(active: true, steps: [
                              { 'name' => 'Vencimento',
                                'collect' => { 'attribute' => 'vencimento_fatura', 'type' => 'text', 'required' => true } },
                              { 'name' => 'Telefone',
                                'collect' => { 'attribute' => 'telefone_secundario', 'type' => 'text', 'required' => true } }
                            ])
      dept
    end
    let(:step) { department.playbook.steps.first } # etapa CORRENTE = Vencimento
    let(:capture) do
      described_class.new(conversation: conversation,
                          persister: Ai::StateManager.new(conversation: conversation, agent: agent), agent: agent)
    end

    def facts
      conversation.reload.additional_attributes['ai_collected_facts'] || {}
    end

    def desync_events
      Ai::Event.where(conversation_id: conversation.id, event_type: 'slot.asked_desync')
    end

    it 'asked_slot ≠ slot da etapa: grava no slot PERGUNTADO (telefone), NÃO no da etapa (vencimento), e emite slot.asked_desync' do
      conversation.update!(additional_attributes: { 'ai_last_asked_slot' => 'telefone_secundario' })

      capture.capture(step, { 'attributes' => {} }, '4998564780', nil, department)

      expect(facts['telefone_secundario']).to eq('4998564780') # destino = a PERGUNTA
      expect(facts).not_to have_key('vencimento_fatura')        # NÃO caiu no slot da etapa
      expect(desync_events.last.payload)
        .to include('asked_slot' => 'telefone_secundario', 'expected_slot' => 'vencimento_fatura')
    end

    it 'conv 395: declined_turn? é avaliado para o slot PERGUNTADO (type phone), não o da etapa (type text)' do
      conversation.update!(additional_attributes: { 'ai_last_asked_slot' => 'telefone_secundario' })
      # effective_type do slot PERGUNTADO (telefone_*) é 'phone'; o do slot da ETAPA (vencimento_*) seria
      # 'text'. O with(type: 'phone') QUEBRA se a origem do slot voltar a ser o da etapa (mutação do item 4).
      expect(Ai::SlotAbsence).to receive(:declined?).with(hash_including(type: 'phone')).and_return(true)

      expect(capture.capture(step, { 'attributes' => {} }, 'não tenho', nil, department)).to eq({ declined: true })
    end

    it 'FALLBACK: sem ai_last_asked_slot, a captura segue o slot da ETAPA (vencimento) e NÃO emite desync' do
      capture.capture(step, { 'attributes' => {} }, '5', nil, department)

      expect(facts['vencimento_fatura']).to eq('5')     # destino = slot da etapa (comportamento anterior)
      expect(facts).not_to have_key('telefone_secundario')
      expect(desync_events).to be_empty
    end

    it 'turno saudável (asked_slot == slot da etapa): NÃO emite slot.asked_desync' do
      conversation.update!(additional_attributes: { 'ai_last_asked_slot' => 'vencimento_fatura' })

      capture.capture(step, { 'attributes' => {} }, '5', nil, department)

      expect(desync_events).to be_empty
      expect(facts).to include('vencimento_fatura' => '5')
    end

    # Conv 396 (sequência real): turno N captura endereco_completo e a reply_text pede confirmação
    # ("Está certo?") -> asked_slot = endereco_completo; o motor avança para a etapa do documento_cpf.
    # Turno N+1: a cliente responde "esta certo". SEM o fix, o cru caía no slot da ETAPA corrente
    # (documento_cpf: "esta certo") e o modelo passava a pedir e-mail contando recusas de documento_cpf.
    # COM asked_slot, o turno N+1 é roteado ao slot PERGUNTADO (endereco_completo, já preenchido) -> a
    # confirmação não corrompe documento_cpf; a etapa segue pedindo o CPF de verdade.
    it 'conv 396: "esta certo" vai ao slot PERGUNTADO (endereco_completo, já cheio) — NÃO corrompe documento_cpf da etapa' do
      dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Cadastro396', status: 'active', behavior: {})
      dept.create_playbook!(active: true, steps: [
                              { 'name' => 'Endereço',
                                'collect' => { 'attribute' => 'endereco_completo', 'type' => 'text', 'required' => true } },
                              { 'name' => 'Documento',
                                'collect' => { 'attribute' => 'documento_cpf', 'type' => 'text', 'required' => true } }
                            ])
      documento_step = dept.playbook.steps[1] # etapa CORRENTE = Documento (índice já avançou no turno N)
      conversation.update!(additional_attributes: {
                             'ai_step_index' => 1,
                             'ai_collected_facts' => { 'endereco_completo' => 'Rua X 123' },
                             'ai_last_asked_slot' => 'endereco_completo'
                           })

      capture.capture(documento_step, { 'attributes' => {} }, 'esta certo', nil, dept)

      expect(facts).not_to have_key('documento_cpf')        # NÃO corrompeu o slot da etapa (era o bug)
      expect(facts['endereco_completo']).to eq('Rua X 123') # slot perguntado intacto (já estava cheio)
      expect(desync_events.last.payload)
        .to include('asked_slot' => 'endereco_completo', 'expected_slot' => 'documento_cpf')
    end
  end
end
