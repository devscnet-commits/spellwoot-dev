# Proposta de UX — Integrações (conectar a IA aos sistemas do cliente)

> Proposta **visual e funcional**, pronta para virar tela. **Sem backend nesta etapa.**
> Regras respeitadas: não muda a arquitetura de Ferramentas; não cria novas capacidades
> internas; mantém a distinção **Capacidades (internas) · Integrações (externas) ·
> Ferramentas (embalagem de negócio que o usuário cria)**.

## Princípio da tela

O cliente pensa: **"quero conectar a IA ao meu sistema"** (cobrança, ERP, CRM), nunca
"vou configurar um endpoint HTTP". Por isso a tela é **negócio primeiro, técnico em segundo
plano** (recolhido em "Detalhes técnicos"). Linguagem de API nunca é protagonista.

### Os 3 conceitos (como aparecem ao usuário)
- **Capacidades** — ações que a IA **já sabe fazer** nativamente (ler/atualizar contato,
  transferir, encerrar). Catálogo fixo, o cliente não cria.
- **Integrações** — **conexões com os sistemas da sua empresa** (ex.: "Cobrança Asaas",
  "ERP IXC"). É o cliente que cria. *(Esta proposta.)*
- **Ferramentas** — a **ação de negócio** que a IA usa numa conversa (ex.: "Consultar fatura"),
  montada em cima de uma Capacidade ou de uma Integração, com governança.

> Frase-guia da área: **"Conecte a IA aos sistemas da sua empresa."**

---

## 1. Tela de lista de Integrações

**Onde fica:** item **Integrações** no grupo *Agentes IA* da navegação (catálogo da conta,
reutilizável por vários departamentos). Também acessível por um atalho no formulário de
Ferramenta ("+ Conectar um sistema").

**Cabeçalho:** título "Integrações" · subtítulo "Conecte a IA aos sistemas da sua empresa
(cobrança, ERP, CRM…)" · botão **+ Nova integração**.

**Colunas (negócio primeiro):**
| Coluna | Conteúdo | Observação |
|---|---|---|
| **Nome** | Nome de negócio ("Cobrança Asaas") | + ícone do sistema |
| **Sistema** | Tipo amigável: "Provedor (IXC)", "Cobrança (Asaas)", "Webhook" | deriva do `kind` |
| **Status** | `Ativa` · `Desativada` · `Com erro` · `Não testada` | chip colorido |
| **Usada em** | "3 ferramentas · 2 departamentos" | mostra impacto antes de mexer |
| **Último teste** | "há 2 h · ✅" / "— · nunca testada" | data + resultado |
| **Ações** | Testar · Editar · Duplicar · Ativar/Desativar · Excluir | menu/ícones |

```
┌ Integrações ──────────────────────────────────── [ + Nova integração ] ┐
│ Conecte a IA aos sistemas da sua empresa.                               │
│ ┌─────────────────────────────────────────────────────────────────────┐│
│ │ Nome             Sistema        Status     Usada em        Teste   ⋯ ││
│ │ 💳 Cobrança Asaas Cobrança       ● Ativa    2 ferramentas   há 2h ✅ ││
│ │ 🌐 ERP IXC        Provedor (IXC) ⚠ Com erro 3 ferramentas   há 1d ❌ ││
│ │ 🔗 Webhook chamado Webhook       ◌ Não testada —            nunca   ││
│ └─────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────┘
```

**Excluir com proteção:** se a integração estiver em uso por Ferramentas, o excluir avisa
("2 ferramentas deixarão de funcionar") e pede confirmação por digitação do nome (padrão do
sistema). Desativar é a opção reversível recomendada.

---

## 2. Tela de criação / edição

Formulário em **duas camadas**: negócio em cima, técnico recolhido. Quase tudo pode vir
**pré-preenchido por um template** (ver §4).

### Bloco 1 — "Sobre esta integração" (negócio)
- **Nome** — "Como você quer chamar?" (ex.: "Cobrança Asaas").
- **Sistema** — seletor com os templates (IXC, SGP, Voalle, Asaas, CRM genérico, Webhook…)
  → mapeia para `kind` e pré-preenche o resto.
- **Para que serve** *(opcional)* — descrição livre ("Consultar faturas e 2ª via").

### Bloco 2 — "Como conectar" (técnico, mas com rótulos de negócio)
| Campo (rótulo de tela) | Campo real | Nota |
|---|---|---|
| **Endereço do sistema (URL)** | `endpoint` | "Onde a IA envia o pedido" |
| **Tipo de chamada** | `http_method` | padrão definido pelo template; recolhido em Avançado |
| **Como o sistema valida o acesso** | `auth` | seletor: *Token de acesso (Bearer)* · *Chave no cabeçalho* · *Sem autenticação* |
| → Token / Cabeçalho + Valor | `auth.token` / `auth.header`+`auth.value` | aparece conforme a opção |

