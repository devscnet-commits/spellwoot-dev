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

  # Achado ao vivo (16/08, ticket 586): collect.attribute aceita string OU array desde sempre
  # (Api::Internal::AiExecuteToolController#collect_attributes já usava Array() puro pra validar
  # avanço), mas #attribute fazia `.to_s` no valor bruto — um array virava UMA string colada
  # ('["cidade", "viabilidade"]'), nunca as duas chaves reais que a validação de avanço exigia. A
  # etapa nunca completava (ai_step_turns subia até estourar o teto de "travado" e transferir pra
  # humano — sem nada de errado visível na conversa).
  describe '.declared_attributes / .multi_attribute? — etapa com MAIS de um atributo' do
    it 'devolve os dois atributos separados, na ordem declarada' do
      step = { 'collect' => { 'attribute' => %w[cidade viabilidade] } }

      expect(described_class.declared_attributes(step)).to eq(%w[cidade viabilidade])
      expect(described_class.multi_attribute?(step)).to be(true)
    end

    it 'etapa de 1 atributo só: declared_attributes tem 1 elemento, multi_attribute? é false' do
      step = { 'collect' => { 'attribute' => 'cidade' } }

      expect(described_class.declared_attributes(step)).to eq(['cidade'])
      expect(described_class.multi_attribute?(step)).to be(false)
    end

    it 'etapa sem collect: declared_attributes vazio' do
      expect(described_class.declared_attributes({ 'name' => 'Boas-vindas' })).to eq([])
    end

    it '#attribute (singular, compat) devolve o PRIMEIRO de uma etapa multi-atributo' do
      step = { 'collect' => { 'attribute' => %w[cidade viabilidade] } }

      expect(described_class.attribute(step)).to eq('cidade')
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

  # "DADOS PARA COLETA NA ETAPA" — cada dado configurado carrega SEU PRÓPRIO type/options/required/hint
  # (collect.items[]), em vez de 1 collect por etapa inteira. #items é a fonte que
  # Ai::PythonOrchestratorClient (REGRA DE EXTRAÇÃO JSON) e Api::Internal::AiExecuteToolController
  # (missing_required_attributes) passam a consumir — os métodos singulares abaixo (#type/#optional?/
  # #options/#domain_from_tool) continuam existindo, só pra compat com quem lê "a etapa tem 1 slot"
  # (StateManager, TurnCapture, TrivialTurnGate etc.), lendo o PRIMEIRO item.
  describe '.items — coleta de VÁRIOS dados na mesma etapa, cada um com seu próprio type/required/hint' do
    let(:step) do
      { 'name' => 'Dados do cliente', 'collect' => { 'items' => [
        { 'attribute' => 'cpf_cliente', 'type' => 'cpf', 'required' => true },
        { 'attribute' => 'nome_cliente', 'type' => 'text', 'required' => true },
        { 'attribute' => 'email_cliente', 'type' => 'email', 'required' => false, 'hint' => 'para nota fiscal' }
      ] } }
    end

    it 'devolve um item normalizado por dado, na ordem declarada' do
      items = described_class.items(step)

      expect(items.map { |i| i['attribute'] }).to eq(%w[cpf_cliente nome_cliente email_cliente])
      expect(items.map { |i| i['type'] }).to eq(%w[cpf text email])
    end

    it 'required por item — obrigatório e opcional na MESMA etapa' do
      items = described_class.items(step)

      expect(items[0]['required']).to be(true)  # cpf_cliente
      expect(items[2]['required']).to be(false) # email_cliente
    end

    it 'item sem "required" explícito -> default true (mesma regra do formato antigo)' do
      step_default = { 'collect' => { 'items' => [{ 'attribute' => 'x', 'type' => 'text' }] } }

      expect(described_class.items(step_default).first['required']).to be(true)
    end

    it 'hint só quando declarado' do
      items = described_class.items(step)

      expect(items[2]['hint']).to eq('para nota fiscal') # email_cliente
      expect(items[0]['hint']).to be_nil                 # cpf_cliente
    end

    it '#declared_attributes / #multi_attribute? funcionam por cima de #items, sem mudança de assinatura' do
      expect(described_class.declared_attributes(step)).to eq(%w[cpf_cliente nome_cliente email_cliente])
      expect(described_class.multi_attribute?(step)).to be(true)
    end

    it 'os métodos singulares (compat) leem o PRIMEIRO item, não quebram numa etapa multi-dado' do
      expect(described_class.attribute(step)).to eq('cpf_cliente')
      expect(described_class.type(step)).to eq('cpf')
      expect(described_class.optional?(step)).to be(false) # cpf_cliente é obrigatório
    end

    it 'etapa antiga (1 collect, sem items[]) continua funcionando via #items — compat retroativa' do
      step_legado = { 'collect' => { 'attribute' => 'cidade', 'type' => 'text' } }

      expect(described_class.items(step_legado)).to eq(
        [{ 'attribute' => 'cidade', 'type' => 'text', 'options' => [], 'domain_from_tool' => nil,
           'required' => true, 'hint' => nil }]
      )
    end

    it 'etapa informativa (sem collect): items vazio, nada quebra' do
      expect(described_class.items({ 'name' => 'Boas-vindas' })).to eq([])
    end
  end
end
