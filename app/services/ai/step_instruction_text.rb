# Renderiza o texto de instrução de UMA etapa do playbook para o prompt/judge. Etapa NOVA (objective/
# rules/suggested_script — o padrão estruturado pro motor Python/Agêntico) vira um bloco
# "Objetivo: .../Regras:\n- .../Fala sugerida: \"...\"". Etapa ANTIGA (só step['instructions'], texto
# livre) cai no fallback — texto ORIGINAL, sem reformatar (não inventa Objetivo/Regras que não existem).
# Único lugar que conhece esse fallback — reaproveitado por TODOS os leitores de instrução de etapa:
# Ai::PythonOrchestratorClient (motor novo), Ai::PromptCompiler (motor legado) e Ai::Workers::CaptureJudge.
module Ai::StepInstructionText
  def self.render(step)
    return nil unless step.is_a?(Hash)

    objective = field(step, 'objective')
    rules = rule_lines(step)
    script = field(step, 'suggested_script')
    return legacy_fallback(step) if objective.blank? && rules.empty? && script.blank?

    build(objective, rules, script)
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

  def self.build(objective, rules, script)
    parts = []
    parts << "Objetivo: #{objective}" if objective.present?
    parts << "Regras:\n#{rules.map { |r| "- #{r}" }.join("\n")}" if rules.any?
    parts << "Fala sugerida: \"#{script}\"" if script.present?
    parts.join("\n")
  end
end
