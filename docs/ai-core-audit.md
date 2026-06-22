# Auditoria do Módulo IA (AI Core) — Congelamento de Arquitetura

> Status: **Arquitetura congelada · Fase visual encerrada.**
> Este documento é a fonte de verdade para entrar na fase funcional sem retrabalho.
> Data da auditoria: 2026-06-22.

O módulo "Agentes IA" (AI Core) é a camada de IA construída sobre o fork do Chatwoot.
Tabelas com prefixo `ai_`, modelos no namespace `Ai::`. Esta auditoria foi feita do
ponto de vista de Product Designer Sênior + CTO de um SaaS que será vendido a clientes:
o objetivo é estabilizar **contratos e UX** antes de codificar o backend pesado, porque
a partir daí cada mudança de UX deixa de custar minutos e passa a custar dias.

---

## 1. Mapa da arquitetura atual (validado)

### 1.1 Hierarquia conceitual

```
Conta (Account)
├── Perfil Operacional (ai_operation_profiles)      ← estratégia de LLM, reutilizável
├── Integrações (ai_integration_links)              ← conectores externos, nível conta
└── Agente IA (ai_agents)                            ← identidade + credenciais
    ├── Caixas do agente (ai_agent_inboxes)          ← onde atende + modo (live/shadow)
    └── Departamento (ai_departments)                ← mini processo operacional
        ├── Playbook (ai_playbooks)                  ← objetivo, etapas, condições
        │   └── Versões (ai_playbook_versions)
        ├── Caixas do departamento (ai_department_inboxes)
        ├── Conhecimento (ai_knowledge_sources → ai_knowledge_chunks + embeddings)
        ├── Ferramentas (ai_tools → ai_integration_links)
        ├── Variáveis de lead (ai_lead_variables)
        └── Integrações habilitadas (ai_department_integrations)
```

Runtime / telemetria (transversal à conversa):

```
Conversa
├── ai_runs                    ← cada geração do modelo (provider, model, tokens, custo, latência, mode)
│   └── ai_events              ← trilha hierárquica do pipeline (department.resolved, knowledge.retrieved…)
├── ai_capability_executions   ← ledger de governança de ferramentas (aprovação + rollback)
└── ai_agent_memory            ← slots + resumo por (conversa, agente)
```

### 1.2 Princípio arquitetural (aprovado, PR #77)

- **Agente = identidade + credenciais.** Nome, empresa, avatar, perfil operacional,
  prompt base, guardrails, ambiente (stage). Não contém o "como atender".
- **Departamento = comportamento.** Cada departamento é um mini processo operacional
  com objetivo, etapas, conhecimento, ferramentas e regras próprias.
- **Perfil Operacional = estratégia de modelos.** Supervisor + workers + roteamento por
  confiança + orçamento. Reutilizável entre agentes.

Esta separação está **correta e não será refatorada.** A fase funcional constrói sobre ela.

---

## 2. Relação Tela ↔ Entidade ↔ Schema

| Tela | Rota | Entidade principal | Tabelas |
|---|---|---|---|
| Agentes (lista) | `ai_agents_index` | Agente | `ai_agents` |
| Agente → Sobre | `ai_agent_detail` | Agente | `ai_agents`, `ai_agent_versions` |
| Agente → Caixas | `ai_agent_detail` | Vínculo agente↔caixa | `ai_agent_inboxes` |
| Agente → Departamentos | `ai_agent_detail` | Departamento (lista) | `ai_departments` |
| Agente → Teste | `ai_agent_detail` | Simulação | `ai_runs` (efêmero no teste) |
| Departamento → Instruções | `ai_department_detail` | Departamento + Playbook | `ai_departments`, `ai_playbooks`, `ai_lead_variables` |
| Departamento → Comportamento | `ai_department_detail` | Departamento (jsonb) | `ai_departments.behavior/transfer_rules/close_rules/sla` |
| Departamento → Conhecimento | embutida | Fonte de conhecimento | `ai_knowledge_sources`, `ai_knowledge_chunks` |
| Departamento → Etapas | `ai_department_detail` | Playbook | `ai_playbooks` |
| Departamento → Ferramentas | embutida | Ferramenta | `ai_tools`, `ai_integration_links` |
| Departamento → Follow-up | `ai_department_detail` | Departamento (jsonb) | `ai_departments.follow_up` |
| Departamento → Integrações | `ai_department_detail` | Vínculo depto↔integração | `ai_department_integrations` |
| Perfis Operacionais | `ai_profiles_index` | Perfil | `ai_operation_profiles` |
| Custos | `ai_costs_index` | Agregação de execuções | `ai_runs` (group by model) |
| Validação (Shadow) | `ai_shadow_runs` | Execuções em modo shadow | `ai_runs` (mode=shadow) + `ai_events` |

**Observações de schema relevantes:**

