# Auditoria READ-ONLY de recursos de um agente de IA (RAG, tools, automações de etapa, handoff,
# follow-up, copilot, etc.). Só leitura — nenhuma escrita. Lógica em Ai::FeaturesAuditor.
#
#   bundle exec rails "ai:agent_features_audit[42]"        # um agente (texto)
#   bundle exec rails "ai:agent_features_audit"            # resumo de todos os agentes
#   FORMAT=json bundle exec rails "ai:agent_features_audit[42]"   # saída JSON
namespace :ai do
  desc 'Audita quais recursos (RAG/tools/automações/handoff/follow-up/copilot/...) um agente de IA usa'
  task :agent_features_audit, %i[agent_id] => :environment do |_t, args|
    json = ENV['FORMAT'].to_s.downcase == 'json'

    if args[:agent_id].present?
      agent = Ai::Agent.find_by(id: args[:agent_id])
      abort("Agente ##{args[:agent_id]} não encontrado.") unless agent

      report = Ai::FeaturesAuditor.new(agent).report
      puts(json ? JSON.pretty_generate(report) : Ai::FeaturesAuditor.render_text(report))
    else
      agents = Ai::Agent.order(:account_id, :id).to_a
      abort('Nenhum agente de IA nesta instalação.') if agents.empty?

      if json
        puts JSON.pretty_generate(agents.map { |a| Ai::FeaturesAuditor.new(a).report })
      else
        agents.each { |a| puts Ai::FeaturesAuditor.new(a).summary_line }
      end
    end
  end
end

# python_orchestrator não tem UI (Ai::Gateway#python_orchestrator_on?, comportamento default OFF —
# agentes sem a chave continuam byte-idênticos ao caminho legado decide()/call_with_tools()). Só
# um rails console/runner ligava a flag até aqui; estas tasks substituem isso por um comando único,
# continuam opt-in POR agente (nunca ligam pra ninguém além do id passado) — deliberadamente NÃO
# um default automático ligado a ter Ai::AgentInbox ativo, que migraria 100% da base de uma vez.
namespace :ai do
  desc 'Liga behavior[\'python_orchestrator\'] = true para UM agente (opt-in, sem console)'
  task :enable_python_orchestrator, %i[agent_id] => :environment do |_t, args|
    agent = Ai::Agent.find_by(id: args[:agent_id])
    abort("Agente ##{args[:agent_id]} não encontrado.") unless agent

    agent.update!(behavior: agent.behavior.to_h.merge('python_orchestrator' => true))
    puts "Agente ##{agent.id} (#{agent.name}): python_orchestrator = true"
  end

  desc 'Desliga behavior[\'python_orchestrator\'] para UM agente (volta ao caminho legado)'
  task :disable_python_orchestrator, %i[agent_id] => :environment do |_t, args|
    agent = Ai::Agent.find_by(id: args[:agent_id])
    abort("Agente ##{args[:agent_id]} não encontrado.") unless agent

    agent.update!(behavior: agent.behavior.to_h.merge('python_orchestrator' => false))
    puts "Agente ##{agent.id} (#{agent.name}): python_orchestrator = false"
  end
end

# Item 3 do usuário: identificar e (opcionalmente) remover Ai::LeadVariable órfãs — variáveis que
# nenhuma etapa do playbook ATUAL do agente referencia mais em collect.attribute. Lógica em
# Ai::LeadVariableOrphanFinder (mesma definição de "em uso" que já bloqueia exclusão manual pela tela).
def ai_rake_print_orphans(agent, orphans)
  puts "Agente ##{agent.id} (#{agent&.name}): #{orphans.size} órfã(s)"
  orphans.each { |v| puts "  ##{v.id} #{v.name}" }
end

def ai_rake_orphan_report_for_agent(agent, json)
  orphans = Ai::LeadVariableOrphanFinder.for_agent(agent)
  if json
    puts JSON.pretty_generate(orphans.map { |v| { id: v.id, name: v.name, agent_id: agent.id } })
  else
    ai_rake_print_orphans(agent, orphans)
  end
end

def ai_rake_prune_orphans(agent, orphans)
  if orphans.empty?
    puts "Agente ##{agent.id} (#{agent.name}): nenhuma órfã para remover."
    return
  end

  unless ENV['CONFIRM'] == 'true'
    puts "[DRY RUN] Removeria #{orphans.size} LeadVariable(s) órfã(s) do agente ##{agent.id} (#{agent.name}):"
    orphans.each { |v| puts "  ##{v.id} #{v.name}" }
    puts 'Rode de novo com CONFIRM=true para remover de verdade.'
    return
  end

  removed = orphans.map { |v| "##{v.id} #{v.name}" }
  orphans.each(&:destroy!)
  puts "Removidas #{removed.size} LeadVariable(s) órfã(s) do agente ##{agent.id} (#{agent.name}):"
  removed.each { |r| puts "  #{r}" }
end

