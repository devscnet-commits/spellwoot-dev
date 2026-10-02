# CRM kanban: the pipelines (closing flows with open stages) and their boards. Cards are conversations;
# agents only see the ones they can access (Conversations::PermissionFilterService).
class Api::V1::Accounts::PipelinesController < Api::V1::Accounts::BaseController
  include PlanFeatureEnforceable

  before_action -> { enforce_plan_feature('crm_kanban', I18n.t('errors.pipelines.plan_feature')) }
  before_action :check_authorization
  before_action :fetch_pipeline, except: [:index]
  before_action :fetch_stage, only: [:stage_cards, :move, :cards]

  def index
    @pipelines = Current.account.operational_flows.where(active: true).includes(:resolution_states, :closing_requirements)
                        .select(&:pipeline?)
  end

  def show
    @columns = board.columns
  end

  def stage_cards
    render json: board.stage_cards(@stage, params[:page])
  end

  def move
    conversation = Current.account.conversations.find_by!(display_id: params[:conversation_id])
    authorize conversation, :show?
    move_card(conversation)
  end

  # Novo negócio: an existing conversation (conversation_id) or a new one for a contact in an inbox.
  def cards
    return move if params[:conversation_id].present?

    conversation = build_conversation
    missing = new_card_missing_keys(conversation)
    return render_missing_attributes(missing) if missing.any?

    conversation.save!
    move_card(conversation)
  end

  def report
    render json: Pipelines::ReportBuilder.new(flow: @pipeline, user: Current.user, account: Current.account,
                                              since: params[:since], upto: params[:until]).perform
  end

  private

  def check_authorization
    authorize(:pipeline)
  end

  def fetch_pipeline
    @pipeline = Current.account.operational_flows.find(params[:id])
  end

  def fetch_stage
    @stage = @pipeline.resolution_states.find(params[:stage_id])
  end

  def board
    Pipelines::BoardBuilder.new(flow: @pipeline, user: Current.user, account: Current.account, params: board_params)
  end

  def board_params
    params.permit(:search, :temperature, :sla, :assignee_id, :status).to_h.symbolize_keys
  end

  def card_attributes
    params.permit(custom_attributes: {})[:custom_attributes].to_h
  end

  def move_card(conversation)
    Pipelines::CardMoveService.new(conversation: conversation, stage: @stage, user: Current.user,
                                   custom_attributes: card_attributes, ip_address: request.ip).perform
    render json: Pipelines::CardPresenter.new(conversation.reload, @pipeline).as_json
  rescue Pipelines::CardMoveService::MissingAttributes => e
    render_missing_attributes(e.keys)
  rescue Conversations::ResultService::InvalidReasonError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def render_missing_attributes(keys)
    render json: { error: I18n.t('errors.conversations.required_attributes_missing'), missing_attributes: keys },
           status: :unprocessable_entity
  end

  def build_conversation
    contact = Current.account.contacts.find(params[:contact_id])
    inbox = Current.account.inboxes.find(params[:inbox_id])
    authorize inbox, :show?
    contact_inbox = ContactInboxBuilder.new(contact: contact, inbox: inbox, source_id: uazapi_source_id(contact, inbox)).perform
    Current.account.conversations.new(inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: :open,
                                      assignee_id: Current.user.id, custom_attributes: card_attributes)
  end

  # UazAPI inboxes (Channel::Api) key the contact by the phone without "+", like incoming messages do.
  def uazapi_source_id(contact, inbox)
    return unless inbox.channel_type == 'Channel::Api' && inbox.channel.try(:uazapi_instance_token).present?

    contact.phone_number.to_s.delete('+').presence
  end

  def new_card_missing_keys(conversation)
    Conversations::RequiredAttributesValidator.new(conversation: conversation, custom_attributes: card_attributes,
                                                   result: @stage.canonical_key, flow: @pipeline).missing_keys
  end
end
