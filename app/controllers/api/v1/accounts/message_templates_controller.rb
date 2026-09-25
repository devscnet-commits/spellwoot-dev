class Api::V1::Accounts::MessageTemplatesController < Api::V1::Accounts::BaseController
  include WhatsappTemplateErrorParsing

  before_action :fetch_inbox
  before_action :validate_whatsapp_cloud_channel

  def index
    result = Whatsapp::MessageTemplateService.new(@inbox.channel).list_templates
    render_template_list_result(result)
  end

  # Feeds the Flow button picker. Kept read-only and scoped to the inbox like every other action
  # here, so it inherits the same account/policy checks from fetch_inbox.
  def flows
    result = Whatsapp::MessageTemplateService.new(@inbox.channel).list_flows

    if result[:success]
      render json: { flows: result[:flows] }
    else
      render json: { error: result[:error] }, status: :unprocessable_entity
    end
  end

  # Cria e publica um Flow a partir de um modelo do catálogo, para o admin não precisar sair
  # daqui só porque a conta ainda não tem nenhum Flow.
  def create_flow
    attrs = flow_params
    return render json: { error: 'O nome do Flow é obrigatório' }, status: :unprocessable_entity if attrs[:name].blank?

    result = Whatsapp::MessageTemplateService.new(@inbox.channel).create_flow(**attrs)

    if result[:success]
      render json: { flow: result[:flow] }
    else
      render json: { error: result[:error] }, status: :unprocessable_entity
    end
  rescue KeyError
    render json: { error: 'Modelo de Flow desconhecido' }, status: :unprocessable_entity
  end

  def create
    template_params = extract_template_params
    service = Whatsapp::MessageTemplateService.new(@inbox.channel)
    result = service.create_template(template_params)
    @inbox.channel.sync_templates if result[:success]
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
    @inbox.channel.sync_templates if result[:success]
    render_template_update_result(result)
  rescue ActionController::ParameterMissing
    render json: { error: 'Template parameters are required' }, status: :unprocessable_entity
  end

  # :id here is the template's name — Meta's delete endpoint addresses templates by name.
  def destroy
    service = Whatsapp::MessageTemplateService.new(@inbox.channel)
    result = service.delete_template(params[:id])
    @inbox.channel.sync_templates if result[:success]
    render_template_delete_result(result)
  end

  def media_upload
    file = params[:file]
    return render json: { error: 'File is required' }, status: :unprocessable_entity if file.blank?

    result = Whatsapp::MediaUploadService.new(@inbox.channel).upload(file)
    render_media_upload_result(result)
  end

  private

  def flow_params
    permitted = params.permit(:key, :name, :heading, :submit_label)
    {
      key: permitted[:key].to_s,
      name: permitted[:name].to_s,
      heading: permitted[:heading].presence || permitted[:name].to_s,
      submit_label: permitted[:submit_label].presence || 'Enviar'
    }
  end

  def fetch_inbox
    @inbox = Current.account.inboxes.find(params[:inbox_id])
    authorize @inbox, :show?
  end

  def validate_whatsapp_cloud_channel
    return if @inbox.channel.is_a?(Channel::Whatsapp) && @inbox.channel.provider == 'whatsapp_cloud'

    render json: { error: 'Message template creation is only available for WhatsApp Cloud API channels' },
           status: :bad_request
  end

  # call_permission_request, flow_id e navigate_screen ficaram de fora desta lista, então o Rails
  # os descartava antes de chegarem ao service — que sabe montá-los desde sempre
  # (Whatsapp::MessageTemplateService#call_permission_request_component e #build_flow_button).
  # Efeito em produção: o subtipo Flows acusava "O ID do Flow do botão é obrigatório" mesmo com o
  # campo preenchido (Whatsapp::MessageTemplateValidator#button_field_error valida um flow_id que
  # nunca chegava), e o subtipo Solicitação de permissões para ligação criava um modelo comum, sem
  # o componente CALL_PERMISSION_REQUEST e sem avisar ninguém.
  def extract_template_params
    params.require(:template).permit(
      :name, :category, :language, :body, :footer, :call_permission_request, :sub_category, :parameter_format,
      header: [:type, :text, :handle, :sample],
      body_sample_values: [],
      body_variable_names: [],
      buttons: [:type, :text, :url, :phone_number, :example, :flow_id, :navigate_screen]
    ).to_h.deep_symbolize_keys
  end

  def extract_update_params
    params.require(:template).permit(
      :category, :body, :footer, :call_permission_request, :sub_category, :parameter_format,
      header: [:type, :text, :handle, :sample],
      body_sample_values: [],
      body_variable_names: [],
      buttons: [:type, :text, :url, :phone_number, :example, :flow_id, :navigate_screen]
    ).to_h.deep_symbolize_keys
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

  def render_media_upload_result(result)
    if result[:success]
      render json: { handle: result[:handle] }
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
