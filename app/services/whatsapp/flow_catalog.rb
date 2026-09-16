# Flows prontos que o painel consegue criar e publicar sozinho, sem o admin sair para o
# WhatsApp Manager. Cobrem os casos que a própria tela de modelos já anuncia: coletar interesse,
# agendar horário e pesquisar satisfação.
#
# A versão do Flow JSON é fixada de propósito. A Meta congela versões antigas periodicamente
# (2.1 a 5.0 já estão congeladas) e cada versão nova muda validação, então subir isso é uma
# decisão consciente, não algo que deva acompanhar a documentação sem teste.
class Whatsapp::FlowCatalog
  FLOW_JSON_VERSION = '7.0'.freeze

  TEMPLATES = {
    'LEAD_CAPTURE' => {
      category: 'LEAD_GENERATION',
      screen_id: 'LEAD_FORM',
      fields: [
        { name: 'full_name', label: 'Nome completo', input_type: 'text', required: true },
        { name: 'phone', label: 'Telefone', input_type: 'phone', required: true },
        { name: 'email', label: 'E-mail', input_type: 'email', required: false },
        { name: 'interest', label: 'No que você tem interesse?', input_type: 'text', required: false }
      ]
    },
    'APPOINTMENT' => {
      category: 'APPOINTMENT_BOOKING',
      screen_id: 'APPOINTMENT_FORM',
      fields: [
        { name: 'full_name', label: 'Nome completo', input_type: 'text', required: true },
        { name: 'phone', label: 'Telefone', input_type: 'phone', required: true },
        { name: 'preferred_date', label: 'Data de preferência', input_type: 'text', required: true },
        { name: 'notes', label: 'Observações', input_type: 'text', required: false }
      ]
    },
    'SURVEY' => {
      category: 'SURVEY',
      screen_id: 'SURVEY_FORM',
      fields: [
        { name: 'rating', label: 'De 0 a 10, qual a sua nota?', input_type: 'number', required: true },
        { name: 'comment', label: 'O que podemos melhorar?', input_type: 'text', required: false }
      ]
    }
  }.freeze

  def self.keys
    TEMPLATES.keys
  end

  def self.category_for(key)
    TEMPLATES.fetch(key)[:category]
  end

  # A Meta exige navigate_screen no botão FLOW e recusa o template sem ele (subcode 2388202).
  # Como o Flow é nosso, sabemos a tela de entrada e não precisamos pedir isso ao admin.
  def self.screen_id_for(key)
    TEMPLATES.fetch(key)[:screen_id]
  end

  # `heading` e `submit_label` vêm da tela para o admin escrever com as palavras dele; só o
  # esqueleto é nosso. Nenhum dos dois pode chegar vazio: a Meta recusa string vazia desde a 6.0.
  def self.build_flow_json(key, heading:, submit_label:)
    template = TEMPLATES.fetch(key)
    inputs = template[:fields].map { |field| text_input(field) }
    footer = footer_component(submit_label, template[:fields])

    {
      version: FLOW_JSON_VERSION,
      screens: [
        {
          id: template[:screen_id],
          title: heading,
          terminal: true,
          success: true,
          layout: {
            type: 'SingleColumnLayout',
            children: [
              { type: 'TextHeading', text: heading },
              { type: 'Form', name: 'flow_form', children: inputs + [footer] }
            ]
          }
        }
      ]
    }.to_json
  end

  def self.text_input(field)
    {
      type: 'TextInput',
      name: field[:name],
      label: field[:label],
      'input-type': field[:input_type],
      required: field[:required]
    }
  end
  private_class_method :text_input

  # A tela terminal precisa de um Footer para conseguir encerrar o Flow, e é o payload dele que
  # devolve as respostas para quem recebe o webhook.
  def self.footer_component(submit_label, fields)
    payload = fields.to_h { |field| [field[:name], "${form.#{field[:name]}}"] }
    {
      type: 'Footer',
      label: submit_label,
      'on-click-action': { name: 'complete', payload: payload }
    }
  end
  private_class_method :footer_component
end
