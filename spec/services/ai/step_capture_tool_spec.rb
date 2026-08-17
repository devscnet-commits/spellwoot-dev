require 'rails_helper'

# Cobertura da tradução atributo -> tool de function-calling (substitui a tool que a etapa gera no
# path do orquestrador Python — ver Ai::PythonOrchestratorClient). Desde o achado ao vivo (uma etapa
# com instrução em texto livre "colete CPF, email e telefone" mas collect só declarando 1 desses),
# schemas_for gera tool pra QUALQUER chave do catálogo passado — não só o que alguma etapa declara.
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
    it 'uma tool por chave do catálogo, mesmo sem playbook nenhum (ex.: veio só de CustomAttributeDefinition/lead_variable)' do
      names = described_class.schemas_for(nil, %w[cpf email telefone]).map { |s| s[:name] }

      expect(names).to contain_exactly('registrar_cpf', 'registrar_email', 'registrar_telefone')
    end

    it 'ACHADO AO VIVO: gera tool pra uma chave que NENHUMA etapa declara via collect — só precisa estar no catálogo' do
      playbook = instance_double(Ai::Playbook, steps: [
                                    { 'name' => 'Coleta', 'instructions' => 'Colete CPF, email e telefone.',
                                      'collect' => { 'attribute' => 'cpf' } } # só CPF está no dropdown collect
                                  ])

      # email/telefone vieram de outra fonte do catálogo (CustomAttributeDefinition/lead_variable),
      # não de collect nenhum — é exatamente o gap que travava a IA.
      names = described_class.schemas_for(playbook, %w[cpf email telefone]).map { |s| s[:name] }

      expect(names).to contain_exactly('registrar_cpf', 'registrar_email', 'registrar_telefone')
    end

    it 'quando a chave TAMBÉM é declarada via collect em alguma etapa, usa o type/options daquela etapa' do
      playbook = instance_double(Ai::Playbook, steps: [
                                    { 'collect' => { 'attribute' => 'idade', 'type' => 'number' } },
                                    { 'collect' => { 'attribute' => 'plano', 'options' => %w[Basico Premium] } }
                                  ])

      schemas = described_class.schemas_for(playbook, %w[idade plano email]).index_by { |s| s[:name] }

      expect(schemas['registrar_idade'][:input_schema][:properties]['idade']).to eq(type: 'number')
      expect(schemas['registrar_plano'][:input_schema][:properties]['plano']).to eq(type: 'string', enum: %w[Basico Premium])
      # 'email' não está em nenhum collect -> fallback string genérica
      expect(schemas['registrar_email'][:input_schema][:properties]['email']).to eq(type: 'string')
    end

    it 'dedup — chave repetida no catálogo gera UMA tool só (nomes únicos p/ a OpenAI)' do
      expect(described_class.schemas_for(nil, %w[cidade cidade]).size).to eq(1)
    end

    it 'catálogo vazio devolve lista vazia' do
      expect(described_class.schemas_for(nil, [])).to eq([])
    end

    # Achado ao vivo (16/08, ticket 586): etapa com collect.attribute = ['cidade', 'viabilidade'] tem
    # que gerar UMA tool por atributo real (registrar_cidade, registrar_viabilidade) — nunca uma tool
    # só pra chave colada ('registrar_["cidade", "viabilidade"]'), que a validação de avanço nunca
    # reconhecia como satisfeita.
    it 'etapa com MAIS de um atributo: uma tool por atributo real, nunca uma chave colada' do
      playbook = instance_double(Ai::Playbook, steps: [
                                    { 'collect' => { 'attribute' => %w[cidade viabilidade], 'options' => %w[Chapecó Maravilha] } }
                                  ])

      names = described_class.schemas_for(playbook, %w[cidade viabilidade]).map { |s| s[:name] }

      expect(names).to contain_exactly('registrar_cidade', 'registrar_viabilidade')
    end

    it 'etapa com MAIS de um atributo: type/options do collect NÃO vazam pros atributos (ambíguo por natureza)' do
      playbook = instance_double(Ai::Playbook, steps: [
                                    { 'collect' => { 'attribute' => %w[cidade viabilidade], 'type' => 'choice',
                                                     'options' => %w[Chapecó Maravilha] } }
                                  ])

      schemas = described_class.schemas_for(playbook, %w[cidade viabilidade]).index_by { |s| s[:name] }

      expect(schemas['registrar_cidade'][:input_schema][:properties]['cidade']).to eq(type: 'string')
      expect(schemas['registrar_viabilidade'][:input_schema][:properties]['viabilidade']).to eq(type: 'string')
    end
  end

  describe '.build_schema' do
    it 'sem step (nil), propriedade string genérica' do
      expect(described_class.build_schema('endereco')).to eq(
        name: 'registrar_endereco',
        description: 'Registra o dado "endereco" assim que o cliente informar — mesmo que ele ' \
                     'adiante esse dado junto de outros, fora de ordem, na mesma mensagem.',
        input_schema: { type: 'object', properties: { 'endereco' => { type: 'string' } }, required: ['endereco'] }
      )
    end

    it 'com step, usa o type/options do collect daquela etapa' do
      number_schema = described_class.build_schema('idade', { 'collect' => { 'attribute' => 'idade', 'type' => 'number' } })
      choice_schema = described_class.build_schema('plano', { 'collect' => { 'attribute' => 'plano', 'options' => %w[Basico Premium] } })

      expect(number_schema[:input_schema][:properties]['idade']).to eq(type: 'number')
      expect(choice_schema[:input_schema][:properties]['plano']).to eq(type: 'string', enum: %w[Basico Premium])
    end
  end
end
