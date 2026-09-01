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

  # :id here is the template's numeric Meta ID (as returned by #index) — Meta's update endpoint
  # addresses templates by ID, not by name.
  def update
    template_params = extract_update_params
    service = Whatsapp::MessageTemplateService.new(@inbox.channel)
    result = service.update_template(params[:id], template_params)
    render_template_update_result(result)
  rescue ActionController::ParameterMissing
    render json: { error: 'Template parameters are required' }, status: :unprocessable_entity
  end

  # :id here is the template's name — Meta's delete endpoint addresses templates by name.
  def destroy
    service = Whatsapp::MessageTemplateService.new(@inbox.channel)
    result = service.delete_template(params[:id])
    render_template_delete_result(result)
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
      body_sample_values: [],
      buttons: [:type, :text, :url, :phone_number, :example]
    ).to_h.symbolize_keys
  end

  def extract_update_params
    params.require(:template).permit(
      :category, :body, :footer,
      body_sample_values: [],
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
      render_service_error(result)
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

  def render_template_update_result(result)
    if result[:success]
      render json: { success: true }
    else
      render_service_error(result)
    end
  end

  def render_template_delete_result(result)
    if result[:success]
      head :no_content
    else
      render_service_error(result)
    end
  end

  def render_service_error(result)
    whatsapp_error = parse_whatsapp_error(result[:response_body])
    render json: {
      error: whatsapp_error[:user_message] || result[:error],
      details: whatsapp_error[:technical_details]
    }, status: :unprocessable_entity
  end
end
