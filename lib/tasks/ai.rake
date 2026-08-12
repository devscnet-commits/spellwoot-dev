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

# Diagnóstico do bug URGENTE ao vivo: "Python em silêncio total desde o deploy, rede confirmada OK".
# Lógica em Ai::PythonOrchestratorDiagnostics (devolve DADOS, não texto — só formata aqui). READ-ONLY
# quanto a dado real: a ÚNICA chamada que toca rede/custa tokens é o passo 4, forçado em mode: 'shadow'
# (nunca muta conversa/contato — ver o comentário do service).
namespace :ai do
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
      runs.each { |r| puts "  ##{r[:id]} #{r[:created_at]} status=#{r[:status]} error_type=#{r[:error_type]} department_id=#{r[:department_id]}" }
    end

    puts "\n#{'=' * 70}"
    puts '3. PYTHON_ORCHESTRATOR_ON? — valor real por department candidato'
    puts '=' * 70
    flags = Ai::PythonOrchestratorDiagnostics.flag_status(conversation)
    if flags.empty?
      puts '  Não achei nenhum department candidato (nem via Ai::Run, nem via Ai::AgentInbox desta inbox).'
    else
      flags.each { |f| puts "  department ##{f[:department_id]} (#{f[:name]}): raw=#{f[:raw].inspect} class=#{f[:raw_class]} => #{f[:on]}" }
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
      puts "  department resolvido: ##{direct[:department_id]} (#{direct[:department_name]}), method=#{direct[:resolve_method]}"
      puts "  resultado: #{direct[:result].inspect}"
      if direct[:result][:reply].present?
        puts '  -> a chamada FUNCIONOU (Python respondeu).'
      else
        puts "  -> reply veio vazio/nil — ver logs do ai-orchestrator e do Rails pro ticket_id=#{conversation.id}."
      end
    end
  end
end
