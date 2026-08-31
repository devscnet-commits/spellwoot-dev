class Api::V1::Accounts::MessageTemplatesController < Api::V1::Accounts::BaseController
  include WhatsappTemplateErrorParsing

  before_action :fetch_inbox
  before_action :validate_whatsapp_cloud_channel

  def index
    result = Whatsapp::MessageTemplateService.new(@inbox.channel).list_templates
    render_template_list_result(result)
  end

  def create
    template_params = extract_template_params
    service = Whatsapp::MessageTemplateService.new(@inbox.channel)
    result = service.create_template(template_params)
    render_template_creation_result(result)
  rescue ActionController::ParameterMissing
    render json: { error: 'Template parameters are required' }, status: :unprocessable_entity
  end

  private

  def fetch_inbox
    @inbox = Current.account.inboxes.find(params[:inbox_id])
    authorize @inbox, :show?
  end

  def validate_whatsapp_cloud_channel
    return if @inbox.channel.is_a?(Channel::Whatsapp) && @inbox.channel.provider == 'whatsapp_cloud'

    render json: { error: 'Message template creation is only available for WhatsApp Cloud API channels' },
           status: :bad_request
  end

  def extract_template_params
    params.require(:template).permit(
      :name, :category, :language, :body, :footer,
      buttons: [:type, :text, :url, :phone_number, :example]
    ).to_h.symbolize_keys
  end

  def render_template_list_result(result)
    if result[:success]
      render json: { templates: result[:templates] }
    else
      whatsapp_error = parse_whatsapp_error(result[:response_body])
      render json: { error: whatsapp_error[:user_message] || result[:error] }, status: :internal_server_error
    end
  end

  def render_template_creation_result(result)
    if result[:success]
      render_successful_template_creation(result)
    else
      render_failed_template_creation(result)
    end
  end

  def render_successful_template_creation(result)
    render json: {
      template: {
        id: result[:template_id],
        name: result[:template_name],
        status: result[:status],
        language: result[:language]
      }
    }, status: :created
  end

  def render_failed_template_creation(result)
    whatsapp_error = parse_whatsapp_error(result[:response_body])
    error_message = whatsapp_error[:user_message] || result[:error]

    render json: {
      error: error_message,
      details: whatsapp_error[:technical_details]
    }, status: :unprocessable_entity
  end
end