- **Não existe tabela `ai_shadow_runs`.** A tela de Validação Shadow é `ai_runs`
  filtrada por `mode='shadow'`, enriquecida com `ai_events`.
- **`ai_runs` já carrega** `account_id, conversation_id, ai_agent_id, run_type, mode,
  provider, model, tokens_in, tokens_out, cost, latency_ms, decision(jsonb), status`.
  → Custo **por agente já é consultável hoje** (falta só a tela).
- **`ai_runs` NÃO tem** `ai_department_id` nem `inbox_id` → custo/métrica por
  departamento/caixa exige evolução (item D).
- **`ai_tools` e `ai_knowledge_sources` têm `ai_department_id` nullable** → o schema já
  suporta ferramentas e conhecimento **compartilhados no nível da conta** (a UI ainda não expõe).
- **`ai_agent_inboxes` tem coluna `priority`** (múltiplos agentes por caixa), mas **não há
  prioridade/departamento-padrão** para roteamento *entre departamentos* de um agente.
- **`ai_agents.identity` (jsonb)** está reservada e não é usada por nada hoje.
- **Sem foreign keys no banco** — integridade referencial é só via associações Rails.

---

## 3. Pontos fortes confirmados pelo schema (aprovados, manter)

- **Governança de ferramentas madura** — `ai_capability_executions` com três níveis
  (`allowed`/`require_confirmation`/`require_approval`), workflow de aprovação
  (`approval_status`, `approved_by_user_id`) e `rollback_data` para desfazer ações
  mutáveis. Em shadow nada executa: só registra a intenção.
- **Observabilidade de pipeline** — `ai_events` hierárquico (`parent_event_id`) cobre cada
  etapa: `message.received → department.resolved → knowledge.retrieved → context.assembled
  → decision.made → tool.executed`.
- **Memória por conversa** — `ai_agent_memory` (state + summary) sustenta coleta de slots.
- **RAG real cabeado** — `pgvector` + gem `neighbor`, embeddings 1536-dim, índice IVFFLAT
  por distância de cosseno em `ai_knowledge_chunks`.
- **Versionamento com snapshot imutável** — `ai_agent_versions` e `ai_playbook_versions`,
  com `snapshot!` idempotente (só versiona em mudança real) e rollback de um clique.
- **Multitenancy** — todo registro `ai_*` carrega `account_id`; rotas exigem `administrator`.
- **Perfis operacionais** — supervisor + workers + roteamento + orçamento, com presets
  Econômico/Balanceado/Premium. Conceito vendável e correto.

---

## 4. Achados da auditoria (consolidado)

### 4.1 Redundâncias

1. **`objetivo` sobrecarregado** — duplicado em **duas colunas** (`ai_departments.objetivo`
   e `ai_playbooks.objetivo`) e com **três papéis na UI**: subtítulo do card, campo
   "Objetivo", e textarea "Instruções do agente". → itens **C** (modelo) + ajuste visual já aplicado.
2. **Transferência/encerramento duplicados** — condições existem em `ai_playbooks`
   (`transfer_when`/`close_when`, aba Etapas) **e** em `ai_departments`
   (`transfer_rules.when`/`close_rules.when`, aba Comportamento). Dois storages para a mesma
   regra. → item **B**.
