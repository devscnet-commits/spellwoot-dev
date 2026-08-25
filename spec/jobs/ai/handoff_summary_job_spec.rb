require 'rails_helper'

RSpec.describe Ai::HandoffSummaryJob do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }

  it 'chama o generator com a conversa e o reason recebidos' do
    generator = instance_double(Ai::HandoffSummaryGenerator, generate: nil)
    expect(Ai::HandoffSummaryGenerator).to receive(:new)
      .with(conversation: conversation, reason: 'credit_exhausted').and_return(generator)

    described_class.new.perform(conversation.id, 'credit_exhausted')
  end

  it 'é no-op (não levanta) quando a conversa não existe' do
    expect(Ai::HandoffSummaryGenerator).not_to receive(:new)
    expect { described_class.new.perform(0, 'loop') }.not_to raise_error
  end

  it 'roda na fila :low' do
    expect(described_class.new.queue_name).to eq('low')
  end
end
