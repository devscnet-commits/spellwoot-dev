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

  describe '.infer — forma direta "grave <chave>", blacklist e cláusula de avanço (bug conv 358)' do
    def infer(instructions)
      described_class.infer({ 'instructions' => instructions })
    end

    # Casos REAIS das etapas (o texto que quebrava antes):
    it '"Grave aparelhos_conectados conforme a resposta." -> aparelhos_conectados' do
      expect(infer('Grave aparelhos_conectados conforme a resposta.')).to eq('aparelhos_conectados')
    end

    it '"Grave endereco_completo com o texto fornecido." -> endereco_completo' do
      expect(infer('Grave endereco_completo com o texto fornecido.')).to eq('endereco_completo')
    end

    it '"Grave o e-mail no atributo email." -> email (forma explícita ainda funciona)' do
      expect(infer('Grave o e-mail no atributo email.')).to eq('email')
    end

    it 'reforço "assim que <chave> estiver preenchido" reconhece a chave' do
      expect(infer('Peça o endereço. Avance assim que endereco_completo estiver preenchido.'))
        .to eq('endereco_completo')
    end

    it 'preferência: a chave da cláusula de avanço vence quando há mais de um candidato' do
      texto = 'Grave endereco_parcial com o que vier. Avance assim que endereco_completo estiver capturado.'
      expect(infer(texto)).to eq('endereco_completo')
    end

    # BLACKLIST — o falso positivo do bug:
    it 'instrução com "atributo personalizado" -> nil (não vira slot "personalizado")' do
      expect(infer('Grave no atributo personalizado a resposta do cliente.')).to be_nil
    end

    it 'palavra única sem "_" e sem conector -> nil (conservador)' do
      expect(infer('Grave email.')).to be_nil # sem "_" e sem conector; a forma explícita/atributo é que pega
    end

    # Etapa informativa (PLANOS): sem verbo de gravação/atributo -> nil
    it 'instrução de PLANOS (só apresenta) -> nil (etapa informativa)' do
      expect(infer('Apresente os planos disponíveis e seus preços ao cliente.')).to be_nil
    end
  end
end
