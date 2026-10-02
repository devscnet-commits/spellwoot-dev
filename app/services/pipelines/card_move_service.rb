# A card dragged (or added) to a pipeline stage by an agent. The stage's required attributes must be
# filled first (the values typed in the "Campos obrigatórios da etapa" popup come in custom_attributes);
# entering the won/lost column sets the conversation result, leaving it for an open stage clears it.
# The stage's Meta conversion event fires like a manual close does.
class Pipelines::CardMoveService
  class MissingAttributes < StandardError
    attr_reader :keys

    def initialize(keys)
      @keys = keys
      super('required attributes missing')
    end
  end

  def initialize(conversation:, stage:, user:, custom_attributes: nil, ip_address: nil)
    @conversation = conversation
    @stage = stage
    @user = user
    @attributes = custom_attributes.to_h
    @ip_address = ip_address
  end

  def perform
    merged = @conversation.custom_attributes.to_h.merge(@attributes)
    validator = Conversations::RequiredAttributesValidator.new(conversation: @conversation, custom_attributes: merged,
                                                               result: @stage.canonical_key, flow: @stage.operational_flow)
    raise MissingAttributes, validator.missing_keys unless validator.valid?

    @conversation.update!(custom_attributes: merged) if @attributes.present?
    Pipelines::StageMover.new(conversation: @conversation, stage: @stage, user: @user, source: 'manual').perform
    sync_result
    Meta::HandleCloseEventService.new(conversation: @conversation, outcome: @stage.canonical_key, user: @user).perform
    @conversation
  end

  private

  def sync_result
    if !@stage.stage?
      result_service(@stage.canonical_key).perform
    elsif !@conversation.result_none?
      result_service('').perform
    end
  end

  def result_service(outcome)
    Conversations::ResultService.new(conversation: @conversation, outcome: outcome, user: @user, ip_address: @ip_address,
                                     sync_stage: false)
  end
end
