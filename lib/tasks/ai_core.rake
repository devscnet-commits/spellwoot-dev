# Helpers for the AI Core vertical slice (Comercial, shadow). Run in SANDBOX only.
#
#   bundle exec rails "ai_core:seed_comercial[ACCOUNT_ID,TEST_INBOX_ID]"
#   bundle exec rails "ai_core:inspect[CONVERSATION_ID]"
namespace :ai_core do
  desc 'Seed the Comercial vertical slice in shadow mode for a given account + test inbox'
  task :seed_comercial, %i[account_id inbox_id] => :environment do |_t, args|
    account = Account.find(args[:account_id])
    inbox = account.inboxes.find(args[:inbox_id])

    profile = Ai::OperationProfile.find_or_create_by!(account_id: account.id, name: 'balanceado') do |p|
      p.supervisor_provider = 'anthropic'
      # Adjust to a model id available in your provider config (RubyLLM/Anthropic).
      p.supervisor_model = 'claude-3-5-sonnet-latest'
      p.budget = { 'monthly_usd' => 50 }
    end

    agent = Ai::Agent.find_or_create_by!(account_id: account.id, name: 'Comercial IA (teste)') do |a|
      a.stage = 'sandbox'
      a.ai_operation_profile_id = profile.id
      a.assistant_name = 'Assistente'
      a.assistant_language = 'pt-BR'
      a.assistant_personality = 'Cordial, objetiva e consultiva.'
      a.base_prompt = 'Você atende clientes interessados em contratar os serviços da empresa.'
      a.guardrails = 'Nunca invente preços, prazos ou cobertura. Se não souber, transfira para um humano.'
    end

    Ai::AgentInbox.find_or_create_by!(ai_agent_id: agent.id, inbox_id: inbox.id) do |b|
      b.mode = 'shadow'
      b.active = true
      b.priority = 1
    end

    department = Ai::Department.find_or_create_by!(ai_agent_id: agent.id, name: 'Comercial') do |d|
      d.account_id = account.id
      d.objetivo = 'Converter leads em clientes'
      d.transfer_rules = { 'when' => ['cliente pedir humano', 'negociação especial'] }
      d.close_rules = { 'when' => ['SLA estourar sem resposta do cliente'] }
    end

    Ai::Playbook.find_or_create_by!(ai_department_id: department.id) do |pb|
      pb.objetivo = department.objetivo
      pb.steps = ['Qualificar', 'Apresentar proposta', 'Coletar documentos', 'Transferir para vendedor']
      pb.transfer_when = ['Cliente pedir humano', 'Cliente solicitar negociação especial', 'Confiança baixa']
      pb.close_when = ['SLA estourar sem resposta do cliente']
      pb.default_messages = { 'greeting' => 'Olá! Posso te ajudar com nossos planos?' }
      pb.active = true
    end

    Ai::Tool.find_or_create_by!(account_id: account.id, ai_department_id: department.id, name: 'Consultar Lead') do |tool|
      tool.description = 'Consulta os dados do lead/contato atual.'
      tool.implementation_type = 'capability'
      tool.capability_key = 'contact.read'
      tool.input_schema = { 'contact_id' => 'integer' }
      tool.governance = 'allowed'
    end

    Ai::Tool.find_or_create_by!(account_id: account.id, ai_department_id: department.id, name: 'Registrar Lead') do |tool|
      tool.description = 'Registra/atualiza dados do lead (nome, interesse, etapa).'
      tool.implementation_type = 'capability'
      tool.capability_key = 'contact.update_attributes'
      tool.input_schema = { 'nome' => 'string', 'interesse' => 'string', 'etapa' => 'string' }
      tool.governance = 'require_confirmation'
    end

    source = Ai::KnowledgeSource.find_or_create_by!(account_id: account.id, ai_department_id: department.id, title: 'FAQ Comercial') do |s|
      s.kind = 'faq'
      s.raw = 'FAQ comercial de exemplo'
    end

    faqs = [
      'Trabalhamos com planos mensais e anuais; o anual tem desconto.',
      'A cobertura depende da região; confirmamos pelo CEP do cliente.',
      'A instalação ocorre em até 5 dias úteis após a contratação.',
      'Aceitamos pagamento via boleto, cartão e Pix.'
    ]
    faqs.each do |content|
      next if source.chunks.exists?(content: content)

      embedding = begin
        defined?(Captain::Llm::EmbeddingService) ? Captain::Llm::EmbeddingService.new(account_id: account.id).get_embedding(content) : nil
      rescue StandardError => e
        Rails.logger.warn "[ai_core:seed] embedding indisponível: #{e.message}"
        nil
      end
      source.chunks.create!(content: content, embedding: embedding.presence)
    end

    puts "OK: slice Comercial (shadow) criada para account=#{account.id} inbox=#{inbox.id} agent=#{agent.id}."
    puts 'Envie uma mensagem de entrada nessa caixa e rode: rails "ai_core:inspect[CONVERSATION_ID]"'
  end

  desc 'Inspect the shadow run(s) recorded for a conversation'
  task :inspect, %i[conversation_id] => :environment do |_t, args|
    runs = Ai::Run.where(conversation_id: args[:conversation_id]).order(created_at: :desc)
    if runs.empty?
      puts "Nenhum ai_run para a conversa #{args[:conversation_id]}."
      next
    end

    runs.each do |run|
      events = Ai::Event.where(conversation_id: run.conversation_id).order(:created_at)
      dept = events.find { |e| e.event_type == 'department.resolved' }&.payload
      knowledge = events.find { |e| e.event_type == 'knowledge.retrieved' }&.payload
      tool = events.find { |e| e.event_type == 'tool.intended' }&.payload

      puts '────────────────────────────────────────'
      puts "RUN ##{run.id}  (mode=#{run.mode}, status=#{run.status})"
      puts "Agente resolvido:     #{run.ai_agent_id}"
      puts "Departamento:         #{dept&.dig('name')}"
      puts "Conhecimento (qtd):   #{knowledge&.dig('count')}"
      puts "Resposta que SERIA enviada: #{run.decision['reply_text']}"
      puts "Ferramenta que SERIA chamada: #{tool&.dig('tool')&.to_json || '—'} (executada? #{tool ? 'NÃO (shadow)' : 'n/a'})"
      puts "Provider/Model:       #{run.provider} / #{run.model}"
      puts "Custo estimado (USD): #{run.cost}"
      puts "Latência (ms):        #{run.latency_ms}"
    end
  end
end
