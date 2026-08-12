# Auditoria READ-ONLY pra decidir se dá pra eliminar o motor legado (decide()/call_with_tools()) e
# tornar o Python o motor ÚNICO, sem flag por department. Levanta os casos que HOJE só funcionam
# direito no legado — "playbook incompatível" não é bem a categoria certa (Ai::Playbook#steps é a
# MESMA estrutura nos dois motores, Ai::StepSlot/Ai::StepInstructionText são compartilhados); os gaps
# reais são de FUNCIONALIDADE do motor Python em si:
#
# 1. Provider: orchestrator.py tem um único client hardcoded (`_client = OpenAI(...)`) — um department
#    cujo Ai::OperationProfile#supervisor_provider NÃO é 'openai' QUEBRA por completo no Python (a
#    chamada tenta usar a chave/API da OpenAI de qualquer forma). O legado suporta múltiplos providers
#    via Ai::LlmToolAdapter/ruby_llm.
# 2. Automações de etapa (tag/webhook/change_team/update_attribute — Ai::StepAutomationRunner): só
#    disparam via Ai::StateManager#track_step -> #fire_step_automations, chamado SÓ no caminho legado
#    do Ai::Gateway#run. O branch do Python (`if python_orchestrator_on?(department)`) faz um `return`
#    ANTES de chegar nessa chamada — "avancar_etapa" (Api::Internal::AiExecuteToolController#advance_step)
#    só incrementa o índice, nunca roda a automação. Um department com automação configurada PERDE essa
#    automação silenciosamente se for pro Python — sem erro, sem log, a automação simplesmente não roda.
module Ai::PythonMigrationAuditor
  module_function

  # [{ department_id:, name:, account_id:, provider: }] — departments cujo provider NÃO é openai.
  def non_openai_provider_departments
    Ai::Department.includes(agent: :operation_profile).filter_map do |d|
      provider = d.agent&.operation_profile&.supervisor_provider
      next if provider.blank? || provider == 'openai'

      { department_id: d.id, name: d.name, account_id: d.account_id, provider: provider }
    end
  end

  # [{ department_id:, name:, account_id:, step_names: [...] }] — departments com QUALQUER etapa que
  # declara automations (tag/webhook/change_team/update_attribute).
  def step_automation_departments
    Ai::Department.includes(:playbook).filter_map do |d|
      steps_with_automations = Array(d.playbook&.steps).select { |s| Array(s['automations'] || s[:automations]).present? }
      next if steps_with_automations.empty?

      { department_id: d.id, name: d.name, account_id: d.account_id,
        step_names: steps_with_automations.map { |s| (s['name'] || s[:name]).to_s.presence || '(sem nome)' } }
    end
  end

  # Departments que HOJE já rodam no Python (não seriam afetados por remover a flag) vs. os que ainda
  # dependem do legado (TODOS seriam movidos se a flag sumisse) — mede o alcance real da mudança.
  def engine_split
    on, off = Ai::Department.find_each.partition { |d| truthy?(d.behavior.to_h['python_orchestrator']) }
    { on_python: on.size, on_legacy: off.size }
  end

  # Relatório único: os dois blockers + o alcance. Vazio nos dois primeiros = seguro (quanto a ESSES
  # dois gaps específicos) prosseguir; blockers presentes = precisa resolver ou excluir esses
  # departments ANTES de eliminar o legado.
  def report
    {
      non_openai_provider: non_openai_provider_departments,
      step_automations: step_automation_departments,
      engine_split: engine_split
    }
  end

  def truthy?(value)
    value == true || value.to_s.strip.casecmp?('true')
  end
end
