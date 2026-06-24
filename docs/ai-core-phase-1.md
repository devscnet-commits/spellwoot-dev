# Proposta — Fase Funcional 1 (AI Core)

> Pré-condição: arquitetura congelada e contratos/UX estabilizados (ver `ai-core-audit.md`).
> Objetivo desta fase: ligar o motor com **contratos definidos**, de forma que nenhuma
> tela ou coluna precise ser refeita depois.

Esta fase entrega o caminho fim-a-fim de uma mensagem do cliente até uma decisão de IA
**observável** (shadow) e, com gate explícito, **respondida** (live). Tudo instrumentado.

## Escopo

1. Gateway IA
2. Shadow operacional
3. Telemetria
4. Métricas
5. Roteamento entre departamentos
6. Estratégia de migração sem retrabalho

Fora de escopo (fica para Fase 2): upload real de arquivos, métricas de resultado
(CSAT/deflection), conhecimento/ferramentas compartilhados, inspector de roteamento visual.

---

## 0. Pré-requisitos de contrato (itens A–E da auditoria)

Executados **antes** da lógica, numa migration + ajuste de contrato:

- **A — Gate único de resposta.** `Ai::ReplyPolicy#effective_reply_state(agent_inbox, conversation)`
  retorna `:off | :shadow | :live` combinando modo da caixa, `reply_scope`, `auto_attendance`
  e horário. UI já mostra o estado efetivo. Nenhum outro lugar decide isso.
- **B — Fonte única transfer/close.** Runtime lê condições **só** do `ai_playbooks`.
  Migration copia `ai_departments.transfer_rules.when`/`close_rules.when` → playbook e para de escrever a duplicata.
- **C — `instructions` canônico.** Migration adiciona `ai_departments.instructions (text)`,
  copia de `behavior.instructions` (onde a UI grava hoje) e o runtime passa a ler a coluna.
- **D — `ai_runs` dimensionado.** Migration adiciona `ai_department_id`, `inbox_id`
  (nullable) e, opcionalmente, `routing_band` e `worker`. O Gateway popula.
- **E — `error_type`.** Migration adiciona `ai_runs.error_type (string, nullable)`; enum
  validado no modelo.

Todas as migrations são **aditivas** (colunas nullable / cópia de dados) → zero downtime,
zero backfill destrutivo.

---

## 1. Gateway IA

**Responsabilidade:** orquestrar uma mensagem recebida até uma decisão registrada.

Pipeline (cada etapa emite um `ai_event`):

```
message.received
  → effective_reply_state (A)              # off encerra aqui
  → department.resolved (roteamento, §5)
  → knowledge.retrieved (RAG, pgvector)
  → context.assembled (prompt + tools do depto)
  → decision.made (supervisor do perfil operacional)
  → [live] conversation.reply | tool.intended/executed (governança)
  → [shadow] grava decisão sem efeito externo
```

- Entrada: hook no fluxo de mensagem do Chatwoot (mensagem de entrada em caixa com agente vinculado).
- Cada execução cria um `ai_run` (mode = estado efetivo) e seus `ai_events`.
- **Idempotência:** uma run por (conversa, mensagem) — evita resposta dupla em reprocessamento.
- Em `:live`, ferramentas mutáveis passam pelo gate de `ai_capability_executions`
  (allowed/confirmation/approval); em `:shadow`, registra `tool.intended` sem executar.

**Contrato de saída (`ai_runs.decision` jsonb):**
`{ decision: 'reply'|'transfer'|'close'|'noop', reply_text, tool: {...}, department_id, routing_band, worker }`.

## 2. Shadow operacional

- Reusa o pipeline em `mode='shadow'`: decide tudo, **não envia** nada ao cliente, não executa ferramenta.
- A tela Validação Shadow (já existe) passa a ler dados reais: departamento resolvido,
  trechos de conhecimento, resposta proposta, ferramenta pretendida, modelo, custo, latência, **error_type** (E).
- Critério de promoção shadow→live: a UI mostra taxa de erro e amostragem de respostas; a
  promoção continua manual (canário via `reply_scope`).

## 3. Telemetria

- `ai_events` já cobre o pipeline; a Fase 1 garante que **toda** etapa emite evento com
  `status` e `payload` padronizados.
- Erros mapeados para `error_type` (E) na run e `status='error'` no evento da etapa que falhou.
- Sem nova tabela: observabilidade vem de `ai_runs` + `ai_events` + `ai_capability_executions`.

## 4. Métricas

- Agregações sobre `ai_runs` (com as dimensões de D):
  - Custo e execuções por **agente / departamento / caixa / período**.
  - Latência média, distribuição por `routing_band` e `worker`.
  - Taxa de erro por `error_type`.
- Custos (tela atual) ganha recorte por agente imediatamente (coluna `ai_agent_id` já existe);
  por departamento/caixa após D.

## 5. Roteamento entre departamentos

- **Resolução:** se a caixa está mapeada a 1 departamento (`ai_department_inboxes`), usa direto.
  Se mapeada a vários (ou nenhum), o worker de classificação do perfil escolhe pelo objetivo/etapas.
- **Fallback (novo):** `ai_departments` ganha `position` + `is_default` (migration aditiva).
  Empate ou baixa confiança → departamento padrão; sem padrão → handoff humano.
- Decisão registrada em `department.resolved` com `method: mapped|classified|default`.

## 6. Estratégia de migração sem retrabalho

Princípios:

1. **Migrations aditivas** — só colunas nullable e cópias; nada é dropado nesta fase.
   Limpeza das duplicatas (ex.: `behavior.instructions`, `*_rules.when`) fica para uma
   migration de remoção **posterior**, após o runtime já ler a fonte canônica.
2. **Dupla escrita temporária** onde houver risco — durante a transição B/C, escrever na
   fonte nova e manter a antiga lida como fallback até a virada.
3. **Feature flag por conta** — Gateway live atrás de flag; shadow pode rodar antes,
   gerando dados sem risco ao cliente.
4. **Ordem de entrega:**
   `migrations A–E` → `Gateway (shadow)` → `Telemetria/Métricas` → `Roteamento` →
   `promoção live (canário)` → `migration de limpeza das duplicatas`.
5. **Deploy Coolify:** migrations no release; WEB e WORKER redeployados juntos
   (Sidekiq consome o pipeline). Sem isso o Gateway não roda.

Resultado: cada PR funcional encaixa num contrato já definido; nenhuma tela construída na
fase visual precisa ser refeita.

---

## Sequência de PRs sugerida

| PR | Conteúdo | Risco |
|---|---|---|
| F1.0 | Migrations A–E (aditivas) + modelos/validações | Baixo |
| F1.1 | Gateway em modo shadow + emissão de eventos | Baixo (sem efeito externo) |
| F1.2 | Telemetria/Métricas (agregações + recortes na UI de Custos/Shadow) | Baixo |
| F1.3 | Roteamento entre departamentos + `is_default`/`position` | Médio |
| F1.4 | Promoção live atrás de flag + gate de ferramentas | Médio |
| F1.5 | Migration de limpeza das duplicatas (após virada) | Médio |
