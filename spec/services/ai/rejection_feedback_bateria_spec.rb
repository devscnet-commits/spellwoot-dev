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
    d = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Cadastro', status: 'active', behavior: {})
    d.create_playbook!(active: true, steps: [
                         { 'name' => 'CPF', 'collect' => { 'attribute' => 'documento_cpf', 'type' => 'cpf', 'required' => true } },
                         { 'name' => 'E-mail', 'collect' => { 'attribute' => 'email_cliente', 'type' => 'email', 'required' => true } }
                       ])
    d
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
      expect(out).not_to include('atendente humano') # ainda não escalou
    end

    it 'no limiar (ai_step_turns >= 2) -> OFERECE humano e manda FAZER o handoff (ação real, não promessa vazia)' do
      out = line(slot: 'documento_cpf', invalid_slot: 'documento_cpf', value: 'AB123456', turns: 2)

      expect(out).to include('atendente humano')
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
end
