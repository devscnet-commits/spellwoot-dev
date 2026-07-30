require 'rails_helper'

RSpec.describe Ai::StepSlot do
  # A inferência da instrução (infer + ~80 linhas de regex/BLACKLIST/STOPWORDS) foi REMOVIDA: a etapa
  # DECLARA a variável (Select do form grava collect['attribute']). #attribute agora é declared_attribute puro.
  describe '.attribute — só a chave DECLARADA no collect (infer removido)' do
    it 'retorna a chave declarada em collect' do
      step = { 'name' => 'Cidade', 'collect' => { 'attribute' => 'cidade' } }

      expect(described_class.attribute(step)).to eq('cidade')
    end

    it 'aceita chaves em símbolo' do
      expect(described_class.attribute({ collect: { attribute: 'cpf_cliente' } })).to eq('cpf_cliente')
    end

    it 'etapa SEM collect -> nil (informativa), MESMO com instrução que antes seria inferida' do
      # "grave ... no atributo email" era inferido para 'email'; sem infer, é nil (a etapa não declara nada).
      step = { 'name' => 'Email', 'instructions' => 'Peça e grave o e-mail do cliente no atributo email.' }

      expect(described_class.attribute(step)).to be_nil
    end

    it 'collect com attribute em branco -> nil' do
      expect(described_class.attribute({ 'collect' => { 'attribute' => '  ' } })).to be_nil
    end

    it 'não expõe mais .infer (a heurística de tenant PT-BR foi apagada)' do
      expect(described_class).not_to respond_to(:infer)
    end
  end

  # optional? governa SÓ a regra de conclusão; a captura é sempre por #attribute. required é obrigatório por
  # default; opcional vem de collect['required']:false (compat) OU do step['slot_required'] (nível da etapa).
  describe '.optional? (precedência: collect explícito > slot_required da etapa > obrigatório)' do
    it 'collect sem required + slot_required:false -> opcional' do
      step = { 'collect' => { 'attribute' => 'email_cliente' }, 'slot_required' => false }

      expect(described_class.attribute(step)).to eq('email_cliente')
      expect(described_class.optional?(step)).to be(true)
    end

    it 'collect sem required e sem slot_required -> OBRIGATÓRIO (default, sem flag)' do
      step = { 'collect' => { 'attribute' => 'email_cliente' } }

      expect(described_class.attribute(step)).to eq('email_cliente')
      expect(described_class.optional?(step)).to be(false)
    end

    it 'collect{required:false} -> opcional (compat)' do
      expect(described_class.optional?({ 'collect' => { 'attribute' => 'cidade', 'required' => false } })).to be(true)
    end

    it 'collect{required:true} vence o slot_required:false (precedência do collect explícito)' do
      step = { 'collect' => { 'attribute' => 'cidade', 'required' => true }, 'slot_required' => false }

      expect(described_class.optional?(step)).to be(false)
    end
  end

  describe '.type / .options / .criterion — leitura do collect' do
    it 'type default text quando não declarado' do
      expect(described_class.type({ 'collect' => { 'attribute' => 'cidade' } })).to eq('text')
    end

    it 'type e options declarados' do
      step = { 'collect' => { 'attribute' => 'plano', 'type' => 'choice', 'options' => ['A', 'B'] } }

      expect(described_class.type(step)).to eq('choice')
      expect(described_class.options(step)).to eq(%w[A B])
    end
  end
end