def ai_rake_orphan_report_for_all(json)
  by_agent = Ai::LeadVariableOrphanFinder.all.group_by(&:ai_agent_id)
  if json
    puts JSON.pretty_generate(
      by_agent.map { |agent_id, vars| { agent_id: agent_id, orphans: vars.map { |v| { id: v.id, name: v.name } } } }
    )
  elsif by_agent.empty?
    puts 'Nenhuma LeadVariable órfã em nenhum agente.'
  else
    by_agent.each { |agent_id, vars| ai_rake_print_orphans(Ai::Agent.find_by(id: agent_id), vars) }
  end
end

namespace :ai do
  desc 'Lista Ai::LeadVariable órfãs (READ-ONLY). Sem args: todo o sistema; com agent_id: só esse agente.'
  task :lead_variables_orphan_report, %i[agent_id] => :environment do |_t, args|
    json = ENV['FORMAT'].to_s.downcase == 'json'

    if args[:agent_id].present?
      agent = Ai::Agent.find_by(id: args[:agent_id])
      abort("Agente ##{args[:agent_id]} não encontrado.") unless agent

      ai_rake_orphan_report_for_agent(agent, json)
    else
      ai_rake_orphan_report_for_all(json)
    end
  end

  desc 'Remove as LeadVariable órfãs de UM agente. Dry-run por padrão; CONFIRM=true remove de fato.'
  task :prune_orphan_lead_variables, %i[agent_id] => :environment do |_t, args|
    agent = Ai::Agent.find_by(id: args[:agent_id])
    abort("Agente ##{args[:agent_id]} não encontrado.") unless agent

    # Recalcula na hora do delete (não reaproveita um relatório antigo) para não apagar uma variável que
    # passou a ser usada por uma etapa nova entre o relatório e a execução desta task.
    orphans = Ai::LeadVariableOrphanFinder.for_agent(agent)
    ai_rake_prune_orphans(agent, orphans)
  end
end

# Item 4 do usuário: achou ao vivo plano_escolhido/registrar_plano_escolhido e viabilidade/
# registrar_viabilidade como pares duplicados (prefixo reservado "registrar_" do design antigo de
# function-calling grudado no nome). Só identifica — não apaga nada. Lógica em Ai::VariableDuplicateFinder.
def ai_rake_print_lead_dupes(lead_dupes)
  return if lead_dupes.empty?

  puts "LeadVariable duplicadas (#{lead_dupes.size}):"
  lead_dupes.each do |d|
    agent = Ai::Agent.find_by(id: d[:agent_id])
    puts "  agente ##{d[:agent_id]} (#{agent&.name}): '#{d[:base]}' (##{d[:base_id]}) <-> " \
         "'#{d[:duplicate]}' (##{d[:duplicate_id]})"
  end
end

def ai_rake_print_attr_dupes(attr_dupes)
  return if attr_dupes.empty?

  puts "CustomAttributeDefinition duplicadas (#{attr_dupes.size}):"
  attr_dupes.each do |d|
    puts "  account ##{d[:account_id]} [#{d[:attribute_model]}]: '#{d[:base]}' (##{d[:base_id]}) <-> " \
         "'#{d[:duplicate]}' (##{d[:duplicate_id]})"
  end
end

namespace :ai do
  desc 'Lista LeadVariable e CustomAttributeDefinition duplicadas pelo prefixo "registrar_" (READ-ONLY)'
  task :variable_duplicates_report, %i[account_id] => :environment do |_t, args|
    json = ENV['FORMAT'].to_s.downcase == 'json'

    account = nil
    if args[:account_id].present?
      account = Account.find_by(id: args[:account_id])
      abort("Conta ##{args[:account_id]} não encontrada.") unless account
    end

    lead_dupes = Ai::VariableDuplicateFinder.lead_variable_duplicates
    attr_dupes = Ai::VariableDuplicateFinder.custom_attribute_duplicates

    if account
      agent_ids = Ai::Agent.where(account_id: account.id).pluck(:id)
      lead_dupes = lead_dupes.select { |d| agent_ids.include?(d[:agent_id]) }
      attr_dupes = attr_dupes.select { |d| d[:account_id] == account.id }
    end

    if json
      puts JSON.pretty_generate(lead_variable_duplicates: lead_dupes, custom_attribute_duplicates: attr_dupes)
    elsif lead_dupes.empty? && attr_dupes.empty?
      puts 'Nenhuma duplicata encontrada.'
    else
      ai_rake_print_lead_dupes(lead_dupes)
      ai_rake_print_attr_dupes(attr_dupes)
    end
  end
end

