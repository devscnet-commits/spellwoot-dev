require 'rails_helper'

RSpec.describe Ai::MessageGrouping do
  describe '.delay_seconds' do
    it 'uses the per-step grouping delay when set on the conversation' do
      conversation = instance_double(
        Conversation,
        additional_attributes: { 'ai_step' => { 'grouping_delay_seconds' => 7 } }
      )
      expect(described_class.delay_seconds(123, conversation: conversation)).to eq(7)
    end

    it 'falls back to the general delay when the step has no delay (no bindings => 0)' do
      conversation = instance_double(
        Conversation,
        additional_attributes: { 'ai_step' => { 'grouping_delay_seconds' => nil } }
      )
      expect(described_class.delay_seconds(999_999, conversation: conversation)).to eq(0)
    end

    it 'falls back to the general delay when there is no conversation' do
      expect(described_class.delay_seconds(999_999)).to eq(0)
    end
  end
end
