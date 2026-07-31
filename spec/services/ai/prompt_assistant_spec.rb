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
end
