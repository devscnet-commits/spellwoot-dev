require 'rails_helper'

# Cobre a camada de STRUCTURED OUTPUT do Ai::ModelRouter: seleção de schema (flag) + normalização do
# envelope achatado de volta ao formato interno. Não faz chamada de rede (testa os métodos puros).
RSpec.describe Ai::ModelRouter do
  describe '.decision_schema_for (flag de fallback)' do
    it 'LIGADO por padrão em openai + json' do
      expect(described_class.decision_schema_for('openai', true)).to eq(Ai::DecisionSchema)
    end

    it 'nil quando json=false (caminho não-decisão)' do
      expect(described_class.decision_schema_for('openai', false)).to be_nil
    end

    it 'nil em provider sem suporte a json_schema (ex.: anthropic)' do
      expect(described_class.decision_schema_for('anthropic', true)).to be_nil
    end

    it 'OFF via ENV["AI_DECISION_SCHEMA"]=off cai no json_object (schema nil)' do
      ENV['AI_DECISION_SCHEMA'] = 'off'
      expect(described_class.decision_schema_for('openai', true)).to be_nil
    ensure
      ENV.delete('AI_DECISION_SCHEMA')
    end
  end

  describe '.coerce_decision (ponto único de parse)' do
    it 'Hash (schema: ruby_llm já parseou) passa direto' do
      hash = { 'decision' => 'reply' }
      expect(described_class.coerce_decision(hash)).to equal(hash)
    end

    it 'String (json_object) usa o parse tolerante' do
      expect(described_class.coerce_decision('{"decision":"noop"}')).to eq({ 'decision' => 'noop' })
    end

    it 'String inválida -> unparsed (rede de segurança intacta)' do
      expect(described_class.coerce_decision('nao tem json aqui')).to eq({ 'decision' => 'unparsed' })
    end
  end

  describe '.normalize_decision (envelope achatado -> interno)' do
    it 'attributes_list -> Hash attributes correto' do
      out = described_class.normalize_decision(
        'decision' => 'reply',
        'attributes_list' => [{ 'key' => 'cidade', 'value' => 'Maravilha' }, { 'key' => 'plano', 'value' => 'Fibra' }]
      )
      expect(out['attributes']).to eq({ 'cidade' => 'Maravilha', 'plano' => 'Fibra' })
      expect(out).not_to have_key('attributes_list')
    end

    it 'itens sem chave são ignorados; [] vira {}' do
      out = described_class.normalize_decision('decision' => 'reply', 'attributes_list' => [{ 'key' => '', 'value' => 'x' }])
      expect(out['attributes']).to eq({})
    end

    it 'tool_name + tool_input_json -> tool{name,input}' do
      out = described_class.normalize_decision(
        'decision' => 'invoke_tool', 'tool_name' => 'Cobertura', 'tool_input_json' => '{"cep":"89870"}'
      )
      expect(out['tool']).to eq({ 'name' => 'Cobertura', 'input' => { 'cep' => '89870' } })
      expect(out).not_to have_key('tool_name')
      expect(out).not_to have_key('tool_input_json')
    end

    it 'tool_name vazio -> sem tool' do
      out = described_class.normalize_decision('decision' => 'reply', 'tool_name' => '', 'tool_input_json' => '{}')
      expect(out).not_to have_key('tool')
    end

    it 'tool_input_json inválido -> tool IGNORADA + log, sem crash' do
      expect(Rails.logger).to receive(:warn).with(/tool_input_json inválido/)
      out = described_class.normalize_decision('decision' => 'invoke_tool', 'tool_name' => 'X', 'tool_input_json' => '{quebrado')
      expect(out).not_to have_key('tool')
    end

    it 'reply_text é PRESERVADO (passa direto; núcleo não o toca)' do
      out = described_class.normalize_decision('decision' => 'reply', 'reply_text' => 'Olá!', 'attributes_list' => [])
      expect(out['reply_text']).to eq('Olá!')
    end

    it 'FLAG OFF byte-idêntico: envelope LEGADO (attributes Hash + tool{name,input}) passa direto' do
      legacy = { 'decision' => 'reply', 'reply_text' => 'oi',
                 'attributes' => { 'cidade' => 'X' }, 'tool' => { 'name' => 'T', 'input' => {} } }
      expect(described_class.normalize_decision(legacy)).to eq(legacy)
    end

    it 'COMPAT Fix 3b: normaliza o NÚCLEO mesmo SEM reply_text no payload' do
      out = described_class.normalize_decision(
        'decision' => 'invoke_tool', 'tool_name' => 'Consultar', 'tool_input_json' => '{"cidade":"X"}',
        'attributes_list' => [{ 'key' => 'cidade', 'value' => 'X' }]
      )
      expect(out['decision']).to eq('invoke_tool')
      expect(out['tool']).to eq({ 'name' => 'Consultar', 'input' => { 'cidade' => 'X' } })
      expect(out['attributes']).to eq({ 'cidade' => 'X' })
      expect(out).not_to have_key('reply_text')
    end
  end

  describe '.sum_tool_loop_usage (soma o usage de todas as rodadas do loop de tools)' do
    it 'soma tokens_in/tokens_out/cached_tokens de TODAS as mensagens assistentes' do
      m1 = instance_double('RubyLLM::Message', role: :assistant, input_tokens: 100, output_tokens: 10, cached_tokens: 20)
      tool = instance_double('RubyLLM::Message', role: :tool, input_tokens: nil, output_tokens: nil, cached_tokens: nil)
      m2 = instance_double('RubyLLM::Message', role: :assistant, input_tokens: 300, output_tokens: 40, cached_tokens: 50)
      chat = instance_double('RubyLLM::Chat', messages: [m1, tool, m2])

      out = described_class.sum_tool_loop_usage(chat, m2)

      expect(out).to eq(tokens_in: 400, tokens_out: 50, cached_tokens: 70)
    end

    it 'fallback [response] quando a gem não expõe chat.messages (comportamento antigo)' do
      response = instance_double('RubyLLM::Message', role: :assistant, input_tokens: 5, output_tokens: 2, cached_tokens: 1)
      chat = double('chat_sem_messages')
      allow(chat).to receive(:respond_to?).with(:messages).and_return(false)

      out = described_class.sum_tool_loop_usage(chat, response)

      expect(out).to eq(tokens_in: 5, tokens_out: 2, cached_tokens: 1)
    end
  end

  describe '.single_usage (caminho SEM tools — idêntico a hoje)' do
    it 'usa o usage da única resposta' do
      response = instance_double('RubyLLM::Message', input_tokens: 7, output_tokens: 3, cached_tokens: 2)
      expect(described_class.single_usage(response)).to eq(tokens_in: 7, tokens_out: 3, cached_tokens: 2)
    end
  end
end
