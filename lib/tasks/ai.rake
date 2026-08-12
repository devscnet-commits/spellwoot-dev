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

# Item 3 do usuário: identificar e (opcionalmente) remover Ai::LeadVariable órfãs — variáveis que
# nenhuma etapa do playbook ATUAL do department referencia mais em collect.attribute. Lógica em
# Ai::LeadVariableOrphanFinder (mesma definição de "em uso" que já bloqueia exclusão manual pela tela).
def ai_rake_print_orphans(department, orphans)
  puts "Department ##{department.id} (#{department&.name}): #{orphans.size} órfã(s)"
  orphans.each { |v| puts "  ##{v.id} #{v.name}" }
end

def ai_rake_orphan_report_for_department(department, json)
  orphans = Ai::LeadVariableOrphanFinder.for_department(department)
  if json
    puts JSON.pretty_generate(orphans.map { |v| { id: v.id, name: v.name, department_id: department.id } })
  else
    ai_rake_print_orphans(department, orphans)
  end
end

def ai_rake_prune_orphans(department, orphans)
  if orphans.empty?
    puts "Department ##{department.id} (#{department.name}): nenhuma órfã para remover."
    return
  end

  unless ENV['CONFIRM'] == 'true'
    puts "[DRY RUN] Removeria #{orphans.size} LeadVariable(s) órfã(s) do department ##{department.id} (#{department.name}):"
    orphans.each { |v| puts "  ##{v.id} #{v.name}" }
    puts 'Rode de novo com CONFIRM=true para remover de verdade.'
    return
  end

  removed = orphans.map { |v| "##{v.id} #{v.name}" }
  orphans.each(&:destroy!)
  puts "Removidas #{removed.size} LeadVariable(s) órfã(s) do department ##{department.id} (#{department.name}):"
  removed.each { |r| puts "  #{r}" }
end

def ai_rake_orphan_report_for_all(json)
  by_department = Ai::LeadVariableOrphanFinder.all.group_by(&:ai_department_id)
  if json
    puts JSON.pretty_generate(
      by_department.map { |dept_id, vars| { department_id: dept_id, orphans: vars.map { |v| { id: v.id, name: v.name } } } }
    )
  elsif by_department.empty?
    puts 'Nenhuma LeadVariable órfã em nenhum department.'
  else
    by_department.each { |dept_id, vars| ai_rake_print_orphans(Ai::Department.find_by(id: dept_id), vars) }
  end
end

namespace :ai do
  desc 'Lista Ai::LeadVariable órfãs (READ-ONLY). Sem args: todo o sistema; com department_id: só esse department.'
  task :lead_variables_orphan_report, %i[department_id] => :environment do |_t, args|
    json = ENV['FORMAT'].to_s.downcase == 'json'

    if args[:department_id].present?
      department = Ai::Department.find_by(id: args[:department_id])
      abort("Department ##{args[:department_id]} não encontrado.") unless department

      ai_rake_orphan_report_for_department(department, json)
    else
      ai_rake_orphan_report_for_all(json)
    end
  end

  desc 'Remove as LeadVariable órfãs de UM department. Dry-run por padrão; CONFIRM=true remove de fato.'
  task :prune_orphan_lead_variables, %i[department_id] => :environment do |_t, args|
    department = Ai::Department.find_by(id: args[:department_id])
    abort("Department ##{args[:department_id]} não encontrado.") unless department

    # Recalcula na hora do delete (não reaproveita um relatório antigo) para não apagar uma variável que
    # passou a ser usada por uma etapa nova entre o relatório e a execução desta task.
    orphans = Ai::LeadVariableOrphanFinder.for_department(department)
    ai_rake_prune_orphans(department, orphans)
  end
end

# Item 4 do usuário: achou ao vivo plano_escolhido/registrar_plano_escolhido e viabilidade/
# registrar_viabilidade como pares duplicados (prefixo reservado "registrar_" do design antigo de
# function-calling grudado no nome). Só identifica — não apaga nada. Lógica em Ai::VariableDuplicateFinder.
def ai_rake_print_lead_dupes(lead_dupes)
  return if lead_dupes.empty?

  puts "LeadVariable duplicadas (#{lead_dupes.size}):"
  lead_dupes.each do |d|
    department = Ai::Department.find_by(id: d[:department_id])
    puts "  department ##{d[:department_id]} (#{department&.name}): '#{d[:base]}' (##{d[:base_id]}) <-> " \
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
      dept_ids = Ai::Department.where(account_id: account.id).pluck(:id)
      lead_dupes = lead_dupes.select { |d| dept_ids.include?(d[:department_id]) }
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
