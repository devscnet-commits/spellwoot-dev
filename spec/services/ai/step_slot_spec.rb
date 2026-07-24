require 'rails_helper'

RSpec.describe Ai::StepSlot do
  describe '.infer / .attribute — inferência da instrução (conserto Parte 1)' do
    it 'infere o slot de "grave o e-mail no atributo email" (sem collect declarado)' do
      step = { 'name' => 'Email', 'instructions' => 'Peça e grave o e-mail do cliente no atributo email.' }

      expect(described_class.infer(step)).to eq('email')
      expect(described_class.attribute(step)).to eq('email')
    end

    it 'infere chave snake_case e normaliza a caixa' do
      expect(described_class.infer({ 'instructions' => 'Salve no atributo Tipo_Cliente = residencial' }))
        .to eq('tipo_cliente')
    end

    it 'etapa SEM padrão de atributo -> nil (segue informativa)' do
      step = { 'name' => 'Boas-vindas', 'instructions' => 'Cumprimente o cliente com simpatia.' }

      expect(described_class.infer(step)).to be_nil
      expect(described_class.attribute(step)).to be_nil
    end

    it 'NÃO infere quando já há collect declarado (usa o declarado)' do
      step = { 'collect' => { 'attribute' => 'cidade' }, 'instructions' => 'grave no atributo outra_coisa' }

      expect(described_class.infer(step)).to be_nil
      expect(described_class.attribute(step)).to eq('cidade')
    end
  end

  # Gap 2: optional? governa SÓ a regra de conclusão; a captura é sempre por #attribute. required só é
  # obrigatório por default; opcional vem de collect['required']:false (compat) OU do step['slot_required'].
  describe '.optional? (Gap 2 — precedência: collect explícito > slot_required da etapa > obrigatório)' do
    it 'slot INFERIDO + slot_required:false -> opcional (attribute lê a chave; sem collect)' do
      step = { 'instructions' => 'peça e grave o email_cliente conforme informado', 'slot_required' => false }

      expect(described_class.attribute(step)).to eq('email_cliente')
      expect(described_class.optional?(step)).to be(true)
    end

    it 'slot INFERIDO sem slot_required -> OBRIGATÓRIO (default, sem flag)' do
      step = { 'instructions' => 'peça e grave o email_cliente conforme informado' }

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

    # === Bugs do dump real (com #263 deployado) — pular genéricos e seguir para a chave real ===
    it '[2] advérbio após "grave" + "atributo <chave>": pega escolha_caminho, não "imediatamente"' do
      expect(infer('Pergunte e grave IMEDIATAMENTE no mesmo turno o atributo escolha_caminho da opção.'))
        .to eq('escolha_caminho')
    end

    it '[11] "atributo customizado <chave>": pula "customizado", pega periodo_reservado' do
      expect(infer('Grave o atributo customizado periodo_reservado com o valor informado.'))
        .to eq('periodo_reservado')
    end

    it '[1] "atributo personalizado <chave>": pula "personalizado", pega cidade' do
      expect(infer('Grave o nome da cidade no atributo personalizado cidade.')).to eq('cidade')
    end

    it 'preferência por "_": token com underscore vence o sem underscore na mesma frase' do
      expect(infer('Grave no atributo cidade endereco_completo do cliente.')).to eq('endereco_completo')
    end
  end
end
