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
end