# Pedido do usuário: antes de eliminar o motor legado (decide()/call_with_tools()) e tornar o Python o
# ÚNICO motor, listar quem só funciona direito no legado hoje. READ-ONLY — lógica em
# Ai::PythonMigrationAuditor.
namespace :ai do
  desc 'Lista agentes que quebrariam se o motor legado fosse eliminado agora (provider != openai, automações de etapa)'
  task python_migration_audit: :environment do
    report = Ai::PythonMigrationAuditor.report
    puts '=' * 70
    puts '1. PROVIDER != OPENAI — orchestrator.py só chama a OpenAI, sempre'
    puts '=' * 70
    if report[:non_openai_provider].empty?
      puts '  Nenhum. Todo agente roteado hoje usa (ou cairia no default) provider openai.'
    else
      report[:non_openai_provider].each do |a|
        puts "  agente ##{a[:agent_id]} (#{a[:name]}, conta #{a[:account_id]}): provider=#{a[:provider]}"
      end
    end
    puts "\n#{'=' * 70}"
    puts '2. AUTOMAÇÕES DE ETAPA — nunca disparam no branch do Python (Ai::Gateway#run faz `return`'
    puts '   antes de chegar em Ai::StateManager#track_step/#fire_step_automations)'
    puts '=' * 70
    if report[:step_automations].empty?
      puts '  Nenhum. Nenhum playbook ativo tem etapa com automations configurada.'
    else
      report[:step_automations].each do |a|
        puts "  agente ##{a[:agent_id]} (#{a[:name]}, conta #{a[:account_id]}): etapas #{a[:step_names].join(', ')}"
      end
    end
    puts "\n#{'=' * 70}"
    puts '3. ALCANCE — quantos agentes seriam movidos se a flag sumisse'
    puts '=' * 70
    puts "  já no Python: #{report[:engine_split][:on_python]}  |  ainda no legado (seriam movidos): #{report[:engine_split][:on_legacy]}"
    total_blockers = report[:non_openai_provider].size + report[:step_automations].size
    puts "\n#{'=' * 70}"
    if total_blockers.zero?
      puts '  Nenhum blocker encontrado nestes 2 pontos.'
    else
      puts "  #{total_blockers} agente(s) com pelo menos 1 blocker — NÃO eliminar o legado sem tratar esses casos."
    end
    puts '=' * 70
  end

  desc 'Diagnostica por que o Python não recebe requisição pra UMA conversa (Sidekiq, Ai::Run, python_orchestrator_on?, chamada direta em shadow)'
  task :diagnose_python_orchestrator, %i[conversation_id] => :environment do |_t, args|
    conversation = Conversation.find_by(id: args[:conversation_id])
    abort("Conversation ##{args[:conversation_id]} não encontrada.") unless conversation
    puts '=' * 70
    puts "1. SIDEKIQ — fila 'medium' (Ai::GatewayRunJob) e falhas"
    puts '=' * 70
    sidekiq = Ai::PythonOrchestratorDiagnostics.sidekiq_status
    if sidekiq[:error]
      puts "  erro consultando Sidekiq: #{sidekiq[:error]}"
    else
      puts "  fila medium: #{sidekiq[:medium_queue_size]} job(s) pendente(s)"
      puts "  retry set: #{sidekiq[:gateway_run_job_retrying]} Ai::GatewayRunJob em retry"
      puts "  dead set:  #{sidekiq[:gateway_run_job_dead]} Ai::GatewayRunJob morto(s)"
    end
    puts "\n#{'=' * 70}"
    puts '2. AI::RUN — últimos runs desta conversa'
    puts '=' * 70
    runs = Ai::PythonOrchestratorDiagnostics.recent_runs(conversation)
    if runs.empty?
      puts '  NENHUM Ai::Run encontrado — o Gateway nunca rodou pra essa conversa (problema é ANTES do Gateway).'
    else
      runs.each { |r| puts "  ##{r[:id]} #{r[:created_at]} status=#{r[:status]} error_type=#{r[:error_type]} agent_id=#{r[:agent_id]}" }
    end
    puts "\n#{'=' * 70}"
    puts '3. PYTHON_ORCHESTRATOR_ON? — valor real por agente candidato'
    puts '=' * 70
    flags = Ai::PythonOrchestratorDiagnostics.flag_status(conversation)
    if flags.empty?
      puts '  Não achei nenhum agente candidato (nem via Ai::Run, nem via Ai::AgentInbox desta inbox).'
    else
      flags.each { |f| puts "  agente ##{f[:agent_id]} (#{f[:name]}): raw=#{f[:raw].inspect} class=#{f[:raw_class]} => #{f[:on]}" }
    end
    puts "\n#{'=' * 70}"
    puts "4. CHAMADA DIRETA (mode: 'shadow' forçado — nunca muta dado real, gasta tokens de verdade)"
    puts '=' * 70
    direct = Ai::PythonOrchestratorDiagnostics.direct_call(conversation)
    if direct[:skipped]
      puts "  #{direct[:skipped]}"
    elsif direct[:exception]
      puts "  !!! EXCEÇÃO (isso é o que o rescue silencioso normalmente esconde): #{direct[:exception]}"
      direct[:backtrace].each { |l| puts "      #{l}" }
    else
      puts "  agente: ##{direct[:agent_id]} (#{direct[:agent_name]})"
      puts "  resultado: #{direct[:result].inspect}"
      if direct[:result][:reply].present?
        puts '  -> a chamada FUNCIONOU (Python respondeu).'
      else
        puts "  -> reply veio vazio/nil — ver logs do ai-orchestrator e do Rails pro ticket_id=#{conversation.id}."
      end
    end
  end
end
