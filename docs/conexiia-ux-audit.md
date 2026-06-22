# Auditoria de UX — Conexiia IA

> Auditoria de **experiência**, não de backend. Princípio que rege tudo:
> **o usuário ensina a empresa para a IA; ele não configura infraestrutura de IA.**
> Conceitos técnicos (RAG, embeddings, chunking, vetores, workers, classificadores, OCR,
> pipelines) são internos e nunca devem aparecer na experiência principal.

Legenda de status: ✅ feito · 🟡 UX agora (sem backend) · 🔵 backend/futuro.

---

## 1. SLA está semanticamente incorreto 🟡

**Hoje:** o campo "SLA" do departamento mostra "Tempo de resposta (minutos)" e a ação
"Ao estourar o SLA: Encerrar conversa".

**O que realmente faz (runtime):** `Ai::SlaSweepJob` encerra conversas **paradas há N minutos
sem atividade**. Não mede tempo de resposta da IA — é um **auto-encerramento por inatividade**.

**Problema:** o rótulo "Tempo de resposta" + "Encerrar conversa" é herança do Chatwoot e descreve
mal a função. Uma IA não deve encerrar por "demorar a responder"; ela responde em segundos.

**Recomendação (UX, sem backend):** renomear honestamente para o que é — por exemplo
"**Encerrar automaticamente conversas inativas após N minutos**" — ou remover do produto se o
auto-encerramento não for valor claro. Um "SLA de resposta" de verdade não precisa existir; o
SLA que importa ("tempo até um humano assumir") é papel do SLA global do Chatwoot.

## 2. Horário de funcionamento está correto — só melhorar nomenclatura 🟡

**Hoje:** o departamento tem um único toggle "Respeitar o horário de funcionamento da caixa".
Em runtime, `Ai::ReplyPolicy` apenas consulta `inbox.out_of_office?` — **a Caixa é a fonte de
verdade**, não há um segundo cadastro de horário no departamento. O modelo está certo.

**Recomendação (UX):** apenas reforçar a copy de que o horário vem **da Caixa** (o toggle só
liga/desliga "respeitar"). Nada estrutural a mudar.

## 3. Copiloto deve consumir créditos da conta 🔵

**Hoje:** toda chamada de LLM (autoatendimento, classificação, RAG, shadow e **copiloto**) passa
pelo `Ai::ModelRouter`, que usa **uma única chave de API no nível da plataforma**. O custo é
**registrado** por conta em `ai_runs` (inclusive `run_type = copilot`), mas **não há carteira de
créditos, dedução ou limite**. Na prática, hoje a Conexiia paga o provedor por tudo.

**Recomendação (backend/futuro):** adotar o **Modelo A** — todo consumo (incl. copiloto) sai da
carteira do cliente. A base já existe (custo por conta em `ai_runs`); falta carteira/saldo +
dedução + enforcement (e, opcionalmente, BYOK). Orçamento é **política de conta**, não do perfil.

## 4. Conhecimento precisa suportar importação em massa 🔵

**Hoje:** o backend (`AiKnowledgeSourcesController`) só aceita **texto manual** (kind/título/raw).
Não há upload de arquivo, crawler de site nem importação de planilha.

**Recomendação (backend/futuro):**
- **FAQ:** importação CSV (pergunta, resposta).
- **Produtos e serviços:** importação CSV/planilha (nome, descrição, preço).
- **Documentos:** upload de PDF/DOCX/TXT/MD + parsing + status de processamento.
- **Site:** importar e indexar páginas a partir de uma URL.

Até existir o backend, esses tipos aparecem como **"em breve" 🚧** (já feito no #115), nunca como
affordance falsa de upload.

## 5. Remover referências visuais a RAG/embeddings/chunking/indexação ✅

**Feito no #115:** purgada a terminologia técnica das telas do cliente (Conhecimento, Teste/Lab,
Shadow) — "trechos", "indexado para busca (RAG)", "Score vetorial", "Worker utilizado",
"classificador". Os termos técnicos permanecem **apenas em Perfis → Avançado**, superfície que a
diretriz autoriza para especialistas. *(Pendente de deploy da sandbox.)*

