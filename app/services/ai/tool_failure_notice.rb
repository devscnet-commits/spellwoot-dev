# Quando uma ferramenta que a IA chamou falha (webhook, integração, capability), deixa uma NOTA INTERNA na
# conversa em linguagem de gente — o que falhou e o provável motivo —, com o detalhe técnico embaixo.
#
# Achado ao vivo: a ferramenta de viabilidade (sistema externo) ficou fora do ar por dias e ninguém soube —
# a falha só ia para o registro (Ai::CapabilityExecution) e de volta para a IA, que seguia o atendimento
# sem o resultado. Silencioso para a equipe.
#
# Uma nota por ferramenta/conversa a cada JANELA: a IA pode tentar a mesma ferramenta várias vezes no mesmo
# turno, e cada tentativa viraria uma nota repetida.
class Ai::ToolFailureNotice
  WINDOW = 10.minutes

  # [padrão no erro técnico, motivo legível]. O primeiro que casar vence.
  REASONS = [
    [/bloquead[ao] por segurança/i, 'o endereço configurado foi bloqueado por segurança (rede interna ou endereço não permitido)'],
    [/inativa/i, 'a integração está desativada'],
    [/sem URL|endpoint ausente|integration_link ausente/i, 'a ferramenta está sem endereço configurado'],
    [/Timeout|execution expired|timed out/i, 'o sistema externo não respondeu a tempo'],
    [/ECONNREFUSED|EHOSTUNREACH|ENETUNREACH|SocketError|Failed to open TCP|Connection refused|getaddrinfo/i,
     'o sistema externo está fora do ar ou inacessível'],
    [/HTTP 40[13]\b/, 'o sistema externo recusou o acesso (credencial inválida ou sem permissão)'],
    [/HTTP 404\b/, 'o endereço configurado não existe no sistema externo (URL errada?)'],
    [/HTTP 5\d\d\b/, 'o sistema externo apresentou um erro interno'],
    [/HTTP 4\d\d\b/, 'o sistema externo recusou os dados enviados']
  ].freeze

  # execution: a linha de auditoria (Ai::CapabilityExecution) quando a ferramenta tem uma — é por ela que
  # as tentativas repetidas são agrupadas. Ferramentas de controle (encerrar/transferir) não têm.
  def self.post(conversation:, tool_name:, error:, execution: nil)
    return if execution && already_noticed?(execution, conversation)

    Messages::MessageBuilder.new(nil, conversation, { content: text(tool_name, error), private: true }).perform
  rescue StandardError => e
    Rails.logger.error "[Ai::ToolFailureNotice] #{e.class}: #{e.message}"
  end

  def self.text(tool_name, error)
    <<~TEXT.strip
      ⚠️ A ferramenta "#{tool_name}" falhou: #{reason(error)}. A IA seguiu o atendimento sem esse resultado — verifique a ferramenta.
      Detalhe técnico: #{error.to_s.first(300)}
    TEXT
  end

  def self.reason(error)
    REASONS.find { |pattern, _| error.to_s.match?(pattern) }&.last || 'erro inesperado'
  end

  def self.already_noticed?(execution, conversation)
    Ai::CapabilityExecution.where(conversation_id: conversation.id, ai_tool_id: execution.ai_tool_id, status: 'failed')
                           .where(created_at: WINDOW.ago..).where.not(id: execution.id).exists?
  end
end
