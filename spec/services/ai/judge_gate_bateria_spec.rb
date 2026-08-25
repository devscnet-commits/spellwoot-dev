require 'rails_helper'

# BATERIA — o juiz de captura persiste pelo MESMO gate do supervisor (uma porta, um cadeado) + o ponteiro
# ai_last_asked_slot é limpo quando o slot perguntado resolve como AUSÊNCIA. Matriz: fonte do valor × tipo ×
# veredito do gate, cada exemplo NOMEADO e EXECUTADO (padrão da matriz de roteamento/avanço). Cobre o bug da
# evidência (slot declinado + ponteiro velho + valor de outro assunto -> não grava no slot fechado).
RSpec.describe 'Juiz pelo gate + asked_slot limpo na ausência — bateria' do # rubocop:disable RSpec/DescribeClass
  subject(:manager) { Ai::StateManager.new(conversation: conversation, agent: agent) }

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'juiz', supervisor_provider: 'openai',
                                 supervisor_model: 'gpt-4.1-mini',
                                 worker_overrides: { 'capture_judge' => { 'mode' => 'always' } })
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }
  let(:run) do
    Ai::Run.create!(account_id: account.id, conversation_id: conversation.id, ai_agent_id: agent.id,
                    inbox_id: inbox.id, run_type: 'decision', mode: 'live', status: 'running')
  end
  let(:dispatcher) { Ai::ActionDispatcher.new(conversation: conversation, account: account, mode: 'live', acts_live: true) }

  def facts
    conversation.reload.additional_attributes.to_h['ai_collected_facts'].to_h
  end

  def step_index
    conversation.reload.additional_attributes.to_h['ai_step_index']
  end

  def stuck
    conversation.reload.additional_attributes.to_h['ai_step_turns'].to_i
  end

  def events(type)
    Ai::Event.where(conversation_id: conversation.id, event_type: type)
  end

  # agente com N slots (array de {attr, required}) + Fim. Tipo derivado do NOME (email_cliente->email etc.).
  def dept_with(*slots)
    steps = slots.map do |s|
      { 'name' => s[:attr], 'collect' => { 'attribute' => s[:attr], 'required' => s.fetch(:required, true) } }
    end
    agent.update!(transfer_rules: { 'stuck_handoff_turns' => 3 })
    agent.create_playbook!(active: true, steps: steps + [{ 'name' => 'Fim' }])
    agent
  end

  def set_asked(slot)
    a = conversation.additional_attributes || {}
    conversation.update!(additional_attributes: a.merge('ai_last_asked_slot' => slot))
  end

  def stub_judge(result)
    allow(Ai::Workers::CaptureJudge).to receive(:judge).and_return(result)
  end

  # Um turno com o MODELO MUDO (sem attributes) + texto -> o juiz roda. attrs preenche o caminho do modelo;
  # asked = o slot que a reply do modelo pediu neste turno (vira ai_last_asked_slot p/ o próximo).
  def turn(dept, text: nil, attrs: nil, asked: nil, message: nil)
    msg = message || create(:message, conversation: conversation, account: account, inbox: inbox,
                                       message_type: :incoming, content: text.to_s)
    decision = { 'step_completed' => false }
    decision['attributes'] = attrs if attrs
    decision['asked_slot'] = asked if asked
    manager.track_step(dept, decision, dispatcher: dispatcher, run: run, message_text: text, message: msg)
  end

  before { conversation.update!(additional_attributes: { 'ai_step_index' => 0 }) }

  # ===== 1) JUIZ answered × tipo/veredito do gate ====================================================
  it 'answered VÁLIDO (email "joao@x.com") -> grava (via :supervisor), slot.captured, AVANÇA' do
    stub_judge(status: 'answered', value: 'joao@x.com')
    turn(dept_with({ attr: 'email_cliente' }), text: 'meu email é joao@x.com')
    aggregate_failures do
      expect(facts['email_cliente']).to eq('joao@x.com')
      expect(events('slot.captured').last.payload).to include('attribute' => 'email_cliente', 'source' => 'judge')
      expect(step_index).to eq(1)
    end
  end

  it 'answered TIPO ERRADO ("10" para email) -> invalid_value, NÃO grava, NÃO avança, teto CONTA' do
    stub_judge(status: 'answered', value: '10')
    turn(dept_with({ attr: 'email_cliente' }), text: 'pode ser 10')
    aggregate_failures do
      expect(facts).not_to have_key('email_cliente')                  # o "10" NÃO virou e-mail (o bug)
      expect(events('slot.captured')).to be_empty                     # sem "captured" mentiroso
      expect(events('facts.rejected').last.payload).to include('attribute' => 'email_cliente', 'reason' => 'invalid_value')
      expect(step_index).to eq(0)                                     # não avança
      expect(stuck).to eq(1)                                          # o teto por etapa conta o turno
    end
  end

  it 'malformed de tipo CERTO ("1103363697" 10 díg para cpf) -> REJEITA (antes gravava cru)' do
    # O caso do playbook SCNET ("se o CPF parecer inválido, confirme UMA vez"): 10 dígitos não é CPF válido.
    stub_judge(status: 'malformed', value: '1103363697')
    turn(dept_with({ attr: 'documento_cpf' }), text: '1103363697')
    aggregate_failures do
      expect(facts).not_to have_key('documento_cpf')
      expect(events('slot.captured')).to be_empty
      expect(events('facts.rejected').last.payload).to include('attribute' => 'documento_cpf', 'reason' => 'invalid_value')
      expect(step_index).to eq(0)
    end
  end

  # ===== 2) DECLÍNIO (fill_absent, caminho separado — não pode quebrar) ==============================
  it 'declínio de opcional -> fill_absent grava o token e AVANÇA (juiz não intervém)' do
    turn(dept_with({ attr: 'email_cliente', required: false }), attrs: { 'email_cliente' => Ai::StepSlot::ABSENT },
                                                                text: 'não tenho email')
    aggregate_failures do
      expect(facts['email_cliente']).to eq(Ai::StepSlot::ABSENT) # token via fill_absent (não pelo gate)
      expect(step_index).to eq(1)
    end
  end

  # ===== 3) ANEXO (determinístico, antes do juiz — intocado) ========================================
  it 'anexo preenche o slot deterministicamente -> AVANÇA (não passa pelo juiz)' do
    msg = create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :incoming, content: '')
    msg.attachments.create!(file_type: :file, fallback_title: 'comprovante.pdf', account_id: account.id)
    turn(dept_with({ attr: 'comprovante' }), message: msg)
    aggregate_failures do
      expect(facts['comprovante']).to eq('comprovante.pdf')
      expect(step_index).to eq(1)
    end
  end

  # ===== 4) O CASO DA EVIDÊNCIA: slot resolvido + ponteiro velho + valor de outro assunto ============
  describe 'slot declinado + ai_last_asked_slot velho + valor de outro assunto' do
    let(:dept) { dept_with({ attr: 'email_cliente', required: false }, { attr: 'vencimento_fatura' }) }

    it 'Q1: o declínio LIMPA o ai_last_asked_slot -> o próximo valor vai ao slot da etapa, não ao e-mail' do
      # turno 1: modelo pergunta email e declina no mesmo turno (asked_slot=email); fill_absent + limpa ponteiro
      turn(dept, attrs: { 'email_cliente' => Ai::StepSlot::ABSENT }, text: 'não tenho', asked: 'email_cliente')
      aggregate_failures do
        expect(facts['email_cliente']).to eq(Ai::StepSlot::ABSENT)
        expect(conversation.reload.additional_attributes).not_to have_key('ai_last_asked_slot') # LIMPO
        expect(step_index).to eq(1) # avançou para vencimento
      end

      # turno 2: cliente responde "10" (vencimento); ponteiro limpo -> vai para o slot da etapa
      stub_judge(status: 'answered', value: '10')
      turn(dept, text: '10')
      aggregate_failures do
        expect(facts['vencimento_fatura']).to eq('10')      # o "10" foi para o dono certo
        expect(facts['email_cliente']).to eq(Ai::StepSlot::ABSENT) # e-mail intocado (segue ausência)
      end
    end
    # (asked_slot chega pelo decision['asked_slot'], não pela mensagem — ver o helper `turn`.)

    it 'Q2 (rede dupla): mesmo com o ponteiro velho FORÇADO no e-mail, o gate barra "10" por tipo' do
      # simula o estado da falha: etapa em vencimento, mas ai_last_asked_slot ainda em email_cliente (declinado)
      conversation.update!(additional_attributes: { 'ai_step_index' => 1,
                                                     'ai_collected_facts' => { 'email_cliente' => Ai::StepSlot::ABSENT } })
      set_asked('email_cliente')
      stub_judge(status: 'answered', value: '10') # o juiz "extrai" 10 para o slot perguntado (email)

      turn(dept, text: '10')

      aggregate_failures do
        expect(facts['email_cliente']).to eq(Ai::StepSlot::ABSENT) # "10" NÃO sobrescreveu (gate: invalid_value)
        expect(events('facts.rejected').last.payload).to include('attribute' => 'email_cliente', 'reason' => 'invalid_value')
      end
    end
  end
end
