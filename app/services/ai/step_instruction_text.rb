# Renderiza o texto de instrução de UMA etapa do playbook para o prompt/judge. Etapa NOVA (objective/
# rules — o padrão estruturado pro motor Python/Agêntico) vira um bloco
# "Objetivo: .../Regras:\n- ...". Etapa ANTIGA (só step['instructions'], texto
# livre) cai no fallback — texto ORIGINAL, sem reformatar (não inventa Objetivo/Regras que não existem).
# Único lugar que conhece esse fallback — reaproveitado por TODOS os leitores de instrução de etapa:
# Ai::PythonOrchestratorClient (motor novo), Ai::PromptCompiler (motor legado) e Ai::Workers::CaptureJudge.
# Tom/abordagem de fala NÃO é campo de etapa (removido — dava a impressão de roteiro fixo pro modelo,
# mesmo com ressalva de "é só exemplo"): quem quer tom consistente configura em Ai::Agent#base_prompt
# (uma vez, vale pra toda a conversa), não repetido por etapa.
module Ai::StepInstructionText
  def self.render(step)
    return nil unless step.is_a?(Hash)

    objective = field(step, 'objective')
    rules = rule_lines(step)
    return legacy_fallback(step) if objective.blank? && rules.empty?

    build(objective, rules)
  end

  def self.field(step, key)
    (step[key] || step[key.to_sym]).to_s.strip
  end

  def self.rule_lines(step)
    Array(step['rules'] || step[:rules]).map { |r| r.to_s.strip }.reject(&:blank?)
  end

  def self.legacy_fallback(step)
    field(step, 'instructions').presence
  end

  def self.build(objective, rules)
    parts = []
    parts << "Objetivo: #{objective}" if objective.present?
    parts << "Regras:\n#{rules.map { |r| "- #{r}" }.join("\n")}" if rules.any?
    parts.join("\n")
  end
end
