# Decides whether the AI should stop and hand off to a human. Reasons, in order:
#   - the model explicitly chose 'handoff';
#   - confidence below the department threshold.
# Pure decision — it does not transfer; the Gateway executes (live) or records intention (shadow).
class Ai::HandoffEvaluator
  # 0 = desligado por padrão: NÃO transfere por confiança sozinho. A transferência por confiança
  # baixa é OPT-IN (só se o usuário definir transfer_rules['min_confidence'] > 0). Sem isso, a IA
  # só transfere quando o MODELO decide handoff (ele já é instruído via prompt).
  # Antes havia um corte fixo de 0.5 que transferia mensagens iniciais/vagas direto, sem recepcionar.
  # (Match por palavra-chave foi REMOVIDO: substring sem contexto gerava falsos positivos — ex.:
  # "a internet anterior era horrível" disparava transferência. Confiamos no min_confidence, que é
  # um sinal da própria IA avaliando o contexto.)
  DEFAULT_MIN_CONFIDENCE = 0.0

  def self.evaluate(decision:, department:)
    rules = department.transfer_rules || {}

    return reason('modelo_pediu_transferencia') if decision['decision'] == 'handoff'

    confidence = decision['confidence']
    minimum = (rules['min_confidence'] || DEFAULT_MIN_CONFIDENCE).to_f
    return reason('confianca_baixa') if minimum.positive? && confidence.is_a?(Numeric) && confidence < minimum

    { handoff: false }
  end

  def self.reason(value)
    { handoff: true, reason: value }
  end
end
