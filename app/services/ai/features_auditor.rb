# Auditoria READ-ONLY dos recursos opcionais de um agente de IA (RAG, tools, automações de etapa,
# handoff, follow-up, etc.). Só leitura — usado pelo rake `ai:agent_features_audit`. Produz um hash
# (report) que serve tanto ao texto quanto ao --json.
#
# Fusão Departamento -> Agente (19/08): o breakdown que antes era por-department (RAG/tools/etapas/
# automações/lead vars/follow-up/finalização/transfer, um bloco por department de um agente
# multi-department) virou um único bloco por AGENTE — não há mais o conceito de "vários departments
# do mesmo agente" pra detalhar separadamente.
class Ai::FeaturesAuditor
  Feature = Struct.new(:in_use, :detail, keyword_init: true)

  def initialize(agent)
    @agent = agent
  end

  def report
    {
      agent: agent_summary,
      agent_features: all_features.transform_values { |f| { in_use: f.in_use, detail: f.detail } },
      cross_account: cross_account.transform_values { |f| { in_use: f.in_use, detail: f.detail } }
    }
  end

  def summary_line
    "##{@agent.id} #{@agent.name.inspect} conta=#{@agent.account_id} stage=#{@agent.stage} " \
      "status=#{@agent.status} [RAG:#{@agent.knowledge_sources.active.exists?} " \
      "tools:#{@agent.tools.active.count} automações:#{total_automations} " \
      "handoff_ia:#{Array(@agent.handoff_agent_ids).size}]"
  end

  def agent_summary
    { id: @agent.id, name: @agent.name, assistant_name: @agent.assistant_name,
      account_id: @agent.account_id, stage: @agent.stage, status: @agent.status }
  end

  def all_features
    prof = @agent.operation_profile
    inboxes = @agent.agent_inboxes
    ks = @agent.knowledge_sources.active
    tools = @agent.tools.active
    steps = playbook_steps
    autos = steps.flat_map { |s| Array(s['automations'] || s[:automations]) }
    {
      'Nível operacional' => feat(prof.present?, prof && "#{prof.name} (#{prof.supervisor_provider}/#{prof.supervisor_model})"),
      'Base prompt' => feat(@agent.base_prompt.present?, @agent.base_prompt.present? ? "#{@agent.base_prompt.length} chars" : nil),
      'Guardrails' => feat(@agent.guardrails.present?),
      'Handoff IA→IA' => feat(handoff_agents.any?, ("#{handoff_agents.size} IAs" if handoff_agents.any?)),
      'Handoff → humanos' => feat(handoff_teams.any?, ("#{handoff_teams.size} times" if handoff_teams.any?)),
      'OCR/Visão (mídia)' => feat(ocr_model.present?, ocr_model),
      'Copilot (uso real)' => feat(copilot_runs.positive?, "#{copilot_runs} runs (ai_runs run_type=copilot)"),
      'Caixas' => feat(inboxes.any?, "#{inboxes.live.count} live, #{inboxes.shadow.count} shadow"),
      'RAG/Conhecimento' => feat(ks.exists?, ks.exists? ? "#{ks.count} fontes, #{chunk_count(ks)} chunks" : nil),
      'Tools' => feat(tools.exists?, tools.exists? ? "#{tools.count} (#{tool_breakdown(tools)})" : nil),
      'Etapas (playbook)' => feat(steps.any?, ("#{steps.size} steps" if steps.any?)),
      'Automações de etapa' => feat(autos.any?, autos.any? ? "#{autos.size} (#{automation_breakdown(autos)})" : nil),
      'Lead variables' => feat(@agent.lead_variables.exists?, ("#{@agent.lead_variables.count}" if @agent.lead_variables.exists?)),
      'Follow-up' => feat(followup_behaviors.any?, ("#{followup_behaviors.size} comportamentos" if followup_behaviors.any?)),
      'Finalização' => feat(close_configured?),
      'Transfer rules' => feat(@agent.transfer_rules.to_h.present?, transfer_detail)
    }
  end

  # -------- TRANSVERSAIS (por conta) --------

  def cross_account
    acc = @agent.account_id
    {
      'Memória do cliente' => feat(Ai::CustomerMemory.where(account_id: acc).exists?, "#{Ai::CustomerMemory.where(account_id: acc).count} registros"),
      'Shadow (avaliador)' => feat(Ai::Shadow.where(account_id: acc).exists?, "#{Ai::Shadow.where(account_id: acc).count}"),
      'Mídia/visão (uso)' => feat(vision_runs(acc).positive?, "#{vision_runs(acc)} runs vision_ocr")
    }
  end

  private

  def feat(in_use, detail = nil)
    Feature.new(in_use: !!in_use, detail: detail.presence)
  end

  def handoff_agents = Array(@agent.handoff_agent_ids)
  def handoff_teams = Array(@agent.handoff_team_ids)

  def ocr_model
    cfg = @agent.operation_profile&.worker(:ocr) || {}
    cfg['model'].presence && "#{(cfg['provider'].presence || 'openai')}/#{cfg['model']}"
  end

  def copilot_runs
    Ai::Run.where(ai_agent_id: @agent.id, run_type: 'copilot').count
  end

  def vision_runs(account_id)
    Ai::Run.where(account_id: account_id, run_type: 'vision_ocr').count
  end

  def playbook_steps
    Array(@agent.playbook&.steps).select { |s| s.is_a?(Hash) }
  end

  def chunk_count(sources_relation)
    Ai::KnowledgeChunk.where(ai_knowledge_source_id: sources_relation.select(:id)).count
  end

  def tool_breakdown(tools)
    tools.group_by { |t| t.implementation_type.presence || 'capability' }
         .map { |type, list| "#{type}:#{list.size}" }.join(', ')
  end

  def automation_breakdown(autos)
    autos.group_by { |a| (a['type'] || a[:type]).to_s.presence || 'desconhecido' }
         .map { |type, list| "#{type}:#{list.size}" }.join(', ')
  end

  def followup_behaviors
    Array(@agent.follow_up.to_h['behaviors'])
  end

  def close_configured?
    @agent.close_rules.to_h.present? || @agent.playbook&.close_when.present?
  end

  def transfer_detail
    mc = @agent.transfer_rules.to_h['min_confidence']
    mc.present? ? "min_confidence=#{mc}" : nil
  end

  def total_automations
    playbook_steps.flat_map { |s| Array(s['automations'] || s[:automations]) }.size
  end

  # -------- Render de texto --------

  def self.render_text(report)
    a = report[:agent]
    out = []
    out << "AGENTE ##{a[:id]} — #{a[:name].inspect} (assistant: #{a[:assistant_name]})  " \
           "[conta=#{a[:account_id]} stage=#{a[:stage]} status=#{a[:status]}]"
    report[:agent_features].each { |label, f| out << "  #{label.ljust(20)}: #{fmt(f)}" }

    out << ''
    out << '  TRANSVERSAIS (por conta, não por agente)'
    report[:cross_account].each { |label, f| out << "    #{label.ljust(20)}: #{fmt(f)}" }
    out.join("\n")
  end

  def self.fmt(feature)
    yn = feature[:in_use] ? 'sim' : 'não'
    feature[:detail].present? ? "#{yn} — #{feature[:detail]}" : yn
  end
end
