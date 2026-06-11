# Resolves which OperationalFlow (Closing Flow) applies to a conversation. The flow is a
# direct attribute of the conversation's Caixa (inbox): teams organize agents, caixas own
# the closing process. Returns the flow only when it is active.
class Conversations::FlowResolver
  def initialize(conversation:, user: nil)
    @conversation = conversation
    @user = user
  end

  def flow
    resolved = @conversation.inbox&.operational_flow
    resolved if resolved&.active
  end
end
