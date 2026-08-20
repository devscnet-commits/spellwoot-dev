require 'rails_helper'

# BATERIA (B2 mitigação) — o valor do slot é validado contra o RESULTADO da ferramenta do turno, quando a
# etapa declara collect['domain_from_tool']. CONV 431: consultar_periodos devolveu ["tarde"], o juiz gravou
# "manhã" (válido no estático), e o resumo entregou "manhã". Agora o gate rejeita fora do domínio dinâmico —
# vale para modelo E juiz (ambos :supervisor). OPT-IN: slot sem domain_from_tool = gate INALTERADO (prova).
RSpec.describe 'Ai slot tool-domain (B2 mitigação)' do # rubocop:disable RSpec/DescribeClass
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
                             { 'name' => 'Período',
                               'collect' => { 'attribute' => 'periodo_reservado', 'type' => 'text',
                                              'domain_from_tool' => 'consultar_periodos', 'required' => true } }
                           ])
    agent
  end
  let(:step) { dept.playbook.steps[0] }
  let(:tool) do
    Ai::Tool.create!(account: account, ai_agent_id: agent.id, name: 'consultar_periodos',
                     implementation_type: 'capability', capability_key: 'schedule.periods', status: 'active')
  end
  let(:manager) { Ai::StateManager.new(conversation: conversation, agent: agent) }

  def executed(output)
    Ai::CapabilityExecution.create!(account_id: account.id, conversation_id: conversation.id, ai_tool_id: tool.id,
                                    capability_key: 'schedule.periods', input: {}, output: output,
                                    rollback_data: {}, status: 'executed')
  end

  def persist(value)
    manager.persist_attributes({ 'periodo_reservado' => value }, dept, source: :supervisor, expected_step: step)
  end

  def facts
    conversation.reload.additional_attributes['ai_collected_facts'] || {}
  end

  def events(type)
    Ai::Event.where(conversation_id: conversation.id, event_type: type)
  end

  # ===== O bug da CONV 431: valor fora do que a ferramenta ofereceu =====
  it 'ferramenta devolveu ["tarde"] + valor "manhã" -> REJEITA (not_in_tool_result), não grava' do
    executed({ 'periodos' => %w[tarde] })

    persist('manhã')

    expect(facts).not_to have_key('periodo_reservado')
    expect(events('facts.rejected').last.payload).to include('attribute' => 'periodo_reservado', 'reason' => 'not_in_tool_result')
  end

  it 'valor DENTRO do domínio ("tarde") -> aceita e grava' do
    executed({ 'periodos' => %w[tarde] })

    persist('tarde')

    expect(facts['periodo_reservado']).to eq('tarde')
  end

  it 'comparação é case-insensitive ("Tarde" ∈ ["tarde"])' do
    executed({ 'periodos' => %w[tarde noite] })

    persist('Tarde')

    expect(facts['periodo_reservado']).to eq('Tarde')
  end

  # ===== A prova de segurança: OPT-IN — slot sem domain_from_tool = gate inalterado =====
  it 'slot SEM domain_from_tool -> gate INALTERADO (grava "manhã" como hoje)' do
    agent.create_playbook!(active: true, steps: [{ 'name' => 'P', 'collect' => { 'attribute' => 'periodo_reservado', 'type' => 'text' } }])
    Ai::StateManager.new(conversation: conversation, agent: agent)
                    .persist_attributes({ 'periodo_reservado' => 'manhã' }, agent, source: :supervisor,
                                        expected_step: agent.playbook.steps[0])

    expect(facts['periodo_reservado']).to eq('manhã')
  end

  # ===== O extrator é GENÉRICO: qualquer array de escalares em qualquer profundidade =====
  it 'output aninhado {"data":{"slots":[...]}} -> extrai e rejeita fora do domínio' do
    executed({ 'data' => { 'slots' => %w[tarde] } })

    persist('manhã')

    expect(facts).not_to have_key('periodo_reservado')
  end

  it 'lista crua (output = ["tarde"]) -> extrai' do
    executed(%w[tarde])

    persist('manhã')

    expect(facts).not_to have_key('periodo_reservado')
  end

  # ===== Fail-open COM telemetria (senão degrada em silêncio) =====
  it 'ferramenta NÃO rodou no turno -> fail-open (grava) + tool_domain.unextractable(no_execution)' do
    tool # cria a ferramenta, mas sem execução

    persist('manhã')

    expect(facts['periodo_reservado']).to eq('manhã') # fail-open: não trava por falta de resultado
    expect(events('tool_domain.unextractable').last.payload).to include('reason' => 'no_execution', 'tool' => 'consultar_periodos')
  end

  it 'output AMBÍGUO (dois arrays de escalares) -> fail-open + unextractable(ambiguous)' do
    executed({ 'periodos' => %w[tarde], 'meta' => %w[ok] })

    persist('manhã')

    expect(facts['periodo_reservado']).to eq('manhã')
    expect(events('tool_domain.unextractable').last.payload).to include('reason' => 'ambiguous')
  end

  it 'output SEM array de escalares -> fail-open + unextractable(none)' do
    executed({ 'status' => 'ok', 'count' => 3 })

    persist('manhã')

    expect(facts['periodo_reservado']).to eq('manhã')
    expect(events('tool_domain.unextractable').last.payload).to include('reason' => 'none')
  end

  # ===== choice + de-ferramenta (options estáticas VAZIAS): o tool_dom é o validador ÚNICO (não double-reject) =====
  # Este é o slot que a UI "opções vêm de: ferramenta" grava: type=choice, options=[] (a lista fixa some),
  # domain_from_tool preenchido. Sem a correção do validador-único, o valor cairia no extract(choice, opts:[]) ->
  # blank -> 'invalid_value', rejeitando à toa um valor que ESTÁ na lista da ferramenta.
  context 'quando o slot é choice com options estáticas vazias (opções vêm da ferramenta)' do # rubocop:disable RSpec/ContextWording
    let(:dept) do
      agent.create_playbook!(active: true, steps: [
                               { 'name' => 'Período',
                                 'collect' => { 'attribute' => 'periodo_reservado', 'type' => 'choice', 'options' => [],
                                                'domain_from_tool' => 'consultar_periodos', 'required' => true } }
                             ])
      agent
    end

    it 'valor DENTRO do domínio -> aceita (o estático de options vazias NÃO rejeita)' do
      executed({ 'periodos' => %w[tarde noite] })

      persist('tarde')

      expect(facts['periodo_reservado']).to eq('tarde')
    end

    it 'valor FORA do domínio -> rejeita como not_in_tool_result (não como invalid_value do estático)' do
      executed({ 'periodos' => %w[tarde noite] })

      persist('manhã')

      expect(facts).not_to have_key('periodo_reservado')
      expect(events('facts.rejected').last.payload).to include('reason' => 'not_in_tool_result')
    end

    it 'ferramenta não rodou -> fail-open (grava), NÃO cai no estático de options vazias' do
      tool

      persist('manhã')

      expect(facts['periodo_reservado']).to eq('manhã')
      expect(events('tool_domain.unextractable').last.payload).to include('reason' => 'no_execution')
    end
  end

  # ===== O AVANÇO respeita o domínio (não avança sobre valor fora da ferramenta) =====
  it 'supervisor_slot_valid?: valor fora do domínio -> false (não avança); dentro -> true' do
    executed({ 'periodos' => %w[tarde] })

    expect(manager.send(:supervisor_slot_valid?, dept, step, { 'attributes' => { 'periodo_reservado' => 'manhã' } })).to be(false)
    expect(manager.send(:supervisor_slot_valid?, dept, step, { 'attributes' => { 'periodo_reservado' => 'tarde' } })).to be(true)
  end
end
