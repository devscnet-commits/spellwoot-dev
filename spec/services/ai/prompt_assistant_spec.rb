require 'rails_helper'

RSpec.describe Ai::PromptAssistant do
  let(:account) { create(:account) }

  def router_result(suggestion: 'texto gerado')
    { provider: 'openai', model: 'gpt-4.1-mini', decision: { 'suggestion' => suggestion },
      tokens_in: 10, tokens_out: 20, cost: 0.0, latency_ms: 5, status: 'recorded' }
  end

  describe '#suggest' do
    it 'gera sugestão de base_prompt e grava um Ai::Run SEM conversa/agente' do
      allow(Ai::ModelRouter).to receive(:decide).and_return(router_result(suggestion: 'meu base prompt'))

      result = described_class.new(account: account, kind: 'base_prompt', brief: 'agente comercial').suggest

      expect(result['suggestion']).to eq('meu base prompt')
      run = Ai::Run.last
      expect(run.run_type).to eq('prompt_assistant')
      expect(run.account_id).to eq(account.id)
      expect(run.conversation_id).to be_nil
      expect(run.ai_agent_id).to be_nil
      expect(run.status).to eq('recorded')
    end

    it 'usa o system prompt específico de cada kind' do
      captured = {}
      allow(Ai::ModelRouter).to receive(:decide) do |**kwargs|
        captured = kwargs
        router_result
      end

      described_class.new(account: account, kind: 'base_prompt', brief: 'x').suggest
      expect(captured[:system_prompt]).to include('base_prompt')

      described_class.new(account: account, kind: 'step_instructions', brief: 'x').suggest
      expect(captured[:system_prompt]).to include('etapa')
    end

    it 'chama o ModelRouter com o modelo fixo barato (openai/gpt-4.1-mini, json)' do
      allow(Ai::ModelRouter).to receive(:decide).and_return(router_result)

      described_class.new(account: account, kind: 'base_prompt', brief: 'x').suggest

      expect(Ai::ModelRouter).to have_received(:decide).with(
        hash_including(profile: nil, provider: 'openai', model: 'gpt-4.1-mini', json: true, account_id: account.id)
      )
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