**Detalhes técnicos (recolhido por padrão):**
- **Cabeçalhos extras** (`headers`) — pares chave/valor.
- **Dados fixos enviados** (`payload_template`) — pares chave/valor enviados sempre
  (a IA preenche o resto na hora, ex.: o CPF).
- **Tempo limite** (`timeout_seconds`) e **Tentativas** (`retry_count`).
- **Status** (`active`/`inactive`).

```
┌ Nova integração ───────────────────────────────────────────────┐
│ Sobre                                                           │
│  Nome           [ Cobrança Asaas                              ] │
│  Sistema        [ Cobrança (Asaas)            ▾ ]               │
│  Para que serve [ Consultar faturas e 2ª via                  ] │
│                                                                 │
│ Como conectar                                                   │
│  Endereço (URL) [ https://api.asaas.com/v3/payments           ] │
│  Acesso         [ Token de acesso (Bearer)    ▾ ]               │
│  Token          [ ••••••••••••••••••           ] 👁              │
│                                                                 │
│  ▸ Detalhes técnicos (cabeçalhos, dados fixos, tempo limite…)   │
│                                                                 │
│  [ Testar conexão ]                      [ Cancelar ] [ Salvar ]│
└─────────────────────────────────────────────────────────────────┘
```

Validações mínimas: Nome obrigatório; Endereço obrigatório e formato de URL; se "Token", o
token é obrigatório. Salvar habilitado só com mudanças (dirty state, padrão do sistema).

---

## 3. Teste de conexão

Disponível **no formulário** e **na linha da lista**. Ao testar:
1. (Opcional) o usuário informa **um exemplo de entrada** que a IA usaria (ex.: `cpf`).
2. O sistema faz **uma chamada real** ao endereço e mostra retorno visual claro.

**Sucesso:**
```
✅ Conexão funcionou — resposta em 320 ms (HTTP 200)
   Prévia da resposta:  { "fatura": "...", "vencimento": "..." }   ▸ ver detalhes
```
**Erro (traduzido para negócio + técnico recolhido):**
| Situação | Mensagem de negócio | Detalhe técnico (recolhido) |
|---|---|---|
| 401/403 | "O sistema recusou o acesso. Verifique o token." | `401 Unauthorized` |
| 404 | "Endereço não encontrado. Confira a URL." | `404 Not Found` |
| Timeout | "O sistema demorou demais para responder." | `timeout após 10s` |
| DNS/Conexão | "Não conseguimos alcançar o endereço." | `getaddrinfo / ECONNREFUSED` |

Sempre mostra **tempo de resposta**. Após um teste, atualiza o **Status** (Ativa/Com erro) e o
"Último teste" da lista. *(Requer, no futuro, um endpoint de teste no backend — fora desta etapa.)*

---

## 4. Catálogo de templates

A criação **começa pelo template** (atalho), com a opção "Começar do zero". Templates são
**andaimes de frontend** que pré-preenchem o formulário (kind, URL de exemplo, tipo de auth,
cabeçalhos, esqueleto de dados e **ferramentas sugeridas**). Não são backend; a conexão real
ainda exige a URL/token do cliente.

```
┌ Conectar um sistema ───────────────────────────────────────────┐
│  Escolha o sistema:                                             │
│  [ 🌐 IXC ]  [ 🌐 SGP ]  [ 🌐 Voalle ]                          │
│  [ 💳 Asaas ] [ 🧩 CRM genérico ] [ 🔗 Webhook genérico ]       │
│  [ ＋ Começar do zero ]                                          │
└─────────────────────────────────────────────────────────────────┘
```

| Template | kind | Pré-preenche | Ferramentas sugeridas |
|---|---|---|---|
| **IXC / SGP / Voalle** | `erp` | auth por token, esqueleto de payload | Consultar fatura · 2ª via de boleto · Consultar plano · Abrir chamado · Consultar protocolo |
| **Asaas** | `erp`/`webhook` | auth por token | Consultar cobrança · 2ª via |
| **CRM genérico** | `webhook` | auth por token/cabeçalho | Consultar cadastro · Atualizar dados |
| **Webhook genérico** | `webhook` | mínimo | (livre) |

> Os templates são o que faz o cenário **provedor de internet** virar realidade sem equipe técnica:
> o cliente escolhe "IXC", cola a URL e o token, testa, e já tem ferramentas sugeridas.

---

