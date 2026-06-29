# Decides whether the AI should stop and hand off to a human. Reasons, in order:
#   - the model explicitly chose 'handoff';
#   - confidence below the department threshold;
#   - a transfer keyword/rule matched the message.
# Pure decision — it does not transfer; the Gateway executes (live) or records intention (shadow).
class Ai::HandoffEvaluator
  # 0 = desligado por padrão: NÃO transfere por confiança sozinho. A transferência por confiança
  # baixa é OPT-IN (só se o usuário definir transfer_rules['min_confidence'] > 0). Sem isso, a IA
  # só transfere quando o MODELO decide handoff (ele já é instruído via prompt) ou por palavra-chave.
  # Antes havia um corte fixo de 0.5 que transferia mensagens iniciais/vagas direto, sem recepcionar.
  DEFAULT_MIN_CONFIDENCE = 0.0

  def self.evaluate(decision:, department:, message_content:)
    rules = department.transfer_rules || {}

    return reason('modelo_pediu_transferencia') if decision['decision'] == 'handoff'

    confidence = decision['confidence']
    minimum = (rules['min_confidence'] || DEFAULT_MIN_CONFIDENCE).to_f
    return reason('confianca_baixa') if minimum.positive? && confidence.is_a?(Numeric) && confidence < minimum

    keywords = Array(rules['keywords'])
    text = message_content.to_s.downcase
    return reason('regra_de_transferencia') if keywords.any? { |k| text.include?(k.to_s.downcase) }

    { handoff: false }
  end

  def self.reason(value)
    { handoff: true, reason: value }
  end
end
