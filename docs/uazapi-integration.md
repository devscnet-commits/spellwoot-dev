# Integração UazAPI - Documentação Técnica

## Visão Geral

Esta documentação descreve a integração do UazAPI como um novo provedor de WhatsApp no Chatwoot. O UazAPI permite gerenciar instâncias do WhatsApp através de uma API REST, incluindo criação de instâncias, conexão via QR code, recebimento de mensagens via webhooks e gerenciamento do ciclo de vida das instâncias.

## Arquitetura

A integração segue a arquitetura existente do Chatwoot para provedores de WhatsApp:

```
┌─────────────────┐
│   Frontend      │
│  (Vue.js)       │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  API Controllers│
│  (Rails)        │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   Services      │
│  (Ruby)         │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   UazAPI API    │
│  (HTTP/REST)    │
└─────────────────┘
```

### Componentes Principais

1. **Frontend (Vue.js)**
   - Componente de criação de inbox UazAPI
   - Exibição de QR code e status de conexão
   - Gerenciamento de reconexão

2. **Backend (Rails)**
   - Controllers para criação e gerenciamento de inboxes
   - Services para comunicação com UazAPI
   - Jobs para processamento de webhooks
   - Webhook controller para receber mensagens

3. **UazAPI**
   - API REST para gerenciamento de instâncias
   - Webhooks para notificações de mensagens

## Arquivos Criados

### Backend

#### Services
- `app/services/whatsapp/providers/uazapi_service.rb`
  - Service principal para comunicação com UazAPI
  - Herda de `Whatsapp::Providers::BaseService`
  - Implementa métodos: `send_message`, `send_template`, `create_instance`, `connect`, `get_status`, `setup_webhook`, `delete_instance`

- `app/services/whatsapp/uazapi_connection_service.rb`
  - Orquestra a criação completa de inbox UazAPI
  - Cria instância UazAPI, canal WhatsApp, inbox Chatwoot
  - Gerencia conexão e configuração de webhook

- `app/services/whatsapp/incoming_message_uazapi_service.rb`
  - Processa mensagens recebidas via webhook
  - Herda de `Whatsapp::IncomingMessageBaseService`
  - Converte mensagens UazAPI para formato Chatwoot

- `app/services/whatsapp/webhook_teardown_service.rb` (modificado)
  - Adicionada lógica para deletar instância UazAPI quando inbox é removido

#### Controllers
- `app/controllers/api/v1/accounts/uazapi_inboxes_controller.rb`
  - Endpoint para criação de inboxes UazAPI
  - Retorna QR code e status inicial
  - Validação de telefone: exatamente 13 dígitos numéricos
  - Limpeza automática de caracteres não numéricos do telefone

- `app/controllers/api/v1/accounts/inboxes_controller.rb` (modificado)
  - Adicionados endpoints: `uazapi_status`, `uazapi_connect`, `uazapi_disconnect`

- `app/controllers/webhooks/uazapi_controller.rb`
  - Recebe webhooks do UazAPI
  - Valida token e enfileira job para processamento

#### Jobs
- `app/jobs/webhooks/uazapi_events_job.rb`
  - Processa eventos recebidos via webhook
  - Delega processamento de mensagens para `IncomingMessageUazapiService`

#### Models
- `app/models/channel/whatsapp.rb` (modificado)
  - Adicionado `'uazapi'` aos provedores disponíveis
  - Método `uazapi?` para verificação de tipo
  - Roteamento para `UazapiService`

#### Policies
- `app/policies/inbox_policy.rb` (modificado)
  - Adicionados métodos de autorização: `uazapi_status?`, `uazapi_connect?`, `uazapi_disconnect?`

#### Views
- `app/views/api/v1/models/_inbox.json.jbuilder` (modificado)
  - Adicionado campo `is_uazapi` na serialização de inbox

### Frontend

#### Componentes Vue
- `app/javascript/dashboard/routes/dashboard/settings/inbox/channels/UazapiWhatsapp.vue`
  - Componente principal para criação de inbox UazAPI
  - Formulário com nome e número de telefone
  - Validação de telefone: exatamente 13 dígitos numéricos (frontend)
  - Limpeza automática de caracteres não numéricos antes do envio
  - Exibição de QR code
  - Polling de status de conexão
  - Botão para reconexão

