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

  # step_instructions: 4 campos SEPARADOS (objective/rules/suggested_script/admin_warnings), não {"suggestion"}.
  def call_model_step_result(objective: 'Obter a cidade', rules: ['Uma regra'], suggested_script: 'Oi!',
                             admin_warnings: [], status: 'recorded')
    { provider: 'openai', model: 'gpt-4.1-mini',
      text: { objective: objective, rules: rules, suggested_script: suggested_script,
              admin_warnings: admin_warnings }.to_json,
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

      result = described_class.new(account: account, kind: 'base_prompt', brief: 'x').suggest

      expect(result['suggestion']).to eq("linha 1\nlinha 2")
    end

    it 'degrada para o texto cru quando o call_model não devolve JSON' do
      allow(Ai::ModelRouter).to receive(:call_model)
        .and_return({ provider: 'openai', model: 'gpt-4.1-mini', text: 'texto solto sem json',
                      tokens_in: 1, tokens_out: 1, status: 'recorded' })

      result = described_class.new(account: account, kind: 'base_prompt', brief: 'x').suggest

      expect(result['suggestion']).to eq('texto solto sem json')
    end

    # step_instructions: a tela tem 3 campos (Ai::StepForm.vue), não 1 textarea — o contrato de saída
    # do assistente tem de bater: objective (string), rules (ARRAY), suggested_script (string), mais
    # admin_warnings (ARRAY, só pro admin humano — NUNCA aplicado ao form).
    describe 'step_instructions — 4 campos SEPARADOS (não {"suggestion"})' do
      it 'faz o parse de objective/rules/suggested_script do TEXTO cru do call_model' do
        allow(Ai::ModelRouter).to receive(:call_model).and_return(
          call_model_step_result(objective: 'Obter a cidade e o tipo de cliente',
                                 rules: ['Regra 1', 'Regra 2'], suggested_script: 'Oi! Me diz sua cidade?')
        )

        result = described_class.new(account: account, kind: 'step_instructions', brief: 'x').suggest

        expect(result['objective']).to eq('Obter a cidade e o tipo de cliente')
        expect(result['rules']).to eq(['Regra 1', 'Regra 2'])
        expect(result['suggested_script']).to eq('Oi! Me diz sua cidade?')
        expect(result).not_to have_key('suggestion') # NÃO é mais o contrato de 1 campo
      end

      # Bug real ao vivo: a IA leu "AVISO: CRIE A VARIÁVEL..." dentro da instrução como se fosse
      # comportamento — admin_warnings existe pra isso NUNCA mais acontecer (campo separado, nunca
      # aplicado ao form/step, só mostrado pro admin em AiPromptAssistant.vue).
      it 'faz o parse de admin_warnings (avisos pro admin, SEPARADOS dos campos de máquina)' do
        allow(Ai::ModelRouter).to receive(:call_model).and_return(
          call_model_step_result(admin_warnings: ['Crie a variável setor_cliente antes de publicar esta etapa.'])
        )

        result = described_class.new(account: account, kind: 'step_instructions', brief: 'x').suggest

        expect(result['admin_warnings']).to eq(['Crie a variável setor_cliente antes de publicar esta etapa.'])
      end

      it 'admin_warnings ausente no JSON vira array vazio (nunca quebra o contrato)' do
        allow(Ai::ModelRouter).to receive(:call_model).and_return(
          { provider: 'openai', model: 'gpt-4.1-mini',
            text: { objective: 'x', rules: [], suggested_script: 'y' }.to_json, # sem "admin_warnings"
            tokens_in: 1, tokens_out: 1, status: 'recorded' }
        )

        result = described_class.new(account: account, kind: 'step_instructions', brief: 'x').suggest

        expect(result['admin_warnings']).to eq([])
      end

      it 'degrada sem quebrar quando o call_model não devolve JSON (texto cru vira suggested_script)' do
        allow(Ai::ModelRouter).to receive(:call_model)
          .and_return({ provider: 'openai', model: 'gpt-4.1-mini', text: 'texto solto sem json',
                        tokens_in: 1, tokens_out: 1, status: 'recorded' })

        result = described_class.new(account: account, kind: 'step_instructions', brief: 'x').suggest

        expect(result['objective']).to eq('')
        expect(result['rules']).to eq([])
        expect(result['suggested_script']).to eq('texto solto sem json')
        expect(result['admin_warnings']).to eq([])
      end

      it 'rules ausente ou não-array no JSON vira array (nunca quebra o contrato)' do
        allow(Ai::ModelRouter).to receive(:call_model).and_return(
          { provider: 'openai', model: 'gpt-4.1-mini',
            text: { objective: 'x', suggested_script: 'y' }.to_json, # sem "rules"
            tokens_in: 1, tokens_out: 1, status: 'recorded' }
        )

        result = described_class.new(account: account, kind: 'step_instructions', brief: 'x').suggest

        expect(result['rules']).to eq([])
      end
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

    # step_instructions: o aviso de "sem contexto" vai em admin_warnings (nunca em objective/rules/
    # suggested_script) — diferente do base_prompt, que ainda embute "AVISO:" no próprio texto.
    it 'SEM department (step_instructions): degrada com CONTEXTO INDISPONÍVEL, aviso roteado pra admin_warnings' do
      prompt = capture_system_prompt(kind: 'step_instructions', dept: nil)

      expect(prompt).to include('CONTEXTO INDISPONÍVEL')
      expect(prompt).to include('coloque o aviso SOMENTE em admin_warnings')
      expect(prompt).not_to include('AVISO: verifique se existe ferramenta cadastrada')
    end

    it 'SEM department (base_prompt): ainda embute "AVISO:" no próprio texto (copy-paste, sem apply direto)' do
      prompt = capture_system_prompt(kind: 'base_prompt', dept: nil)

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

      it 'item 2 — PROÍBE instrução de validação manual de formato' do
        expect(step).to include('NÃO gere instrução de VALIDAÇÃO manual de formato')
      end

      it 'item 3 — PROÍBE turno só para confirmar' do
        expect(step).to include('NÃO gere turno só para CONFIRMAR um valor')
        expect(step).to include('está certinho?') # cita o próprio anti-padrão como proibido
      end

      # Bug real ao vivo (WhatsApp): cliente disse "vendas", a IA respondeu "Perfeito, é vendas
      # mesmo?" em loop, sem nunca salvar o dado nem chamar avancar_etapa. Diferente do item 3 (que só
      # proíbe o assistente de GERAR esse anti-padrão): esta regra OBRIGA o assistente a incluir, em
      # TODA etapa que coleta dado, um item literal de "rules" contra confirmação — reforço redundante
      # de propósito, mesmo padrão do item 6 (cláusula de escape obrigatória).
      it 'item 3b — OBRIGA (não só proíbe) um item fixo de "rules" contra loop de confirmação' do
        expect(step).to include('OBRIGATORIAMENTE este item literal em "rules"')
        expect(step).to include('Nunca peça confirmação de algo que o cliente já disse claramente')
        expect(step).to include('Se o cliente informou o dado, aceite e inclua em "dados_coletados" imediatamente')
      end

      # Motor novo (agêntico): quem valida/decide avançar é a própria IA via tools — não um motor à
      # parte. Guarda contra REINTRODUZIR a alegação antiga (contradiria o motor Python/agêntico).
      it 'princípio — NÃO alega que um motor à parte valida formato ou decide avançar sozinho' do
        expect(step).not_to include('O MOTOR já cuida de')
        expect(step).not_to include('Quem valida o formato é o MOTOR')
      end

      # Structured Outputs: o assistente parou de gerar "chame a ferramenta registrar_X"/
      # "avancar_etapa" — essas tools não existem mais no motor novo (a IA que lia essa instrução
      # procurava a tool, não achava, e desistia — encerrava o atendimento). Guarda dos dois lados:
      # o contrato JSON precisa aparecer, e o texto de tool-calling precisa ter sumido de vez.
      it 'princípio — instrui USO DO CONTRATO JSON: "dados_coletados" ao receber o dado, "avancar_etapa" ao concluir' do
        expect(step).to include('dados_coletados')
        expect(step).to include('avancar_etapa')
        expect(step).not_to match(/chame\s+(?:imediatamente\s+)?a\s+(?:ferramenta|tool)\s+['"]?(?:registrar_|avancar_etapa)/i)
      end

      # "padrão ouro" (2026-08): a saída deixou de ser 1 texto com blocos markdown e virou 3 campos JSON
      # SEPARADOS — espelha os 3 campos da tela (Ai::StepForm.vue), não 1 textarea.
      it 'formato de saída — 3 campos JSON separados: objective / rules (array) / suggested_script' do
        expect(step).to include('"objective"')
        expect(step).to include('"rules"')
        expect(step).to include('"suggested_script"')
        expect(step).not_to include('**Objetivo:**') # formato antigo (markdown num texto só) removido
        expect(step).not_to include('**Regras:**')
        expect(step).not_to include('**Fala sugerida:**')
      end

      it 'NÃO proíbe mais etapa com múltiplos dados (o motor agêntico salva um por um via tools)' do
        expect(step).not_to include('UMA etapa = UM dado')
        expect(step).not_to include('É PROIBIDO gerar uma etapa que peça dois ou mais dados')
      end

      # Dado de TERCEIRO (indicado) não pode reusar a variável do cliente e sobrescrever (bug real).
      it 'entidade — reusa só o dado do MESMO cliente; dado de outra pessoa vira variável NOVA' do
        expect(step).to include('DE QUEM é o dado')
        expect(step).to include('PERTENCE A OUTRA PESSOA') # CRITÉRIO, não lista de palavras PT
        expect(step).to include('NA DÚVIDA de quem é o dado, prefira CRIAR') # viés conservador
      end

      # Bug real ao vivo (o motivo desta rodada de ajuste): a IA leu "AVISO: CRIE A VARIÁVEL X ANTES
      # DE USAR ESTA ETAPA" dentro da instrução e ficou confusa — não é regra de comportamento, é
      # aviso pro admin. Guardas contra REINTRODUZIR esse vazamento nos 3 campos de máquina.
      describe 'admin_warnings — avisos pro admin NUNCA vazam pros campos de máquina (bug real)' do
        it 'declara o 4º campo admin_warnings e a REGRA DE OURO (3 campos de máquina vs aviso pro admin)' do
          expect(step).to include('"admin_warnings"')
          expect(step).to include('REGRA DE OURO')
          expect(step).to include('vão DIRETO pro system_prompt')
        end

        it 'PROÍBE explicitamente as frases do bug real dentro de objective/rules/suggested_script' do
          expect(step).to include('"AVISO:"')
          expect(step).to include('"CRIE A VARIÁVEL"')
          expect(step).to include('"ANTES DE USAR ESTA ETAPA"')
        end

        it 'regra da variável nova: o aviso "Crie a variável..." vai em admin_warnings, não em rules' do
          expect(step).to include('O AVISO de que a variável ainda precisa ser criada')
          expect(step).to include('vai em "admin_warnings"')
          expect(step).to include('Crie a variável <nome_sugerido> antes de publicar')
        end

        it 'regra de ação-só-com-fonte: o aviso de consulta sem fonte vai em admin_warnings, não na instrução' do
          expect(step).to include('NÃO menciona essa consulta')
          expect(step).to include('O aviso do motivo vai SÓ em')
          expect(step).to include('"admin_warnings": "Você pediu consulta a')
        end
      end
    end
  end
end
