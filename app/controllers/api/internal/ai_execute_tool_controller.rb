# Machine-to-machine endpoint called by the Python AI orchestrator, either mid function-calling loop
# (OpenAI invoking a Rails-side admin-configured tool) or — since the Structured Outputs refactor,
# orchestrator.py — for the five control actions Python itself dispatches from the model's parsed JSON
# reply (dados_coletados/avancar_etapa/transferir_humano/encerrar_atendimento): "registrar_*"/
# "salvar_memoria_ia" (Ai::StepCaptureTool / free-form save — a playbook step's collect slot, or
# anything else), "avancar_etapa" (agentic step advance — the model decides, not a server-side index
# gate), "conversation.resolve"/"conversation.transfer" (close/handoff), and "continuar_conversa"
# (legacy no-op, no longer called — kept recognized here for backward compatibility, harmless). None
# of these five are a configured Ai::Tool row — they're recognized by name, same as the legacy path's
# non-tool decision fields (handoff/close). Real (admin-configured) tools still delegate to the
# existing Ai::ToolExecutor/Ai::CapabilityRegistry framework — same audited path
# (Ai::CapabilityExecution) used by Ai::Gateway's own tool handling.
#
# Name translation: Ai::PythonOrchestratorClient SANITIZES every tool name before it reaches OpenAI
# (Ai::ToolNameSanitizer — OpenAI 400s on anything outside [a-zA-Z0-9_-], and Ai::CapabilityRegistry's
# whole convention is dotted keys). Python calls back with that SAME sanitized name, so every lookup
# here resolves it against the real candidate set (CONTROL_CAPABILITIES / the department's own tool
# names) instead of guessing what character a "_" used to be.
class Api::Internal::AiExecuteToolController < ActionController::API
  before_action :authenticate_internal_request!

  CONTROL_CAPABILITIES = [Ai::PythonOrchestratorClient::RESOLVE_TOOL, Ai::PythonOrchestratorClient::TRANSFER_TOOL].freeze

  def create
    conversation = ::Conversation.find(params[:ticket_id])
    department = Ai::Department.find(params[:ai_department_id])
    # Multi-tenant guard: the department must belong to the SAME account as the conversation. Without
    # this, a malformed/forged payload could execute one account's tool against another account's
    # conversation. This endpoint already sits behind the internal Bearer token (authenticate_internal_request!),
    # so 403 here doesn't expose anything to an unauthenticated caller — only to whoever already holds that token.
    unless department.account_id == conversation.account_id
      return render json: { error: 'forbidden' }, status: :forbidden
    end

    return render json: continue_conversation if params[:tool_name] == Ai::PythonOrchestratorClient::CONTINUE_TOOL

    return render json: advance_step(conversation, department) if params[:tool_name] == Ai::PythonOrchestratorClient::ADVANCE_STEP_TOOL

    control_key = resolve_control_capability(params[:tool_name])
    return render json: run_capability(conversation, department, control_key) if control_key

    attribute = Ai::StepCaptureTool.attribute_for(params[:tool_name])
    return render json: capture_attribute(conversation, department, attribute) if attribute

    return render json: save_memory(conversation, department) if params[:tool_name] == Ai::PythonOrchestratorClient::MEMORY_TOOL

    return render json: search_knowledge(department) if params[:tool_name] == Ai::PythonOrchestratorClient::KNOWLEDGE_TOOL

    tool = find_real_tool!(department, params[:tool_name])

    execution = Ai::ToolExecutor.new(
      tool: tool,
      input: arguments,
      conversation: conversation,
      mode: mode
    ).perform

    render json: { result: execution.output, status: execution.status, error: execution.error }
  rescue ActiveRecord::RecordNotFound => e
    render json: { error: e.message }, status: :not_found
  end

  private

  # nil when tool_name doesn't sanitize-match either control capability (not a control tool call).
  def resolve_control_capability(sanitized_name)
    CONTROL_CAPABILITIES.find { |key| Ai::ToolNameSanitizer.sanitize(key) == sanitized_name }
  end

  # Ai::Tool#name has no format validation — an admin could type spaces/accents/dots into it, which
  # Ai::PythonOrchestratorClient would ALSO have sanitized on the way out. Resolve against the
  # department's own (real, unsanitized) tool names before hitting the DB by name.
  def find_real_tool!(department, sanitized_name)
    tools = department.tools.active.to_a
    original_name = Ai::ToolNameSanitizer.resolve(sanitized_name, tools.map(&:name))
    tools.find { |t| t.name == original_name } ||
      raise(ActiveRecord::RecordNotFound, "Couldn't find Ai::Tool with name=#{sanitized_name.inspect}")
  end

  def mode
    params[:mode].presence || 'shadow'
  end

  # Same live/shadow discipline Ai::ToolExecutor already enforces for real tools — shadow never
  # mutates, it only records that the AI WOULD have acted, so a department piloted behind canary/
  # shadow doesn't leak side effects (step advance, resolve, transfer) into real conversation state.
  def live?
    mode == 'live'
  end

  def arguments
    params[:arguments].present? ? params[:arguments].to_unsafe_h : {}
  end

  # Upsert (Ai::StateManager#persist_attributes merges by key — calling this again with a corrected
  # value UPDATES ai_collected_facts, never duplicates).
  def capture_attribute(conversation, department, attribute)
    return { result: {}, status: 'skipped', error: nil } unless live?

    persist_and_report(conversation, department, attribute, arguments[attribute])
  end

  # Híbrido, deliberado (Ai::PythonOrchestratorClient::MEMORY_TOOL comment): "registrar_*" continua
  # sendo a via pra atributo JÁ conhecido (collect/CustomAttributeDefinition) — o NOME da tool garante
  # a chave exata, sem risco de a IA inventar uma chave livre que não bate com nenhum
  # CustomAttributeDefinition (já aconteceu neste projeto — "cidade_usuario" em vez de "cidade" — e o
  # espelhamento pra custom_attributes falhou em silêncio). "salvar_memoria_ia" é só pro que SOBRA:
  # contexto sem tool dedicada. Mesmo mecanismo de persistência (persist_attributes, source: :trusted,
  # sem gate) — se a IA por acaso usar uma chave que JÁ é um CustomAttributeDefinition real, espelha
  # igual a qualquer outro dado :trusted; não há proteção especial contra isso aqui, é o mesmo
  # comportamento de qualquer escrita confiável.
  def save_memory(conversation, department)
    return { result: {}, status: 'skipped', error: nil } unless live?

    chave = arguments['chave'].to_s.strip
    return { result: {}, status: 'skipped', error: 'chave vazia — nada foi registrado' } if chave.blank?

    persist_and_report(conversation, department, chave, arguments['valor'])
  end

  def persist_and_report(conversation, department, key, value)
    gated = Ai::StateManager.new(conversation: conversation, agent: department.agent)
                            .persist_attributes({ key => value }, department, source: :trusted)
    persisted = gated.key?(key)
    { result: { key => value }, status: persisted ? 'executed' : 'skipped',
      error: persisted ? nil : 'valor vazio — nada foi registrado' }
  end

  # RAG agentic (Ai::PythonOrchestratorClient::KNOWLEDGE_TOOL): a IA chamou "consultar_conhecimento" NO
  # MEIO do turno (function-calling de verdade, não um control tool disparado depois do JSON parseado —
  # ver comentário de #knowledge_tool). Roda em QUALQUER modo, live OU shadow: é leitura pura, sem
  # efeito colateral nenhum pra proteger — diferente de capture_attribute/save_memory/advance_step, que
  # gateiam por live? porque ESCREVEM estado da conversa. Isto fecha o gap de "RAG vazio silencioso": o
  # resultado da busca é sempre um function_call_output que a IA precisa processar, mesmo quando é
  # "nada encontrado" — nunca mais um bloco de prompt que simplesmente não aparece sem avisar ninguém.
  def search_knowledge(department)
    query = arguments['pergunta'].to_s.strip
    return { result: {}, status: 'skipped', error: 'pergunta vazia — nada foi buscado' } if query.blank?

    chunks = Ai::KnowledgeRetriever.retrieve(query: query, account_id: department.account_id, department_id: department.id)
    conteudo = chunks.present? ? chunks.join("\n---\n") : 'Nada encontrado na base de conhecimento para essa pergunta.'
    { result: { 'encontrado' => chunks.present?, 'conteudo' => conteudo }, status: 'executed', error: nil }
  rescue StandardError => e
    category = knowledge_error_category(e)
    Rails.logger.error "[Api::Internal::AiExecuteToolController#search_knowledge] #{category} #{e.class}: #{e.message}"
    # Categorizado (equivalente ao knowledge_timeout do motor legado — Ai::Run::ERROR_TYPES ainda lista
    # a categoria, só não tinha mais nenhum emissor vivo): sem isso, um timeout/erro na busca virava 500
    # cru pro Python, sem sinal nenhum de PORQUE a ferramenta falhou. Devolve como qualquer outra tool
    # (result/status/error) para a IA poder seguir a conversa em vez de travar o turno inteiro.
    { result: {}, status: 'failed', error: category }
  end

  # Nomes de classe (comparados por NOME, não pela constante — Faraday/PG podem não estar carregados
  # neste processo) que denotam timeout/queda de conexão. Mesmo critério de Ai::Gateway#timeout_error?,
  # duplicado aqui de propósito: este controller não referencia estado/instância do Gateway (mesmo
  # padrão de #execute_step_conclusion, que espelha Ai::Gateway#force_conclusion em vez de reusar).
  KNOWLEDGE_TIMEOUT_ERROR_NAMES = %w[
    Timeout::Error Net::OpenTimeout Net::ReadTimeout Errno::ETIMEDOUT
    Faraday::TimeoutError PG::QueryCanceled ActiveRecord::StatementTimeout ActiveRecord::QueryCanceled
  ].freeze

  def knowledge_error_category(exception)
    ancestors = exception.class.ancestors.filter_map(&:name)
    timed_out = (ancestors & KNOWLEDGE_TIMEOUT_ERROR_NAMES).any? || exception.message.to_s.downcase.include?('timeout')
    timed_out ? 'knowledge_timeout' : 'knowledge_search_failed'
  end

  # "continuar_conversa" (Ai::PythonOrchestratorClient::CONTINUE_TOOL): pure no-op, NEVER touches the
  # database — it exists only so tool_choice="required" (orchestrator.py) always has a safe option
  # when the model just wants to talk (greet, ask, answer) without registering data or advancing the
  # step. No live/shadow gate either: there's no side effect to distinguish.
  def continue_conversation
    { result: 'ok', status: 'executed', error: nil }
  end

  # Agentic step advance: the AI decides a step is done (or the customer declined an optional field)
  # and calls this — Rails only clamps at the last step and resets ai_step_turns (Ai::Gateway's
  # stuck-turn ceiling counts turns SINCE the last genuine advance, mirroring the legacy path's
  # Gap 4 semantics without reusing its decision-shaped Ai::StepResolver machinery).
  #
  # on_complete (desfecho declarado NA ETAPA que está sendo concluída — "Encerrar o atendimento" no
  # AiStepForm.vue): GAP real achado em auditoria (13/08) — nunca foi lido no caminho Python; a etapa
  # só avançava o índice, o desfecho configurado nunca disparava. Mesmo padrão de leitura de campo da
  # etapa que já existe pra transferir_humano/encerrar_atendimento (o Python NÃO injeta texto extra de
  # despedida aqui — a "mensagem_para_cliente" do próprio turno do modelo já é o texto ao cliente,
  # igual os outros dois campos; force_conclusion do motor legado injetava close_farewell porque ali o
  # texto do modelo era outra coisa — aqui NÃO é). Espelha Ai::Gateway#force_conclusion (motor legado)
  # nas 3 ações, sem reusar Ai::ActionDispatcher (não existe fora do Gateway) — usa Ai::CapabilityRegistry
  # direto, igual #run_capability já faz pras outras 2 control tools.
  # Bug ticket 557 (achado 13/08): avançava por ÍNDICE puro (current_index + 1), sem checar se a etapa
  # que estava sendo deixada tinha o dado obrigatório (step['collect']['attribute']) em
  # ai_collected_facts — um dado adiantado pra QUALQUER etapa futura era tratado como "pode avançar",
  # pulando etapas inteiras sem dado nenhum. Ai::StateManager#track_step faria essa validação (toda a
  # máquina de recusa de slot, Gap 1-4) mas só é chamado pelo Ai::Gateway#run LEGADO, deletado na
  # eliminação de hoje — o caminho Python nunca passou por ali. NÃO ressuscita StateManager/
  # StepResolver/TurnCapture — checagem nova e isolada, só pra este caminho.
  #
  # "Varredura" (decisão confirmada): se o cliente adiantou dados de VÁRIAS etapas seguintes na mesma
  # mensagem, uma ÚNICA chamada de avancar_etapa varre todas as etapas consecutivas já satisfeitas,
  # parando exatamente na primeira com dado obrigatório faltando — não trava etapa por etapa esperando
  # uma chamada por etapa. status 'blocked_missing_data' SÓ quando NENHUM avanço foi possível (a etapa
  # de PARTIDA já está sem o dado); se a varredura moveu pelo menos 1 posição antes de parar, é
  # 'executed' (progresso real aconteceu, só não foi até o fim).
  # Achado ao vivo (investigação da transferência prematura "conclusao"): a varredura cruzava uma
  # etapa INFORMATIVA (sem collect — ex.: "FINALIZAÇÃO", cujo desfecho configurado era "Transferir
  # para um time humano") e disparava o on_complete dela na hora, porque #missing_required_attributes
  # devolve [] pra etapa sem collect (nada a exigir) — nunca dava BREAK ali. O cliente nunca recebia a
  # mensagem daquela etapa (resumo, despedida): o desfecho executava mudo, no MEIO do turno que só
  # devia concluir a etapa ANTERIOR (comprovante de residência). Etapa informativa só pode concluir
  # (on_complete OU automações) quando é a PRÓPRIA que recebeu este avancar_etapa (index ==
  # start_index) — nunca de carona numa varredura vinda de etapa(s) anterior(es). Mesmo critério do
  # manual interno: "etapa sem dado é informativa: ela conclui quando o modelo diz que terminou, não
  # quando capturou algo" — motivo (index == start_index) É esse "o modelo disse que terminou ESTA".
  #
  # Segundo achado (mesma investigação): "Automações ao concluir etapa" (tag/webhook/mudar de
  # time/mudar de department/preencher atributo — Ai::StepAutomationRunner) nunca disparava no
  # caminho Python — só existia o disparo via Ai::StateManager#track_step, morto desde a eliminação
  # do motor legado (zero call sites). Religado aqui, mesma idempotência por índice
  # (ai_step_last_fired_index) que o caminho legado já usava — sobrevive a um retry de webhook
  # duplicado do Python sem repetir a automação.
  def advance_step(conversation, department)
    return { result: {}, status: 'skipped', error: nil } unless live?

    steps = Array(department.playbook&.steps)
    return { result: {}, status: 'skipped', error: 'sem etapas configuradas' } if steps.empty?

    attrs = conversation.additional_attributes || {}
    facts = attrs['ai_collected_facts'] || {}
    start_index = attrs['ai_step_index'].to_i.clamp(0, steps.size - 1)
    index = start_index

    loop do
      break if missing_required_attributes(steps[index], facts).any?

      current_step = steps[index]
      break if index != start_index && collect_attributes(current_step).empty?

      fire_step_automations(conversation, current_step, index)

      on_complete = current_step.is_a?(Hash) ? (current_step['on_complete'] || current_step[:on_complete]) : nil
      if on_complete.is_a?(Hash)
        # Persiste o índice ANTES do desfecho: este `return` pulava a gravação do fim do método, então
        # a etapa que acabou de ser concluída continuava sendo a "atual" no turno seguinte e
        # ai_step_turns seguia subindo até o stuck_handoff_turns — sempre que o desfecho configurado
        # NÃO encerrava a conversa (transferir, preencher atributo, mudar de time).
        persist_step_index(conversation, index)
        return execute_step_conclusion(conversation, department, on_complete)
      end

      break if index == steps.size - 1

      index += 1
    end

    if index == start_index && missing_required_attributes(steps[index], facts).any?
      return { result: { 'ai_step_index' => index }, status: 'blocked_missing_data', error: nil }
    end

    persist_step_index(conversation, index)
    { result: { 'ai_step_index' => index }, status: 'executed', error: nil }
  end

  # Relê os atributos do banco em vez de reusar o Hash lido no início de #advance_step: a varredura
  # passa por #fire_step_automations, que roda Ai::StepAutomationRunner (uma automação "preencher
  # atributo" escreve no MESMO additional_attributes) — gravar por cima do Hash antigo desfaria isso.
  def persist_step_index(conversation, index)
    attrs = (conversation.reload.additional_attributes || {}).merge('ai_step_index' => index, 'ai_step_turns' => 0)
    conversation.update!(additional_attributes: attrs)
  end

  # "Automações ao concluir etapa" (lista "+ Adicionar automação" — distinta do "Desfecho ao concluir
  # o funil", que é #on_complete/#execute_step_conclusion). Idempotente por índice, mesma semântica de
  # Ai::StateManager#already_fired?/#mark_fired (chave compartilhada — não importa qual caminho
  # dispara primeiro, os dois respeitam a mesma marca). Sem dispatcher/run (este controller não tem
  # run_record de Gateway) — Ai::StepAutomationRunner cai no caminho SEM auditoria de
  # Ai::CapabilityExecution pras ações via CapabilityRegistry, mesmo padrão que #run_capability já usa
  # pras control tools (avancar_etapa/registrar_* também não geram linha de auditoria).
  def fire_step_automations(conversation, step, index)
    automations = Array(step.is_a?(Hash) ? (step['automations'] || step[:automations]) : nil)
    return if automations.empty?

    attrs = conversation.additional_attributes || {}
    last_fired = attrs['ai_step_last_fired_index']
    return if last_fired.is_a?(Integer) && last_fired >= index

    attrs['ai_step_last_fired_index'] = index
    conversation.update!(additional_attributes: attrs)

    Ai::StepAutomationRunner.new(conversation: conversation, account: conversation.account,
                                 agent: department.agent, dispatcher: nil, run: nil).run(step)
  end

  # 'collect' => 'attribute' aceita string OU array (ver #missing_required_attributes) — extraído
  # pra reuso: "etapa sem NENHUM attribute declarado" é a mesma definição de "etapa informativa" do
  # manual interno, usada tanto pra validar dado obrigatório quanto pra travar a varredura acima.
  def collect_attributes(step)
    return [] unless step.is_a?(Hash)

    Array(step.dig('collect', 'attribute') || step.dig(:collect, :attribute)).compact_blank
  end

  # collect.attribute aceita string (único formato real usado pela tela hoje) OU array — Array()
  # normaliza os dois sem inventar campo novo (suporta múltiplos campos obrigatórios por etapa se o
  # playbook algum dia vier a usar isso; hoje sempre 1 elemento). slot_required: false (NUNCA
  # collect.required — ver AiStepForm/aiStepPayload) = campo opcional, NUNCA bloqueia avanço — decisão
  # CONFIRMADA (não é mais assunção pendente): cliente respondeu -> salva normalmente (fora do escopo
  # deste método, quem grava é registrar_*/salvar_memoria_ia); cliente não respondeu OU disse
  # explicitamente "prefiro não informar" -> tanto faz pro avanço, a etapa segue de qualquer jeito
  # porque não é obrigatória. Sem sinal novo de "recusa" vindo do modelo — a ausência do dado em
  # ai_collected_facts já basta pra decidir (não bloqueia), não precisa distinguir os dois casos.
  def missing_required_attributes(step, facts)
    return [] unless step.is_a?(Hash)
    return [] if step['slot_required'] == false || step[:slot_required] == false

    collect_attributes(step).reject { |attr| facts.to_h[attr.to_s].present? }
  end

  # As 3 ações do desfecho declarado — espelha Ai::Gateway#force_conclusion (motor legado) exatamente,
  # trocando action_dispatcher/handoff_coordinator memoizados do Gateway por instâncias locais (este
  # controller não tem run_record nem @acts_live — roda direto, o gate live? já filtrou acima).
  def execute_step_conclusion(conversation, department, info)
    case info['action'].to_s
    when 'close'
      result = Ai::CapabilityRegistry.execute(Ai::PythonOrchestratorClient::RESOLVE_TOOL,
                                              conversation: conversation, input: {})
      { result: { 'conclusion' => 'close' }.merge(result[:output].is_a?(Hash) ? result[:output] : {}),
        status: 'executed', error: nil }
    when 'handoff_ai'
      routed = step_handoff_coordinator(conversation, department).route_to_ai({ 'handoff_target' => info['target'].to_s })
      { result: { 'conclusion' => 'handoff_ai', 'target' => info['target'], 'routed' => routed ? true : false },
        status: 'executed', error: nil }
    else # handoff_human (default) — mesma leitura de team que Ai::Gateway#force_conclusion
      coordinator = step_handoff_coordinator(conversation, department)
      team_id = coordinator.conclusion_team_id(info)
      reason = info['reason'].presence || 'conclusao'
      # Achado 2.3: handoff_human já entregue (ai_handoff true) — pula TAMBÉM o "unassign" da
      # transferência. Sem isto, uma 2ª chamada (retry de webhook duplicado) desatribuía a conversa
      # aqui e não reatribuía ninguém, porque o guard de Ai::HandoffCoordinator#assign_human (abaixo)
      # já torna essa chamada um no-op — unassign sem reassign deixava a conversa sem dono.
      unless conversation.additional_attributes.to_h['ai_handoff']
        transfer_input = { 'unassign' => true }
        transfer_input['team_id'] = team_id if team_id
        Ai::CapabilityRegistry.execute(Ai::PythonOrchestratorClient::TRANSFER_TOOL,
                                       conversation: conversation, input: transfer_input)
      end
      coordinator.assign_human(team_id, reason: reason)
      { result: { 'conclusion' => 'handoff_human', 'team_id' => team_id }, status: 'executed', error: nil }
    end
  rescue StandardError => e
    Rails.logger.error "[Api::Internal::AiExecuteToolController#execute_step_conclusion] #{e.class}: #{e.message}"
    { result: {}, status: 'failed', error: e.message }
  end

  # Ai::HandoffCoordinator exige um `message` (route_to_ai usa .inbox_id/.id pra reenfileirar o
  # GatewayRunJob) — este controller não recebe o message_id que disparou o turno (o payload Rails->
  # Python nunca mandou), então usa a ÚLTIMA mensagem incoming da conversa como substituta razoável
  # (mesma inbox, é o que dispararia o próximo turno de qualquer forma).
  def step_handoff_coordinator(conversation, department)
    Ai::HandoffCoordinator.new(conversation: conversation, account: department.account, agent: department.agent,
                               message: conversation.messages.incoming.order(:id).last)
  end

  # conversation.resolve / conversation.transfer: direct Ai::CapabilityRegistry calls (same registry
  # Ai::ToolExecutor dispatches to for configured tools) — not routed through Ai::ToolExecutor because
  # these aren't admin-configured Ai::Tool rows, they're always-available control tools. No
  # Ai::CapabilityExecution audit row for the same reason "avancar_etapa"/"registrar_*" don't have one.
  def run_capability(conversation, department, key)
    return { result: {}, status: 'skipped', error: nil } unless live?

    return transfer_to_human(conversation, department) if key == Ai::PythonOrchestratorClient::TRANSFER_TOOL

    result = Ai::CapabilityRegistry.execute(key, conversation: conversation, input: arguments)
    { result: result[:output], status: 'executed', error: nil }
  rescue StandardError => e
    Rails.logger.error "[Api::Internal::AiExecuteToolController#run_capability] #{key}: #{e.class}: #{e.message}"
    { result: {}, status: 'failed', error: e.message }
  end

  # "transferir_humano": true — campo DIRETO do contrato estruturado (fora de on_complete, o modelo
  # decide no meio da conversa). BUG achado ao vivo (13/08, conv 556): só chamar
  # Ai::CapabilityRegistry.execute('conversation.transfer', ...) "funciona" (status executed, sem
  # exceção) mas não faz o handoff de verdade — sem "unassign"/"team_id" no input o assignee nunca
  # muda, e sem Ai::HandoffCoordinator#assign_human a flag additional_attributes['ai_handoff'] nunca é
  # setada (Ai::ReplyPolicy#effective_reply_state é quem lê essa flag pra parar de responder — ver
  # reply_policy.rb:45). Resultado: a IA seguia respondendo normalmente nos turnos seguintes, como se
  # a transferência nunca tivesse acontecido. Mesmo padrão que #execute_step_conclusion (on_complete)
  # já usa corretamente — só que ali o modelo declara um team_id via on_complete.
  #
  # handoff_target (achado ao vivo, 17/08): o motor Ruby legado tinha um campo pro modelo nomear o
  # TIME de destino (whitelist Ai::PromptCompiler#human_handoff_teams) — o Structured Outputs nunca
  # reproduziu isso (STRUCTURED_REPLY_SCHEMA só tinha handoff_summary), então TODA transferência direta
  # caía sempre no mesmo time default/configurado, cega à intenção — mesmo com o admin escrevendo um
  # guardrail tipo "nunca invente nomes de time, use só os da lista" (texto sem efeito nenhum, porque
  # não existia ONDE a IA declarar um nome). orchestrator.py manda handoff_target de volta; repassa pro
  # MESMO Ai::HandoffCoordinator#human_team_id/match_team_by_name que #execute_step_conclusion já usa.
  # Pedido do dono da conta (18/08, redução de prompt): a instrução que listava a whitelist no prompt
  # (Ai::PythonOrchestratorClient#handoff_target_instruction) foi REMOVIDA — handoff_target volta vazio
  # do modelo agora, então #human_team_id cai sempre no time default (reverte o achado de 17/08 pra
  # contas com 2+ times marcados; risco assumido, ver comentário em
  # Ai::PythonOrchestratorClient#system_prompt).
  def transfer_to_human(conversation, department)
    save_handoff_summary(conversation)
    coordinator = step_handoff_coordinator(conversation, department)
    team_id = coordinator.human_team_id({ 'handoff_target' => arguments['handoff_target'].to_s })
    Ai::CapabilityRegistry.execute(Ai::PythonOrchestratorClient::TRANSFER_TOOL, conversation: conversation,
                                   input: { 'unassign' => true, 'team_id' => team_id })
    coordinator.assign_human(team_id, reason: 'model_requested')
    { result: { 'transferred' => true, 'team_id' => team_id }, status: 'executed', error: nil }
  end

  # A IA é instruída (Ai::PythonOrchestratorClient#tool_usage_instruction) a SEMPRE preencher
  # handoff_summary ao chamar conversation.transfer — resumo do que já foi conseguido + o motivo,
  # pro humano que assumir não começar do zero. Salvo ANTES de executar a capability (que reabre/
  # desatribui a conversa) para não depender de ordem de commit entre as duas escritas.
  def save_handoff_summary(conversation)
    summary = arguments['handoff_summary'].to_s.strip
    return if summary.blank?

    attrs = conversation.additional_attributes || {}
    attrs['handoff_summary'] = summary
    conversation.update!(additional_attributes: attrs)
  end

  def authenticate_internal_request!
    expected = ENV.fetch('INTERNAL_AI_TOKEN', nil)
    token = request.headers['Authorization'].to_s.sub(/\ABearer\s+/i, '')
    return render json: { error: 'unauthorized' }, status: :unauthorized if expected.blank? || token.blank?
    return if ActiveSupport::SecurityUtils.secure_compare(token, expected)

    render json: { error: 'unauthorized' }, status: :unauthorized
  end
end