- `app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Whatsapp.vue` (modificado)
  - Adicionado UazAPI à lista de provedores disponíveis

- `app/javascript/dashboard/routes/dashboard/settings/inbox/Index.vue` (modificado)
  - Exibição de status de conexão UazAPI
  - Busca automática de status ao carregar a listagem de inboxes
  - Badge de status baseado exclusivamente no campo `status` do backend
  - Botão "Reconnect WhatsApp" com modal completo contendo QR code
  - Polling automático de status durante reconexão até ficar conectado
  - Botão de refresh de status manual

- `app/javascript/dashboard/routes/dashboard/settings/inbox/Settings.vue` (modificado)
  - Exibição de Instance ID e Instance Token
  - Botões para copiar informações

#### API Clients
- `app/javascript/dashboard/api/uazapi.js`
  - Cliente API para endpoints UazAPI
  - Métodos: `createInbox`, `getStatus`, `connect`, `disconnect`

- `app/javascript/dashboard/api/inboxes.js` (modificado)
  - Adicionados métodos: `getUazapiStatus`, `connectUazapi`

#### Internacionalização
- `app/javascript/dashboard/i18n/locale/en/inboxMgmt.json` (modificado)
  - Adicionadas traduções para UazAPI
- `app/javascript/dashboard/i18n/locale/pt_BR/inboxMgmt.json` (modificado)
  - Adicionadas traduções completas para UazAPI em português do Brasil
  - Traduções para formulário, status, mensagens de erro e sucesso
- `config/locales/pt_BR.yml` (modificado)
  - Adicionada tradução para `activerecord.errors.messages.record_invalid`
  - Adicionada tradução para `errors.uazapi.phone_number_invalid`

### Configuração

#### Routes
- `config/routes.rb` (modificado)
  - Adicionadas rotas:
    - `POST /api/v1/accounts/:account_id/uazapi_inboxes`
    - `GET /api/v1/accounts/:account_id/inboxes/:id/uazapi_status`
    - `POST /api/v1/accounts/:account_id/inboxes/:id/uazapi_connect`
    - `POST /api/v1/accounts/:account_id/inboxes/:id/uazapi_disconnect`
    - `POST /webhooks/uazapi/:phone_number`

#### Docker
- `docker/entrypoints/sidekiq.sh` (criado)
  - Script de inicialização do Sidekiq
  - Aguarda PostgreSQL e Redis estarem prontos

- `docker-compose.yaml` (modificado)
  - Configuração do serviço Sidekiq com entrypoint customizado

#### Redis
- `lib/redis/config.rb` (modificado)
  - Timeout aumentado de 1s para 10s

## Configuração Necessária

### Variáveis de Ambiente

Adicione as seguintes variáveis ao arquivo `.env`:

```bash
# UazAPI Configuration
UAZAPI_BASE_URL=https://api.uazapi.com  # ou https://free.uazapi.com
UAZAPI_ADMIN_TOKEN=seu_token_admin_aqui
UAZAPI_WEBHOOK_BASE_URL=https://seu-dominio.com  # URL base para webhooks
```

**Importante**: 
- `UAZAPI_ADMIN_TOKEN`: Token administrativo fornecido pelo UazAPI
- `UAZAPI_WEBHOOK_BASE_URL`: URL base do seu Chatwoot (usado para construir URLs de webhook)
- Após adicionar/modificar variáveis no `.env`, recrie os containers: `docker compose down && docker compose up -d`

### Redis

Certifique-se de que o Redis está configurado corretamente:

```bash
REDIS_PASSWORD=redis123  # ou sua senha
```

## Fluxo de Funcionamento

### 1. Criação de Inbox UazAPI

```
Usuário preenche formulário
    ↓
Frontend chama POST /api/v1/accounts/:account_id/uazapi_inboxes
    ↓
UazapiConnectionService.perform
    ↓
1. Cria instância no UazAPI (POST /instance/init)
2. Cria Channel::Whatsapp no Chatwoot
3. Cria Inbox no Chatwoot
4. Conecta instância (POST /instance/connect) → retorna QR code
5. Configura webhook (POST /webhook)
    ↓
Retorna QR code e status para frontend
    ↓
Frontend exibe QR code e inicia polling de status
```

