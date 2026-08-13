require 'rails_helper'

RSpec.describe Ai::CapabilityRegistry do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }

  describe '.conversation_add_label' do
    it 'adds labels as a union and returns rollback data with the previous list' do
      conversation.update_labels(['antiga'])

      result = described_class.execute('conversation.add_label', conversation: conversation, input: { 'label' => 'vip' })

      expect(conversation.reload.label_list).to include('vip', 'antiga')
      expect(result[:rollback_data]['previous']).to include('antiga')
    end

    it 'raises on a blank label' do
      expect do
        described_class.execute('conversation.add_label', conversation: conversation, input: { 'label' => '  ' })
      end.to raise_error(/label/)
    end
  end

  describe '.conversation_update_attributes' do
    it 'merges the given keys into custom_attributes without dropping the others' do
      conversation.update!(custom_attributes: { 'cidade' => 'Maravilha' })

      described_class.execute('conversation.update_attributes', conversation: conversation,
                                                                input: { 'etapa' => 'qualificado' })

      expect(conversation.reload.custom_attributes).to eq('cidade' => 'Maravilha', 'etapa' => 'qualificado')
    end
  end

  describe '.rollback' do
    it 'restores the previous labels' do
      conversation.update_labels(['a'])
      execution = Ai::CapabilityExecution.new(conversation_id: conversation.id,
                                              capability_key: 'conversation.add_label',
                                              rollback_data: { 'previous' => ['a'] })
      conversation.add_labels(['b'])

      expect(described_class.rollback(execution)).to be(true)
      expect(conversation.reload.label_list).to contain_exactly('a')
    end

    it 'restores the previous custom_attributes' do
      conversation.update!(custom_attributes: { 'x' => '2' })
      execution = Ai::CapabilityExecution.new(conversation_id: conversation.id,
                                              capability_key: 'conversation.update_attributes',
                                              rollback_data: { 'custom_attributes' => { 'x' => '1' } })

      expect(described_class.rollback(execution)).to be(true)
      expect(conversation.reload.custom_attributes).to eq('x' => '1')
    end
  end
end
