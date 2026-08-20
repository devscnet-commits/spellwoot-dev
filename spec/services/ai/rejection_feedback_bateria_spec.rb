require 'rails_helper'

# BATERIA (4) — FEEDBACK DE REJEIÇÃO POR FORMATO. Um slot de formato barra um valor legítimo (passaporte/RNE
# no lugar do CPF, número internacional no telefone) e hoje a IA repergunta idêntico até o teto. Este PR faz o
# motor SINALIZAR o motivo ao prompt para a IA EXPLICAR (e rotear "não tenho" para a ausência), com escalada
# soft ao humano reusando ai_step_turns. NÃO toca o motor de validação (supervisor_fact_reason intocado):
# só observa a rejeição. Genérico (qualquer formato), não CPF-específico.
RSpec.describe 'Ai rejection feedback (4)' do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'p', supervisor_provider: 'openai',
                                 supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }
  let(:dept) do
    agent.create_playbook!(active: true, steps: [
                             { 'name' => 'CPF', 'collect' => { 'attribute' => 'documento_cpf', 'type' => 'cpf', 'required' => true } },
                             { 'name' => 'E-mail', 'collect' => { 'attribute' => 'email_cliente', 'type' => 'email', 'required' => true } }
                           ])
    agent
  end
  let(:cpf_step) { dept.playbook.steps[0] }
  let(:manager) { Ai::StateManager.new(conversation: conversation, agent: agent) }

  def attrs
    conversation.reload.additional_attributes
  end

  # ===== A DIRETIVA (PromptCompiler) — genérica, com escalada soft EXECUTÁVEL =========================
  describe 'PromptCompiler.rejection_feedback_line' do
    let(:steps) { dept.playbook.steps }

    def line(slot:, invalid_slot:, value:, turns:)
      Ai::PromptCompiler.rejection_feedback_line(steps, 0, slot,
                                                 { 'invalid' => { 'slot' => invalid_slot, 'value' => value }, 'step_turns' => turns })
    end

    it 'rejeição do slot corrente -> explica o valor e o tipo esperado; SEM escalada abaixo do limiar' do
      out = line(slot: 'documento_cpf', invalid_slot: 'documento_cpf', value: 'AB123456', turns: 0)

      expect(out).to include('AB123456', '(cpf)', 'NÃO tem o formato esperado')
      expect(out).to include('registre a ausência') # roteia o "não tenho" p/ o caminho determinístico
      expect(out).not_to include('falar com um atendente') # ainda não escalou
    end

    it 'no limiar (ai_step_turns >= 2) -> OFERECE falar com atendente (espelha o transfer_when) e manda FAZER o handoff' do
      out = line(slot: 'documento_cpf', invalid_slot: 'documento_cpf', value: 'AB123456', turns: 2)

      expect(out).to include('OFEREÇA falar com um atendente') # texto espelha o gatilho "cliente pede para falar com atendente"
      expect(out).to include('FAÇA a transferência', 'não apenas diga que vai') # guarda contra promessa vazia
    end

    it 'é GENÉRICO: em slot de e-mail cita (email), não CPF' do
      out = Ai::PromptCompiler.rejection_feedback_line(steps, 1, 'email_cliente',
                                                       { 'invalid' => { 'slot' => 'email_cliente', 'value' => 'foo' }, 'step_turns' => 0 })

      expect(out).to include('(email)')
      expect(out).not_to include('cpf')
    end

    it 'rejeição de OUTRO slot (não o corrente) -> nil (não vaza feedback de outro dado)' do
      expect(line(slot: 'documento_cpf', invalid_slot: 'email_cliente', value: 'x', turns: 5)).to be_nil
    end

    it 'sem rejeição pendente -> nil' do
      expect(Ai::PromptCompiler.rejection_feedback_line(steps, 0, 'documento_cpf', {})).to be_nil
    end
  end

  # ===== A CAPTURA (StateManager) — só OBSERVA; o motor de validação fica intocado ====================
  describe 'StateManager#persist_slot_feedback — registra/limpa ai_last_invalid' do
    it 'valor de formato errado -> registra ai_last_invalid e NÃO grava o slot (motor de validação intocado)' do
      manager.persist_attributes({ 'documento_cpf' => 'AB123456' }, dept, source: :supervisor, expected_step: cpf_step)

      expect(attrs['ai_last_invalid']).to eq({ 'slot' => 'documento_cpf', 'value' => 'AB123456' })
      expect(attrs['ai_collected_facts'] || {}).not_to have_key('documento_cpf') # rejeitado como antes
      expect(Ai::Event.where(conversation_id: conversation.id, event_type: 'facts.rejected')
                      .where("payload->>'reason' = 'invalid_value'")).to be_present
    end

    it 'valor válido depois -> grava o slot e LIMPA ai_last_invalid' do
      manager.persist_attributes({ 'documento_cpf' => 'AB123456' }, dept, source: :supervisor, expected_step: cpf_step)
      manager.persist_attributes({ 'documento_cpf' => '110.336.369-75' }, dept, source: :supervisor, expected_step: cpf_step)

      expect(attrs['ai_collected_facts']).to include('documento_cpf' => '110.336.369-75')
      expect(attrs).not_to have_key('ai_last_invalid') # resolvido -> feedback some
    end

    it 'recusa declarada (__sem_valor__) NÃO vira feedback de formato (é ausência, não formato errado)' do
      manager.persist_attributes({ 'documento_cpf' => Ai::StepSlot::ABSENT }, dept, source: :supervisor, expected_step: cpf_step)

      expect(attrs).not_to have_key('ai_last_invalid')
    end

    it 'chave inesperada (fora do playbook) NÃO vira feedback de formato' do
      manager.persist_attributes({ 'chave_fantasma' => 'AB123456' }, dept, source: :supervisor, expected_step: cpf_step)

      expect(attrs).not_to have_key('ai_last_invalid')
    end
  end

  # ===== O caso das 3 INSISTÊNCIAS — não desaparece nem duplica; oferta a partir da 2ª ================
  describe 'cliente insiste com valor inválido três vezes' do
    def block_for(turns)
      Ai::PromptCompiler.collection_state_block(
        dept.playbook.steps, 0, {}, nil,
        { 'invalid' => attrs['ai_last_invalid'], 'step_turns' => turns }
      )
    end

    it 'o bloco aparece nas 3, UMA vez cada (não duplica), e a oferta entra a partir da 2ª (não some)' do
      blocks = []
      # 3 rejeições do MESMO valor inválido; ai_step_turns cresce 1,2,3 (o resolver conta o turno inválido —
      # coberto pelo teto absoluto em state_manager_spec; aqui simulamos o contador para focar o RENDER).
      3.times do |i|
        manager.persist_attributes({ 'documento_cpf' => 'AB123456' }, dept, source: :supervisor, expected_step: cpf_step)
        # não desaparece nem vira lista: segue um único {slot,value} após cada rejeição
        expect(attrs['ai_last_invalid']).to eq({ 'slot' => 'documento_cpf', 'value' => 'AB123456' })
        blocks << block_for(i + 1)
      end

      aggregate_failures do
        blocks.each { |b| expect(b.scan('NÃO tem o formato esperado').size).to eq(1) } # aparece 1x por turno (não duplica)
        expect(blocks[0]).not_to include('falar com um atendente') # turno 1: sem oferta
        expect(blocks[1]).to include('falar com um atendente')     # turno 2: oferta
        expect(blocks[2]).to include('falar com um atendente')     # turno 3: oferta (não some)
      end
    end
  end
end