### 2. Conexão via QR Code

```
Usuário escaneia QR code no WhatsApp
    ↓
Frontend faz polling em GET /api/v1/accounts/:account_id/inboxes/:id/uazapi_status
    ↓
Backend consulta UazAPI (GET /instance/status)
    ↓
Quando status = "connected", frontend para polling
```

### 3. Recebimento de Mensagens

```
UazAPI recebe mensagem do WhatsApp
    ↓
UazAPI envia webhook para POST /webhooks/uazapi/:phone_number
    ↓
UazapiController valida token e enfileira UazapiEventsJob
    ↓
UazapiEventsJob processa evento
    ↓
IncomingMessageUazapiService converte mensagem
    ↓
Mensagem criada no Chatwoot
```

### 4. Envio de Mensagens

```
Usuário envia mensagem no Chatwoot
    ↓
Channel::Whatsapp usa UazapiService
    ↓
UazapiService.send_message
    ↓
POST /message/text para UazAPI
    ↓
UazAPI envia mensagem via WhatsApp
```

### 5. Deleção de Inbox

```
Usuário deleta inbox no Chatwoot
    ↓
WebhookTeardownService é chamado
    ↓
Verifica se é inbox UazAPI
    ↓
Chama UazapiService.delete_instance
    ↓
DELETE /instance para UazAPI
    ↓
Instância removida do UazAPI
```

## Endpoints da API

### Criar Inbox UazAPI

**POST** `/api/v1/accounts/:account_id/uazapi_inboxes`

**Request Body:**
```json
{
  "inbox_name": "Suporte WhatsApp",
  "phone_number": "5511999999999"
}
```

**Validação:**
- `phone_number`: Deve ter exatamente 13 dígitos numéricos
- Caracteres não numéricos são removidos automaticamente antes da validação
- Validação ocorre tanto no frontend quanto no backend

**Response:**
```json
{
  "qr_code": "data:image/png;base64,...",
  "status": "connecting",
  "pair_code": "ABC123",
  "inbox": {
    "id": 1,
    "name": "Suporte WhatsApp",
    ...
  }
}
```

### Obter Status

**GET** `/api/v1/accounts/:account_id/inboxes/:id/uazapi_status`

**Response:**
```json
{
  "qr_code": "data:image/png;base64,...",
  "status": "connected",
  "pair_code": "",
  "connected": true,
  "logged_in": false,
  "profile_name": "Nome do Perfil",
  "profile_pic_url": "https://..."
}
```

**Status possíveis:**
- `disconnected`: Desconectado
- `connecting`: Conectando (aguardando escaneamento do QR code)
- `connected`: Conectado e pronto para uso

**Nota Importante**: O frontend utiliza **exclusivamente** o campo `status` para determinar o estado da conexão. Os campos `connected` e `logged_in` são ignorados para evitar inconsistências, pois podem retornar valores diferentes do estado real representado por `status`.

### Conectar

**POST** `/api/v1/accounts/:account_id/inboxes/:id/uazapi_connect`

**Response:**
```json
{
  "qr_code": "data:image/png;base64,...",
  "status": "connecting",
  "pair_code": "ABC123"
}
```

### Desconectar

**POST** `/api/v1/accounts/:account_id/inboxes/:id/uazapi_disconnect`

**Response:**
```json
{
  "message": "Disconnected successfully"
}
```

### Webhook (UazAPI → Chatwoot)

**POST** `/webhooks/uazapi/:phone_number`

**Headers:**
```
token: <instance_token>
```

**Request Body:**
```json
{
  "event": "messages.upsert",
  "data": {
    "key": {...},
    "message": {...},
    ...
  }
}
```

## Estrutura de Dados

### Channel::Whatsapp (UazAPI)

O canal armazena as seguintes informações em `provider_config`:

```ruby
{
  "api_key" => "instance_token",  # Token da instância
  "phone_number" => "5511999999999",
  "provider" => "uazapi",
  "uazapi_instance_id" => "instance_id_from_uazapi"
}
```

