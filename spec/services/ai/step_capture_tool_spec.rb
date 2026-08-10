require 'rails_helper'

# Cobertura da tradução etapa -> tool de function-calling (substitui o texto de instrução das
# etapas no path do orquestrador Python — ver Ai::PythonOrchestratorClient).
RSpec.describe Ai::StepCaptureTool do
  describe '.tool_name / .attribute_for' do
    it 'são inversas uma da outra' do
      expect(described_class.tool_name('endereco')).to eq('registrar_endereco')
      expect(described_class.attribute_for('registrar_endereco')).to eq('endereco')
    end

    it 'attribute_for devolve nil para um nome que não é uma capture tool (ex.: tool real configurada)' do
      expect(described_class.attribute_for('conversation.add_label')).to be_nil
    end
  end

  describe '.schemas_for' do
    it 'nil (sem playbook) devolve lista vazia' do
      expect(described_class.schemas_for(nil)).to eq([])
    end

    it 'gera uma tool por atributo declarado, ignorando etapas sem collect (informativas)' do
      playbook = instance_double(Ai::Playbook, steps: [
                                    { 'name' => 'Acolhimento', 'instructions' => 'Cumprimente' }, # sem collect
                                    { 'name' => 'Endereço', 'collect' => { 'attribute' => 'endereco', 'type' => 'text' } }
                                  ])

      schemas = described_class.schemas_for(playbook)

      expect(schemas.size).to eq(1)
      expect(schemas.first).to eq(
        name: 'registrar_endereco',
        description: 'Registra o dado "endereco" assim que o cliente informar — mesmo que ele ' \
                     'adiante esse dado junto de outros, fora de ordem, na mesma mensagem.',
        input_schema: { type: 'object', properties: { 'endereco' => { type: 'string' } }, required: ['endereco'] }
      )
    end

    it 'dedup por atributo — duas etapas declarando o mesmo attribute geram UMA tool só (nomes únicos p/ a OpenAI)' do
      playbook = instance_double(Ai::Playbook, steps: [
                                    { 'collect' => { 'attribute' => 'cidade' } },
                                    { 'collect' => { 'attribute' => 'cidade' } }
                                  ])

      expect(described_class.schemas_for(playbook).size).to eq(1)
    end

    it 'etapa tipo number vira propriedade number; etapa com options vira enum' do
      playbook = instance_double(Ai::Playbook, steps: [
                                    { 'collect' => { 'attribute' => 'idade', 'type' => 'number' } },
                                    { 'collect' => { 'attribute' => 'plano', 'options' => %w[Basico Premium] } }
                                  ])

      schemas = described_class.schemas_for(playbook).index_by { |s| s[:name] }

      expect(schemas['registrar_idade'][:input_schema][:properties]['idade']).to eq(type: 'number')
      expect(schemas['registrar_plano'][:input_schema][:properties]['plano']).to eq(type: 'string', enum: %w[Basico Premium])
    end
  end
end
