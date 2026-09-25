class Whatsapp::MessageTemplateValidator
  NAME_REGEX = /\A[a-z0-9_]+\z/
  ALLOWED_CATEGORIES = %w[MARKETING UTILITY AUTHENTICATION].freeze
  # QUICK_REPLY, URL, PHONE_NUMBER and COPY_CODE are valid for both Marketing and Utility templates,
  # so no category-conditional split is needed here yet. CATALOG, FLOW and ORDER_DETAILS are
  # Marketing-only, enforced by the builder UI (only offered under their matching subtype) and by
  # EXCLUSIVE_BUTTON_TYPES below, since Meta requires each to be the template's only button.
  # call_permission_request (params[:call_permission_request]) isn't a button at all — it's a
  # separate CALL_PERMISSION_REQUEST template component, validated by call_permission_request_error.
  ALLOWED_BUTTON_TYPES = %w[QUICK_REPLY URL PHONE_NUMBER COPY_CODE CATALOG FLOW ORDER_DETAILS VOICE_CALL].freeze
  EXCLUSIVE_BUTTON_TYPES = %w[CATALOG FLOW ORDER_DETAILS].freeze
  # Meta fixes the button text for these two ("View catalog" / "Copy Pix code") and rejects a
  # custom one — skip the required-text check for them (button_field_error is a no-op for both).
  FIXED_TEXT_BUTTON_TYPES = %w[CATALOG ORDER_DETAILS].freeze
  # Meta rejects an unknown sub_category with a generic error, so screen it here to give the user
  # something actionable instead. ORDER_STATUS is the only one the builder offers today.
  ALLOWED_SUB_CATEGORIES = %w[ORDER_STATUS].freeze
  ALLOWED_HEADER_TYPES = %w[NONE TEXT IMAGE VIDEO DOCUMENT].freeze
  CALL_PERMISSION_REQUEST_HEADER_TYPES = %w[NONE TEXT].freeze
  # Meta rejects a VIDEO header on an order details template — only text, image or document (the
  # document format is what carries a PDF invoice in the header).
  ORDER_DETAILS_HEADER_TYPES = %w[NONE TEXT IMAGE DOCUMENT].freeze
  MAX_HEADER_TEXT_LENGTH = 60
  MAX_BODY_LENGTH = 1024
  MAX_FOOTER_LENGTH = 60
  MAX_BUTTON_TEXT_LENGTH = 25
  # Meta caps the voice call button's label at 20, not the 25 every other button gets.
  MAX_VOICE_CALL_TEXT_LENGTH = 20
  MAX_BUTTON_PHONE_LENGTH = 20
  MAX_BUTTONS = 10
  PARAMETER_FORMATS = %w[POSITIONAL NAMED].freeze
  NAMED_VARIABLE_REGEX = /\A[a-z][a-z0-9_]*\z/

  # require_name: false for edits — Meta's template update endpoint only accepts category and
  # components, the name can't be changed after creation.
  def initialize(params, require_name: true)
    @params = params
    @require_name = require_name
  end

  def valid?
    errors.empty?
  end

  def errors
    @errors ||= [
      (name_error if @require_name),
      category_error,
      sub_category_error,
      order_details_header_error,
      header_error,
      body_error,
      footer_error,
      call_permission_request_error,
      *button_errors
    ].compact
  end

  private

  def call_permission_request?
    ActiveModel::Type::Boolean.new.cast(@params[:call_permission_request])
  end

  def call_permission_request_error
    return unless call_permission_request?
    return 'O cabeçalho de um modelo de solicitação de permissão de ligação deve ser Texto ou estar ausente' unless CALL_PERMISSION_REQUEST_HEADER_TYPES.include?(header_type)
    return 'Um modelo de solicitação de permissão de ligação não pode ter botões' if @params[:buttons].present?
  end

  def header_type
    @params[:header]&.[](:type) || 'NONE'
  end

  def header_error
    header = @params[:header]
    return if header.blank? || header[:type].blank? || header[:type] == 'NONE'
    return "O tipo de cabeçalho deve ser um dos seguintes: #{ALLOWED_HEADER_TYPES.join(', ')}" unless ALLOWED_HEADER_TYPES.include?(header[:type])

    header[:type] == 'TEXT' ? header_text_error(header) : header_media_error(header)
  end

  def header_text_error(header)
    text = header[:text].to_s
    return 'O texto do cabeçalho é obrigatório' if text.blank?
    return "O texto do cabeçalho deve ter no máximo #{MAX_HEADER_TEXT_LENGTH} caracteres" if text.length > MAX_HEADER_TEXT_LENGTH

    header_variable_error(header, text)
  end

  # Meta allows at most one variable in a header — unlike the body, which allows several — and
  # it must follow the template's own parameter_format (positional {{1}} or a NAMED token).
  def header_variable_error(header, text)
    tokens = text.scan(/\{\{([^{}]*)\}\}/).flatten
    return if tokens.empty?
    return 'O cabeçalho pode ter no máximo uma variável' if tokens.size > 1

    token = tokens.first
    if parameter_format == 'NAMED'
      return 'O nome da variável do cabeçalho deve começar com letra minúscula e conter apenas letras, números e underline' unless token.match?(NAMED_VARIABLE_REGEX)
    elsif token != '1'
      return 'A variável do cabeçalho deve ser {{1}}'
    end

    'Informe um valor de exemplo para a variável do cabeçalho' if header[:sample].to_s.blank?
  end

  def header_media_error(header)
    'A mídia do cabeçalho é obrigatória — envie um arquivo primeiro' if header[:handle].blank?
  end

  def name_error
    name = @params[:name].to_s
    return 'O nome é obrigatório' if name.blank?
    return 'O nome deve conter apenas letras minúsculas, números e underline' unless name.match?(NAME_REGEX)
  end

  def category_error
    return if ALLOWED_CATEGORIES.include?(@params[:category])

    "A categoria deve ser uma das seguintes: #{ALLOWED_CATEGORIES.join(', ')}"
  end

  def order_details_header_error
    return unless Array(@params[:buttons]).any? { |button| button[:type] == 'ORDER_DETAILS' }
    return if ORDER_DETAILS_HEADER_TYPES.include?(header_type)

    'O cabeçalho de um modelo de detalhes do pedido deve ser Texto, Imagem ou Documento'
  end

  def sub_category_error
    sub_category = @params[:sub_category]
    return if sub_category.blank?
    return "O tipo #{sub_category} não é suportado" unless ALLOWED_SUB_CATEGORIES.include?(sub_category)

    'Um modelo de status do pedido deve ter apenas corpo e rodapé, sem cabeçalho e sem botões' if order_status_extra_components?
  end

  def order_status_extra_components?
    header_type != 'NONE' || @params[:buttons].present?
  end

  def body_error
    return if @params[:category] == 'AUTHENTICATION'

    body = @params[:body].to_s
    return 'O corpo da mensagem é obrigatório' if body.blank?
    return "O corpo da mensagem deve ter no máximo #{MAX_BODY_LENGTH} caracteres" if body.length > MAX_BODY_LENGTH
    return 'O corpo da mensagem não pode começar ou terminar com uma variável' if dangling_variable?(body)

    variable_sample_error(body)
  end

  # Meta treats a variable as "leading/trailing" even with punctuation stuck to it (e.g. "...{{2}}."
  # is still rejected as trailing) — confirmed live against the real Graph API, which rejects that
  # shape with error_subcode 2388299 "Leading or Trailing Params Not Allowed" even though it doesn't
  # literally end the string. Match that by allowing punctuation/whitespace around the variable.
  def dangling_variable?(body)
    body.match?(/\A[[:punct:]\s]*\{\{[a-zA-Z0-9_]+\}\}/) || body.match?(/\{\{[a-zA-Z0-9_]+\}\}[[:punct:]\s]*\z/)
  end

  def parameter_format
    PARAMETER_FORMATS.include?(@params[:parameter_format]) ? @params[:parameter_format] : 'POSITIONAL'
  end

  def variable_sample_error(body)
    tokens = body.scan(/\{\{([^{}]*)\}\}/).flatten.uniq
    return if tokens.empty?

    parameter_format == 'NAMED' ? named_variable_error(tokens) : positional_variable_error(tokens)
  end

  def positional_variable_error(tokens)
    return 'As variáveis devem ser numeradas (ex: {{1}}, {{2}}), não ter nome, para o tipo Número' unless tokens.all? { |token| token.match?(/\A\d+\z/) }

    numbers = tokens.map(&:to_i).sort
    return 'As variáveis devem ser sequenciais a partir de {{1}} (ex: {{1}}, {{2}})' unless numbers == (1..numbers.size).to_a

    sample_values = @params[:body_sample_values] || []
    return "Informe um valor de exemplo para cada variável (#{numbers.size} esperado(s))" if sample_values.size != numbers.size
    return 'Os valores de exemplo não podem ficar em branco' if sample_values.any?(&:blank?)
  end

  def named_variable_error(tokens)
    return 'Os nomes das variáveis devem começar com letra minúscula e conter apenas letras, números e underline (ex: {{nome_cliente}})' unless tokens.all? { |token| token.match?(NAMED_VARIABLE_REGEX) }

    names = @params[:body_variable_names] || []
    return 'Informe o nome de cada variável' if names.size != tokens.size
    return 'Os nomes das variáveis não correspondem às variáveis usadas no corpo da mensagem' unless names.sort == tokens.sort

    sample_values = @params[:body_sample_values] || []
    return "Informe um valor de exemplo para cada variável (#{tokens.size} esperado(s))" if sample_values.size != tokens.size
    return 'Os valores de exemplo não podem ficar em branco' if sample_values.any?(&:blank?)
  end

  def footer_error
    footer = @params[:footer]
    return if footer.blank?
    return "O rodapé deve ter no máximo #{MAX_FOOTER_LENGTH} caracteres" if footer.length > MAX_FOOTER_LENGTH
  end

  def button_errors
    buttons = @params[:buttons] || []
    return ["Um modelo pode ter no máximo #{MAX_BUTTONS} botões"] if buttons.size > MAX_BUTTONS

    error = exclusive_button_error(buttons)
    return [error] if error

    buttons.filter_map { |button| button_error(button) }
  end

  def exclusive_button_error(buttons)
    exclusive_button = buttons.find { |button| EXCLUSIVE_BUTTON_TYPES.include?(button[:type]) }
    return if exclusive_button.blank?

    "Um botão do tipo #{exclusive_button[:type]} precisa ser o único botão do modelo" if buttons.size > 1
  end

  def button_error(button)
    type = button[:type]
    return "O tipo de botão #{type} não é suportado" unless ALLOWED_BUTTON_TYPES.include?(type)
    return button_field_error(button) if fixed_text_button?(button)

    text = button[:text].to_s
    return "O texto do botão é obrigatório para botões do tipo #{type}" if text.blank?

    max_text = type == 'VOICE_CALL' ? MAX_VOICE_CALL_TEXT_LENGTH : MAX_BUTTON_TEXT_LENGTH
    return "O texto do botão deve ter no máximo #{max_text} caracteres" if text.length > max_text

    button_field_error(button)
  end

  # The AUTHENTICATION category's COPY_CODE button is Meta's OTP button — fixed text, no sample
  # code — unlike the same button type used for a Marketing promo code, which is user-editable.
  def fixed_text_button?(button)
    FIXED_TEXT_BUTTON_TYPES.include?(button[:type]) || (button[:type] == 'COPY_CODE' && @params[:category] == 'AUTHENTICATION')
  end

  def button_field_error(button)
    case button[:type]
    when 'URL'
      url_button_error(button)
    when 'PHONE_NUMBER'
      phone_number_error(button[:phone_number])
    when 'COPY_CODE'
      return if @params[:category] == 'AUTHENTICATION'

      'O código de exemplo do botão é obrigatório' if button[:example].blank?
    when 'FLOW'
      flow_button_error(button)
    end
  end

  # Meta allows at most one variable in a URL button, always positional ({{1}}), and only at the
  # very end of the URL (a dynamic path suffix, not a dynamic domain or middle segment). The
  # example must be the full resolved URL, not just the variable's value.
  def url_button_error(button)
    url = button[:url].to_s
    return 'A URL do botão é obrigatória' if url.blank?

    tokens = url.scan(/\{\{([^{}]*)\}\}/).flatten
    return if tokens.empty?
    return 'A URL pode ter no máximo uma variável' if tokens.size > 1
    return 'A variável da URL deve ser {{1}}' unless tokens.first == '1'
    return 'A variável da URL deve estar no final do endereço' unless url.end_with?('{{1}}')

    'Informe uma URL de exemplo, com um valor real no lugar de {{1}}' if button[:example].blank?
  end

  # A Meta recusa o template quando o botão FLOW vem sem navigate_screen (code 100, subcode
  # 2388202), apesar de uma das páginas da documentação dizer que o campo é opcional.
  def flow_button_error(button)
    return 'O ID do Flow do botão é obrigatório' if button[:flow_id].blank?

    'A tela inicial do Flow é obrigatória' if button[:navigate_screen].blank?
  end

  def phone_number_error(phone_number)
    return 'O número de telefone do botão é obrigatório' if phone_number.blank?
    return "O número de telefone do botão deve ter no máximo #{MAX_BUTTON_PHONE_LENGTH} caracteres" if phone_number.length > MAX_BUTTON_PHONE_LENGTH
  end
end
