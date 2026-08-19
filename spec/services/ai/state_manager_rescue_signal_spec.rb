require 'rails_helper'

# ITEM 2 (vale mais que o conserto): um rescue NÃO pode transformar erro de CÓDIGO em degradação silenciosa.
# CONV 436: Ai::StepSlot.domain_from_tool ausente no worker -> NoMethodError -> rescue do tool_domain -> nil,
# ZERO evento, uma hora perdida. rescue_signal agora emite 'internal.code_error' (VISÍVEL) para erro de código,
# e NÃO para erro esperado (provedor/rede — degradação operacional normal).
RSpec.describe 'Ai::StateManager#rescue_signal (erro de código vira sinal visível)' do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'p', supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) do
    a = Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id,
                          behavior: {})
    a.create_playbook!(active: true, steps: [
                         { 'name' => 'AGENDAMENTO',
                           'collect' => { 'attribute' => 'periodo_reservado', 'type' => 'choice',
                                          'options' => %w[manhã tarde], 'domain_from_tool' => 'consultar_periodos' } }
                       ])
    a
  end
  let(:manager) { Ai::StateManager.new(conversation: conversation, agent: agent) }

  def code_error_events
    Ai::Event.where(conversation_id: conversation.id, event_type: 'internal.code_error')
  end

  # dispara o caminho gated_facts -> tool_domain -> Ai::StepSlot.domain_from_tool (o ponto do NoMethodError da 436)
  def persist_supervisor
    manager.persist_attributes({ 'periodo_reservado' => 'manhã' }, agent, source: :supervisor, expected_step: agent.playbook.steps[0])
  end

  it 'NoMethodError no tool_domain -> emite internal.code_error com a classe e o escopo (não engole em silêncio)' do
    allow(Ai::StepSlot).to receive(:domain_from_tool).and_raise(NoMethodError.new("undefined method `domain_from_tool'"))

    persist_supervisor

    ev = code_error_events.last
    expect(ev).to be_present
    expect(ev.payload).to include('scope' => 'tool_domain', 'error' => 'NoMethodError')
  end

  it 'erro ESPERADO (não-código) no mesmo ponto -> NÃO emite internal.code_error (só loga; degradação normal)' do
    allow(Ai::StepSlot).to receive(:domain_from_tool).and_raise(RuntimeError.new('provedor fora'))

    persist_supervisor

    expect(code_error_events).to be_empty
  end

  it 'o turno NÃO morre por causa do sinal: o gate degrada (grava pelo estático) apesar do NoMethodError' do
    allow(Ai::StepSlot).to receive(:domain_from_tool).and_raise(NoMethodError.new('x'))

    persist_supervisor

    # "manhã" ∈ options estáticas -> grava (degradação, como a 436) — mas AGORA com o evento acima para ser visível
    expect(conversation.reload.additional_attributes['ai_collected_facts']).to include('periodo_reservado' => 'manhã')
  end
end
