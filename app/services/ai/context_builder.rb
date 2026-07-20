# Extraído do Ai::Gateway (quebra do God object — Passo 2): monta o contexto textual que vai ao modelo
# a partir da conversa — a mensagem do usuário (histórico recente + citação + texto atual) e a lista de
# atributos personalizados preenchíveis. Funções PURAS: só leem a conversa/mensagem/conta e retornam
# string/array; não emitem eventos nem alteram estado. Contexto do run injetado no initialize;
# `current`/`department` variam por chamada.
class Ai::ContextBuilder
  HISTORY_LIMIT = 12

  def initialize(conversation:, message:, account:)
    @conversation = conversation
    @message = message
    @account = account
  end

  # The model used to receive ONLY the latest message, so it re-asked things already answered
  # (city/segment in a loop). Pair the current message with the recent transcript (everything up to
  # our last reply) so it has the conversation context. The current customer burst is kept separate
  # because grouping may join several messages into `current`.
  def user_message(current)
    # Se o cliente RESPONDEU/citou uma mensagem específica (reply do WhatsApp), traz o conteúdo
    # citado para o modelo entender a referência (ex.: "já enviei" citando onde mandou os dados).
    quoted = quoted_message_content
    current = "(O cliente está respondendo a esta mensagem anterior: \"#{quoted}\")\n#{current}" if quoted.present?

    last_out_id = @conversation.messages.outgoing.maximum(:id) || 0
    history = @conversation.messages
                           .where(message_type: %i[incoming outgoing])
                           .where('messages.id <= ?', last_out_id)
                           .includes(:attachments)
                           .order(created_at: :desc).limit(HISTORY_LIMIT).to_a.reverse
                           .map { |m| "#{m.incoming? ? 'Cliente' : 'Atendente'}: #{message_body(m)}" }
                           .reject { |line| line.end_with?(': ') }
    return current if history.empty?

    "Histórico recente da conversa:\n#{history.join("\n")}\n\nMensagem atual do cliente:\n#{current}"
  end

  # Atributos personalizados de conversa que a IA pode preencher: as definições da conta menos os
  # que o department desabilitou (lista "Atributos personalizados" da tela). Vira a instrução de
  # quais chaves preencher em `attributes`.
  def fillable_attributes(department)
    disabled = Array(department.behavior.to_h['disabled_custom_attributes'])
    ::CustomAttributeDefinition
      .where(account_id: @account.id, attribute_model: :conversation_attribute)
      .where.not(attribute_key: disabled)
      .pluck(:attribute_key, :attribute_display_name)
  rescue StandardError => e
    Rails.logger.error "[Ai::ContextBuilder#fillable_attributes] #{e.class}: #{e.message}"
    []
  end

  private

  # Corpo da mensagem no histórico: o texto; ou, se não houver texto MAS houver anexo (BUG 3), um
  # placeholder pelo tipo do anexo — para a IA saber, nos turnos seguintes, que o anexo existiu (antes
  # a linha virava "Cliente: " e era descartada -> a IA repergunta localização/comprovante já recebidos).
  def message_body(message)
    text = message.content.to_s.strip.first(500)
    return text if text.present?

    attachment_placeholder(message)
  end

  def attachment_placeholder(message)
    att = message.attachments.to_a.first
    return '' unless att

    case att.file_type.to_s
    when 'location' then '[enviou uma localização]'
    when 'file' then "[enviou um documento: #{attachment_name(att)}]"
    when 'image' then '[enviou uma imagem]'
    when 'audio' then '[enviou um áudio]'
    when 'video' then '[enviou um vídeo]'
    else '[enviou um anexo]'
    end
  end

  def attachment_name(att)
    (att.file.attached? ? att.file.blob.filename.to_s : att.fallback_title.to_s).presence || 'arquivo'
  end

  # Conteúdo da mensagem citada quando o cliente responde a uma mensagem específica (reply do canal).
  # O Chatwoot resolve a citação para o id da mensagem em content_attributes['in_reply_to'].
  def quoted_message_content
    ref_id = (@message.in_reply_to if @message.respond_to?(:in_reply_to)) ||
             @message.content_attributes&.dig('in_reply_to')
    return nil if ref_id.blank?

    @conversation.messages.find_by(id: ref_id)&.content.to_s.strip.first(300).presence
  rescue StandardError => e
    Rails.logger.error "[Ai::ContextBuilder#quoted_message_content] #{e.class}: #{e.message}"
    nil
  end
end
