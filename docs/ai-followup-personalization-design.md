# Design: personalização do Follow-up via IA (2026-08-22)

Documento de escopo/arquitetura — **nenhum código foi alterado ainda**. Registrado a
pedido da dona da conta ("pode guardar na memória, pois isso será nosso próximo
ajuste") pra retomar exatamente daqui, sem re-derivar a discussão. Trigger original:
a tela de Follow-up manda sempre o MESMO texto fixo por tentativa, pra qualquer
cliente, em qualquer etapa — o pedido do chefe da dona da conta foi tornar isso
personalizado por etapa/contexto, usando a IA de verdade (chamada real à OpenAI,
custo aceito conscientemente — ver §1).

## 0. Decisão confirmada

- O follow-up vai **chamar a IA de verdade** por tentativa (não é o "Option A/C" —
  texto fixo/template Liquid — que tinha sido cogitado antes). O custo é aceito: quem
  paga é a conta do cliente final, e a trava de quantas chamadas acontecem já existe
  (ver §1).
- Precisa continuar aparecendo em Custos de IA (cria `Ai::Run` por tentativa, igual
  todo turno real).

## 1. A trava já existe — não precisa de mecanismo novo

Cada comportamento do Follow-up (`agent.follow_up['behaviors'][i]`) já tem uma lista
ordenada de `attempts` (delay + ação). O job só dispara UMA tentativa por vez, na
ordem, e para depois da última (cai na ação de inatividade — transferir/finalizar/
aguardar). Isso já é exatamente "o admin configura quantas chamadas podem
acontecer" — só que hoje cada tentativa dispara texto fixo; com a mudança, cada
`attempt` dispara uma chamada de IA. A contagem/trava não muda.

## 2. Hierarquia de configuração (evita "inferno de configuração manual")

Configurar um texto por etapa × tentativa não escala (N etapas × M tentativas).
Desenho adotado — 1 template reutilizável no agente, com override pontual por
tentativa:

```
Ai::Agent#follow_up (coluna jsonb JÁ EXISTENTE — só ganha chaves novas):
{
  'type' => 'ai_generated',   # NOVO. 'fixed_text' = comportamento de hoje, inalterado
  'template' => 'Retome a conversa de forma simpática. Peça {campo_pendente} de forma ' \
                'natural. Cliente parou há {tempo_inativo} na etapa {etapa_nome}. ' \
                'Seja breve (máx 2 frases).',
  'behaviors' => [ ... ]      # JÁ EXISTE, inalterado
}

agent.follow_up['behaviors'][i]['attempts'][j] (array JÁ EXISTE, ganha 2 chaves):
{
  'delay_minutes' => 5,               # JÁ EXISTE
  'message' => '',                    # JÁ EXISTE — só usado se type == 'fixed_text'
  'follow_up_type' => 'use_template', # NOVO. ou 'custom'
  'follow_up_custom' => nil,          # NOVO. override — texto fixo (Liquid), só se 'custom'
}
```

Variáveis do template (resolvidas server-side, texto simples — NÃO é Liquid, porque
não vai pro cliente, vai pra instrução da IA):

| Variável | Fonte |
|---|---|
| `{campo_pendente}` | Primeiro atributo da etapa atual ainda não coletado — precisa de helper novo, ver §4 |
| `{etapa_nome}` | `current_step['name']` |
| `{tempo_inativo}` | Calculado da última mensagem do cliente (mesmo dado que o job já usa pra decidir SE dispara) |
| `{nome_cliente}` | `conversation.contact.name` |
| `{historico_resumido}` | Reusa `Ai::AgentMemory#summary` (resumo rolante que JÁ é atualizado a cada turno real — não recalcular do zero) |

`follow_up_custom` (override por tentativa) é o escape-hatch pro texto fixo de
sempre — útil por exemplo na ÚLTIMA tentativa antes de transferir pro humano, onde
o admin pode preferir garantir a palavra exata em vez de deixar a IA gerar.

**Gap em aberto**: quando a etapa atual não tem `collect` (etapa só informativa,
`{campo_pendente}` resolve vazio) — decidir entre (a) fallback textual genérico
("retome a conversa, sem pedir nada específico") ou (b) não disparar follow-up
nessas etapas. Não decidido ainda.

## 3. Requisição à OpenAI — arquitetura confirmada

Verificado (busca própria, fontes: community.openai.com, developers.openai.com) que
o array `input` da Responses API aceita itens com `role: "developer" | "system" |
"user" | "assistant"`, com `developer`/`system` tendo prioridade sobre `user`. Não é
caminho hipotético — é documentado oficialmente. **Mas é código NOVO pra nós**: hoje,
em todo `ai-orchestrator/orchestrator.py`, `input` só é construído como
`[{"role": "user", "content": ...}]` — nunca um item `developer`/`system`.

Desenho limpo (`instructions` continua intocado, igual todo turno real; `input`
carrega só o gatilho específico desta chamada):

```json
{
  "model": "gpt-5.6-terra",
  "conversation": "conv_xxx",
  "instructions": "<Prompt base> <Regras de segurança> <Etapa atual> — EXATAMENTE igual a um turno real, via _build_instructions, sem concatenar nada de follow-up aqui",
  "input": [
    { "role": "developer", "content": "<template do follow-up já com variáveis substituídas>" }
  ],
  "text": { "format": { "type": "json_schema", "name": "followup_message",
    "schema": { "type": "object", "properties": { "message": { "type": "string" } },
                "required": ["message"], "additionalProperties": false } } }
}
```

Por que um único item `role: developer` em `input` (sem item `role: user` fake):
já é suficiente pra disparar a geração — não precisa fingir que o cliente disse
algo. `instructions` continua sendo a identidade PERMANENTE do agente (reusa
`_build_instructions(system_prompt)` tal como já existe hoje, zero duplicação).

**Schema mínimo, não o schema pesado**: follow-up não decide ferramenta/handoff/
avanço de etapa — é uma mensagem única. Reusar o schema de decisão completo
(`Ai::DecisionSchema`/`_build_reply_schema`) seria token e complexidade
desperdiçados à toa. Um `text.format` com só `{message: string}` já usa o MESMO
mecanismo (`_turn_kwargs` já monta `text.format` assim hoje) — só com schema menor.

## 4. Peças a construir (nenhuma existe ainda)

**Python (`ai-orchestrator/orchestrator.py`)**:
1. Caminho novo que aceita montar `input` como `[{"role": "developer", "content": ...}]`
   em vez de sempre `role: "user"`.
2. Pular o loop de ferramentas (`parallel_tool_calls`/iterações) — follow-up é
   resposta única, sem tool call.
3. Schema mínimo (`{message: string}`) em vez do schema de decisão completo.
4. Reusar `_build_instructions(system_prompt)` sem alteração — mesmo `system_prompt`
   que os turnos reais já montam (Prompt base + Regras + Etapa atual).

**Rails**:
5. Método novo em `Ai::PythonOrchestratorClient` (ex.: `run_followup`) que chama o
   caminho novo do Python acima — reusa o MESMO cliente HTTP (`HTTParty`), só aponta
   pra um modo/rota diferente. **Não existe hoje nenhuma chamada Ruby → OpenAI
   direta** (só HTTP Rails → serviço Python → OpenAI) — importante não inventar um
   segundo caminho paralelo pra OpenAI.
6. Helper `pending_slot_for(step, conversation)` — primeiro atributo declarado da
   etapa (`Ai::StepSlot.declared_attributes(step)`) que ainda não está nos dados
   coletados da conversa. **A chave exata de onde os dados coletados ficam salvos
   precisa ser confirmada no `Ai::StateManager` antes de implementar** (visto
   `ai_collected_facts`/`persist_collected_facts` no código, mas não confirmado com
   certeza total qual é a leitura correta).
7. `Ai::FollowupConversationJob#maybe_send_attempt` — ramifica pra
   `send_ai_generated_attempt` quando `agent.follow_up['type'] == 'ai_generated'`;
   mantém o caminho de hoje (texto fixo, `Messages::MessageBuilder` direto) quando
   `'fixed_text'`.
8. `Ai::Run.create!` por tentativa gerada por IA (`account_id`, `conversation_id`,
   `ai_agent_id`, `run_type: 'followup'`, `provider`, `model`, `tokens_in`,
   `tokens_out`, `cost` via `Ai::ModelRouter.estimate_cost`) — pra aparecer em Custos
   de IA como qualquer outro turno.

**Frontend** (tela Follow-up, dentro de `AiAgentBehaviorPanel.vue`):
9. Seletor de tipo por agente: "Texto fixo (sem custo)" vs "Gerado pela IA (com
   custo)".
