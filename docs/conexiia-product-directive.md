# Diretriz de Produto — Conexiia IA

> **Fonte de verdade do produto.** Toda decisão de UX, arquitetura e modelagem do módulo IA
> se valida contra este documento. Em caso de conflito, esta diretriz prevalece.

## Princípio central

A Conexiia **não** é uma plataforma para especialistas em IA. É uma plataforma para empresas
configurarem agentes de atendimento de forma **simples**, com **profundidade opcional** para
usuários avançados.

Prioridades, nesta ordem:
1. Simplicidade para o usuário leigo.
2. Clareza operacional.
3. Evolução gradual da complexidade.
4. Transparência sem poluição visual.
5. Menor quantidade possível de conceitos expostos.

## O que o cliente compra

- **Compra:** atendimento automatizado · economia operacional · qualidade de resposta · melhoria contínua.
- **Não compra:** modelos · workers · embeddings · OCR · pipelines · roteadores · classificadores.

→ Conceitos técnicos **nunca** são protagonistas da experiência.

## Objetos principais

- **Agente = identidade e presença.** Nome, avatar, humano/IA, caixas onde atende, status.
  **Não** é o local principal de configuração da inteligência.
- **Departamento = inteligência operacional. É o objeto mais importante do sistema.** Todo o
  valor vive aqui: objetivo, conhecimento, instruções, etapas, ferramentas. Toda melhoria de
  qualidade acontece prioritariamente no departamento.

## Perfil Operacional

- O conceito "Perfil Operacional" é **interno**. O cliente pensa em **resultado**, não em perfil.
- A experiência principal apresenta **níveis de atendimento**: **Econômico · Equilibrado · Máxima Qualidade**. Nunca conceitos técnicos.
- Perfis continuam existindo internamente como **templates reutilizáveis**; usuários avançados
  podem editá-los; usuários comuns não precisam entendê-los.
- **Orçamento não faz parte do perfil** — é política de gasto, da conta (decisão de modelagem
  fechada na discussão de arquitetura).

## Workers

Não expandir a arquitetura de workers agora. **Não** criar telas/fluxos para Supervisor, OCR,
Tradução, Classificador, RAG, Embeddings. Eles existem internamente, mas **não** fazem parte da
experiência principal. **O cliente não escolhe worker.**

## Conhecimento — o usuário ensina a empresa para a IA

O usuário **não configura IA**: ele **ensina a empresa** para a IA. Ele nunca precisa entender
RAG, embeddings, vetores, chunking, workers, classificadores, OCR ou pipelines — isso é
**infraestrutura interna** da plataforma e permanece invisível.

A área de Conhecimento é organizada por **fontes de negócio**, não por tecnologia:
- **FAQ** — pergunta + resposta (criação rápida; importação CSV no futuro).
- **Documentos** — upload de PDF/DOCX/TXT/MD com status de processamento *(roadmap de backend)*.
- **Site** — importar e indexar páginas de uma URL *(roadmap de backend)*.
- **Produtos e serviços** — nome, descrição e preço (importação CSV no futuro).
- **Procedimentos** — título + passo a passo.

**Nunca exibir** ao cliente: embeddings, chunking, vetores, indexação, RAG ou qualquer
terminologia técnica de IA. O cliente pensa "estou ensinando minha empresa", nunca "estou
configurando um sistema RAG".

### Ciclo oficial do produto: Ensinar → Atender → Medir → Evoluir
1. **Ensinar** — o cliente adiciona FAQ, documentos, site, produtos, procedimentos.
2. **Atender** — a IA usa esse conhecimento para responder.
3. **Medir** — o Shadow monitora dúvidas não respondidas, falhas, baixa confiança, temas recorrentes.
4. **Evoluir** — o Shadow sugere ações ("essa pergunta apareceu 27 vezes e não tem resposta" →
   **Criar FAQ**); o usuário aprova; o conhecimento cresce; a IA melhora. O Shadow é a
   **principal ferramenta de evolução do conhecimento**.

Honestidade: enquanto upload de documentos, importação de site e CSV não existirem no backend,
**não simular** esses fluxos — sinalizar como **"em breve" 🚧**.

## Caminho crítico do produto

O sistema deve ser utilizável apenas com:
1. Criar agente → 2. Criar departamento → 3. Adicionar conhecimento → 4. Instruções →
5. Etapas → 6. Ferramentas → 7. Conectar caixa → 8. Testar → 9. Ativar.

