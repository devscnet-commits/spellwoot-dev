require 'rails_helper'

RSpec.describe Ai::DecisionSchema do
  let(:json_schema) { described_class.new.to_json_schema }
  let(:inner) { json_schema[:schema] }
  let(:props) { inner[:properties] }

  describe 'enum de decision (elimina "decision inventado" por construção)' do
    it 'aceita EXATAMENTE os 5 valores e nenhum outro' do
      expect(props[:decision][:enum]).to match_array(%w[reply invoke_tool handoff close noop])
    end

    it 'não inclui valores fora do contrato (text/message/resposta)' do
      expect(props[:decision][:enum]).not_to include('text', 'message', 'resposta')
    end
  end

  describe 'strict (compatível com Structured Output da OpenAI)' do
    it 'additionalProperties false + strict true' do
      expect(inner[:additionalProperties]).to be(false)
      expect(inner[:strict]).to be(true)
    end

    it 'todos os campos do núcleo são required' do
      expect(inner[:required]).to include(:decision, :tool_name, :tool_input_json, :handoff_reason,
                                          :handoff_target, :current_step, :step_completed, :confidence, :attributes_list)
    end
  end

  describe 'campos livres representados como formas FECHADAS' do
    it 'tool_input_json é STRING (JSON serializado)' do
      expect(props[:tool_input_json][:type]).to eq('string')
    end

    it 'attributes_list é ARRAY de objetos {key,value} com additionalProperties false' do
      expect(props[:attributes_list][:type]).to eq('array')
      items = props[:attributes_list][:items]
      expect(items[:type]).to eq('object')
      expect(items[:properties].keys).to match_array(%i[key value])
      expect(items[:additionalProperties]).to be(false)
    end

    it 'tipa step_completed (boolean) e confidence (number)' do
      expect(props[:step_completed][:type]).to eq('boolean')
      expect(props[:confidence][:type]).to eq('number')
    end
  end

  describe 'reply_text isolado (compat Fix 3b)' do
    it 'reply_text é apenas um campo string à parte' do
      expect(props[:reply_text][:type]).to eq('string')
    end

    # Prova de desacoplamento: um schema-núcleo SEM reply_text (o que o 3b fará) continua válido.
    it 'remover reply_text (simulando o 3b) mantém o NÚCLEO válido e com o enum intacto' do
      core = RubyLLM::Schema.create do
        string :decision, enum: %w[reply invoke_tool handoff close noop]
        string :tool_name
        string :tool_input_json
        boolean :step_completed
        number :confidence
        array :attributes_list do
          object do
            string :key
            string :value
          end
        end
      end
      js = core.new.to_json_schema[:schema]
      expect(js[:required]).not_to include(:reply_text)
      expect(js[:properties][:decision][:enum]).to match_array(%w[reply invoke_tool handoff close noop])
      expect(js[:additionalProperties]).to be(false)
    end
  end
end
