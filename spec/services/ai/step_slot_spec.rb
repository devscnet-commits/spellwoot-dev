require 'rails_helper'

RSpec.describe Ai::StepSlot do
  describe '.infer / .required_attribute — inferência da instrução (conserto Parte 1)' do
    it 'infere o slot de "grave o e-mail no atributo email" (sem collect declarado)' do
      step = { 'name' => 'Email', 'instructions' => 'Peça e grave o e-mail do cliente no atributo email.' }

      expect(described_class.infer(step)).to eq('email')
      expect(described_class.required_attribute(step)).to eq('email')
    end

    it 'infere chave snake_case e normaliza a caixa' do
      expect(described_class.infer({ 'instructions' => 'Salve no atributo Tipo_Cliente = residencial' }))
        .to eq('tipo_cliente')
    end

    it 'etapa SEM padrão de atributo -> nil (segue informativa)' do
      step = { 'name' => 'Boas-vindas', 'instructions' => 'Cumprimente o cliente com simpatia.' }

      expect(described_class.infer(step)).to be_nil
      expect(described_class.required_attribute(step)).to be_nil
    end

    it 'NÃO infere quando já há collect declarado (usa o declarado)' do
      step = { 'collect' => { 'attribute' => 'cidade' }, 'instructions' => 'grave no atributo outra_coisa' }

      expect(described_class.infer(step)).to be_nil
      expect(described_class.required_attribute(step)).to eq('cidade')
    end

    it 'collect declarado com required:false -> required_attribute nil (opcional), mas attribute lê a chave' do
      step = { 'collect' => { 'attribute' => 'cidade', 'required' => false } }

      expect(described_class.required_attribute(step)).to be_nil
      expect(described_class.attribute(step)).to eq('cidade')
    end
  end
end
