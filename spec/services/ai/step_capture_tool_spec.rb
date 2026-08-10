require 'rails_helper'

# Cobertura da tradução etapa -> tool de function-calling (substitui a tool que a etapa ATUAL gera
# no path do orquestrador Python — ver Ai::PythonOrchestratorClient; o texto de instructions da
# etapa continua indo pro system_prompt, não é este módulo que cobre isso).
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

    it 'uma tool por atributo declarado em QUALQUER etapa — todas de uma vez (fluxo agentic)' do
      playbook = instance_double(Ai::Playbook, steps: [
                                    { 'name' => 'Acolhimento', 'instructions' => 'Cumprimente' }, # sem collect
                                    { 'name' => 'Endereço', 'collect' => { 'attribute' => 'endereco', 'type' => 'text' } },
                                    { 'name' => 'Telefone extra', 'collect' => { 'attribute' => 'telefone_extra' } }
                                  ])

      names = described_class.schemas_for(playbook).map { |s| s[:name] }

      expect(names).to contain_exactly('registrar_endereco', 'registrar_telefone_extra')
    end

    it 'dedup por atributo — duas etapas declarando o mesmo attribute geram UMA tool só (nomes únicos p/ a OpenAI)' do
      playbook = instance_double(Ai::Playbook, steps: [
                                    { 'collect' => { 'attribute' => 'cidade' } },
                                    { 'collect' => { 'attribute' => 'cidade' } }
                                  ])

      expect(described_class.schemas_for(playbook).size).to eq(1)
    end
  end

  describe '.build_schema' do
    it 'nil quando a etapa não declara collect (etapa informativa)' do
      expect(described_class.build_schema({ 'name' => 'Acolhimento', 'instructions' => 'Cumprimente' })).to be_nil
    end

    it 'nil quando a etapa é nil (sem etapa ativa)' do
      expect(described_class.build_schema(nil)).to be_nil
    end

    it 'gera a tool a partir do collect da etapa' do
      step = { 'name' => 'Endereço', 'collect' => { 'attribute' => 'endereco', 'type' => 'text' } }

      expect(described_class.build_schema(step)).to eq(
        name: 'registrar_endereco',
        description: 'Registra o dado "endereco" assim que o cliente informar — mesmo que ele ' \
                     'adiante esse dado junto de outros, fora de ordem, na mesma mensagem.',
        input_schema: { type: 'object', properties: { 'endereco' => { type: 'string' } }, required: ['endereco'] }
      )
    end

    it 'etapa tipo number vira propriedade number; etapa com options vira enum' do
      number_schema = described_class.build_schema({ 'collect' => { 'attribute' => 'idade', 'type' => 'number' } })
      choice_schema = described_class.build_schema({ 'collect' => { 'attribute' => 'plano', 'options' => %w[Basico Premium] } })

      expect(number_schema[:input_schema][:properties]['idade']).to eq(type: 'number')
      expect(choice_schema[:input_schema][:properties]['plano']).to eq(type: 'string', enum: %w[Basico Premium])
    end
  end
end