## Validação de Dados

### Validação de Telefone

O número de telefone é validado tanto no frontend quanto no backend:

**Requisitos:**
- Deve ter exatamente 13 dígitos numéricos
- Apenas números são aceitos (caracteres não numéricos são removidos automaticamente)
- Exemplo válido: `5511999999999`

**Frontend:**
- Validação em tempo real usando Vuelidate
- Mensagem de erro exibida imediatamente ao usuário
- Caracteres não numéricos são removidos antes do envio

**Backend:**
- Validação no controller antes de processar
- Retorna erro 422 se a validação falhar
- Mensagem de erro traduzida conforme o locale do sistema

**Mensagens de Erro:**
- Português (pt_BR): "O número de telefone deve ter exatamente 13 dígitos numéricos"
- Inglês (en): "Phone number must have exactly 13 numeric digits"

## Troubleshooting

### Problema: Erro 422 ao criar instância

**Causa**: `UAZAPI_ADMIN_TOKEN` não configurado ou inválido, ou número de telefone inválido

**Solução**:
1. Verifique se `UAZAPI_ADMIN_TOKEN` está no `.env`
2. Verifique se o número de telefone tem exatamente 13 dígitos numéricos
3. Recrie os containers: `docker compose down && docker compose up -d`
4. Verifique logs: `docker compose logs rails | grep UAZAPI`

### Problema: Erro de validação de telefone

**Causa**: Número de telefone não atende aos requisitos (13 dígitos numéricos)

**Solução**:
1. Verifique se o número tem exatamente 13 dígitos
2. Remova caracteres não numéricos (espaços, parênteses, hífens, etc.)
3. Exemplo correto: `5511999999999` (13 dígitos)
4. O sistema remove automaticamente caracteres não numéricos, mas o resultado final deve ter 13 dígitos

### Problema: QR code não aparece

**Causa**: Erro na chamada para UazAPI ou instância não criada

**Solução**:
1. Verifique logs do Rails: `docker compose logs rails`
2. Verifique se `UAZAPI_BASE_URL` está correto
3. Teste manualmente a API do UazAPI

### Problema: Mensagens não chegam

**Causa**: Webhook não configurado ou URL incorreta

**Solução**:
1. Verifique se `UAZAPI_WEBHOOK_BASE_URL` está correto
2. Verifique logs do webhook: `docker compose logs rails | grep webhook`
3. Verifique se o webhook foi configurado no UazAPI (via `setup_webhook`)

### Problema: Sidekiq não inicia

**Causa**: Redis não acessível ou timeout

**Solução**:
1. Verifique se Redis está rodando: `docker compose ps redis`
2. Verifique `REDIS_PASSWORD` no `.env`
3. Verifique logs: `docker compose logs sidekiq`
4. Aumente timeout em `lib/redis/config.rb` se necessário

### Problema: Status sempre "disconnected"

**Causa**: Instância não conectada ou erro na consulta de status

**Solução**:
1. Use o botão "Reconnect" na interface
2. Verifique logs: `docker compose logs rails | grep status`
3. Verifique se a instância existe no UazAPI

### Problema: Instância não deletada ao remover inbox

**Causa**: `WebhookTeardownService` não chamado ou erro na deleção

**Solução**:
1. Verifique logs: `docker compose logs rails | grep delete_instance`
2. Verifique se `UAZAPI_ADMIN_TOKEN` está correto
3. Delete manualmente no UazAPI se necessário

### Problema: Traduções aparecem em inglês

**Causa**: Locale do sistema não está configurado como `pt_BR`

**Solução**:
1. Verifique as configurações de idioma do usuário ou da conta
2. Certifique-se de que o locale está configurado como `pt_BR`
3. Reinicie os serviços: `docker compose restart vite rails`
4. Faça um hard refresh no navegador (Ctrl+Shift+R ou Cmd+Shift+R)

## Testes

### Testar Criação de Inbox

```bash
curl -X POST http://localhost:3000/api/v1/accounts/1/uazapi_inboxes \
  -H "Content-Type: application/json" \
  -H "api_access_token: seu_token" \
  -d '{
    "inbox_name": "Teste",
    "phone_number": "5511999999999"
  }'
```

