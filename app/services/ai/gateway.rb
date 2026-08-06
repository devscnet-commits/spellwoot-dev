# The AI Gateway — F1 happy-path, SHADOW only.
# Pipeline: message.received -> resolve_agent (caller) -> resolve_department -> assemble_context
#           -> retrieve_knowledge -> decide -> record ai_runs + ai_events.
# In shadow it NEVER replies, NEVER executes a tool, NEVER writes operational changes — it only
# records intention, runs and events.
class Ai::Gateway
  # Valores VÁLIDOS do campo `decision` no contrato do LLM (ver Ai::PromptCompiler#response_contract).
  # Qualquer outro valor é "fora do contrato" e cai na rede de segurança do dispatch (decision.unknown_kind).
  KNOWN_DECISION_KINDS = %w[reply invoke_tool handoff close noop].freeze
  # Fase 2: janela do e-mail ao admin quando um erro de provedor vira handoff. 1h por (conta, provedor) —
  # maior que os 15 min do handoff-sem-agente de propósito: cota estourada é condição sustentada, o admin
  # quer UM aviso e não dezenas. Ver #notify_admin_provider_error.
  PROVIDER_ERROR_NOTIFY_TTL = 1.hour

  def initialize(message:, agent_inbox:, mode: nil, content_override: nil)
    @message = message
    @agent_inbox = agent_inbox
    @agent = agent_inbox.agent
    @conversation = message.conversation
    @account = message.account
    # mode may be downgraded by the caller (team routing): a non-owner agent observes (shadow).
    @mode = mode || agent_inbox.mode
    # When grouping, the caller passes the whole customer burst as the content to consider.
    @content_override = content_override
    # Breadcrumb da etapa corrente do pipeline; o rescue do topo usa p/ tipar o erro (classify_error).
    @stage = nil
  end

  def run
    run_record = Ai::Run.create!(
      account_id: @account.id, conversation_id: @conversation.id, ai_agent_id: @agent.id,
      inbox_id: @message.inbox_id, run_type: 'decision', mode: @mode, status: 'running'
    )
    emit(run_record, 'message.received', { content: @message.content.to_s.first(500), message_id: @message.id })

    # Invisible worker: turn media (audio/image) into text the supervisor can use. Passa o profile
    # do agente para o OCR ler o worker de visão configurado (worker_overrides['ocr']).
    media_text = Ai::Workers::MediaProcessor.process(@message, @agent.operation_profile)
    emit(run_record, 'media.preprocessed', { text: media_text }) if media_text.present?
    base_content = @content_override.presence || @message.content
    effective_content = [base_content, media_text].compact.join("\n").strip

    @stage = :department
    department, resolution = Ai::DepartmentResolver.resolve(
      agent: @agent, inbox_id: @message.inbox_id, message_content: effective_content, conversation: @conversation
    )

    # A partir daqui NÃO é mais classificação de departamento: gravar o resultado e o estado é
    # infra/DB. Uma exceção aqui deve virar 'internal_error', não 'classification_failed' (ver
    # classify_error). Por isso o :department cobre SÓ a chamada de resolve acima.
    @stage = :persist
    # Fase 2: override de department pedido mas NÃO honrado (deletado/inativo/outra conta) -> tag de
    # visibilidade + segue normal (o department já veio do fluxo padrão). Nunca interrompe o run.
    flag_unavailable_department_override(resolution)
    emit(run_record, 'department.resolved', { department_id: department&.id, name: department&.name, method: resolution })
    return finalize(run_record, 'no_department') unless department

    run_record.update!(ai_department_id: department.id)

    # Config do departamento + gate de política (reply state) + caminho ask_resume — nada disso é
    # classificação; erro aqui é 'internal_error', não 'classification_failed'.
    @stage = :policy
    # Limite de caracteres da mensagem do cliente (anti-abuso/tokens). Ação configurável:
    # 'truncate' (padrão: corta nos N primeiros) ou 'ask_resume' (pede pro cliente resumir e
    # NÃO processa o texto gigante). Tratado abaixo, após o gate de resposta.
    max_input = department.behavior.to_h['max_input_chars'].to_i
    input_action = department.behavior.to_h['max_input_action'].presence || 'truncate'
    input_exceeded = max_input.positive? && effective_content.length > max_input
    effective_content = effective_content.first(max_input) if input_exceeded && input_action != 'ask_resume'

    # Single gate for every outward action (reply, tools, transfer/resolve): the AI only acts when
    # this conversation is effectively live — i.e. live binding + auto_attendance on + within hours
    # + reply_scope all/canary-match. Otherwise it observes (records intention) only, so a live
    # binding piloted "behind canary" never touches non-canary conversations.
    @acts_live =
      Ai::ReplyPolicy.effective_reply_state(mode: @mode, department: department, conversation: @conversation) == :live

    # Billing Fase 2: aviso proativo de saldo baixo (90% usado) + bloqueio ao ESGOTAR. Só ao vivo p/
    # o bloqueio; conta sem balance/plano ou com chave própria (custom_llm_api_key) = LIBERA
    # (fail-open). Ao esgotar, entrega ao humano com nota interna e NÃO roda o modelo (zero custo).
    maybe_notify_low_balance(run_record)
    if @acts_live && credit_exhausted?
      force_credit_handoff(run_record)
      return finalize(run_record, 'credit_exhausted')
    end

    # Teto de respostas da IA (max_replies): ao atingir o limite configurado no departamento, a IA
    # para de responder e TRANSFERE para humano — mesmo fluxo do force_credit_handoff (nota interna +
    # transfer + assign, sem mensagem ao cliente). Verifica antes de rodar o modelo (zero custo LLM).
    if @acts_live && max_replies_reached?(department)
      force_max_replies_handoff(run_record, department)
      return finalize(run_record, 'max_replies')
    end

    # Fase 3 — circuit breaker por (conta, provider). Com o breaker ABERTO, PULA todo o caminho condenado
    # (RAG + montagem de contexto + chamada ao modelo) e vai direto ao handoff da Fase 1 — MESMO padrão
    # pré-chamada do credit_exhausted? acima, custo e latência ZERO. Só ao vivo (shadow nunca transfere nem
    # mexe no breaker). :half_open = passe de teste concedido a ESTE run (segue o fluxo normal; a chamada lá
    # embaixo fecha/reabre via record_success/record_failure). notify:false no skip — o e-mail já saiu na
    # ABERTURA (a 3ª falha, throttle de 1h); com o breaker já aberto NÃO reenvia. Ver Ai::ProviderBreaker.
    if @acts_live
      case provider_breaker.state
      when :open
        run_record.update!(provider: supervisor_provider, status: 'error', error_type: 'provider_error')
        emit(run_record, 'provider.breaker_skipped', { provider: supervisor_provider, open_until: provider_breaker.open_until })
        force_provider_handoff(run_record, notify: false)
        return finalize(run_record, 'error')
      when :half_open
        emit(run_record, 'provider.breaker_half_open', { provider: supervisor_provider })
      end
    end

    # Mensagem acima do limite + ação "pedir resumo": avisa o cliente e encerra a execução
    # (não roda o modelo no texto gigante). 'truncate' segue normal (já cortado acima).
    if input_exceeded && input_action == 'ask_resume'
      message = department.behavior.to_h['max_input_message'].presence ||
                'Sua mensagem ficou longa demais para eu entender bem. Pode resumir em poucas linhas, por favor? 🙂'
      emit(run_record, 'input.too_long', { chars: effective_content.length, max: max_input })
      action_dispatcher.reply(department, message)
      return finalize(run_record, 'input_too_long')
    end

    @stage = :knowledge
    # (Camada 3) Conhecimento SOB DEMANDA: o worker (opt-in) roda UMA vez por turno e decide se busca e de
    # qual kind. Só reivindica o turno cedo QUANDO vai rodar o worker (live + texto + worker on) — assim o
    # worker fica DENTRO da idempotência do BUG 1 (claim perdido em re-exec/2º binding => worker NÃO roda),
    # e o caminho worker-OFF (default) segue IDÊNTICO a hoje (claim continua dentro do track_step).
    active_step = @acts_live ? state_manager.current_step(department) : nil
    # Approach 1a (conv 393): o conhecimento derivado da etapa precisa da etapa que ENTRA, não da que sai.
    # next_step é um valor SEPARADO, usado SÓ pelo resolve_knowledge (look-ahead do catálogo no turno da
    # transição). NÃO alimenta o juiz nem o gate de atributos — ao contrário do Gap 2, aqui só o conhecimento
    # olha o destino. nil em shadow (como o active_step) e na última etapa.
    next_step = @acts_live ? state_manager.next_step(department) : nil

    # Camada 0 — triagem de turno trivial (opt-in, default OFF). ANTES de qualquer chamada ao modelo:
    # um turno trivial ("ok"/"obrigada"/emoji solto em reação à nossa última msg) NÃO acorda o supervisor.
    # Gate determinístico (regex + estado local), custo ZERO. Silêncio é o comportamento v1 DECIDIDO
    # (responder "de nada" convidaria outro "obrigada" — loop de cortesia). Vale live E shadow (em shadow
    # também economiza a chamada; sem efeito colateral). OFF => byte-idêntico ao fluxo atual.
    # active_step é nil em shadow por design, então resolvemos a etapa REAL aqui p/ a condição c valer nos
    # dois modos (na dúvida, NÃO pula). Ver Ai::TrivialTurnGate.
    if trivial_gate_on?
      gate = Ai::TrivialTurnGate.skip?(text: effective_content, conversation: @conversation,
                                       step: active_step || state_manager.current_step(department),
                                       conclude_ready: state_manager.conclude_ready_for_current?(department))
      if gate[:skip]
        run_record.update!(run_type: 'trivial_skip', tokens_in: 0, tokens_out: 0, cost: 0)
        emit(run_record, 'turn.trivial_skipped', { reason: gate[:reason] })
        return finalize(run_record, 'recorded')
      end
    end

    judge_result =
      if @acts_live && effective_content.present? && state_manager.judge_enabled? && state_manager.claim_turn(@message)
        state_manager.run_turn_judge(active_step, effective_content)
      end

    kn = resolve_knowledge(run_record, department, active_step, next_step, judge_result, effective_content)
    knowledge = kn[:chunks]
    emit(run_record, 'knowledge.retrieved',
         { count: knowledge.size, preview: knowledge.first(2), kinds: kn[:kinds], source: kn[:source] })
    run_record.update!(knowledge_count: knowledge.size)

    memory = Ai::AgentMemory.find_by(conversation_id: @conversation.id, ai_agent_id: @agent.id)
    customer_memory = @conversation.contact_id &&
                      Ai::CustomerMemory.find_by(contact_id: @conversation.contact_id, account_id: @account.id)
    tools  = department.tools.active.to_a
    @stage = :context
    system_prompt = Ai::PromptCompiler.compile(
      agent: @agent, department: department, knowledge: knowledge, memory: memory, tools: tools,
      collected: (@conversation.contact&.custom_attributes || {})
        .merge(@conversation.additional_attributes&.dig('ai_collected_facts') || {})
        .merge(@conversation.custom_attributes || {}),
      fillable_attributes: context_builder.fillable_attributes(department),
      customer_memory: customer_memory,
      # Índice determinístico da etapa (fonte de verdade no servidor). O PromptCompiler ancora o
      # modelo nesta etapa em vez de deixá-lo se autolocalizar. StateManager#track_step avança no fim.
      step_index: (@conversation.additional_attributes || {})['ai_step_index'].to_i,
      # Guarda (conv 397): a etapa declarou conhecimento e o retrieval voltou vazio -> o prompt avisa
      # "não afirme, verifique" (o modelo não tem fonte).
      knowledge_gap: kn[:declared_empty],
      # (4) Feedback de rejeição por formato: o último valor barrado (ai_last_invalid) + os turnos gastos na
      # etapa (ai_step_turns, reusado p/ a escalada soft ao humano). O prompt explica em vez de reperguntar.
      slot_feedback: {
        'invalid' => (@conversation.additional_attributes || {})['ai_last_invalid'],
        'step_turns' => (@conversation.additional_attributes || {})['ai_step_turns'].to_i,
        # Proposta pendente (ai_last_proposed_value, de QUALQUER origem): dispara a linha de CONTRATO que
        # obriga o modelo a popular attributes[slot] na confirmação (senão vem mudo -> echo_missing).
        'pending_proposed' => (@conversation.additional_attributes || {})['ai_last_proposed_value']
      }
    )
    emit(run_record, 'context.assembled', { prompt_chars: system_prompt.length, tools: tools.map(&:name) })

    @stage = :decision
    user_message_text = context_builder.user_message(effective_content)
    # Histórico estruturado: [{role: :user/:assistant, content: '...'}] em vez de um blob de texto.
    # Injetado via chat.add_message no ModelRouter para preservar a alternância user/assistant real.
    structured = context_builder.structured_messages(effective_content)
    # Native tool loop: when department has active tools in live mode, register adapters so
    # ruby_llm handles tool_use → execute → tool_result internally with correct IDs (no
    # text-injected second call). In shadow or when no tools, fall back to decide() unchanged.
    adapters = @acts_live && tools.any? \
               ? Ai::LlmToolAdapter.for_department(department, conversation: @conversation, mode: @mode, run: run_record) \
               : []
    # Responses API: só para departamentos SEM ferramentas (evita split de histórico entre as duas APIs).
    # Em shadow ou com tools, openai_conv_id fica nil e o decide usa o caminho normal de messages.
    openai_conv_id = @acts_live && tools.empty? \
                     ? (@conversation.additional_attributes || {})['openai_conversation_id'] \
                     : nil
    result = if adapters.any?
               Ai::ModelRouter.call_with_tools(
                 profile: @agent.operation_profile, system_prompt: system_prompt,
                 user_message: user_message_text, tools: adapters, account_id: @account.id,
                 messages: structured
               )
             else
               Ai::ModelRouter.decide(
                 profile: @agent.operation_profile, system_prompt: system_prompt,
                 user_message: user_message_text, account_id: @account.id, json: true,
                 messages: structured, conversation_id: openai_conv_id
               )
             end
    # Persiste o conversation_id retornado pela Responses API para o próximo turno continuar o fio.
    persist_openai_conversation_id(result[:openai_conversation_id]) if result[:openai_conversation_id].present?
    # BYOK (billing Fase 3): se a chave PRÓPRIA do cliente falhou por auth (401), sinaliza com tag,
    # refaz a decisão na chave global da SCNET e cobra 1 crédito SCNET desse retry. Substitui `result`.
    # Só no caminho decide() — adapters já usaram a chave correta e têm seu próprio error_type.
    result = maybe_byok_fallback(run_record, system_prompt, effective_content, result) if adapters.empty?
    run_record.update!(
      provider: result[:provider], model: result[:model],
      tokens_in: result[:tokens_in], tokens_out: result[:tokens_out], cached_tokens: result[:cached_tokens],
      cost: result[:cost], latency_ms: result[:latency_ms],
      decision: result[:decision] || {}, status: result[:status],
      error_type: (result[:status] == 'error' ? 'provider_error' : nil)
    )
    emit(run_record, 'decision.made',
         { decision: result[:decision], cost: result[:cost], latency_ms: result[:latency_ms],
           temperature: result[:temperature], cached_tokens: result[:cached_tokens] },
         run_id: run_record.id)

    # Fase 3 — alimenta o breaker com o RESULTADO desta chamada (só ao vivo): erro incrementa as falhas
    # consecutivas (abre na 3ª ou reabre um half-open); sucesso zera e fecha. O e-mail da abertura sai pelo
    # force_provider_handoff (caminho de erro logo abaixo), NÃO aqui. record_* são no-op com o kill-switch OFF.
    if @acts_live
      if result[:status] == 'error'
        opened = provider_breaker.record_failure
        emit(run_record, 'provider.breaker_opened', { provider: result[:provider] }.merge(opened)) if opened
      elsif (closed_via = provider_breaker.record_success)
        emit(run_record, 'provider.breaker_closed', { provider: result[:provider], via: closed_via })
      end
    end

    # Provider indisponível (rate-limit/cota/billing, ou auth que o BYOK não recuperou): a decisão veio com
    # status 'error' e VAZIA. Sem esta guarda, o dispatch cai no unknown_kind {handled:'none'} = SILÊNCIO
    # (conv 413: "oi"/"olá?" sem resposta, sem transferência, sem alerta). Espelha o force_credit_handoff,
    # mas PÓS-chamada (o erro do provedor só se sabe depois de tentar). Só ao vivo; em shadow apenas registra
    # o erro, como hoje. Curto-circuita antes do track_step/dispatch (a decisão vazia não avança etapa).
    if @acts_live && result[:status] == 'error'
      force_provider_handoff(run_record)
      return finalize(run_record, 'error')
    end

    # Track which step the conversation is on so message grouping can use that step's delay; also
    # fires the step's completion automations when the model signals step_completed (audited actions
    # reuse this run's dispatcher). message_text alimenta a extração determinística de slot (Camada A).
    # track_step swallows its own errors — never breaks the Gateway. Devolve um sinal quando a etapa de
    # slot travou por N turnos (Camada B) — tratado logo abaixo.
    step_signal = nil
    if @acts_live
      step_signal = state_manager.track_step(department, result[:decision] || {}, dispatcher: action_dispatcher,
                                                                                  run: run_record, message_text: effective_content,
                                                                                  message: @message, judge_result: judge_result)
      # Grava os dados coletados (cidade, plano, etc.) nos atributos da conversa, conforme o modelo
      # devolveu em `attributes`. Só chaves que batem com um attribute_key real do department (o resto
      # vira attributes.unknown_key, sem sujar o JSON). Assim os campos são alimentados e reaproveitados.
      # active_step foi resolvido ANTES do track_step acima (pré-avanço). O gate anti-contaminação valida
      # `attributes` contra o slot que estava ATIVO neste turno — não o da próxima etapa que track_step
      # acabou de ativar. Sem isso, o valor recém-coletado cai como unexpected_key (regressão do #284).
      state_manager.persist_attributes((result[:decision] || {})['attributes'], department,
                                       source: :supervisor, expected_step: active_step)
    end

    # Camada B (rede de segurança do avanço-por-slot): a IA ficou presa numa etapa de COLETA por N
    # mensagens sem obter o dado. NÃO forçamos avanço (cadastro incompleto): avisamos o cliente e
    # TRANSFERIMOS para humano, com motivo claro no resumo. Curto-circuita antes de qualquer dispatch.
    # (b)-core: DESFECHO declarado pela etapa (on_complete) na conclusão determinística do funil. Mesmo canal
    # do stuck_handoff (outcome[:signal]); o destino vem da ETAPA, não da intenção do modelo. Curto-circuita.
    if step_signal.is_a?(Hash) && step_signal[:conclude]
      force_conclusion(run_record, department, step_signal[:conclude], result[:decision] || {})
      state_manager.update_memory
      return finalize(run_record, 'recorded')
    end

    if step_signal.is_a?(Hash) && step_signal[:stuck_handoff]
      force_stuck_handoff(run_record, department, step_signal[:stuck_handoff])
      state_manager.update_memory
      return finalize(run_record, 'recorded')
    end

    # Tool handling. SHADOW never executes — only records intention. LIVE runs the executor,
    # which executes the tool immediately (tools are autonomous).
    @stage = :tool
    intended_tool = result.dig(:decision, 'tool')
    execution = nil
    if adapters.empty? && intended_tool.present?
      tool = department.tools.active.find_by(name: intended_tool['name'])
      if @acts_live && tool
        execution = Ai::ToolExecutor.new(
          tool: tool, input: intended_tool['input'], conversation: @conversation, mode: @mode, run: run_record
        ).perform
        emit(run_record, 'tool.executed',
             { tool: tool.name, status: execution.status, execution_id: execution.id })
      else
        emit(run_record, 'tool.intended', { tool: intended_tool, executed: false, reason: action_dispatcher.not_acting_reason(tool) })
      end
    end

    # An `invoke_tool` decision only runs the tool — it carries no reply, so the conversation would
    # stall. Take a SECOND turn feeding the tool result back so the AI answers the customer with it.
    # Single hop (we don't execute another tool) to avoid loops; `result` is replaced for dispatch.
    if adapters.empty? && intended_tool.present? && @acts_live && execution&.status == 'executed'
      # Auto-fill: se o output da ferramenta contém a chave do slot da etapa corrente, persiste o valor
      # SEM depender de o modelo reportar o dado em `attributes` no followup (o modelo frequentemente diz
      # attributes:{} no followup pois o prompt enxuto não instrui extração). Source :trusted (default)
      # — a ferramenta é fonte autorizada, bypassa o gate incluindo o guard already_filled.
      # Só escalares (String/Numeric) — hashes/arrays não formam um slot simples. Só persiste se o valor
      # for não-vazio. Procura primeiro em output['body'] (formato de webhook), cai no output inteiro.
      if active_step
        slot_key = Ai::StepSlot.attribute(active_step)
        if slot_key.present?
          out_hash = execution.output.is_a?(Hash) ? execution.output : {}
          body = out_hash['body'].is_a?(Hash) ? out_hash['body'] : out_hash
          slot_val = body[slot_key]
          if (slot_val.is_a?(String) || slot_val.is_a?(Numeric)) && slot_val.to_s.strip.present?
            state_manager.persist_attributes({ slot_key => slot_val.to_s.strip }, department)
          end
        end
      end
      # 2ª chamada só REDIGE a resposta pós-ferramenta (não avança etapa, não grava attributes, não roda
      # outra ferramenta) -> usa um prompt ENXUTO (sem playbook/âncora/estado-da-coleta/lead_vars/tools)
      # para cortar o custo do reenvio. Recompilado AQUI (só quando há followup), reusando RAG/memória já
      # carregados. Ver Ai::PromptCompiler.compile(followup: true).
      followup_prompt = Ai::PromptCompiler.compile(
        agent: @agent, department: department, knowledge: knowledge, memory: memory,
        tools: [], customer_memory: customer_memory, followup: true,
        # A âncora e o estado da coleta do followup precisam do MESMO estado da 1ª chamada: em que etapa
        # estamos e o que já foi coletado (senão o followup repergunta / pede dado de outra etapa).
        collected: (@conversation.contact&.custom_attributes || {})
          .merge(@conversation.additional_attributes&.dig('ai_collected_facts') || {})
          .merge(@conversation.custom_attributes || {}),
        step_index: (@conversation.additional_attributes || {})['ai_step_index'].to_i
      )
      result = tool_followup(run_record, followup_prompt, effective_content, intended_tool, execution)
    end

    # Native tool path: emit tool.executed events and auto-fill the active slot from each
    # adapter's executions. The tool section above is a no-op for this path because the
    # decision from call_with_tools carries no 'tool' key — tools already ran inside.
    if adapters.any? && @acts_live
      adapters.each do |adapter|
        adapter.executions.each do |exec|
          emit(run_record, 'tool.executed',
               { tool: adapter.ai_tool.name, status: exec.status, execution_id: exec.id })
        end
      end
      if active_step
        slot_key = Ai::StepSlot.attribute(active_step)
        if slot_key.present?
          adapters.flat_map(&:executions).each do |exec|
            next unless exec.status == 'executed'
            out_hash = exec.output.is_a?(Hash) ? exec.output : {}
            body     = out_hash['body'].is_a?(Hash) ? out_hash['body'] : out_hash
            slot_val = body[slot_key]
            next unless (slot_val.is_a?(String) || slot_val.is_a?(Numeric)) && slot_val.to_s.strip.present?
            state_manager.persist_attributes({ slot_key => slot_val.to_s.strip }, department)
            break
          end
        end
      end
    end

    @stage = :dispatch
    decision_kind = (result[:decision] || {})['decision']

    # Bug 3 hotfix: the model returned something we couldn't parse into a decision. NEVER dispatch it
    # to the customer (raw JSON/config used to leak via the reply fallback) — mark the run as an error
    # for review and stop before any action.
    if decision_kind == 'unparsed'
      run_record.update!(error_type: 'unparsed_decision')
      emit(run_record, 'decision.unparsed', {})
      return finalize(run_record, 'error')
    end

    # Intelligent handoff / close. Shadow records intention; live executes the native action.
    handoff = Ai::HandoffEvaluator.evaluate(
      decision: result[:decision] || {}, department: department
    )
    if handoff[:handoff]
      # Try AI->AI routing first (to an allowed agent); otherwise hand to a human.
      routed = @acts_live && handoff_coordinator.route_to_ai(result[:decision] || {})
      unless routed
        # Idempotência: se JÁ houve handoff nesta conversa e ela seguiu SEM responsável (1ª atribuição
        # falhou), NÃO reenvia a mensagem de transição — só refaz a atribuição (transfer + assign),
        # evitando a mensagem duplicada quando o cliente cobra e o fluxo re-executa.
        retrying_handoff = @conversation.additional_attributes&.dig('ai_handoff').present? &&
                           @conversation.assignee_id.blank?
        # Tell the customer we're handing off (the model's "transferindo você..." text), THEN
        # transfer (reopen + unassign for a human). Without the reply the customer saw silence.
        action_dispatcher.reply(department, (result[:decision] || {})['reply_text']) unless retrying_handoff
        team_id = handoff_coordinator.human_team_id(result[:decision] || {})
        input = { 'unassign' => true }
        input['team_id'] = team_id if team_id # roteia para o time; senão mantém o atual
        action_dispatcher.execute_action('conversation.transfer', input, run_record, 'handoff', extra: { reason: handoff[:reason], team_id: team_id })
        # Atribuição DEPOIS do trabalho da IA: o próprio handoff atribui um humano (round-robin
        # entre os agentes online do time/caixa). Mantenha a auto-atribuição da caixa DESLIGADA
        # para a IA atender primeiro; aqui é o único ponto que entrega a um agente. reason vem do
        # HandoffEvaluator (modelo_pediu_transferencia / palavra_chave) -> dispara o resumo do handoff.
        handoff_coordinator.assign_human(team_id, reason: handoff[:reason]) if @acts_live
      end
    elsif decision_kind == 'close'
      # Despedida antes de resolver (fix do encerramento silencioso): a mensagem da aba Finalização
      # (close_rules['message']) tem prioridade; senão o reply_text que o modelo gerou nesta decisão
      # (antes descartado); se nenhum existir, fecha em silêncio como antes. Usa o mesmo mecanismo de
      # reply (respeita live/shadow, reply_scope e max_replies).
      farewell = close_farewell(department, result[:decision] || {})
      action_dispatcher.reply(department, farewell) if farewell.present?
      action_dispatcher.execute_action('conversation.resolve', {}, run_record, 'close')
    elsif decision_kind == 'reply'
      safe_reply = guard_against_loop(run_record, system_prompt, effective_content,
                                      (result[:decision] || {})['reply_text'])
      action_dispatcher.reply(department, safe_reply) if safe_reply
    elsif adapters.empty? && intended_tool.present? && @acts_live
      # Safety net: a tool ran but the follow-up decision still isn't a plain reply/close/handoff —
      # send whatever text we have so the customer is never left waiting after a tool call.
      action_dispatcher.reply(department, (result[:decision] || {})['reply_text'])
    elsif KNOWN_DECISION_KINDS.include?(decision_kind)
      # noop (a IA escolheu não agir) ou invoke_tool sem execução ao vivo: valores VÁLIDOS do contrato,
      # sem ação de saída aqui. Não é desvio — não registra decision.unknown_kind.
    else
      # Rede de segurança: decision FORA do contrato (ex.: "text"). Sem isto, o Gateway descartava um
      # reply_text VÁLIDO em SILÊNCIO (cliente sem resposta, sem handoff, sem erro). Com texto, trata
      # como reply (mesmo caminho — passa por LoopGuard e pelo consumo de crédito do reply). Sem texto,
      # só registra o desvio para observabilidade (não some sem rastro).
      unknown_reply = (result[:decision] || {})['reply_text']
      if unknown_reply.present?
        emit(run_record, 'decision.unknown_kind', { decision: decision_kind, handled: 'reply' })
        safe_reply = guard_against_loop(run_record, system_prompt, effective_content, unknown_reply)
        action_dispatcher.reply(department, safe_reply) if safe_reply
      else
        emit(run_record, 'decision.unknown_kind', { decision: decision_kind, handled: 'none' })
      end
    end

    state_manager.update_memory
    finalize(run_record, result[:status] == 'error' ? 'error' : 'recorded')
  rescue StandardError => e
    error_type = classify_error(e)
    # Loga a etapa e a categoria junto do erro — o "porquê" fica no log; o "o quê" (agregável) na run.
    Rails.logger.error "[Ai::Gateway] conv=#{@conversation&.id} stage=#{@stage} type=#{error_type} #{e.class}: #{e.message}"
    run_record.update!(status: 'error', error_type: error_type) if defined?(run_record) && run_record&.persisted?
    nil
  end

  private

  # Camada 0 ligada? Opt-in por perfil no MESMO padrão aninhado dos demais workers
  # (worker_overrides['trivial_gate']['mode'] == 'on'). Ausente/qualquer outro valor => OFF (default),
  # e o fluxo fica byte-idêntico ao atual.
  def trivial_gate_on?
    @agent.operation_profile&.worker('trivial_gate')&.dig('mode').to_s == 'on'
  end

  # (Camadas 3/4) Decide a busca de conhecimento a partir da INTENÇÃO do worker. Devolve
  # { chunks:, kinds:, source: } — source audita a origem:
  #  - judge_result nil (worker OFF/default, shadow, ou claim perdido) -> RAG como hoje (full, sem filtro,
  #    todo turno). source 'all' — REGRESSÃO TOTAL do comportamento atual.
  #  - worker FALHOU -> fallback: full RAG + evento knowledge.fallback (auditável). source 'fallback'.
  #  - asks_about != 'nada' -> busca kinds:[asks_about] com a QUERY do worker (não o texto cru, que deu o
  #    resultado ruim). source 'worker'.
  #  - etapa DECLARA conhecimento (step['knowledge']) -> busca a query/kinds declarados. source 'step'.
  #  - senão -> NÃO busca (economia) + evento knowledge.skipped. source 'none'.
  def resolve_knowledge(run_record, department, step, next_step, judge_result, query_text)
    return search_knowledge(department, nil, query_text, 'all') if judge_result.nil?

    if judge_result[:status].to_s == 'failed'
      emit(run_record, 'knowledge.fallback', { reason: judge_result[:reason].to_s.first(80) })
      return search_knowledge(department, nil, query_text, 'fallback')
    end

    asks = judge_result[:asks_about].to_s
    return search_knowledge(department, [asks], judge_result[:query].presence || query_text, 'worker') if asks.present? && asks != 'nada'

    # Conhecimento DECLARADO pela etapa (step['knowledge']). A etapa ATUAL VENCE o look-ahead da próxima
    # (`step` antes de `next_step`) — cravado: na conv 397 foi o look-ahead da etapa seguinte (PLANOS,
    # kind produto) que roubou o turno da VIABILIDADE, que precisa de cidades_atendidas (kind documento).
    # kinds e query vêm do DADO da etapa; nenhum kind/vocabulário de tenant fica em código.
    req = step_knowledge_request(step) || step_knowledge_request(next_step)
    return search_declared(run_record, department, req) if req

    emit(run_record, 'knowledge.skipped', { reason: 'no_question_no_declared_step' })
    { chunks: [], kinds: nil, source: 'none' }
  end

  # Busca o conhecimento DECLARADO pela etapa. GUARDA determinística (conv 397): se a etapa declarou uma
  # fonte e o retrieval voltou VAZIO, o modelo não tem base — marca declared_empty (o PromptCompiler
  # injeta "não afirme, verifique") e emite knowledge.declared_empty (auditável). source 'step' nos dois.
  def search_declared(run_record, department, req)
    result = search_knowledge(department, req[:kinds], req[:query], 'step', list_all: req[:list_all])
    return result if result[:chunks].present?

    emit(run_record, 'knowledge.declared_empty', { kinds: req[:kinds], query: req[:query].to_s.first(120) })
    result.merge(declared_empty: true)
  end

  # Conhecimento que a etapa DECLARA precisar: step['knowledge'] = { query, kinds, list_all }. query
  # obrigatória; kinds OPCIONAL (array; vazio => todos os kinds); list_all OPCIONAL (default false —
  # "trazer todos os itens deste tipo", ex.: lista de planos/convênios; true bypassa a similaridade).
  # nil quando a etapa não declara conhecimento (ou a query está vazia). Retorna { kinds:, query:, list_all: }.
  def step_knowledge_request(step)
    decl = step.is_a?(Hash) ? (step['knowledge'] || step[:knowledge]) : nil
    return nil unless decl.is_a?(Hash)

    query = (decl['query'] || decl[:query]).to_s.strip
    return nil if query.blank?

    kinds = Array(decl['kinds'] || decl[:kinds]).map { |k| k.to_s.strip }.reject(&:blank?)
    list_all = (decl['list_all'] || decl[:list_all]).to_s.strip.downcase == 'true'
    { kinds: kinds.presence, query: query, list_all: list_all }
  end

  def search_knowledge(department, kinds, query, source, list_all: false)
    chunks = Ai::KnowledgeRetriever.retrieve(query: query, account_id: @account.id,
                                             department_id: department.id, kinds: kinds, list_all: list_all)
    { chunks: chunks, kinds: kinds, source: source }
  end

  # Montagem do contexto textual do modelo (histórico + citação + atributos preenchíveis), extraído
  # do Gateway (Passo 2 da quebra do God object). Memoizado — criado 1x por run, sob demanda.
  def context_builder
    @context_builder ||= Ai::ContextBuilder.new(
      conversation: @conversation, message: @message, account: @account
    )
  end

  # Escritas de estado derivado (atributos coletados, etapa atual, memória), extraído do Gateway
  # (Passo 4). Memoizado — só depende de @conversation/@agent (sem restrição de ordem).
  def state_manager
    @state_manager ||= Ai::StateManager.new(conversation: @conversation, agent: @agent)
  end

  # Execução de ações do pipeline (reply + capabilities nativas), extraído do Gateway (Passo 3).
  # Memoizado — depende de @acts_live, então SÓ é acessado depois da resolução do gate (linha ~52).
  def action_dispatcher
    # as_human é constante por run (o agente é fixo), então injetamos na construção em vez de repetir
    # nos 4 call-sites de reply. No modo humano o dispatcher quebra a resposta em várias mensagens.
    @action_dispatcher ||= Ai::ActionDispatcher.new(
      conversation: @conversation, account: @account, mode: @mode, acts_live: @acts_live,
      as_human: @agent.identify_as == 'human'
    )
  end

  # Nomes de classes (comparados por NOME p/ não exigir a constante carregada — ex.: PG/Faraday
  # podem não estar em memória) que denotam timeout/queda de conexão.
  TIMEOUT_ERROR_NAMES = %w[
    Timeout::Error Net::OpenTimeout Net::ReadTimeout Errno::ETIMEDOUT
    Redis::TimeoutError Faraday::TimeoutError
    PG::QueryCanceled ActiveRecord::StatementTimeout ActiveRecord::QueryCanceled
  ].freeze

  # Traduz a exceção que borbulhou até o rescue do topo numa categoria de Ai::Run::ERROR_TYPES,
  # cruzando a ETAPA onde estourou (@stage) com a CLASSE da exceção (timeout tem classe
  # reconhecível). Retorna SEMPRE um valor válido de ERROR_TYPES; 'unknown' é o piso honesto.
  #
  # CORTE HISTÓRICO (refactor dos stages, jul/2026): antes, a janela :department cobria também
  # persistência/política/ask_resume, então erros de DB/policy caíam em 'classification_failed'.
  # Agora :persist/:policy têm rótulo próprio ('internal_error'). Logo, a partir do deploy deste
  # commit, a queda de 'classification_failed' e a subida de 'internal_error' é RECLASSIFICAÇÃO —
  # não mudança de comportamento. O projeto está em sandbox/sem prod, então não há degrau real hoje;
  # este registro fica pronto para quando a série histórica passar a importar.
  def classify_error(exception)
    timed_out = timeout_error?(exception)
    case @stage
    when :knowledge        then 'knowledge_timeout'             # busca RAG/pgvector
    when :tool             then 'tool_failed'                   # executor de ferramenta estourou
    when :department       then 'classification_failed'         # SÓ a resolução do departamento
    when :persist, :policy then 'internal_error'               # write de estado / gate de política (não é classificação)
    when :decision         then timed_out ? 'provider_timeout' : 'provider_error'
    else                        timed_out ? 'provider_timeout' : 'unknown'
    end
  rescue StandardError
    'unknown'
  end

  # Reconhece timeouts por classe (herança, não igualdade) ou pela mensagem, sem referenciar a
  # constante da classe diretamente (evita NameError se o gem não estiver carregado).
  def timeout_error?(exception)
    ancestors = exception.class.ancestors.filter_map(&:name)
    (ancestors & TIMEOUT_ERROR_NAMES).any? || exception.message.to_s.downcase.include?('timeout')
  end

  # Second model turn after a tool ran: feeds the tool output back so the AI replies to the customer
  # with the result (e.g. coverage lookup -> "sim, atendemos sua cidade"). Returns the new decision
  # for the normal dispatch. Single hop — it never triggers another tool execution.
  def tool_followup(run_record, system_prompt, user_message, tool_call, execution)
    followup_message = "#{user_message}\n\n[Resultado da ferramenta \"#{tool_call['name']}\"]:\n" \
                       "#{execution.output.to_json}\n\n" \
                       'Use esse resultado para responder ao cliente agora (decision: "reply").'
    result = Ai::ModelRouter.decide(
      profile: @agent.operation_profile, system_prompt: system_prompt,
      user_message: followup_message, account_id: @account.id, json: true
    )
    emit(run_record, 'tool.followup',
         { decision: result[:decision], cost: result[:cost], latency_ms: result[:latency_ms],
           prompt_chars: system_prompt.length })
    result
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#tool_followup] #{e.class}: #{e.message}"
    { decision: {} }
  end

  # Cluster de handoff/atribuição extraído do Gateway (Passo 1 da quebra do God object): route IA->IA,
  # resolução do time de destino e entrega a um humano. Memoizado — criado 1x por run, sob demanda.
  def handoff_coordinator
    @handoff_coordinator ||= Ai::HandoffCoordinator.new(
      conversation: @conversation, account: @account, agent: @agent, message: @message
    )
  end

  # Aplica a tag de visibilidade quando um override de department foi pedido mas não pôde ser honrado
  # (department deletado/inativo/de outra conta). Best-effort: NUNCA interrompe o run. Reusa o handler
  # conversation_add_label direto (sem auditoria/gate live-shadow) porque roda no stage :department,
  # antes do action_dispatcher existir — e é um sinal operacional que deve aparecer mesmo em shadow.
  def flag_unavailable_department_override(resolution)
    return if resolution == 'override'
    return if @conversation.additional_attributes&.dig('ai_department_override').blank?

    Ai::CapabilityRegistry.execute('conversation.add_label', conversation: @conversation,
                                                             input: { 'label' => 'department-override-indisponivel' })
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#flag_unavailable_department_override] #{e.class}: #{e.message}"
  end

  # Rede de segurança anti-loop de repergunta (defesa em profundidade). Se o reply_text repete as 2
  # últimas respostas (parafraseando) COM o cliente respondendo entre elas, tenta 1 vez com um nudge;
  # se AINDA repetir, força handoff e NÃO envia. Retorna o texto a enviar, ou nil (quando escalou p/
  # handoff). Só age ao vivo; em shadow devolve o texto original (sem efeito colateral).
  def guard_against_loop(run_record, system_prompt, user_message, reply_text)
    return reply_text unless @acts_live && reply_text.present?

    guard = Ai::LoopGuard.new(conversation: @conversation, current_run: run_record)
    return reply_text unless guard.loop?(reply_text)

    emit(run_record, 'reply.loop_detected', { chars: reply_text.length })
    retried = loop_retry(run_record, system_prompt, user_message)
    new_reply = (retried[:decision] || {})['reply_text'].to_s

    if new_reply.present? && !guard.loop?(new_reply)
      # A resposta regenerada saiu do loop: passa a valer (mantém a run auditável coerente).
      run_record.update!(decision: retried[:decision]) if retried[:decision].is_a?(Hash)
      return new_reply
    end

    # Loop persistiu mesmo após o retry -> handoff forçado, sem enviar a resposta problemática.
    force_loop_handoff(run_record)
    nil
  end

  # Regenera a decisão com um nudge anti-repetição no fim do system prompt. UMA tentativa só (nunca
  # entra em loop de retry). Devolve o result do ModelRouter (ou vazio em erro).
  def loop_retry(run_record, system_prompt, user_message)
    nudge = "\n\nATENÇÃO: você já fez esta mesma pergunta/confirmação antes, de forma muito parecida. " \
            'NÃO repita. Trate o que o cliente já respondeu como confirmado e AVANCE para o próximo ' \
            'passo; se não for possível avançar, peça ajuda humana.'
    result = Ai::ModelRouter.decide(
      profile: @agent.operation_profile, system_prompt: "#{system_prompt}#{nudge}",
      user_message: user_message, account_id: @account.id, json: true
    )
    emit(run_record, 'reply.loop_retry', { status: result[:status] })
    result
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#loop_retry] #{e.class}: #{e.message}"
    { decision: {} }
  end

  # Handoff forçado quando o loop persiste após o retry: entrega ao humano no time PADRÃO do agente,
  # reaproveitando o mesmo fluxo do handoff normal (transfer + assign). Não envia texto ao cliente.
  def force_loop_handoff(run_record)
    team_id = handoff_coordinator.human_team_id({})
    input = { 'unassign' => true }
    input['team_id'] = team_id if team_id
    action_dispatcher.execute_action('conversation.transfer', input, run_record, 'handoff', extra: { reason: 'loop' })
    handoff_coordinator.assign_human(team_id, reason: 'loop')
    emit(run_record, 'handoff.loop_forced', { team_id: team_id })
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#force_loop_handoff] #{e.class}: #{e.message}"
  end

  # Camada B da rede de segurança do avanço-por-slot: a IA ficou presa numa etapa de COLETA por N
  # mensagens sem obter o dado (o modelo não devolveu o attribute e a extração determinística não pegou).
  # Em vez de FORÇAR o avanço com dado faltando (cadastro incompleto), na sequência: (1) AVISA o cliente,
  # (2) TRANSFERE para humano reaproveitando o mesmo fluxo do force_loop_handoff (transfer + assign), (3)
  # registra o motivo específico no resumo do handoff (o reason vira o "Resumo da transferência"), (4)
  # emite step.stuck_handoff para telemetria (quais etapas travam mais).
  def force_stuck_handoff(run_record, department, info)
    action_dispatcher.reply(department, stuck_handoff_warning(department)) # aviso ANTES da transferência
    reason = stuck_handoff_reason(info)
    team_id = handoff_coordinator.human_team_id({})
    input = { 'unassign' => true }
    input['team_id'] = team_id if team_id
    action_dispatcher.execute_action('conversation.transfer', input, run_record, 'handoff', extra: { reason: reason })
    handoff_coordinator.assign_human(team_id, reason: reason) # reason livre -> vira o Resumo da transferência
    # Gap 4: reason distingue a rede (recusa vs 'max_turns' absoluto); refusals acompanha o max_turns
    # quando houve recusas no meio (telemetria de "quais etapas travam mais" na alternância). .compact
    # tira os nil (a rede de recusa não manda refusals; o vazio não manda reason).
    emit(run_record, 'step.stuck_handoff',
         { attribute: info[:attribute], step_name: info[:step_name], turns: info[:turns],
           reason: info[:reason], refusals: info[:refusals] }.compact)
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#force_stuck_handoff] #{e.class}: #{e.message}"
  end

  # (b)-core — DESFECHO declarado pela etapa (step['on_complete']) na conclusão do funil. Reusa a MESMA
  # maquinaria: handoff_human -> transfer + assign_human (com resumo, reason 'conclusao') abrindo a conversa
  # com dono na fila do atendente; close -> conversation.resolve (despedida antes); handoff_ai -> route_to_ai.
  # O destino do handoff_human vem da ETAPA (team_id validado contra a whitelist em conclusion_team_id), não
  # da intenção do modelo. decision leva o reply_text que o modelo redigiu nesta etapa (a despedida).
  def force_conclusion(run_record, department, info, decision)
    case info['action'].to_s
    when 'close'
      farewell = close_farewell(department, decision)
      action_dispatcher.reply(department, farewell) if farewell.present?
      action_dispatcher.execute_action('conversation.resolve', {}, run_record, 'close')
      emit(run_record, 'conclusion.executed', { action: 'close' })
    when 'handoff_ai'
      routed = handoff_coordinator.route_to_ai({ 'handoff_target' => info['target'].to_s })
      emit(run_record, 'conclusion.executed', { action: 'handoff_ai', target: info['target'], routed: routed ? true : false })
    else # handoff_human (default)
      reason = info['reason'].presence || 'conclusao'
      team_id = handoff_coordinator.conclusion_team_id(info)
      action_dispatcher.reply(department, decision['reply_text']) if decision['reply_text'].present?
      input = { 'unassign' => true }
      input['team_id'] = team_id if team_id
      action_dispatcher.execute_action('conversation.transfer', input, run_record, 'handoff',
                                       extra: { reason: reason, team_id: team_id })
      handoff_coordinator.assign_human(team_id, reason: reason)
      emit(run_record, 'conclusion.executed', { action: 'handoff_human', team_id: team_id })
    end
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#force_conclusion] #{e.class}: #{e.message}"
  end

  # Mensagem de aviso ao cliente antes de transferir (configurável via transfer_rules['stuck_message'];
  # senão uma default acolhedora em pt-BR — o cliente não pode sentir corte seco).
  def stuck_handoff_warning(department)
    (department.transfer_rules || {})['stuck_message'].presence ||
      'Vou te encaminhar para um especialista do nosso time que vai te ajudar melhor com isso, tá? 😊'
  end

  # Motivo específico e honesto — o HandoffSummaryGenerator usa este texto livre no "Resumo da transferência".
  # Gap 4 v2: DISTINGUE as duas redes. O texto antigo chamava QUALQUER travamento de "tentou coletar sem
  # sucesso", inclusive PERGUNTA legítima (conv 389: a compradora que pediu os planos era descrita como
  # tentativa falha). Agora:
  #  - 'declined' (rede de recusa): o cliente RECUSOU o dado — info[:turns] é a contagem de RECUSAS.
  #  - 'max_turns'/fallback (teto absoluto): a etapa não AVANÇOU em N mensagens — info[:turns] é a contagem
  #    de turnos (não implica que o cliente tentou e falhou; pode ser digressão/pergunta).
  # Usa o nome amigável da etapa quando houver, não só a chave técnica.
  def stuck_handoff_reason(info)
    label = info[:step_name].presence || info[:attribute]
    if info[:reason].to_s == 'declined'
      "Transferido automaticamente: o cliente não forneceu o dado essencial \"#{label}\" " \
        "(recusou #{info[:turns]} vezes). Encaminhado para atendimento humano."
    else
      "Transferido automaticamente: a IA não conseguiu avançar a etapa \"#{label}\" após " \
        "#{info[:turns]} mensagens do cliente. Encaminhado para atendimento humano para não travar o cliente."
    end
  end

  # Saldo de créditos de IA relevante para enforcement (billing Fase 2). nil = NÃO enforça (fail-open):
  # conta sem balance/plano, ou conta com chave própria (custom_llm_api_key — BYOK). A flag é sempre
  # false hoje (Fase 3 não implementada); o check é fail-safe, preparado pro futuro.
  def billing_balance
    return nil if @account.feature_enabled?('custom_llm_api_key')

    @account.ai_credit_balance
  end

  def credit_exhausted?
    balance = billing_balance
    balance.present? && balance.total <= 0
  end

  # Aviso proativo de 90% usado: quando plan_credits <= 10% do teto do plano, notifica a SCHNET UMA
  # vez por ciclo (guardado por low_balance_notified_at, resetado na renovação). O short-circuit pelo
  # flag roda ANTES da query do plano, então o caso comum (já avisado) é barato.
  def maybe_notify_low_balance(run_record)
    balance = billing_balance
    return if balance.nil? || balance.low_balance_notified_at.present?

    cap = current_plan_credits_cap
    return if cap <= 0 || balance.plan_credits > cap * 0.1

    AdministratorNotifications::CreditRequestMailer.low_balance_warning(@account, balance.total, cap).deliver_later
    balance.update!(low_balance_notified_at: Time.current)
    emit(run_record, 'credit.low_balance_notified', { remaining: balance.total, cap: cap })
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#maybe_notify_low_balance] #{e.class}: #{e.message}"
  end

  def current_plan_credits_cap
    @account.subscriptions.current.first&.plan&.ai_credits_included.to_i
  end

  # Handoff forçado quando o saldo de créditos de IA esgota: nota interna + entrega ao humano no time
  # PADRÃO do agente, reaproveitando o mesmo fluxo do force_loop_handoff (transfer + assign). NÃO
  # envia texto ao cliente (a IA simplesmente não responde; um humano assume).
  def force_credit_handoff(run_record)
    action_dispatcher.internal_note('⚠️ Crédito de IA esgotado — atendimento transferido para um humano.')
    team_id = handoff_coordinator.human_team_id({})
    input = { 'unassign' => true }
    input['team_id'] = team_id if team_id
    action_dispatcher.execute_action('conversation.transfer', input, run_record, 'handoff', extra: { reason: 'credit_exhausted' })
    handoff_coordinator.assign_human(team_id, reason: 'credit_exhausted')
    emit(run_record, 'handoff.credit_exhausted', { team_id: team_id })
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#force_credit_handoff] #{e.class}: #{e.message}"
  end

  # Transferência silenciosa ao atingir o teto de respostas (max_replies). Espelha force_credit_handoff:
  # nota interna ao atendente + transfer + assign_human, SEM mensagem ao cliente. Não usa reply() para
  # o aviso porque o próprio gate de max_replies bloquearia a mensagem — o humano recebe e responde ele mesmo.
  def force_max_replies_handoff(run_record, department)
    max = department.behavior.to_h['max_replies'].to_i
    action_dispatcher.internal_note("⚠️ Limite de #{max} respostas da IA atingido — atendimento transferido para um humano.")
    team_id = handoff_coordinator.human_team_id({})
    input = { 'unassign' => true }
    input['team_id'] = team_id if team_id
    action_dispatcher.execute_action('conversation.transfer', input, run_record, 'handoff', extra: { reason: 'max_replies_reached' })
    handoff_coordinator.assign_human(team_id, reason: 'max_replies_reached')
    emit(run_record, 'handoff.max_replies_reached', { max: max, team_id: team_id })
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#force_max_replies_handoff] #{e.class}: #{e.message}"
  end

  def max_replies_reached?(department)
    max = department.behavior.to_h['max_replies'].to_i
    max.positive? && Ai::Event.where(conversation_id: @conversation.id, event_type: 'reply.sent').count >= max
  end

  # Provider de IA indisponível (rate-limit/cota/billing, ou auth não recuperado pelo BYOK): a IA não
  # conseguiu decidir. Espelha o force_credit_handoff: NOTA PRIVADA ao atendente com o motivo técnico (que o
  # cliente nunca vê) + transferência + assign_human. reason 'provider_unavailable' -> resumo + card.
  # DECISÃO DE PRODUTO: NÃO manda mensagem automática ao cliente — a conversa cai no time humano e o
  # atendente responde ele mesmo (uma frase "já vou te atender" seria mais uma promessa que o sistema não
  # cumpre, o padrão que estamos eliminando). Só ao vivo (o call-site já gateia @acts_live).
  # notify: (Fase 3) — o e-mail da Fase 2 sai só na ABERTURA do breaker (a chamada que REALMENTE falhou),
  # NÃO a cada transferência com o breaker JÁ aberto. O caminho normal (Fase 1/2) chama sem argumento =>
  # notify:true, comportamento IDÊNTICO ao de antes. Só o skip do breaker aberto passa notify:false (ali não
  # houve chamada nem provider_error novo — e run_record.provider nem está setado).
  # Provider resolvido do perfil ANTES da chamada (mesma resolução do Ai::ModelRouter.decide: perfil ->
  # 'openai'). Serve ao breaker pré-chamada (o result[:provider] pós-chamada é idêntico — sem provider
  # explícito no call-site e o BYOK não troca de provider).
  def supervisor_provider
    @agent.operation_profile&.supervisor_provider.presence || 'openai'
  end

  # Breaker por (conta, provider) memoizado no run — o mesmo objeto para o gate pré-chamada e o record
  # pós-chamada (estado real vive no cache, não no objeto).
  def provider_breaker
    @provider_breaker ||= Ai::ProviderBreaker.new(account: @account, provider: supervisor_provider)
  end

  def force_provider_handoff(run_record, notify: true)
    action_dispatcher.internal_note('⚠️ Transferido automaticamente: a IA não conseguiu responder por ' \
                                    'indisponibilidade do provedor de IA (verifique cota/billing).')
    team_id = handoff_coordinator.human_team_id({})
    input = { 'unassign' => true }
    input['team_id'] = team_id if team_id
    action_dispatcher.execute_action('conversation.transfer', input, run_record, 'handoff', extra: { reason: 'provider_unavailable' })
    handoff_coordinator.assign_human(team_id, reason: 'provider_unavailable')
    emit(run_record, 'handoff.provider_unavailable', { team_id: team_id })
    # Fase 2: avisa os ADMINS da conta (cota/billing é de quem paga, não do atendente). DEPOIS do handoff
    # e best-effort — nunca derruba a transferência (ver #notify_admin_provider_error). Fase 3: com o breaker
    # ABERTO o Gateway pula a chamada e transfere sem provider_error novo — passa notify:false para NÃO
    # reenviar; o aviso já saiu na abertura (a 3ª falha, throttle de 1h). Ver #run e Ai::ProviderBreaker.
    notify_admin_provider_error(run_record.provider) if notify
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#force_provider_handoff] #{e.class}: #{e.message}"
  end

  # E-mail aos admins da conta quando um provider_error resulta em handoff. Reusa o padrão do
  # notify_admin_no_agent (AccountNotificationMailer.with(account:) + throttle por cache). Throttle de
  # 1 HORA por (conta, provedor): cota estourada é condição SUSTENTADA — o admin quer UM aviso, não
  # dezenas (por isso a janela é maior que os 15 min do notify_admin_no_agent). Best-effort: qualquer
  # falha aqui (mailer, cache) só loga; o handoff já ocorreu e não pode ser afetado.
  def notify_admin_provider_error(provider)
    return unless provider_error_notify_allows?(provider)

    AdministratorNotifications::AccountNotificationMailer
      .with(account: @account)
      .provider_error_handoff(@account, provider.to_s)
      .deliver_later
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#notify_admin_provider_error] #{e.class}: #{e.message}"
  end

  # 1 e-mail por (conta, provedor) a cada PROVIDER_ERROR_NOTIFY_TTL. Mesmo padrão cache-based do
  # Persiste o conversation_id da Responses API em additional_attributes da conversa. Usa lock! para
  # não colidir com persist_collected_facts do StateManager (ambos fazem lock!/reload antes de escrever).
  def persist_openai_conversation_id(conv_id)
    return if conv_id.blank?

    @conversation.lock!
    attrs = (@conversation.additional_attributes || {}).dup
    return if attrs['openai_conversation_id'] == conv_id

    attrs['openai_conversation_id'] = conv_id
    @conversation.update!(additional_attributes: attrs)
  rescue StandardError => e
    Rails.logger.warn "[Ai::Gateway#persist_openai_conversation_id] #{e.class}: #{e.message}"
  end

  # notify_throttle_allows? do HandoffCoordinator (perder o estado = no máximo 1 e-mail extra), mas
  # chave e janela PRÓPRIAS — não altera o comportamento daquele. Escreve a marca ao permitir.
  def provider_error_notify_allows?(provider)
    key = "ai:provider_error_notify:#{@account.id}:#{provider}"
    return false if Rails.cache.read(key)

    Rails.cache.write(key, true, expires_in: PROVIDER_ERROR_NOTIFY_TTL)
    true
  end

  # BYOK (billing Fase 3): a chave própria do cliente foi recusada por auth (401). Só age ao vivo e só
  # quando a 1ª chamada REALMENTE usou a chave própria (account_provider_key presente = feature ligada +
  # chave no Hub) — assim um 401 da chave global da SCNET NÃO é rotulado como "chave-propria-falhou".
  # Aplica a tag de visibilidade, refaz a decisão forçando a chave global e, se o retry der certo, cobra
  # 1 crédito SCNET (auto-provisiona um AiCreditBalance zerado se a conta BYOK ainda não tiver um — daí a
  # Fase 2 assume o handoff por saldo esgotado nas próximas mensagens). Best-effort: qualquer erro
  # devolve o result original (a IA segue o caminho de erro normal).
  def maybe_byok_fallback(run_record, system_prompt, user_message, result)
    return result unless @acts_live
    return result unless result[:status] == 'error' && result[:error_type] == 'auth_error'
    return result if Ai::ModelRouter.account_provider_key(@account.id, result[:provider]).blank?

    apply_label('chave-propria-falhou')
    emit(run_record, 'decision.byok_fallback', { provider: result[:provider] })
    retried = Ai::ModelRouter.decide(
      profile: @agent.operation_profile, system_prompt: system_prompt,
      user_message: context_builder.user_message(user_message), account_id: @account.id, json: true,
      force_global_key: true, messages: context_builder.structured_messages(user_message)
    )
    consume_byok_fallback_credit if retried[:status] != 'error'
    retried
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#maybe_byok_fallback] #{e.class}: #{e.message}"
    result
  end

  # Cobra 1 crédito SCNET do fallback BYOK, FURANDO o short-circuit de billing_balance (que retorna nil
  # para contas custom_llm_api_key): acessa o AiCreditBalance direto, auto-provisionando um zerado se
  # ainda não existir. Sem saldo, o InsufficientCredits é engolido (a resposta já sai; a Fase 2 bloqueia
  # a partir da próxima mensagem, pois agora existe um balance esgotado).
  def consume_byok_fallback_credit
    balance = AiCreditBalance.find_or_create_by(account_id: @account.id)
    balance.consume!(1)
  rescue AiCreditBalance::InsufficientCredits => e
    Rails.logger.info "[Ai::Gateway] fallback BYOK sem saldo SCNET: #{e.message}"
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#consume_byok_fallback_credit] #{e.class}: #{e.message}"
  end

  # Tag de visibilidade best-effort (mesmo handler direto do flag_unavailable_department_override).
  def apply_label(label)
    Ai::CapabilityRegistry.execute('conversation.add_label', conversation: @conversation, input: { 'label' => label })
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#apply_label] #{e.class}: #{e.message}"
  end

  # Mensagem de despedida ao encerrar proativamente (decision 'close'): mensagem da Finalização
  # (close_rules['message']) tem prioridade; senão o reply_text da própria decisão; senão nil (silêncio).
  def close_farewell(department, decision)
    department.close_rules.to_h['message'].presence || decision['reply_text'].presence
  end

  def finalize(run_record, status)
    run_record.update!(status: status)
    run_record
  end

  def emit(run_record, type, payload, run_id: nil)
    Ai::Event.create!(
      account_id: @account.id, conversation_id: @conversation.id,
      ai_run_id: run_id, event_type: type, payload: payload, status: 'ok'
    )
  end
end
