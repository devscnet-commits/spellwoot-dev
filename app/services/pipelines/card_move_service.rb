# A card moved to a pipeline stage. By an agent (drag on the board, "Novo negócio"): the stage's
# required attributes must be filled first (the values typed in the "Campos obrigatórios da etapa"
# popup come in custom_attributes). By the system (automations, cadence, reopen): no requirement
# check. Entering the won/lost column sets the conversation result, leaving it for an open stage
# clears it; the stage's Meta conversion event fires for human moves like a manual close does.
class Pipelines::CardMoveService
  class MissingAttributes < StandardError
    attr_reader :keys

    def initialize(keys)
      @keys = keys
      super('required attributes missing')
    end
  end

  def initialize(conversation:, stage:, user: nil, custom_attributes: nil, source: 'manual')
    @conversation = conversation
    @stage = stage
    @user = user.is_a?(User) ? user : nil
    @attributes = custom_attributes.to_h
    @source = source
  end

  def perform
    merged = @conversation.custom_attributes.to_h.merge(@attributes)
    check_requirements!(merged) if @source == 'manual'

    moved = false
    # One commit: the card never lands in a closing column with the result left unset (and vice versa).
    ActiveRecord::Base.transaction do
      @conversation.update!(custom_attributes: merged) if @attributes.present?
      moved = Pipelines::StageMover.new(conversation: @conversation, stage: @stage, user: @user, source: @source).perform
      sync_result if moved
    end
    Meta::HandleCloseEventService.new(conversation: @conversation, outcome: @stage.canonical_key, user: @user).perform if moved && @user
    @conversation
  end

  private

  def check_requirements!(merged)
    validator = Conversations::RequiredAttributesValidator.new(conversation: @conversation, custom_attributes: merged,
                                                               result: @stage.canonical_key, flow: @stage.operational_flow)
    raise MissingAttributes, validator.missing_keys unless validator.valid?
  end

  def sync_result
    if !@stage.stage?
      result_service(@stage.canonical_key).perform
    elsif !@conversation.result_none?
      result_service('').perform
    end
  end

  def result_service(outcome)
    Conversations::ResultService.new(conversation: @conversation, outcome: outcome, user: @user, sync_stage: false)
  end
end