3. **Tipo/Categoria do agente** — era texto livre cujo placeholder ("ex: Comercial,
   Suporte") espelhava nomes de departamento. Como um agente tem vários departamentos,
   rotular o agente de "Comercial" é enganoso. → **resolvido**: virou categoria controlada
   de organização, sem relação com departamentos (ver §6).

### 4.2 Faltando / esperado pelo cliente

- **Custo por agente/departamento** — hoje Custos é só `by_model` no nível da conta.
  Por agente é trivial (coluna existe); por departamento/caixa exige item **D**.
- **Taxonomia de erro do Shadow** — `status` só diz `'error'`. Falta `error_type`
  estruturado (`provider_timeout`, `knowledge_timeout`, `tool_failed`,
  `guardrail_blocked`, `budget_exceeded`, `classification_failed`). → item **E**.
- **Departamento padrão / prioridade de roteamento** — sem fallback quando o classificador
  fica ambíguo entre N departamentos.
- **Conhecimento/ferramentas compartilhados** — schema já permite (department_id nullable);
  UI não expõe. Importante para contas com muitos departamentos.
- **Filtros de período** em Custos e Shadow (7/30 dias, mês atual).
- **Métricas de resultado** — resolução, handoff, CSAT, deflection (provam ROI).
- **Kill switch global proeminente** — hoje só `auto_attendance` por departamento.
- **Upload real de arquivos** + status de indexação + contagem de chunks por fonte.

### 4.3 Nomenclatura sobrecarregada (revisada — ver §6)

- **"Modelo"** = perfil operacional no Sobre, mas = LLM em Custos/Perfis → relabel para
  "Perfil operacional" no Sobre.
- **Status "Ativo"** colidia com `status active/inactive` → status live relabel para "Ao vivo".
- **"Tipo"** = categoria / capacidade / tipo de dado → coluna da lista relabel para "Categoria".
- **"Shadow"** — confirmado **consistente** (modo de caixa, status derivado e tela de
  Validação significam a mesma coisa: observa e não responde). Mantido; clareza reforçada.

### 4.4 Fluxo confuso (estrutural)

- **4 gates de resposta dispersos** — para a IA responder ao vivo precisam alinhar:
  modo da caixa (`ai_agent_inboxes.mode`) + `behavior.reply_scope` (off/canary/all) +
  `behavior.auto_attendance` + horário. O usuário põe a caixa em "Live" e nada acontece
  porque `reply_scope` nasce `off`. Além disso, o "none" da UI das Caixas não é um modo do
  modelo (`MODES = [live, shadow]` + booleano `active`). → item **A**.

### 4.5 Escalabilidade (muitos agentes/departamentos)

- **Lista de Agentes** — tem busca/filtros/tabela; falta paginação/virtualização para centenas.
- **Aba Departamentos** — **resolvido**: ganhou busca + ordenação (ver §6).
- **Sem grupos/pastas** para agentes e departamentos.
- **Conhecimento/ferramentas** sem busca/paginação quando crescem.

### 4.6 Mobile

- Tabelas escondem colunas secundárias / ganham scroll horizontal; containers com padding
  responsivo. Mobile é ferramenta de admin → "usável" é suficiente. **Aprovado.**

---

## 5. Checklist de bloqueadores para a fase funcional (A–E)

> Estes itens mexem em **migration e/ou comportamento de runtime** e por isso entram
> **junto com o backend**, não na camada visual. Estão aqui como contrato a ser cumprido.

### A) Consolidação dos gates de resposta da IA
- **Problema:** 4 controles dispersos decidem se a IA responde; "none" da UI não existe no modelo.
- **Proposta:** estado único por caixa — `off / shadow / live` — em `ai_agent_inboxes`
  (`mode` passa a aceitar `off`/`none` OU usa-se `active=false` como "off" de forma explícita
  e documentada). `reply_scope` (off/canary/all) vira um **refinamento de rollout dentro de
  `live`** (ex.: live + canário). Horário e `auto_attendance` permanecem como guardas, mas a
  UI deve mostrar um **resumo do estado efetivo** ("Vai responder? Sim/Não e por quê").
- **Contrato p/ Gateway:** o Gateway lê um único método `effective_reply_state(inbox, conversation)`.

### B) Fonte única para transferência e encerramento
- **Problema:** condições duplicadas entre `ai_playbooks` e `ai_departments.*_rules`.
- **Proposta:** **playbook é a fonte de verdade** (`transfer_when`/`close_when`). Os campos
  `transfer_rules.when`/`close_rules.when` em `ai_departments` ficam **só para metadados não
  duplicados** (ex.: `transfer_rules.message`, `close_rules.inactivity_minutes`). Migrar dados
  existentes do depto → playbook e parar de escrever a duplicata.
- **Contrato:** runtime lê condições **apenas** do playbook.

### C) Definição canônica de Objetivo vs Instruções no modelo de dados
- **Problema:** `objetivo` em duas colunas + três papéis na UI.
- **Ajuste visual já aplicado:** UI separa "Objetivo" (curto) de "Instruções" (longo);
  por ora "Instruções" persiste em `ai_departments.behavior.instructions` (sem migration,
  sem efeito de runtime).
- **Decisão canônica (fase funcional):** promover **`instructions` a coluna dedicada** em
  `ai_departments` (text) e manter `objetivo` como resumo curto. `ai_playbooks.objetivo`
  deixa de ser espelho — passa a referenciar (ou é removido em favor do depto).

### D) Evolução de `ai_runs` para métricas por departamento/caixa
- **Problema:** `ai_runs` não tem `ai_department_id` nem `inbox_id`.
- **Proposta:** adicionar `ai_department_id` (nullable, FK lógica) e `inbox_id` (nullable) a
  `ai_runs`, populados pelo Gateway. Opcionalmente promover `routing_band` e `worker` de
  dentro de `decision` (jsonb) para colunas consultáveis se quisermos métricas de roteamento.
- **Ganho:** Custos e Métricas por agente/departamento/caixa sem backfill futuro.

### E) Taxonomia estruturada de erros do Shadow
- **Problema:** `ai_runs.status` só distingue `recorded/running/error`.
- **Proposta:** adicionar `error_type` (string, nullable) a `ai_runs` com enum:
  `provider_timeout, knowledge_timeout, tool_failed, guardrail_blocked, budget_exceeded,
  classification_failed, unknown`. O Gateway preenche; a tela de Shadow exibe o motivo.

---

## 6. Ajustes não-comportamentais aplicados (camada visual/contratual)

Aplicados nesta fase, **sem migration e sem alterar runtime**:

1. **Objetivo vs Instruções (visual)** — aba Instruções do departamento agora tem um campo
   curto "Objetivo" e um textarea separado "Instruções do agente". As instruções persistem
   em `behavior.instructions` (jsonb existente). Decisão canônica de schema fica no item C.
2. **Busca + ordenação na aba Departamentos** — filtro por nome/objetivo e ordenação
   (Nome A–Z / Mais recentes). Puramente frontend.
3. **Categoria controlada** — `category` do agente deixou de ser texto livre e virou uma
   lista controlada **de organização** (Clientes / Parceiros / Equipe interna / Outro),
   **sem relação com departamentos, roteamento ou comportamento**. Serve só para organizar
   e filtrar a lista de agentes.
4. **Nomenclatura desambiguada:**
   - Sobre: "Modelo (perfil operacional)" → **"Perfil operacional"**.
   - Lista: status "Ativo" (live) → **"Ao vivo"**; coluna "Tipo" → **"Categoria"**.
   - "Shadow" mantido (é consistente); reforçado o sentido "observa, não responde".

---

## 7. Itens futuros (não bloqueantes)

Construídos **sobre dados que já existem** — viram tela quando o produto pedir, sem dívida estrutural:

- Custo e métricas por agente/departamento/caixa (depende de D para depto/caixa).
- Filtros de período em Custos e Shadow.
- Métricas de resultado: resolução, handoff, CSAT, deflection.
- Conhecimento e ferramentas compartilhados no nível da conta (schema já suporta).
- Grupos/pastas para agentes e departamentos; paginação/virtualização.
- Inspector de roteamento (distribuição entre departamentos, simulação em conversa real).
- Kill switch global proeminente (pausar IA da conta/agente).
- Upload real de arquivos + status de indexação + contagem de chunks por fonte.
- Editor amigável de schema de Ferramentas (substituir JSON cru).

---

## 8. Decisões arquiteturais aprovadas (congeladas)

| # | Decisão | Status |
|---|---|---|
| 1 | Separação Agente (identidade) ↔ Departamento (comportamento) ↔ Perfil (estratégia) | ✅ Congelada |
| 2 | Perfil Operacional como entidade separada e reutilizável | ✅ Congelada |
| 3 | Conhecimento e Ferramentas escopados ao departamento (com suporte latente a nível conta) | ✅ Congelada |
| 4 | Governança de ferramentas via `ai_capability_executions` (3 níveis + rollback) | ✅ Congelada |
| 5 | Telemetria via `ai_runs` + `ai_events`; Shadow = `ai_runs(mode=shadow)` | ✅ Congelada |
| 6 | RAG via pgvector/neighbor, embeddings 1536-dim | ✅ Congelada |
| 7 | Versionamento por snapshot imutável (agente + playbook) | ✅ Congelada |
| 8 | Playbook como fonte única de transferência/encerramento | 🔜 a efetivar (item B) |
| 9 | `instructions` como coluna dedicada do departamento | 🔜 a efetivar (item C) |
| 10 | `ai_runs` dimensionado por departamento/caixa + `error_type` | 🔜 a efetivar (itens D, E) |

---

## 9. Mapa final validado vs roadmap ConexiIA

| Roadmap | Dado/Tela | Status | Pré-requisito real |
|---|---|---|---|
| Gateway IA | agent_inboxes.mode + behavior + playbook | 🟡 | A + B + alinhar "none" |
| RAG real | knowledge_sources/chunks + pgvector | 🟢 | só upload (futuro) |
| Workers | operation_profiles | 🟢 | nenhum |
| Shadow real | ai_runs(mode=shadow) + ai_events | 🟡 | E |
| Upload de conhecimento | knowledge_sources.raw | 🟡 | storage/indexação (futuro) |
| Métricas operacionais | ai_runs + ai_events | 🟡 | D |
| Custos reais | ai_runs.cost (já tem ai_agent_id) | 🟡 | só UI p/ por-agente; +colunas p/ por-depto (D) |
| Telemetria | ai_events + capability_executions | 🟢 | nenhum estrutural |

**Veredito:** o módulo está arquiteturalmente sadio e mais maduro do que as telas sugerem.
Bloqueadores reais antes de codificar pesado: **A, B, C, D, E** — três decisões de contrato
e duas colunas baratas. Resolvidos, a sequência Gateway → Shadow → Telemetria → Métricas →
Roteamento segue sem retrabalho de UX.

---

## Anexo — Proposta de Fase Funcional 1

Ver `docs/ai-core-phase-1.md`.