## 6. Princípio: o usuário ensina a empresa, não configura IA ✅ (registrado)

Registrado na diretriz canônica (`conexiia-product-directive.md`, seção "Conhecimento" + ciclo
**Ensinar → Atender → Medir → Evoluir**). É o critério para validar qualquer tela nova.

---

## Achados a partir dos prints

## 7. Aba "Avançado" do departamento confunde 🟡 (print 1)

**Hoje:** entre as abas-núcleo (Instruções/Conhecimento/Etapas/Ferramentas) e as secundárias
(Comportamento/Follow-up/Integrações) existe um rótulo "Avançado". Ele **não é clicável** — é um
separador de grupo —, mas visualmente parece **uma aba desabilitada**, o que gera a dúvida
"qual é a função disso?".

**Recomendação (UX):** ou **remover** o pseudo-rótulo e separar os grupos só por espaçamento/
divisória clara, ou transformá-lo num cabeçalho inequívoco (não alinhado como aba). O objetivo é
nunca parecer um item clicável quebrado.

## 8. "Resposta ao cliente" x "modo Live" é ambíguo 🟡 (print 2)

**Hoje:** a Caixa define o modo do agente (**Live** = pode responder · **Shadow** = só observa).
Dentro do departamento, "Resposta ao cliente → Quando enviar a resposta" oferece "Desligada (só
observa) · Apenas conversas com label canário · Todas as conversas", com a nota "Só vale em caixas
no modo Live".

**Problema:** são **duas camadas de liga/desliga** com vocabulário conflitante — dizer que a caixa
"é a que responde (Live)" e ao mesmo tempo oferecer "só observa" no departamento soa contraditório.

**O que isso é de fato:** um **rollout progressivo de segurança** dentro de uma caixa já Live
(começa sem responder ninguém → só conversas marcadas → todas). Não é um segundo "ligar IA".

**Recomendação (UX):** reescrever como alcance/rollout, sem repetir "ligar/desligar". Ex.:
"**Alcance da resposta automática**: Ninguém ainda (só observa) · Só conversas marcadas (canário) ·
Todas". E deixar claro que isso é uma liberação gradual **dentro** de uma caixa Live.

## 9. Tela de Follow-up não comunica a função 🟡 (print 3)

**O que faz (runtime):** quando a **última mensagem da conversa foi nossa e o cliente ficou em
silêncio** por N minutos, a IA envia **uma** mensagem proativa de retomada (um cutucão). Dispara
uma vez por silêncio e respeita as mesmas regras de horário/canário/kill-switch.

**Problema:** "Follow-up / Aguardar (minutos) / Mensagem de follow-up" não explica **quando**
dispara nem para quem; o termo "follow-up" é jargão.

**Recomendação (UX):** renomear para algo como "**Retomar conversa parada**" e descrever o
gatilho: "Se o cliente ficar **N minutos sem responder** depois da última mensagem da IA, enviar
automaticamente esta mensagem (uma vez)." Mantém o conceito, só comunica melhor.

---

## Resumo de prioridade

| # | Achado | Status | Tipo |
|---|--------|--------|------|
| 5 | Terminologia técnica nas telas | ✅ #115 | UX (feito) |
| 6 | Princípio "ensinar a empresa" | ✅ diretriz | Doc |
| 1 | "SLA" → auto-encerramento por inatividade | 🟡 | UX copy/decisão |
| 2 | Horário — reforçar copy "vem da Caixa" | 🟡 | UX copy |
| 7 | "Avançado" parece aba quebrada | 🟡 | UX |
| 8 | "Resposta ao cliente" vs Live | 🟡 | UX (reframe rollout) |
| 9 | Follow-up não comunica função | 🟡 | UX copy |
| 3 | Copiloto consome créditos da conta | 🔵 | Backend (créditos) |
| 4 | Importação em massa (CSV/upload/site) | 🔵 | Backend |