Qualquer configuração fora desse fluxo é **secundária**.

## Shadow (diferencial)

O Shadow ensina o cliente a melhorar a IA continuamente. Deve responder: onde a IA errou · o
que faltou · qual ferramenta deveria ter usado · qual conhecimento faltou · como melhorar.
**Shadow vale mais do que expor detalhes técnicos do motor.**

## Créditos e consumo

O cliente entende facilmente: plano contratado · consumo atual · créditos restantes · compra de
créditos adicionais. **O cliente não precisa entender tokens** — o sistema traduz complexidade
técnica em consumo compreensível.

## Regra para novas funcionalidades (gate da camada principal)

Nada entra na camada principal sem responder **SIM** a pelo menos uma:
1. O cliente consulta isso semanalmente?
2. Ajuda a configurar melhor a IA?
3. Ajuda a entender decisões da IA?
4. Ajuda a economizar dinheiro?

Se **não** para todas → fica em Avançado ou não existe.

## Filosofia final

A Conexiia deve parecer uma **plataforma de atendimento inteligente**, não uma bancada de
engenharia de IA. Complexidade interna é aceitável; complexidade exposta ao cliente, não.

---

## Anexo A — Como o estado atual se compara à diretriz

| Tela / conceito | Estado hoje | Conforme a diretriz? |
|---|---|---|
| Departamento como núcleo (Conhecimento/Instruções/Etapas/Ferramentas) | Existe, mas compete com Comportamento/Follow-up/Integrações no mesmo nível | 🟡 Precisa hierarquizar |
| Perfil exposto como "Econômico/Balanceado/Premium" | Exibido como "Perfil"; formulário expõe **workers, modelos, roteamento** | 🔴 Expõe motor; deve virar "nível de atendimento" e esconder workers |
| Orçamento dentro do Perfil | Campo no perfil | 🔴 Deve sair do perfil (política de conta) |
| Campos sem consumo (Tom de voz, Saudação, Mensagem fora de horário, Encerramento, Escalonamento, "Transferir quando" duplicado, Versão, Descrição) | Visíveis | 🔴 Remover da interface |
| Agente/Sobre | Formulário longo (empresa, site, idioma, categoria, ambiente, voz…) | 🟡 Reduzir a identidade + Avançado |
| Shadow | Painel de inteligência com insights acionáveis | 🟢 Alinhado (manter como diferencial) |
| Créditos/consumo | Existe "Custos" em USD/tokens (técnico) | 🔴 Traduzir para plano/consumo/créditos |

## Anexo B — Backlog derivado (sem decidir prazo aqui)

**UX agora (sem backend, sem expandir workers):**
- Remover campos obsoletos da interface (mantidos no banco).
- Agente/Sobre → identidade + "Avançado".
- Departamento → 4 alavancas como núcleo; Comportamento/Follow-up/Integrações em "Avançado".
- Perfil → reapresentar como **nível de atendimento** (Econômico/Equilibrado/Máxima); workers/modelos/roteamento só em "Avançado" para o power user.
- Conhecimento → reenquadrar como **"Conhecimento da empresa"**, organizado por fontes de negócio (FAQ/Produtos/Procedimentos); purgar terminologia técnica (RAG/trechos/chunk/vetor/worker) das telas do cliente; Documentos/Site/CSV sinalizados como **"em breve" 🚧** até existir backend.

**Funcional/futuro (backend — fora do escopo de UX):**
- Tradução de custo em **plano / consumo / créditos** (esconder tokens).
- Orçamento como política de **conta** (separado do perfil).
- Motor por **departamento** via herança+override (decisão de arquitetura registrada).
- Ligar de verdade os workers internos (maturidade) — sem expor ao cliente.
- Conhecimento: **upload + parsing** de PDF/DOCX/TXT/MD, **importação de site** (URL → páginas), **importação CSV** (FAQ/Produtos), preço estruturado em Produtos e status de processamento.
- Shadow → **Evoluir**: ação "Criar FAQ" a partir de um insight (pergunta recorrente sem resposta vira conhecimento aprovado pelo usuário).
- "SLA" do departamento: renomear para **auto-encerramento por inatividade** (ou remover) — não é SLA de resposta.