10. Campo de template único (nível agente), com dica listando as variáveis
    disponíveis (`{campo_pendente}`, `{etapa_nome}`, `{tempo_inativo}`,
    `{nome_cliente}`, `{historico_resumido}`).
11. Por tentativa: opção "usar template do agente" (padrão) vs "customizar" (volta
    pro texto fixo de hoje, só nesta tentativa).
12. Botão de pré-visualização/teste (mesma filosofia da aba Teste — mostrar um
    exemplo gerado antes de salvar).
13. Aviso de custo perto do campo, apontando pra Custos de IA.

## 5. Achado relacionado, mas escopo separado (não fazer junto)

Durante a investigação apareceu um problema real e verificado, mas diferente deste:
`Ai::StateManager#known_slot_keys` (usado como `known_attribute_keys` no schema de
TODO turno real, não só follow-up) junta os atributos de **todas as etapas do
playbook**, não só a atual — o enum de `dados_coletados[].chave` mandado à OpenAI em
todo turno é maior do que precisa. Confirmado gasta token à toa. **Não misturar essa
correção com o trabalho de follow-up** — afeta o motor principal (todo turno ao
vivo), é uma frente de trabalho separada. Ao corrigir, cuidado: cortar pra "só a
etapa atual" quebraria a captura de "dados antecipados" (cliente informa um dado de
etapa futura antes de ser perguntado — comportamento hoje válido e usado). Melhor
opção discutida: excluir só chaves de etapas JÁ CONCLUÍDAS, manter atual + futuras.

