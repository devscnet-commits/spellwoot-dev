require 'rails_helper'

RSpec.describe Ai::TurnCapture do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:message) do
    create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :incoming, content: 'oi')
  end

  def build_capture(conv = conversation)
    described_class.new(conversation: conv, persister: Ai::StateManager.new(conversation: conv, agent: nil))
  end

  describe '#claim — semantica already-won' do
    it 'claim 2x na MESMA instancia, mesmo id -> true nas duas; o UPDATE atomico roda 1x so' do
      capture = build_capture
      expect(capture).to receive(:atomic_claim).once.and_call_original

      expect(capture.claim(message)).to be(true)
      expect(capture.claim(message)).to be(true) # already-won: no-op-true, sem 2o atomic_claim
    end

    it 'instancia DIFERENTE, mesmo id -> segunda claim retorna false (protecao entre processos)' do
      expect(build_capture.claim(message)).to be(true) # 1a instancia vence e grava a coluna (persistido)

      # 2o binding / re-run: objeto de conversa FRESCO do banco, @claimed vazio -> perde no atomic_claim
      other_conv = Conversation.find(conversation.id)
      expect(build_capture(other_conv).claim(message)).to be(false)
    end

    it 'sem message id (follow-up/teste) -> true (sem idempotencia)' do
      expect(build_capture.claim(Object.new)).to be(true)
    end

    it 'grava ai_last_captured_message_id no primeiro claim vencedor' do
      build_capture.claim(message)

      expect(conversation.reload.additional_attributes['ai_last_captured_message_id']).to eq(message.id.to_s)
    end
  end
end
