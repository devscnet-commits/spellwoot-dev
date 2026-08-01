require 'rails_helper'

# Regressão do #302 (o formato da saída dependia de QUAL método chamava o modelo). O assistente DEVE usar
# call_model (texto livre, SEM schema) — nunca decide (que impõe o DecisionSchema strict e devolve o
# ENVELOPE de decisão em vez do {"suggestion"}). O spec exercita a chamada REAL (call_model) e trava as
# duas portas: decide NÃO é chamado, e call_model é chamado SEM :schema (senão alguém reintroduz o schema
# e a saída volta a ser o envelope, com o spec verde — foi assim que o #302 sobreviveu).
RSpec.describe Ai::PromptAssistant do
  let(:account) { create(:account) }

  # Forma do call_model (TEXTO CRU), não do decide (:decision). O parse do {"suggestion"} é do serviço.
  def call_model_result(suggestion: 'texto gerado', status: 'recorded')
    { provider: 'openai', model: 'gpt-4.1-mini', text: { suggestion: suggestion }.to_json,
      tokens_in: 10, tokens_out: 20, status: status }
  end

  describe '#suggest' do
    it 'gera sugestão de base_prompt e grava um Ai::Run SEM conversa/agente' do
      allow(Ai::ModelRouter).to receive(:call_model).and_return(call_model_result(suggestion: 'meu base prompt'))

      result = described_class.new(account: account, kind: 'base_prompt', brief: 'agente comercial').suggest

      expect(result['suggestion']).to eq('meu base prompt')
      run = Ai::Run.last
      expect(run.run_type).to eq('prompt_assistant')
      expect(run.account_id).to eq(account.id)
      expect(run.conversation_id).to be_nil
      expect(run.ai_agent_id).to be_nil
      expect(run.status).to eq('recorded')
    end

    # A PROVA do #302 (porta 1): o serviço usa call_model e NUNCA decide. Falha com o código antigo, que
    # chamava decide (schema strict -> {"suggestion"} impossível -> a saída era o envelope de decisão).
    it 'usa call_model e NUNCA decide (senão a saída vira o envelope do DecisionSchema)' do
      expect(Ai::ModelRouter).not_to receive(:decide)
      allow(Ai::ModelRouter).to receive(:call_model).and_return(call_model_result)

      described_class.new(account: account, kind: 'base_prompt', brief: 'x').suggest

      expect(Ai::ModelRouter).to have_received(:call_model)
    end

    # A PROVA do #302 (porta 2, a que o usuário pediu): call_model é chamado SEM :schema (ou schema nil).
    # Sem esta asserção, alguém "melhora" passando o DecisionSchema de novo e o spec fica verde enquanto a
    # produção volta a devolver o envelope — exatamente como o #302 sobreviveu.
    it 'chama call_model SEM :schema (não reintroduzir o DecisionSchema por engano)' do
      captured = nil
      allow(Ai::ModelRouter).to receive(:call_model) do |**kwargs|
        captured = kwargs
        call_model_result
      end

      described_class.new(account: account, kind: 'base_prompt', brief: 'x').suggest

      expect(captured).not_to have_key(:schema) # schema ausente == DecisionSchema NÃO imposto
      expect(captured[:schema]).to be_nil        # e, se um dia vier explícito, tem de ser nil
    end

    it 'usa o system prompt específico de cada kind e o modelo fixo barato (openai/gpt-4.1-mini, json)' do
      captured = {}
      allow(Ai::ModelRouter).to receive(:call_model) do |**kwargs|
        captured = kwargs
        call_model_result
      end

      described_class.new(account: account, kind: 'base_prompt', brief: 'x').suggest
      expect(captured).to include(provider: 'openai', model: 'gpt-4.1-mini', json: true, account_id: account.id)
      expect(captured[:system_prompt]).to include('base_prompt')

      described_class.new(account: account, kind: 'step_instructions', brief: 'x').suggest
      expect(captured[:system_prompt]).to include('etapa')
    end

    it 'faz o parse do {"suggestion"} do TEXTO cru do call_model (não lê :decision)' do
      allow(Ai::ModelRouter).to receive(:call_model)
        .and_return(call_model_result(suggestion: "linha 1\nlinha 2"))

      result = described_class.new(account: account, kind: 'step_instructions', brief: 'x').suggest

      expect(result['suggestion']).to eq("linha 1\nlinha 2")
    end

    it 'degrada para o texto cru quando o call_model não devolve JSON' do
      allow(Ai::ModelRouter).to receive(:call_model)
        .and_return({ provider: 'openai', model: 'gpt-4.1-mini', text: 'texto solto sem json',
                      tokens_in: 1, tokens_out: 1, status: 'recorded' })

      result = described_class.new(account: account, kind: 'base_prompt', brief: 'x').suggest

      expect(result['suggestion']).to eq('texto solto sem json')
    end

    it 'computa o custo localmente (call_model não devolve cost) — Run com cost numérico' do
      allow(Ai::ModelRouter).to receive(:call_model).and_return(call_model_result)

      described_class.new(account: account, kind: 'base_prompt', brief: 'x').suggest

      expect(Ai::Run.last.cost).to be_a(Numeric)
    end

    it 'rejeita kind inválido sem chamar o modelo' do
      result = described_class.new(account: account, kind: 'xpto', brief: 'oi').suggest

      expect(result['error']).to be_present
      expect(Ai::Run.count).to eq(0)
    end

    it 'rejeita brief em branco' do
      result = described_class.new(account: account, kind: 'base_prompt', brief: '   ').suggest

      expect(result['error']).to be_present
      expect(Ai::Run.count).to eq(0)
    end
  end

  # PR4 — o assistente deixa de ser cego: quando recebe o department, ancora as CAPACIDADES REAIS
  # (tools/knowledge/variáveis) no system_prompt para NÃO sugerir consulta sem fonte (item 1) nem
  # variável inventada (item 3). Capturamos o system_prompt entregue ao call_model.
  describe '#suggest — capacidades reais do department' do
    let(:profile) do
      Ai::OperationProfile.create!(account_id: account.id, name: 'p', supervisor_provider: 'openai',
                                   supervisor_model: 'gpt-4.1-mini')
    end
    let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }
    let(:department) do
      Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Financeiro', status: 'active', behavior: {})
    end

    def capture_system_prompt(kind:, dept:)
      captured = {}
      allow(Ai::ModelRouter).to receive(:call_model) do |**kwargs|
        captured = kwargs
        call_model_result
      end
      described_class.new(account: account, kind: kind, brief: 'x', department: dept).suggest
      captured[:system_prompt]
    end

    it 'injeta as FERRAMENTAS e FONTES reais do department (ancora o item 1)' do
      Ai::Tool.create!(account: account, ai_department_id: department.id, name: 'consulta_fatura',
                       implementation_type: 'capability', capability_key: 'billing.read', status: 'active',
                       description: 'Consulta faturas em aberto')
      Ai::KnowledgeSource.create!(account: account, ai_department_id: department.id, kind: 'produto',
                                  title: 'Planos residenciais', status: 'active')

      prompt = capture_system_prompt(kind: 'step_instructions', dept: department)

      expect(prompt).to include('CAPACIDADES REAIS DESTE AGENTE')
      expect(prompt).to include('consulta_fatura: Consulta faturas em aberto')
      expect(prompt).to include('produto: Planos residenciais')
    end

    it 'department SEM tools nem knowledge: diz NENHUMA (o modelo tem de AVISAR, não inventar)' do
      prompt = capture_system_prompt(kind: 'step_instructions', dept: department)

      expect(prompt).to include('Ferramentas cadastradas: NENHUMA')
      expect(prompt).to include('Fontes de conhecimento cadastradas: NENHUMA')
    end

    it 'step_instructions injeta as VARIÁVEIS existentes; base_prompt NÃO (variável é de etapa)' do
      Ai::LeadVariable.create!(account: account, ai_department_id: department.id, name: 'tipo_consulta',
                               var_type: 'lista', values: %w[fatura contrato])

      step_prompt = capture_system_prompt(kind: 'step_instructions', dept: department)
      base_prompt = capture_system_prompt(kind: 'base_prompt', dept: department)

      expect(step_prompt).to include('Variáveis já cadastradas')
      expect(step_prompt).to include('tipo_consulta')
      expect(base_prompt).not_to include('Variáveis já cadastradas')
    end

    it 'variável: CAD de conversation_attribute sobrepõe como painel; LeadVariable-only = memória interna' do
      Ai::LeadVariable.create!(account: account, ai_department_id: department.id, name: 'interesse',
                               var_type: 'texto', values: [])
      Ai::LeadVariable.create!(account: account, ai_department_id: department.id, name: 'cpf_cnpj',
                               var_type: 'texto', values: [])
      create(:custom_attribute_definition, account: account, attribute_key: 'cpf_cnpj',
                                           attribute_model: 'conversation_attribute')

      prompt = capture_system_prompt(kind: 'step_instructions', dept: department)

      expect(prompt).to include('- interesse (texto, memória interna)')
      expect(prompt).to include('- cpf_cnpj (aparece no painel)')
    end

    it 'SEM department: degrada com CONTEXTO INDISPONÍVEL (não recusa)' do
      prompt = capture_system_prompt(kind: 'step_instructions', dept: nil)

      expect(prompt).to include('CONTEXTO INDISPONÍVEL')
      expect(prompt).to include('AVISO: verifique se existe ferramenta cadastrada')
    end

    it 'lê as tools DAQUELE department (não vaza de outro department da mesma conta)' do
      other = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Outro', status: 'active',
                                     behavior: {})
      Ai::Tool.create!(account: account, ai_department_id: other.id, name: 'so_do_outro',
                       implementation_type: 'capability', capability_key: 'x.y', status: 'active', description: 'x')

      prompt = capture_system_prompt(kind: 'step_instructions', dept: department)

      expect(prompt).not_to include('so_do_outro')
    end

    it 'item 4 (identidade) é regra dura nos DOIS kinds — guarda contra remoção' do
      identity = 'NUNCA gere texto sobre como o agente deve se identificar'
      expect(Ai::PromptAssistant::Prompts::BASE_PROMPT_SYSTEM).to match(/IDENTIDADE/)
      expect(Ai::PromptAssistant::Prompts::BASE_PROMPT_SYSTEM).to include(identity)
      expect(Ai::PromptAssistant::Prompts::STEP_INSTRUCTIONS_SYSTEM).to match(/IDENTIDADE/)
      expect(Ai::PromptAssistant::Prompts::STEP_INSTRUCTIONS_SYSTEM).to include(identity)
    end

    # O assistente NÃO pode gerar instrução que o motor já faz (validar formato, confirmar, estimar,
    # prometer avanço) — guardas contra a remoção das regras que consertam a saída conflitante.
    describe 'STEP não duplica/contradiz o motor (guardas)' do
      # normaliza o whitespace: o heredoc quebra as frases em várias linhas físicas (\n no meio das frases).
      let(:step) { Ai::PromptAssistant::Prompts::STEP_INSTRUCTIONS_SYSTEM.gsub(/\s+/, ' ') }

      it 'item 1 — PROÍBE estimar/registrar o melhor valor (em qualquer tipo, não condicionado)' do
        expect(step).to include('estimar dado do cliente é ensinar a IA a inventar')
        expect(step).to match(/PROIBIDO gerar "estime o valor"/)
        expect(step).to include('NUNCA prometa "seguir sem" um dado obrigatório') # item 4 (não trava o estrangeiro)
      end

      it 'item 2 — PROÍBE instrução de validação de formato (quem valida é o gate pelo tipo)' do
        expect(step).to include('NÃO gere instrução de VALIDAÇÃO de formato')
        expect(step).to include('Quem valida o formato é o MOTOR, pelo TIPO do slot')
      end

      it 'item 3 — PROÍBE turno só para confirmar (o motor já faz o aviso inline, #310)' do
        expect(step).to include('NÃO gere turno só para CONFIRMAR um valor')
        expect(step).to include('está certinho?') # cita o próprio anti-padrão como proibido
      end

      it 'princípio — declara que o MOTOR já valida/acusa/avança/trata ausência' do
        expect(step).to include('O MOTOR já cuida de')
      end
    end
  end
end
