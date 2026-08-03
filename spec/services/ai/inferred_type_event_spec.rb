require 'rails_helper'

# Instrumentação temporária (Fase 1 do type_for_key): mede o RESIDUAL de fatos cujo tipo o gate resolveria
# pela INFERÊNCIA (type_for_key) e não por `type` declarado — o que perde validação quando a inferência for
# apagada (Fase 2). Slots de etapa já declaram o tipo (prod = 0); isto pega o step-less (lead_variable/fillable).
RSpec.describe 'Ai::StateManager — evento slot.inferred_type_used (Fase 1 type_for_key)' do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'p', supervisor_provider: 'openai',
                                 supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }
  let(:department) do
    d = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Cad', status: 'active', behavior: {})
    d.create_playbook!(active: true, steps: [
                         { 'name' => 'CPF', 'collect' => { 'attribute' => 'documento_cpf', 'type' => 'cpf' } },
                         { 'name' => 'Tel fixo', 'collect' => { 'attribute' => 'telefone_fixo', 'type' => 'text' } }
                       ])
    d.lead_variables.create!(account: account, name: 'telefone_cliente') # step-less, chave infere phone
    d.lead_variables.create!(account: account, name: 'cidade')           # step-less, NÃO infere formato
    d
  end
  let(:cpf_step) { department.playbook.steps[0] }
  let(:tel_step) { department.playbook.steps[1] }
  let(:manager) { Ai::StateManager.new(conversation: conversation, agent: agent) }

  def events
    Ai::Event.where(conversation_id: conversation.id, event_type: 'slot.inferred_type_used')
             .map { |e| e.payload.slice('attribute', 'inferred_type', 'step_less') }
  end

  it 'chave STEP-LESS que infere formato (lead_variable telefone_cliente) -> emite; declarado e não-formato NÃO' do
    manager.persist_attributes(
      { 'documento_cpf' => '110.336.369-75', 'telefone_cliente' => '47999998888', 'cidade' => 'Chapecó' },
      department, source: :supervisor, expected_step: cpf_step
    )

    attrs = events
    expect(attrs).to include('attribute' => 'telefone_cliente', 'inferred_type' => 'phone', 'step_less' => true)
    expect(attrs.map { |a| a['attribute'] }).not_to include('documento_cpf') # tipo DECLARADO (cpf)
    expect(attrs.map { |a| a['attribute'] }).not_to include('cidade')        # chave não infere formato
  end

  it 'slot de etapa declarado como TEXT mas cuja chave infere formato -> emite (step_less false)' do
    manager.persist_attributes(
      { 'telefone_fixo' => '4733334444' }, department, source: :supervisor, expected_step: tel_step
    )

    expect(events).to include('attribute' => 'telefone_fixo', 'inferred_type' => 'phone', 'step_less' => false)
  end

  it 'fonte :trusted (não passa pelo gate) NÃO emite (a medição é do gate do supervisor)' do
    manager.persist_attributes({ 'telefone_cliente' => '47999998888' }, department, source: :trusted)

    expect(events).to be_empty
  end
end
