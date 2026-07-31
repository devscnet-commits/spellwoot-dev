require 'rails_helper'

# Ponto de limpeza da posse forçada IA→IA (ai_routed_agent_id) no conversation.resolved. É o que garante que
# uma conversa REABERTA depois de resolvida caia na eleição normal (a marca já foi) e não fique órfã.
RSpec.describe Ai::RoutedAgentCleanupListener do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:listener) { described_class.instance }

  def resolved_event
    Events::Base.new('conversation_resolved', Time.zone.now, conversation: conversation)
  end

  before { account.enable_features!('ai_core') }

  it 'limpa a posse forçada (ai_routed_agent_id) ao resolver — só a marca sai, o resto fica' do
    conversation.update!(additional_attributes: { 'ai_routed_agent_id' => 42, 'ai_collected_facts' => { 'x' => '1' } })

    listener.conversation_resolved(resolved_event)

    attrs = conversation.reload.additional_attributes
    expect(attrs).not_to have_key('ai_routed_agent_id')
    expect(attrs['ai_collected_facts']).to eq({ 'x' => '1' })
  end

  it 'reabrir depois de resolvida: a marca já foi limpa -> nada de posse forçada pendente' do
    conversation.update!(additional_attributes: { 'ai_routed_agent_id' => 42 })
    listener.conversation_resolved(resolved_event)
    # "reabre": a conversa volta a 'open', mas os additional_attributes já não têm a marca
    conversation.update!(status: :open)

    expect(conversation.reload.additional_attributes).not_to have_key('ai_routed_agent_id')
  end

  it 'no-op quando não há marca (não sujeita o resto)' do
    conversation.update!(additional_attributes: { 'ai_collected_facts' => { 'y' => '2' } })

    listener.conversation_resolved(resolved_event)

    expect(conversation.reload.additional_attributes).to eq({ 'ai_collected_facts' => { 'y' => '2' } })
  end

  it 'gated por ai_core: conta sem a feature NÃO mexe na marca' do
    account.disable_features!('ai_core')
    conversation.update!(additional_attributes: { 'ai_routed_agent_id' => 42 })

    listener.conversation_resolved(resolved_event)

    expect(conversation.reload.additional_attributes['ai_routed_agent_id']).to eq(42)
  end
end
