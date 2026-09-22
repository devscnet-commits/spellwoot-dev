require 'rails_helper'

# A memória de cliente custa uma chamada ao modelo por conversa RESOLVIDA (Ai::CustomerMemoryUpdater,
# gpt-4.1-mini). Ela só é LIDA num turno de IA, então numa caixa sem IA vinculada o gasto não produzia
# nada — e caía igualmente em caixa de atendimento humano e de grupo, que foi o consumo relatado em
# produção. O corte é a CAIXA ter IA ativa, não esta conversa ter sido atendida por IA.
RSpec.describe Ai::CustomerMemoryListener do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:listener) { described_class.instance }

  def resolved_event
    Events::Base.new('conversation_resolved', Time.zone.now, conversation: conversation)
  end

  def bind_ai!(active: true, mode: 'live')
    profile = Ai::OperationProfile.create!(account_id: account.id, name: 'padrão',
                                           supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
    agent = Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id)
    Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: mode, active: active)
  end

  before { account.enable_features!('ai_core') }

  it 'não gasta chamada quando a caixa não tem nenhuma IA vinculada' do
    expect { listener.conversation_resolved(resolved_event) }.not_to have_enqueued_job(Ai::CustomerMemoryJob)
  end

  it 'não gasta chamada quando o vínculo de IA existe mas está inativo' do
    bind_ai!(active: false)

    expect { listener.conversation_resolved(resolved_event) }.not_to have_enqueued_job(Ai::CustomerMemoryJob)
  end

  it 'memoriza numa caixa com IA ativa, mesmo que esta conversa tenha sido atendida por humano' do
    bind_ai!

    expect { listener.conversation_resolved(resolved_event) }
      .to have_enqueued_job(Ai::CustomerMemoryJob).with(conversation.id)
  end

  it 'segue pulando conversa sem contato' do
    bind_ai!
    # Em memória: o listener lê o objeto que vem no evento, e contact_id é NOT NULL no banco.
    conversation.contact_id = nil

    expect { listener.conversation_resolved(resolved_event) }.not_to have_enqueued_job(Ai::CustomerMemoryJob)
  end

  it 'segue pulando conta sem ai_core' do
    bind_ai!
    account.disable_features!('ai_core')

    expect { listener.conversation_resolved(resolved_event) }.not_to have_enqueued_job(Ai::CustomerMemoryJob)
  end
end
