require 'rails_helper'

# Frente (a) — DESEMPATE entre IAs na mesma caixa: entre os bindings live elegíveis, exatamente UM roda
# (por [priority ASC, id ASC]); os perdedores são pulados INTEIROS (sem chamada ao modelo — o modelo mora
# dentro de Ai::Gateway#run, então não instanciar = custo zero). Shadow explícito segue rodando.
RSpec.describe Ai::GatewayRunJob do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'p', supervisor_provider: 'openai',
                                 supervisor_model: 'gpt-4.1-mini')
  end
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: 'open') }
  let(:message) do
    create(:message, account: account, inbox: inbox, conversation: conversation,
                     message_type: 'incoming', content: 'oi')
  end

  before { allow(Ai::LocationNormalizer).to receive(:normalize) }

  def agent(name)
    Ai::Agent.create!(account: account, name: name, status: 'active',
                      ai_operation_profile_id: profile.id, team_id: nil)
  end

  def binding_for(ai_agent, mode:, priority:)
    Ai::AgentInbox.create!(ai_agent_id: ai_agent.id, inbox_id: inbox.id, mode: mode, active: true, priority: priority)
  end

  # Espiã do Gateway: registra QUAIS bindings realmente rodaram. Como o modelo (Ai::ModelRouter.decide)
  # mora DENTRO do #run, um binding que não é instanciado/rodado = zero chamada ao modelo.
  def spy_gateway
    ran = []
    fake = instance_double(Ai::Gateway, run: nil)
    allow(Ai::Gateway).to receive(:new) do |**kwargs|
      ran << { agent_id: kwargs[:agent_inbox].ai_agent_id, mode: kwargs[:mode] }
      fake
    end
    ran
  end

  def tie_event
    Ai::Event.find_by(conversation_id: conversation.id, event_type: 'agent.priority_tie')
  end

  describe '#perform — eleição do binding live' do
    # Estado real das inbox 47/45: dois bindings live, mesma priority (1), agentes sem team_id.
    it 'dois live, mesma priority, sem team_id: só o de MENOR id roda, o outro NÃO chama o modelo, e emite agent.priority_tie' do
      a_maya = agent('Maya') # criado 1º -> id menor
      a_nova = agent('Nova')
      b_maya = binding_for(a_maya, mode: 'live', priority: 1)
      b_nova = binding_for(a_nova, mode: 'live', priority: 1)
      expect(b_maya.id).to be < b_nova.id

      ran = spy_gateway
      described_class.new.perform(message.id)

      aggregate_failures do
        expect(ran).to eq([{ agent_id: a_maya.id, mode: 'live' }]) # exatamente UM, o menor id, em live
        expect(tie_event).to be_present
        expect(tie_event.payload['agent_ids']).to match_array([a_maya.id, a_nova.id])
        expect(tie_event.payload['chosen_agent_id']).to eq(a_maya.id)
        expect(tie_event.payload['priority']).to eq(1)
      end
    end

    it 'priority MENOR vence o id: priority 0 do id MAIOR ganha do priority 1 do id menor (e NÃO há tie)' do
      a_maya = agent('Maya')
      a_nova = agent('Nova')
      binding_for(a_maya, mode: 'live', priority: 1) # id menor, priority maior
      binding_for(a_nova, mode: 'live', priority: 0) # id maior, priority MENOR -> vence

      ran = spy_gateway
      described_class.new.perform(message.id)

      expect(ran).to eq([{ agent_id: a_nova.id, mode: 'live' }])
      expect(tie_event).to be_nil # priorities distintas -> sem empate
    end

    it 'shadow EXPLÍCITO continua rodando junto do vencedor live (NÃO é pulado — é o propósito)' do
      a_live = agent('Maya')
      a_shadow = agent('Sombra')
      binding_for(a_live, mode: 'live', priority: 1)
      binding_for(a_shadow, mode: 'shadow', priority: 1)

      ran = spy_gateway
      described_class.new.perform(message.id)

      expect(ran).to match_array([{ agent_id: a_live.id, mode: 'live' }, { agent_id: a_shadow.id, mode: 'shadow' }])
      expect(tie_event).to be_nil # só 1 live elegível -> sem empate
    end

    it 'um único live: roda em live e NÃO emite tie' do
      a_maya = agent('Maya')
      binding_for(a_maya, mode: 'live', priority: 1)

      ran = spy_gateway
      described_class.new.perform(message.id)

      expect(ran).to eq([{ agent_id: a_maya.id, mode: 'live' }])
      expect(tie_event).to be_nil
    end
  end

  # Vencedor FORÇADO (handoff IA→IA): a IA de destino (ai_routed_agent_id) ganha ACIMA da eleição por
  # [priority, id]. É o que faz o transfer GRUDAR — sem isso, a de priority 1 reassumiria no turno seguinte.
  describe '#perform — vencedor forçado (ai_routed_agent_id)' do
    it 'força o destino ACIMA da eleição: a de priority 1 é PULADA, o destino roda live' do
      maya = agent('Maya')      # priority 1 — ganharia a eleição normal
      dest = agent('Comercial') # priority 2 — o alvo do handoff IA→IA
      binding_for(maya, mode: 'live', priority: 1)
      binding_for(dest, mode: 'live', priority: 2)
      conversation.update!(additional_attributes: { 'ai_routed_agent_id' => dest.id })

      ran = spy_gateway
      described_class.new.perform(message.id)

      expect(ran).to eq([{ agent_id: dest.id, mode: 'live' }]) # o destino em live; a Maya (pri 1) pulada
    end

    it 'MULTI-TURNO: a marca persiste — no turno seguinte o destino ganha de novo (não a Maya)' do
      maya = agent('Maya')
      dest = agent('Comercial')
      binding_for(maya, mode: 'live', priority: 1)
      binding_for(dest, mode: 'live', priority: 2)
      conversation.update!(additional_attributes: { 'ai_routed_agent_id' => dest.id })

      msg2 = create(:message, account: account, inbox: inbox, conversation: conversation,
                              message_type: 'incoming', content: 'e agora?')
      ran = spy_gateway
      described_class.new.perform(msg2.id)

      expect(ran.map { |r| r[:agent_id] }).to eq([dest.id]) # ainda o destino — o transfer grudou
    end

    it 'item 5: marca aponta agente FORA da inbox -> LIMPA + emite handoff.routed_agent_missing + eleição normal' do
      maya = agent('Maya')
      binding_for(maya, mode: 'live', priority: 1)
      gone = agent('Sumida') # NÃO vinculada a esta inbox
      conversation.update!(additional_attributes: { 'ai_routed_agent_id' => gone.id })

      ran = spy_gateway
      described_class.new.perform(message.id)

      aggregate_failures do
        expect(ran).to eq([{ agent_id: maya.id, mode: 'live' }]) # cai na eleição normal, não fica sem resposta
        expect(conversation.reload.additional_attributes).not_to have_key('ai_routed_agent_id') # marca limpa
        expect(Ai::Event.find_by(conversation_id: conversation.id,
                                 event_type: 'handoff.routed_agent_missing')).to be_present
      end
    end

    # Conversa REABERTA depois de resolvida: o RoutedAgentCleanupListener já limpou a marca no resolved, então
    # o estado que chega aqui é "sem marca". Prova o desfecho pedido: cai na eleição normal, sem posse forçada
    # pendente e SEM handoff.routed_agent_missing (não é órfã — é uma conversa nova para o motor).
    it 'conversa reaberta (marca já limpa no resolved): eleição normal, nada de posse órfã' do
      maya = agent('Maya')
      dest = agent('Comercial')
      binding_for(maya, mode: 'live', priority: 1)
      binding_for(dest, mode: 'live', priority: 2)
      conversation.update!(additional_attributes: {}) # sem ai_routed_agent_id

      ran = spy_gateway
      described_class.new.perform(message.id)

      aggregate_failures do
        expect(ran).to eq([{ agent_id: maya.id, mode: 'live' }]) # priority 1 vence a eleição normal
        expect(Ai::Event.where(conversation_id: conversation.id,
                               event_type: 'handoff.routed_agent_missing')).to be_empty
      end
    end
  end
end
