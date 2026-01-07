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
  - Exibição de QR code
  - Polling de status de conexão
  - Botão para reconexão

- `app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Whatsapp.vue` (modificado)
  - Adicionado UazAPI à lista de provedores disponíveis

- `app/javascript/dashboard/routes/dashboard/settings/inbox/Index.vue` (modificado)
  - Exibição de status de conexão UazAPI
  - Botões de reconexão e refresh de status

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
  "pair_code": ""
}
```

**Status possíveis:**
- `disconnected`: Desconectado
- `connecting`: Conectando
- `connected`: Conectado

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

## Troubleshooting

### Problema: Erro 422 ao criar instância

**Causa**: `UAZAPI_ADMIN_TOKEN` não configurado ou inválido

**Solução**:
1. Verifique se `UAZAPI_ADMIN_TOKEN` está no `.env`
2. Recrie os containers: `docker compose down && docker compose up -d`
3. Verifique logs: `docker compose logs rails | grep UAZAPI`

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

## Referências

- [Especificação OpenAPI UazAPI](./uazapi-openapi-spec.yaml)
- [Documentação Chatwoot WhatsApp Channels](https://www.chatwoot.com/docs/product/channels/whatsapp)

## Changelog

### 2026-01-07
- Integração inicial do UazAPI como provedor de WhatsApp
- Implementação de criação, conexão e gerenciamento de instâncias
- Implementação de webhooks para recebimento de mensagens
- Implementação de deleção automática de instâncias
- Correção de problemas com Sidekiq e Redis
- Adição de interface para gerenciamento de status e reconexão

