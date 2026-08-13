# Baseline de custo da IA

Ferramenta **read-only** para documentar o custo/tokens da IA antes de qualquer otimização.
Lê apenas a tabela `ai_runs` (model `Ai::Run`) com `SELECT` agregado — **não escreve nada** no banco
(nenhum `update`/`delete`/`create`, nenhuma migração).

## O que a task imprime

`ai:cost_report[dias]` (default 7 dias) imprime, para o período:

- **a)** custo total, `tokens_in`/`tokens_out` e contagem de runs **por `run_type`**
  (`decision` = supervisor/decide, `capture_judge`, `shadow_eval`, `followup`, e outros);
- **b)** custo **por conta** (top 10 por custo);
- **c)** custo médio e `tokens_in` médio **por conversa** (agrupado por `conversation_id`) e **por turno** (por run);
- **d)** taxa de status (**recorded** vs **error**) por `run_type`;
- **e)** se a coluna `cached_tokens` existir: soma total e **% de runs com `cached_tokens > 0`**.

> Observação: `cost` é o valor **gravado** em `ai_runs.cost` no momento da chamada (estimado por
> `Ai::ModelRouter.estimate_cost`). Pode divergir de um recálculo posterior — este baseline usa o gravado.

## Como rodar

### Local (default 7 dias)

```bash
bundle exec rails "ai:cost_report"
```

### Local (período custom, ex.: 30 dias)

```bash
bundle exec rails "ai:cost_report[30]"
```

### No Coolify (container Rails)

Qualquer uma das opções (equivalentes):

```bash
# via rake
bundle exec rake "ai:cost_report[7]"

# via rails runner (quando o binário rake não estiver no PATH do container)
bundle exec rails runner 'Rails.application.load_tasks; Rake::Task["ai:cost_report"].invoke("7")'
```

Em banco vazio a task roda sem erro e imprime zeros / `(sem runs)`.

## Baseline em <DATA>

Rode a task e cole os números abaixo.

### a) Por run_type

| run_type      | runs | cost (USD) | tokens_in | tokens_out |
|---------------|------|------------|-----------|------------|
| decision      |      |            |           |            |
| capture_judge |      |            |           |            |
| shadow_eval   |      |            |           |            |
| followup      |      |            |           |            |
| (outros)      |      |            |           |            |
| **TOTAL**     |      |            |           |            |

### b) Custo por conta (top 10)

| account_id | runs | cost (USD) |
|------------|------|------------|
|            |      |            |

### c) Médias

| métrica                | valor |
|------------------------|-------|
| conversas distintas    |       |
| turnos (runs)          |       |
| cost médio / conversa  |       |
| tokens_in médio / conversa |   |
| cost médio / turno     |       |
| tokens_in médio / turno |      |

### d) Status por run_type

| run_type      | total | recorded (%) | error (%) |
|---------------|-------|--------------|-----------|
| decision      |       |              |           |
| capture_judge |       |              |           |
| shadow_eval   |       |              |           |

### e) cached_tokens

| métrica                    | valor |
|----------------------------|-------|
| soma cached_tokens         |       |
| runs com cache > 0         |       |
| % de runs com cache > 0    |       |
