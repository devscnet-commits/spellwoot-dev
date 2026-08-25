# Diagnóstico do bug URGENTE ao vivo: "Python em silêncio total desde o deploy, conectividade Rails->
# Python confirmada OK via Net::HTTP manual". Cada método devolve DADOS estruturados, não texto — quem
# formata pro terminal é a rake task (lib/tasks/ai.rake, ai:diagnose_python_orchestrator), então cada
# passo dá pra testar direto (RSpec) sem parsear print.
#
# READ-ONLY quanto a dado real: a ÚNICA chamada que toca rede/custa tokens é #direct_call, e ela FORÇA
# mode: 'shadow' — Api::Internal::AiExecuteToolController só muta o banco quando mode == 'live' (ver
# #capture_attribute/#save_memory/#advance_step/#run_capability, todos gateados por #live?) — então
# mesmo essa chamada não altera nenhuma conversa/contato real, e nunca manda mensagem ao cliente (quem
# fala com o WhatsApp é Ai::Gateway#action_dispatcher, que este service NUNCA chama — só o
# Ai::PythonOrchestratorClient é exercitado diretamente).
module Ai::PythonOrchestratorDiagnostics
  module_function

  # --- Passo 1: o job (Ai::GatewayRunJob) está sendo enfileirado/processado, ou empacando? -----------
  # Ai::GatewayRunJob#perform NÃO tem rescue próprio — se algo ANTES de "Ai::Gateway.new(...).run"
  # explodir (Ai::LocationNormalizer tem rescue próprio; Ai::MessageGrouping/a query de bindings não
  # têm), o job inteiro falha e cai no retry/dead set do Sidekiq — SEM NUNCA criar um Ai::Run, sem
  # nunca cogitar o Python. Fila 'medium' é onde Ai::GatewayRunJob roda (queue_as :medium, no job).
  def sidekiq_status
    require 'sidekiq/api'
    {
      medium_queue_size: Sidekiq::Queue.new('medium').size,
      gateway_run_job_retrying: Sidekiq::RetrySet.new.count { |j| j.klass == 'Ai::GatewayRunJob' },
      gateway_run_job_dead: Sidekiq::DeadSet.new.count { |j| j.klass == 'Ai::GatewayRunJob' }
    }
  rescue StandardError => e
    { error: "#{e.class}: #{e.message}" }
  end

  # --- Passo 2: o Gateway#run sequer CHEGOU a rodar pra essa conversa? --------------------------------
  # Ai::Run.create! é a PRIMEIRA linha de Ai::Gateway#run — sem run recente, o problema é ANTES do
  # Gateway (job não enfileirado, ou falhou antes dessa linha). Com run mas status='error', o problema
  # tá DENTRO do Gateway (o rescue de método inteiro) — ANTES de chegar no branch do Python, que teria
  # seu próprio decision.made com source: 'python_orchestrator'.
  def recent_runs(conversation, limit: 5)
    Ai::Run.where(conversation_id: conversation.id).order(created_at: :desc).limit(limit)
           .pluck(:id, :created_at, :status, :error_type, :ai_agent_id)
           .map do |id, created_at, status, error_type, agent_id|
      { id: id, created_at: created_at, status: status, error_type: error_type, agent_id: agent_id }
    end
  end

  # --- Passo 3: python_orchestrator_on? bate o esperado pro agente real? ------------------------------
  # raw.class importa: string truthy ("true") só passa desde a correção que aceita os dois formatos —
  # se esse fix ainda não subiu no ambiente checado, uma flag gravada como STRING ainda cai no legado
  # SEM exceção nenhuma (sintoma idêntico a "Python em silêncio total").
  def flag_status(conversation)
    agent_ids = Ai::Run.where(conversation_id: conversation.id).distinct.pluck(:ai_agent_id).compact
    agent_ids = candidate_agent_ids(conversation) if agent_ids.empty?
    return [] if agent_ids.empty?

    Ai::Agent.where(id: agent_ids).map do |a|
      raw = a.behavior.to_h['python_orchestrator']
      { agent_id: a.id, name: a.name, raw: raw, raw_class: raw.class.to_s, on: truthy?(raw) }
    end
  end

  # --- Passo 4: reproduz a chamada de verdade (rede real, tokens reais) — mode: 'shadow' SEMPRE. Se
  # EXPLODIR aqui, é exatamente o que os rescues silenciosos (Ai::Gateway#run e
  # Ai::PythonOrchestratorClient#perform) escondem hoje em produção — devolvemos a exceção CRUA em vez
  # de engolir, é o ponto inteiro deste diagnóstico.
  def direct_call(conversation)
    message = conversation.messages.incoming.order(:created_at).last
    return { skipped: 'sem mensagem incoming nesta conversa' } if message.nil?

    binding = Ai::AgentInbox.where(inbox_id: conversation.inbox_id, active: true).first
    return { skipped: 'nenhum Ai::AgentInbox ativo nesta inbox' } if binding.nil?

    agent = binding.agent

    result = Ai::PythonOrchestratorClient.process_message(
      conversation: conversation, content: message.content, agent: agent,
      mode: 'shadow', message: message
    )
    { agent_id: agent.id, agent_name: agent.name, result: result }
  rescue StandardError => e
    { exception: "#{e.class}: #{e.message}", backtrace: e.backtrace.first(10) }
  end

  def candidate_agent_ids(conversation)
    Ai::AgentInbox.where(inbox_id: conversation.inbox_id, active: true).pluck(:ai_agent_id).uniq
  end

  def truthy?(value)
    value == true || value.to_s.strip.casecmp?('true')
  end
end
