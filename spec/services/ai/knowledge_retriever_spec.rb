require 'rails_helper'

RSpec.describe Ai::KnowledgeRetriever do
  let(:account) { create(:account) }

  # Evita o after_commit :sync_knowledge (ingest real) — montamos os chunks à mão.
  before { allow(Ai::KnowledgeIngestJob).to receive(:perform_later) }

  def source(kind:, title:, status: 'active')
    Ai::KnowledgeSource.create!(account: account, kind: kind, title: title, status: status)
  end

  def chunk(src, content)
    Ai::KnowledgeChunk.create!(ai_knowledge_source_id: src.id, content: content, embedding: nil)
  end

  describe 'Camada 1 — sem kinds: comportamento inalterado (retrocompat)' do
    it 'busca em TODOS os kinds (sem filtro) — sem vetor cai no ILIKE, como hoje' do
      allow(described_class).to receive(:embed).and_return(nil) # força o ILIKE (como sem chave)
      chunk(source(kind: 'produto', title: 'P'), 'Plano Fibra 300 Mega R$ 89,90')
      chunk(source(kind: 'faq', title: 'F'), 'Como faço para trocar de plano?')

      chunks = described_class.retrieve(query: 'plano', account_id: account.id)

      expect(chunks).to include('Plano Fibra 300 Mega R$ 89,90')
      expect(chunks).to include('Como faço para trocar de plano?') # kind não filtrado
    end

    it 'retrieve/retrieve_scored seguem aceitando a chamada sem kinds (Copilot/Tester)' do
      allow(described_class).to receive(:embed).and_return(nil)
      chunk(source(kind: 'faq', title: 'F'), 'texto qualquer')

      expect { described_class.retrieve(query: 'texto', account_id: account.id) }.not_to raise_error
      expect(described_class.retrieve_scored(query: 'texto', account_id: account.id)).to include(:chunks, :top_score)
    end
  end

  describe 'Camada 1 — list_all: fonte pequena do kind devolve tudo sem vetor' do
    before do
      # 5 produtos, 526 chars no total (como a conta 2 real).
      [['Internet Fibra 1 Giga', 'Internet Fibra 1 Giga — R$ 169,90/mês. Alta velocidade residencial.'],
       ['Combo Fibra + Wi-Fi Mesh', 'Combo Fibra + Wi-Fi Mesh — R$ 149,90/mês. Cobertura total.'],
       ['Internet Fibra 300 Mega', 'Internet Fibra 300 Mega — R$ 89,90/mês. Instalação gratuita.'],
       ['Internet Empresarial 500 Mega', 'Internet Empresarial 500 Mega — R$ 249,90/mês. Suporte prioritário.'],
       ['Internet Fibra 600 Mega', 'Internet Fibra 600 Mega — R$ 119,90/mês. Ideal para streaming.']].each do |t, c|
        chunk(source(kind: 'produto', title: t), c)
      end
      chunk(source(kind: 'faq', title: 'F'), 'Como trocar de plano? Fale com o comercial.')
    end

    it 'list_all:true devolve TODOS os 5 produtos SEM busca vetorial (nem embed chamado)' do
      expect(described_class).not_to receive(:embed)

      chunks = described_class.retrieve(query: 'quero saber dos valores', account_id: account.id,
                                        kinds: ['produto'], list_all: true)

      expect(chunks.size).to eq(5)
      expect(chunks.join).to include('R$ 89,90').and include('R$ 249,90') # o mais barato E o empresarial
      expect(chunks.join).not_to include('Como trocar de plano') # nenhum FAQ
    end

    # NAMED: em list_all a query é DECORATIVA — devolve todos do kind mesmo sem match semântico.
    it 'list_all:true devolve todos os chunks do kind mesmo com query que NÃO casa semanticamente' do
      chunks = described_class.retrieve(query: 'xyzzy nada a ver com planos', account_id: account.id,
                                        kinds: ['produto'], list_all: true)

      expect(chunks.size).to eq(5) # todos, apesar da query não casar
    end

    it 'list_all:true — kind NÃO-produto (documento) também devolve TUDO sem busca vetorial' do
      chunk(source(kind: 'documento', title: 'Cidades'), 'Cidades atendidas: Maravilha, Chapecó, São Miguel.')
      expect(described_class).not_to receive(:embed)

      chunks = described_class.retrieve(query: 'atende minha cidade?', account_id: account.id,
                                        kinds: ['documento'], list_all: true)

      expect(chunks).to include('Cidades atendidas: Maravilha, Chapecó, São Miguel.')
      expect(chunks.join).not_to include('R$') # nenhum produto (kind filtrado)
    end

    # NAMED (o conserto deste PR): list_all:false com conjunto PEQUENO usa SIMILARIDADE — NÃO cai no
    # small_catalog. Mutação: falha (embed NÃO seria chamado) se o atalho voltar a rodar sem o flag.
    it 'list_all:false com conjunto pequeno usa similaridade (embed é chamado), não o small_catalog' do
      expect(described_class).to receive(:embed).and_return(nil)

      described_class.retrieve(query: 'quero saber dos valores', account_id: account.id, kinds: ['produto'])
    end
  end

  describe 'Camada 1 — catálogo grande (acima do limite): busca restrita ao kind' do
    before do
      stub_const('Ai::KnowledgeRetriever::SMALL_CATALOG_CHAR_LIMIT', 100) # força "acima do limite"
      allow(described_class).to receive(:embed).and_return(nil) # sem vetor -> ILIKE restrito ao scope
      chunk(source(kind: 'produto', title: 'P1'), 'Plano Fibra 300 Mega R$ 89,90 residencial rápido')
      chunk(source(kind: 'produto', title: 'P2'), 'Plano Empresarial 500 Mega R$ 249,90 corporativo')
      chunk(source(kind: 'faq', title: 'F'), 'Plano: como faço para cancelar meu plano?')
    end

    it 'list_all:true acima do limite NÃO devolve tudo: cai no vetor restrito ao kind (o dump seria caro)' do
      chunks = described_class.retrieve(query: 'plano', account_id: account.id, kinds: ['produto'], list_all: true)

      expect(chunks).not_to be_empty
      expect(chunks.join).not_to include('cancelar meu plano') # o FAQ (outro kind) fica de fora
      expect(chunks.all? { |c| c.include?('R$') }).to be(true) # só produtos
    end
  end
end
