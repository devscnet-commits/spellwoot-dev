require 'rails_helper'

# Regressão do #302 aplicada ao gerador de memória do contato: o serviço DEVE usar call_model (texto livre,
# SEM schema) — nunca decide (que anexa o DecisionSchema strict e devolve o ENVELOPE de decisão em vez do
# {"summary","key_facts"} que o prompt pede). O updater não tinha spec — foi por isso que quebrou em
# 3cc275025 (decide→strict) e sangrou custo por semanas sem ninguém ver. As duas portas: decide NÃO chamado,
# e call_model SEM :schema (senão alguém reintroduz o schema e a saída volta a ser o envelope, verde-mentiroso).
RSpec.describe Ai::CustomerMemoryUpdater do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }

  before do
    create(:message, conversation: conversation, account: account, inbox: inbox,
                     message_type: :incoming, content: 'moro em Chapecó')
  end

  # Forma do call_model (TEXTO CRU), não do decide (:decision). O parse do {"summary","key_facts"} é do serviço.
  def call_model_result(text:, status: 'recorded')
    { provider: 'openai', model: 'gpt-4.1-mini', text: text, tokens_in: 10, tokens_out: 20, status: status }
  end

  def memory
    Ai::CustomerMemory.find_by(contact_id: contact.id, account_id: account.id)
  end

  describe '#update' do
    it 'usa call_model e NUNCA decide (senão a saída vira o ENVELOPE do DecisionSchema — bug #302)' do
      expect(Ai::ModelRouter).not_to receive(:decide)
      allow(Ai::ModelRouter).to receive(:call_model)
        .and_return(call_model_result(text: '{"summary":"Cliente de Chapecó","key_facts":{"cidade":"Chapecó"}}'))

      described_class.new(conversation: conversation).update

      expect(Ai::ModelRouter).to have_received(:call_model)
    end

    it 'chama call_model SEM :schema (não reintroduzir o DecisionSchema por engano)' do
      captured = nil
      allow(Ai::ModelRouter).to receive(:call_model) do |**kwargs|
        captured = kwargs
        call_model_result(text: '{"summary":"x","key_facts":{}}')
      end

      described_class.new(conversation: conversation).update

      expect(captured).not_to have_key(:schema) # schema ausente == DecisionSchema NÃO imposto
      expect(captured[:schema]).to be_nil
    end

    it 'faz o parse do {summary,key_facts} do TEXTO cru e grava no CustomerMemory' do
      allow(Ai::ModelRouter).to receive(:call_model).and_return(
        call_model_result(text: 'ruído {"summary":"Cliente de Chapecó, plano 600",' \
                                '"key_facts":{"cidade":"Chapecó","plano":"600"}} fim')
      )

      described_class.new(conversation: conversation).update

      expect(memory.summary).to eq('Cliente de Chapecó, plano 600')
      expect(memory.key_facts).to include('cidade' => 'Chapecó', 'plano' => '600')
    end

    it 'texto SEM JSON: não derruba e PRESERVA a memória atual (summary não vira nil)' do
      Ai::CustomerMemory.create!(account: account, contact: contact, summary: 'resumo anterior',
                                 key_facts: { 'cidade' => 'Chapecó' })
      allow(Ai::ModelRouter).to receive(:call_model).and_return(call_model_result(text: 'sem json aqui'))

      described_class.new(conversation: conversation).update

      expect(memory.summary).to eq('resumo anterior') # apply: presence || memory.summary
      expect(memory.key_facts).to include('cidade' => 'Chapecó')
    end

    it 'grava o Ai::Run (run_type customer_memory) com custo numérico computado localmente' do
      allow(Ai::ModelRouter).to receive(:call_model).and_return(call_model_result(text: '{"summary":"x","key_facts":{}}'))

      described_class.new(conversation: conversation).update

      run = Ai::Run.where(run_type: 'customer_memory').last
      expect(run.cost).to be_a(Numeric)
      expect(run.status).to eq('recorded')
    end
  end
end