### Testar Status

```bash
curl http://localhost:3000/api/v1/accounts/1/inboxes/1/uazapi_status \
  -H "api_access_token: seu_token"
```

### Testar Webhook (simulação)

```bash
curl -X POST http://localhost:3000/webhooks/uazapi/5511999999999 \
  -H "Content-Type: application/json" \
  -H "token: instance_token" \
  -d '{
    "event": "messages.upsert",
    "data": {...}
  }'
```

## Notas Importantes

1. **WhatsApp Business**: É recomendado usar contas WhatsApp Business para maior estabilidade
2. **Limites**: O UazAPI pode ter limites de instâncias conectadas
3. **Webhooks**: A URL do webhook é construída automaticamente usando `UAZAPI_WEBHOOK_BASE_URL`
4. **Tokens**: Cada instância tem seu próprio token, armazenado em `provider_config.api_key`
5. **Status**: O status é consultado via polling no frontend, não via webhooks
6. **Deleção**: Ao deletar inbox, a instância UazAPI é automaticamente removida
7. **Campo Status**: O frontend utiliza exclusivamente o campo `status` da resposta do backend para exibir o estado da conexão. Os campos `connected` e `logged_in` são ignorados para garantir consistência
8. **Busca Automática de Status**: Ao carregar a listagem de inboxes, o status de todos os inboxes UazAPI é buscado automaticamente do backend
9. **Reconexão**: O botão "Reconnect WhatsApp" abre um modal com QR code e faz polling automático até a conexão ser estabelecida
10. **Validação de Telefone**: O número de telefone deve ter exatamente 13 dígitos numéricos. Caracteres não numéricos são removidos automaticamente, mas o número final deve ter exatamente 13 dígitos para ser aceito
11. **Internacionalização**: A integração está totalmente traduzida para português do Brasil (pt_BR). Certifique-se de que o locale do sistema está configurado como `pt_BR` para ver todas as traduções

## Referências

- [Especificação OpenAPI UazAPI](./uazapi-openapi-spec.yaml)
- [Documentação Chatwoot WhatsApp Channels](https://www.chatwoot.com/docs/product/channels/whatsapp)

## Changelog

### 2026-01-07 (Internacionalização e Validações)
- **Tradução completa para português do Brasil**: Todas as strings da interface UazAPI foram traduzidas para pt_BR
  - Traduções adicionadas em `app/javascript/dashboard/i18n/locale/pt_BR/inboxMgmt.json`
  - Traduções de erros adicionadas em `config/locales/pt_BR.yml`
  - Correção de erro de tradução faltante: `activerecord.errors.messages.record_invalid`
- **Validação de telefone**: Implementada validação rigorosa do número de telefone
  - Frontend: Validação em tempo real com Vuelidate (exatamente 13 dígitos numéricos)
  - Backend: Validação no controller antes de processar a requisição
  - Limpeza automática: Caracteres não numéricos são removidos automaticamente
  - Mensagens de erro traduzidas em português do Brasil
  - Validação garante formato consistente: `5511999999999` (13 dígitos)

### 2026-01-07 (Atualizações)
- **Correção do status na listagem**: Status de inboxes UazAPI agora é buscado automaticamente ao carregar a página, evitando exibição incorreta de "disconnected"
- **Implementação completa do botão Reconnect**: Botão "Reconnect WhatsApp" agora abre modal com QR code e faz polling automático até conexão ser estabelecida
- **Correção do badge de status**: Badge agora utiliza exclusivamente o campo `status` do backend, ignorando campos `connected` e `logged_in` para evitar inconsistências
- Melhoria na experiência do usuário com feedback visual durante reconexão

### 2026-01-07 (Integração Inicial)
- Integração inicial do UazAPI como provedor de WhatsApp
- Implementação de criação, conexão e gerenciamento de instâncias
- Implementação de webhooks para recebimento de mensagens
- Implementação de deleção automática de instâncias
- Correção de problemas com Sidekiq e Redis
- Adição de interface para gerenciamento de status e reconexão

