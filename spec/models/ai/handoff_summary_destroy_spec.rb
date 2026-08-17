require 'rails_helper'

# Regressão do bug de conversa órfã: ai_handoff_summaries tinha FK restritiva a conversations SEM
# dependent (model) nem ON DELETE CASCADE (banco). Deletar a conversa — ou o contato em cascata —
# travava com InvalidForeignKey quando a conversa tinha um resumo de handoff, deixando-a órfã.
RSpec.describe 'Destroy de conversa/contato com Ai::HandoffSummary', type: :model do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }

  def summary_for(conversation, reason: 'loop')
    Ai::HandoffSummary.create!(account: account, conversation: conversation, reason: reason, content: 'resumo')
  end

  it 'deleta a conversa mesmo com resumo de handoff (dependent: :delete_all no model)' do
    conversation = create(:conversation, account: account)
    summary_for(conversation)

    expect { conversation.destroy! }.not_to raise_error
    expect(Ai::HandoffSummary.where(conversation_id: conversation.id)).not_to exist
  end

  it 'deleta o contato em cascata: a conversa com resumo vai junto, sem FK violation' do
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    summary_for(conversation, reason: 'credit_exhausted')

    perform_enqueued_jobs do
      expect { contact.destroy! }.not_to raise_error
    end

    expect(Conversation.where(id: conversation.id)).not_to exist
    expect(Ai::HandoffSummary.where(conversation_id: conversation.id)).not_to exist
  end

  it 'a FK no banco é ON DELETE CASCADE (defesa em profundidade; cobre delete por SQL direto)' do
    fk = ActiveRecord::Base.connection.foreign_keys('ai_handoff_summaries')
                           .find { |f| f.to_table == 'conversations' }

    expect(fk).to be_present
    expect(fk.on_delete).to eq(:cascade)
  end
end
