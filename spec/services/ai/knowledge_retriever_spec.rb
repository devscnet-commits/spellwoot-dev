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

  describe 'Camada 1 — catálogo pequeno (kinds:[produto] cabe no limite)' do
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

    it 'devolve TODOS os 5 produtos SEM busca vetorial (nem embed chamado)' do
      expect(described_class).not_to receive(:embed)

      chunks = described_class.retrieve(query: 'quero saber dos valores', account_id: account.id, kinds: ['produto'])

      expect(chunks.size).to eq(5)
      expect(chunks.join).to include('R$ 89,90').and include('R$ 249,90') # o mais barato E o empresarial
      expect(chunks.join).not_to include('Como trocar de plano') # nenhum FAQ
    end

    it 'independe do texto da query (catálogo ignora similaridade)' do
      chunks = described_class.retrieve(query: 'xyzzy nada a ver', account_id: account.id, kinds: ['produto'])

      expect(chunks.size).to eq(5) # todos, mesmo sem match textual
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

    it 'não devolve o catálogo inteiro e NÃO traz chunk de outro kind (restrito a produto)' do
      chunks = described_class.retrieve(query: 'plano', account_id: account.id, kinds: ['produto'])

      expect(chunks).not_to be_empty
      expect(chunks.join).not_to include('cancelar meu plano') # o FAQ (outro kind) fica de fora
      expect(chunks.all? { |c| c.include?('R$') }).to be(true) # só produtos
    end
  end
end