## 5. Relação com Ferramentas

A Integração é o **cano**; a Ferramenta é a **ação de negócio** que a IA chama. A governança
fica **na Ferramenta**, não na Integração.

```
  Integração                     Ferramenta                      IA
  (conexão externa)              (ação de negócio)               (na conversa)
  "ERP IXC"            ─────►     "Consultar fatura"     ─────►   decide chamar
  URL + token                     governança: Permitido           com input { cpf }
                                  schema: { cpf }
                       ─────►     "Abrir chamado"
                                  governança: Exige confirmação
```

- Uma Integração pode sustentar **várias Ferramentas** (mesmo ERP → "Consultar fatura",
  "Consultar plano", "Abrir chamado").
- Atalho: ao salvar uma Integração, oferecer **"Criar ferramenta a partir desta integração"**
  → abre o formulário de Ferramenta já com Tipo = *Integração* e o conector selecionado;
  resta nomear, escolher **governança** (Permitido / Exige confirmação / Exige aprovação) e o
  **schema de entrada** (campos que a IA preenche).
- No formulário de Ferramenta, o seletor de Integração deixa de ficar vazio: lista as
  integrações **ativas e habilitadas no departamento**, com um link "+ Conectar um sistema".

---

## 6. Relação com Departamentos

- A Integração é **da conta** (catálogo central, reutilizável).
- Cada **Departamento escolhe quais integrações pode usar** — é a aba *Integrações* do
  departamento (já existe, hoje só liga/desliga). Reapresentar como
  **"Sistemas disponíveis neste departamento"** com toggles.
- Uma Ferramenta de um departamento só pode apontar para uma integração **habilitada ali**.
- Fluxo completo:
  1. **Conta:** criar a Integração (esta tela) e testar.
  2. **Departamento → Sistemas disponíveis:** habilitar a integração.
  3. **Departamento → Ferramentas:** criar a Ferramenta sobre ela, com governança e schema.

---

## 7. Linguagem da interface (negócio → técnico)

| Técnico | Como aparece na tela |
|---|---|
| Integration / endpoint | **Integração / Endereço do sistema (URL)** |
| HTTP method | **Tipo de chamada** (recolhido; default por template) |
| Auth / Bearer token | **Como o sistema valida o acesso / Token de acesso** |
| Headers | **Cabeçalhos extras** (em Detalhes técnicos) |
| Payload template | **Dados fixos enviados** (em Detalhes técnicos) |
| Timeout / retry | **Tempo limite / Tentativas** |
| 200/4xx/5xx | traduzidos ("funcionou", "recusou o acesso", "demorou demais") |

Regra de copy: o **rótulo principal é de negócio**; o termo técnico aparece só como apoio
(placeholder, "ver detalhes" ou dentro de "Detalhes técnicos").

---

## 8. Estados vazios e mensagens

- **Nenhuma integração criada:** estado vazio com chamada "Conecte a IA ao seu primeiro
  sistema" + os cards de template + CTA **+ Nova integração**. (Nada de tabela vazia seca.)
- **Integração com erro:** chip vermelho `Com erro`; no detalhe, último teste + motivo
  traduzido + **Testar novamente**. Ferramentas que dependem dela mostram aviso
  ("depende de uma integração com erro").
- **Integração sem teste:** chip âmbar `Não testada` + nudge "Teste antes de usar em
  produção". Permitir salvar, mas sinalizar.
- **Integração desativada:** chip cinza `Desativada`; some do seletor de Ferramentas; as
  Ferramentas que a usam exibem aviso ("integração desativada — a IA não executará esta ação").
- **Excluir em uso:** bloqueia/aviso com a contagem de Ferramentas afetadas; sugere
  **Desativar** em vez de excluir.

---

## Escopo desta proposta × backend (futuro)

**UX agora (frontend):** lista, formulário em 2 camadas, catálogo de templates (constantes de
frontend), estados vazios/erro, reframe da aba do departamento, atalho Integração→Ferramenta.

**Backend necessário depois (fora desta etapa):**
- Rotas `create/update/destroy` + strong params para `ai_integration_links` (hoje só `index`).
- Endpoint de **teste de conexão** (executa a chamada e devolve status/tempo/erro).
- Evoluir o conector para montar **query string** em chamadas GET (hoje envia tudo no corpo JSON).
- Conteúdo real dos **templates** de ERP de ISP (mapeamento de endpoints/campos).

> Nada aqui altera a arquitetura de Ferramentas nem cria capacidades internas. Apenas dá ao
> cliente a porta de entrada que falta: **criar, testar, editar e reutilizar integrações** sem
> depender da equipe técnica.
