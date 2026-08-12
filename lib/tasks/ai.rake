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
# departments sem a chave continuam byte-idênticos ao caminho legado decide()/call_with_tools()). Só
# um rails console/runner ligava a flag até aqui; estas tasks substituem isso por um comando único,
# continuam opt-in POR department (nunca ligam pra ninguém além do id passado) — deliberadamente NÃO
# um default automático ligado a ter Ai::AgentInbox ativo, que migraria 100% da base de uma vez.
namespace :ai do
  desc 'Liga behavior[\'python_orchestrator\'] = true para UM department (opt-in, sem console)'
  task :enable_python_orchestrator, %i[department_id] => :environment do |_t, args|
    department = Ai::Department.find_by(id: args[:department_id])
    abort("Department ##{args[:department_id]} não encontrado.") unless department

    department.update!(behavior: department.behavior.to_h.merge('python_orchestrator' => true))
    puts "Department ##{department.id} (#{department.name}): python_orchestrator = true"
  end

  desc 'Desliga behavior[\'python_orchestrator\'] para UM department (volta ao caminho legado)'
  task :disable_python_orchestrator, %i[department_id] => :environment do |_t, args|
    department = Ai::Department.find_by(id: args[:department_id])
    abort("Department ##{args[:department_id]} não encontrado.") unless department

    department.update!(behavior: department.behavior.to_h.merge('python_orchestrator' => false))
    puts "Department ##{department.id} (#{department.name}): python_orchestrator = false"
  end
end

# Pedido do usuário: antes de eliminar o motor legado (decide()/call_with_tools()) e tornar o Python o
# ÚNICO motor, listar quem só funciona direito no legado hoje. READ-ONLY — lógica em
# Ai::PythonMigrationAuditor.
namespace :ai do
  desc 'Lista departments que quebrariam se o motor legado fosse eliminado agora (provider != openai, automações de etapa)'
  task python_migration_audit: :environment do
    report = Ai::PythonMigrationAuditor.report

    puts '=' * 70
    puts '1. PROVIDER != OPENAI — orchestrator.py só chama a OpenAI, sempre'
    puts '=' * 70
    if report[:non_openai_provider].empty?
      puts '  Nenhum. Todo department roteado hoje usa (ou cairia no default) provider openai.'
    else
      report[:non_openai_provider].each do |d|
        puts "  department ##{d[:department_id]} (#{d[:name]}, conta #{d[:account_id]}): provider=#{d[:provider]}"
      end
    end

    puts "\n#{'=' * 70}"
    puts '2. AUTOMAÇÕES DE ETAPA — nunca disparam no branch do Python (Ai::Gateway#run faz `return`'
    puts '   antes de chegar em Ai::StateManager#track_step/#fire_step_automations)'
    puts '=' * 70
    if report[:step_automations].empty?
      puts '  Nenhum. Nenhum playbook ativo tem etapa com automations configurada.'
    else
      report[:step_automations].each do |d|
        puts "  department ##{d[:department_id]} (#{d[:name]}, conta #{d[:account_id]}): etapas #{d[:step_names].join(', ')}"
      end
    end

    puts "\n#{'=' * 70}"
    puts '3. ALCANCE — quantos departments seriam movidos se a flag sumisse'
    puts '=' * 70
    puts "  já no Python: #{report[:engine_split][:on_python]}  |  ainda no legado (seriam movidos): #{report[:engine_split][:on_legacy]}"

    total_blockers = report[:non_openai_provider].size + report[:step_automations].size
    puts "\n#{'=' * 70}"
    if total_blockers.zero?
      puts '  Nenhum blocker encontrado nestes 2 pontos.'
    else
      puts "  #{total_blockers} department(s) com pelo menos 1 blocker — NÃO eliminar o legado sem tratar esses casos."
    end
    puts '=' * 70
  end
end
