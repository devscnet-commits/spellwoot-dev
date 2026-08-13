require 'rails_helper'

# DIAGNÓSTICO (conv 436): o juiz gravou "manhã" com source:judge, o slot tem domain_from_tool="consultar_periodos",
# a ferramenta devolveu periodos:["tarde"], e NENHUM evento tool_domain.* saiu. Hipótese a testar POR EXECUÇÃO
# (não leitura): o caminho do JUIZ (Ai::TurnCapture#persist_judged) atravessa o gate com o expected_step certo e
# o tool_domain REJEITA "manhã"? Se SIM -> o código está são -> o bug de prod é DADO/TIMING (o step em memória no
# turno não tinha domain_from_tool: run anterior à escrita por console, ou escrita fora do playbook ativo).
RSpec.describe 'Ai tool-domain via caminho do JUIZ (repro conv 436)' do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'p', supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }
  let(:dept) do
    d = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Reserva', status: 'active', behavior: {})
    # UMA etapa só, com a declaração — idêntico ao playbook 5 [13] AGENDAMENTO
    d.create_playbook!(active: true, steps: [
                         { 'name' => 'AGENDAMENTO',
                           'collect' => { 'attribute' => 'periodo_reservado', 'type' => 'choice',
                                          'options' => %w[manhã tarde], 'domain_from_tool' => 'consultar_periodos' } }
                       ])
    d
  end
  let(:step) { dept.playbook.steps[0] }
  let(:tool) do
    Ai::Tool.create!(account: account, ai_department_id: dept.id, name: 'consultar_periodos',
                     implementation_type: 'webhook', webhook_config: { 'url' => 'https://x' }, status: 'active')
  end
  let(:manager) { Ai::StateManager.new(conversation: conversation, agent: agent) }
  let(:capture) { Ai::TurnCapture.new(conversation: conversation, persister: manager, agent: agent) }

  # output EXATO da conv 436: {"body":{"cidade":"Maravilha","periodos":["tarde"]}} — periodos é o ÚNICO array de escalares
  before do
    Ai::CapabilityExecution.create!(account_id: account.id, conversation_id: conversation.id, ai_tool_id: tool.id,
                                    capability_key: 'schedule.periods',
                                    input: {}, output: { 'body' => { 'cidade' => 'Maravilha', 'periodos' => %w[tarde] } },
                                    rollback_data: {}, status: 'executed')
  end

  def facts
    conversation.reload.additional_attributes['ai_collected_facts'] || {}
  end

  def events(type)
    Ai::Event.where(conversation_id: conversation.id, event_type: type)
  end

  it 'persist_judged("manhã") com expected_step = a etapa que declara domain_from_tool -> REJEITA (não grava)' do
    # o juiz decidiu {status:answered, value:"manhã"} -> persist_judged é o que grava
    capture.send(:persist_judged, step, 'periodo_reservado', 'manhã', dept, 'judge', 'answered')

    expect(facts).not_to have_key('periodo_reservado')                       # NÃO gravou (ao contrário de prod)
    expect(events('facts.rejected').last&.payload).to include('reason' => 'not_in_tool_result')
    expect(events('slot.captured')).to be_empty                              # não registra captura sem gravar
  end

  it 'controle: "tarde" (dentro do domínio) grava — prova que o caminho do juiz NÃO está morto' do
    capture.send(:persist_judged, step, 'periodo_reservado', 'tarde', dept, 'judge', 'answered')

    expect(facts['periodo_reservado']).to eq('tarde')
  end

  it 'controle: a extração pega o array nested {body:{periodos:[...]}} (não é output plano)' do
    tool_dom = manager.send(:tool_domain, step, dept)
    expect(tool_dom[:list]).to eq(%w[tarde]) # se isto falhar, o furo é o extrator no output aninhado
  end
end