## 6. Coisas real x hipotético — corrigido nesta discussão

- ❌ `Ai::Playbook#steps[0]['attempts'][0]` — attempts NUNCA moram dentro de Etapas,
  moram em `agent.follow_up['behaviors'][i]['attempts']`.
- ❌ `OpenAI.responses.create(...)` chamado direto do Ruby — não existe esse caminho
  hoje; tudo passa pelo serviço Python via HTTP.
- ❌ `conversation.openai_conversation_id` — não existe essa coluna no Rails; quem
  gerencia a conversa nativa da OpenAI é só o Python (`_ensure_conversation`).
- ❌ `Ai::StateManager.current_step(agent)` como method de classe — é instância:
  `Ai::StateManager.new(conversation:, agent:).current_step(agent)`.
- ❌ `Ai::Run.create(type:, tokens_used:)` — colunas reais são `run_type`,
  `tokens_in`/`tokens_out` separados, `account_id` obrigatório.
- ❌ `Messages::MessageBuilder.create(content:)` — assinatura real é
  `Messages::MessageBuilder.new(sender, conversation, params).perform`.
- ✅ Tools reais (as da aba Ferramentas) NÃO são step-scoped hoje
  (`@agent.tools.active`, sem filtro de etapa) — restringir por etapa tem risco real
  de quebrar um cliente pedindo algo fora do roteiro linear (a ferramenta de
  conhecimento já é oferecida sem restrição de etapa, de propósito). Não mexer nisso
  junto com o follow-up.
