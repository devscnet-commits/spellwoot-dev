# Auditoria READ-ONLY dos recursos opcionais de um agente de IA e seus departments (RAG, tools,
# automações de etapa, handoff, follow-up, copilot, etc.). Só leitura — usado pelo rake
# `ai:agent_features_audit`. Produz um hash (report) que serve tanto ao texto quanto ao --json.
#
# Escopo: recursos de AGENTE (profile/base_prompt/guardrails/handoff/OCR/caixas/copilot-uso) no topo;
# recursos de DEPARTMENT (RAG/tools/etapas/automações/lead vars/follow-up/finalização/transfer/copilot-
# config) por department; TRANSVERSAIS (memória/shadow/mídia) rotulados como por-conta. Ver memória
# ai-department-architecture: department é o substrato vivo, por isso o breakdown por department.
class Ai::FeaturesAuditor
  Feature = Struct.new(:in_use, :detail, keyword_init: true)

  def initialize(agent)
    @agent = agent
  end

  def report
    {
      agent: agent_summary,
      agent_features: agent_features.transform_values { |f| { in_use: f.in_use, detail: f.detail } },
      departments: @agent.departments.active.order(:position, :id).map { |d| department_entry(d) },
      cross_account: cross_account.transform_values { |f| { in_use: f.in_use, detail: f.detail } },
      rollup: rollup
    }
  end

  def summary_line
    depts = @agent.departments.active.to_a
    "##{@agent.id} #{@agent.name.inspect} conta=#{@agent.account_id} stage=#{@agent.stage} " \
      "status=#{@agent.status} departments=#{depts.size} " \
      "[RAG:#{depts_with_rag(depts)} tools:#{total_tools(depts)} automações:#{total_automations(depts)} " \
      "handoff_ia:#{Array(@agent.handoff_agent_ids).size}]"
  end

  # -------- AGENTE --------

  def agent_summary
    { id: @agent.id, name: @agent.name, assistant_name: @agent.assistant_name,
      account_id: @agent.account_id, stage: @agent.stage, status: @agent.status }
  end

  def agent_features
    prof = @agent.operation_profile
    inboxes = @agent.agent_inboxes
    {
      'Nível operacional' => feat(prof.present?, prof && "#{prof.name} (#{prof.supervisor_provider}/#{prof.supervisor_model})"),
      'Base prompt' => feat(@agent.base_prompt.present?, @agent.base_prompt.present? ? "#{@agent.base_prompt.length} chars" : nil),
      'Guardrails' => feat(@agent.guardrails.present?),
      'Handoff IA→IA' => feat(handoff_agents.any?, ("#{handoff_agents.size} IAs" if handoff_agents.any?)),
      'Handoff → humanos' => feat(handoff_teams.any?, ("#{handoff_teams.size} times" if handoff_teams.any?)),
      'OCR/Visão (mídia)' => feat(ocr_model.present?, ocr_model),
      'Copilot (uso real)' => feat(copilot_runs.positive?, "#{copilot_runs} runs (ai_runs run_type=copilot)"),
      'Caixas' => feat(inboxes.any?, "#{inboxes.live.count} live, #{inboxes.shadow.count} shadow")
    }
  end

  # -------- DEPARTMENT --------

  def department_entry(dept)
    { id: dept.id, name: dept.name, is_default: dept.is_default,
      features: department_features(dept).transform_values { |f| { in_use: f.in_use, detail: f.detail } } }
  end

  def department_features(dept)
    steps = playbook_steps(dept)
    autos = steps.flat_map { |s| Array(s['automations'] || s[:automations]) }
    ks = dept.knowledge_sources.active
    tools = dept.tools.active
    {
      'RAG/Conhecimento' => feat(ks.exists?, ks.exists? ? "#{ks.count} fontes, #{chunk_count(ks)} chunks" : nil),
      'Tools' => feat(tools.exists?, tools.exists? ? "#{tools.count} (#{tool_breakdown(tools)})" : nil),
      'Etapas (playbook)' => feat(steps.any?, ("#{steps.size} steps" if steps.any?)),
      'Automações de etapa' => feat(autos.any?, autos.any? ? "#{autos.size} (#{automation_breakdown(autos)})" : nil),
      'Lead variables' => feat(dept.lead_variables.exists?, ("#{dept.lead_variables.count}" if dept.lead_variables.exists?)),
      'Follow-up' => feat(followup_behaviors(dept).any?, ("#{followup_behaviors(dept).size} comportamentos" if followup_behaviors(dept).any?)),
      'Finalização' => feat(close_configured?(dept)),
      'Transfer rules' => feat(dept.transfer_rules.to_h.present?, transfer_detail(dept)),
      'Copilot (config)' => feat(dept.copilot_config.to_h.present?, 'scaffold: config não lida no fluxo ativo')
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

  def rollup
    depts = @agent.departments.active.to_a
    {
      rag_departments: "#{depts_with_rag(depts)}/#{depts.size}",
      chunks_total: chunk_count(Ai::KnowledgeSource.active.where(ai_department_id: depts.map(&:id))),
      tools_total: total_tools(depts),
      automations_total: total_automations(depts),
      followup_departments: "#{depts_with_followup(depts)}/#{depts.size}",
      handoff_ia: Array(@agent.handoff_agent_ids).size
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

  def playbook_steps(dept)
    Array(dept.playbook&.steps).select { |s| s.is_a?(Hash) }
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

  def followup_behaviors(dept)
    Array(dept.follow_up.to_h['behaviors'])
  end

  def close_configured?(dept)
    dept.close_rules.to_h.present? || dept.playbook&.close_when.present?
  end

  def transfer_detail(dept)
    mc = dept.transfer_rules.to_h['min_confidence']
    mc.present? ? "min_confidence=#{mc}" : nil
  end

  def depts_with_rag(depts)
    depts.to_a.count { |d| d.knowledge_sources.active.exists? }
  end

  def depts_with_followup(depts)
    depts.to_a.count { |d| followup_behaviors(d).any? }
  end

  def total_tools(depts)
    depts.to_a.sum { |d| d.tools.active.count }
  end

  def total_automations(depts)
    depts.to_a.sum { |d| playbook_steps(d).flat_map { |s| Array(s['automations'] || s[:automations]) }.size }
  end

  # -------- Render de texto --------

  def self.render_text(report)
    a = report[:agent]
    out = []
    out << "AGENTE ##{a[:id]} — #{a[:name].inspect} (assistant: #{a[:assistant_name]})  " \
           "[conta=#{a[:account_id]} stage=#{a[:stage]} status=#{a[:status]}]"
    report[:agent_features].each { |label, f| out << "  #{label.ljust(20)}: #{fmt(f)}" }

    out << ''
    out << "  DEPARTMENTS (#{report[:departments].size})"
    if report[:departments].empty?
      out << '    (nenhum department — atenção: o Gateway exige department resolvido para responder)'
    end
    report[:departments].each do |d|
      tag = d[:is_default] ? ' (default)' : ''
      out << "  - ##{d[:id]} #{d[:name].inspect}#{tag}"
      d[:features].each { |label, f| out << "      #{label.ljust(20)}: #{fmt(f)}" }
    end

    out << ''
    out << '  TRANSVERSAIS (por conta, não por agente)'
    report[:cross_account].each { |label, f| out << "    #{label.ljust(20)}: #{fmt(f)}" }

    out << ''
    r = report[:rollup]
    out << "  ROLLUP: RAG #{r[:rag_departments]} depts (#{r[:chunks_total]} chunks) · " \
           "Tools #{r[:tools_total]} · Automações #{r[:automations_total]} · " \
           "Follow-up #{r[:followup_departments]} · Handoff IA #{r[:handoff_ia]}"
    out.join("\n")
  end

  def self.fmt(feature)
    yn = feature[:in_use] ? 'sim' : 'não'
    feature[:detail].present? ? "#{yn} — #{feature[:detail]}" : yn
  end
end
