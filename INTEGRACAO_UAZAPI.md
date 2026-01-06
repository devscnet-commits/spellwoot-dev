# Integração uazapi - Análise e Plano de Implementação

## 📋 Sumário Executivo

Este documento contém a análise técnica e o plano de implementação para adicionar a integração com a **uazapi** como uma nova opção de provider WhatsApp no Chatwoot.

**Objetivo**: Adicionar a opção "uazapi" na tela de seleção de providers WhatsApp em `/app/accounts/3/settings/inboxes/new/whatsapp`, com suporte futuro para conexão via QR Code.

---

## 🔍 Análise da Arquitetura Atual

### 1. Estrutura de Providers WhatsApp Existentes

O Chatwoot atualmente suporta os seguintes providers de WhatsApp:

#### Backend (Ruby)
- **Model**: `app/models/channel/whatsapp.rb`
  - Providers suportados: `['default', 'whatsapp_cloud']`
  - `default` = 360Dialog
  - `whatsapp_cloud` = WhatsApp Cloud API (Meta)
  - Campo `provider_config` (JSONB) armazena credenciais específicas de cada provider

#### Services (Ruby)
- **Base Service**: `app/services/whatsapp/providers/base_service.rb`
  - Classe abstrata que define interface comum
  - Métodos obrigatórios: `send_message`, `send_template`, `sync_templates`, `validate_provider_config`
  
- **360Dialog Service**: `app/services/whatsapp/providers/whatsapp_360_dialog_service.rb`
  - API Key authentication
  - Base URL: `https://waba.360dialog.io/v1`
  
- **WhatsApp Cloud Service**: `app/services/whatsapp/providers/whatsapp_cloud_service.rb`
  - Bearer Token authentication
  - Requer: `api_key`, `phone_number_id`, `business_account_id`
  - Base URL: `https://graph.facebook.com`

#### Frontend (Vue.js)
- **Componente Principal**: `app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Whatsapp.vue`
  - Gerencia seleção de providers
  - Define `PROVIDER_TYPES` e `availableProviders`
  
- **Componentes de Configuração**:
  - `360DialogWhatsapp.vue` - Configuração 360Dialog
  - `CloudWhatsapp.vue` - Configuração WhatsApp Cloud (manual)
  - `WhatsappEmbeddedSignup.vue` - OAuth Meta
  - `Twilio.vue` - Configuração Twilio

### 2. Fluxo de Criação de Inbox

```
1. Usuário acessa /settings/inboxes/new
2. Seleciona canal "WhatsApp"
3. Rota: /settings/inboxes/new/whatsapp
4. Componente Whatsapp.vue renderiza seleção de provider
5. Usuário escolhe provider (ex: "uazapi")
6. Query param adicionada: ?provider=uazapi
7. Componente específico renderizado (UazapiWhatsapp.vue)
8. POST /api/v1/accounts/:account_id/inboxes
9. Backend cria Channel::Whatsapp com provider='uazapi'
10. Redirect para adicionar agentes
```

### 3. Estrutura de Dados

#### Tabela `channel_whatsapp`
```sql
CREATE TABLE channel_whatsapp (
  id BIGSERIAL PRIMARY KEY,
  phone_number VARCHAR NOT NULL UNIQUE,
  provider VARCHAR DEFAULT 'default',
  provider_config JSONB,
  message_templates JSONB,
  message_templates_last_updated TIMESTAMP,
  account_id INTEGER NOT NULL,
  created_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL
);
```

#### Exemplo `provider_config` para diferentes providers:

**360Dialog:**
```json
{
  "api_key": "xxxxx",
  "webhook_verify_token": "xxxxx"
}
```

**WhatsApp Cloud:**
```json
{
  "api_key": "xxxxx",
  "phone_number_id": "123456789",
  "business_account_id": "987654321",
  "webhook_verify_token": "xxxxx"
}
```

---

## 🎯 Plano de Implementação - uazapi

### Fase 1: Backend (Ruby on Rails)

#### 1.1. Atualizar Model `Channel::Whatsapp`

**Arquivo**: `app/models/channel/whatsapp.rb`

```ruby
# Adicionar 'uazapi' aos providers suportados
PROVIDERS = %w[default whatsapp_cloud uazapi].freeze
```

#### 1.2. Criar Service Provider para uazapi

**Arquivo**: `app/services/whatsapp/providers/uazapi_service.rb`

```ruby
class Whatsapp::Providers::UazapiService < Whatsapp::Providers::BaseService
  def send_message(phone_number, message)
    # Implementar envio de mensagem via API uazapi
  end

  def send_template(phone_number, template_info, message)
    # Implementar envio de template via API uazapi
  end

  def sync_templates
    # Implementar sincronização de templates da uazapi
    whatsapp_channel.mark_message_templates_updated
    # Fazer requisição para endpoint de templates da uazapi
  end

  def validate_provider_config?
    # Validar credenciais da uazapi
    # Testar conexão com API
    response = HTTParty.post(
      "#{api_base_path}/validate",
      headers: api_headers,
      body: { instance_id: whatsapp_channel.provider_config['instance_id'] }.to_json
    )
    response.success?
  end

  def api_headers
    {
      'Authorization' => "Bearer #{whatsapp_channel.provider_config['api_token']}",
      'Content-Type' => 'application/json'
    }
  end

  def media_url(media_id)
    "#{api_base_path}/media/#{media_id}"
  end

  private

  def api_base_path
    ENV.fetch('UAZAPI_BASE_URL', 'https://api.uazapi.com/v1')
  end

  # Implementar métodos auxiliares específicos da uazapi
end
```

**Campos esperados no `provider_config`**:
```json
{
  "api_token": "token_da_uazapi",
  "instance_id": "id_da_instancia",
  "webhook_verify_token": "token_gerado_automaticamente",
  "qr_code": "codigo_qr_base64" // Para futuro uso
}
```

#### 1.3. Atualizar `provider_service` no Model

**Arquivo**: `app/models/channel/whatsapp.rb`

```ruby
def provider_service
  case provider
  when 'whatsapp_cloud'
    Whatsapp::Providers::WhatsappCloudService.new(whatsapp_channel: self)
  when 'uazapi'
    Whatsapp::Providers::UazapiService.new(whatsapp_channel: self)
  else
    Whatsapp::Providers::Whatsapp360DialogService.new(whatsapp_channel: self)
  end
end
```

#### 1.4. Controller de Webhooks

**Considerar**: A uazapi provavelmente enviará webhooks para receber mensagens

**Arquivo**: `app/controllers/webhooks/whatsapp_controller.rb`

Verificar se precisa adicionar lógica específica para identificar webhooks da uazapi.

---

### Fase 2: Frontend (Vue.js)

#### 2.1. Adicionar Provider à Lista de Opções

**Arquivo**: `app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Whatsapp.vue`

```javascript
const PROVIDER_TYPES = {
  WHATSAPP: 'whatsapp',
  TWILIO: 'twilio',
  WHATSAPP_CLOUD: 'whatsapp_cloud',
  WHATSAPP_EMBEDDED: 'whatsapp_embedded',
  WHATSAPP_MANUAL: 'whatsapp_manual',
  THREE_SIXTY_DIALOG: '360dialog',
  UAZAPI: 'uazapi', // ADICIONAR
};

const availableProviders = computed(() => [
  {
    key: PROVIDER_TYPES.WHATSAPP,
    title: t('INBOX_MGMT.ADD.WHATSAPP.PROVIDERS.WHATSAPP_CLOUD'),
    description: t('INBOX_MGMT.ADD.WHATSAPP.PROVIDERS.WHATSAPP_CLOUD_DESC'),
    icon: 'i-woot-whatsapp',
  },
  {
    key: PROVIDER_TYPES.TWILIO,
    title: t('INBOX_MGMT.ADD.WHATSAPP.PROVIDERS.TWILIO'),
    description: t('INBOX_MGMT.ADD.WHATSAPP.PROVIDERS.TWILIO_DESC'),
    icon: 'i-woot-twilio',
  },
  // ADICIONAR:
  {
    key: PROVIDER_TYPES.UAZAPI,
    title: t('INBOX_MGMT.ADD.WHATSAPP.PROVIDERS.UAZAPI'),
    description: t('INBOX_MGMT.ADD.WHATSAPP.PROVIDERS.UAZAPI_DESC'),
    icon: 'i-woot-whatsapp', // ou criar ícone específico
  },
]);
```

#### 2.2. Criar Componente de Configuração

**Arquivo**: `app/javascript/dashboard/routes/dashboard/settings/inbox/channels/UazapiWhatsapp.vue`

```vue
<script setup>
import { ref } from 'vue';
import { useVuelidate } from '@vuelidate/core';
import { useAlert } from 'dashboard/composables';
import { required } from '@vuelidate/validators';
import { useRouter } from 'vue-router';
import { useStore } from 'vuex';
import NextButton from 'dashboard/components-next/button/Button.vue';
import { isPhoneE164OrEmpty } from 'shared/helpers/Validators';

const store = useStore();
const router = useRouter();

// Form data
const inboxName = ref('');
const phoneNumber = ref('');
const apiToken = ref('');
const instanceId = ref('');

// Validations
const v$ = useVuelidate({
  inboxName: { required },
  phoneNumber: { required, isPhoneE164OrEmpty },
  apiToken: { required },
  instanceId: { required },
}, { inboxName, phoneNumber, apiToken, instanceId });

// Para futuro: QR Code
const qrCode = ref('');
const showQrCode = ref(false);

const createChannel = async () => {
  v$.value.$touch();
  if (v$.value.$invalid) return;

  try {
    const whatsappChannel = await store.dispatch('inboxes/createChannel', {
      name: inboxName.value.trim(),
      channel: {
        type: 'whatsapp',
        phone_number: phoneNumber.value,
        provider: 'uazapi',
        provider_config: {
          api_token: apiToken.value,
          instance_id: instanceId.value,
        },
      },
    });

    router.replace({
      name: 'settings_inboxes_add_agents',
      params: {
        page: 'new',
        inbox_id: whatsappChannel.id,
      },
    });
  } catch (error) {
    useAlert(error.message || 'Erro ao conectar com uazapi');
  }
};

// Método para futuro: gerar/obter QR Code
const generateQrCode = async () => {
  // Implementar chamada à API da uazapi para gerar QR Code
  showQrCode.value = true;
};
</script>

<template>
  <form class="flex flex-wrap flex-col mx-0" @submit.prevent="createChannel">
    <div class="flex-shrink-0 flex-grow-0">
      <label :class="{ error: v$.inboxName.$error }">
        {{ $t('INBOX_MGMT.ADD.WHATSAPP.INBOX_NAME.LABEL') }}
        <input
          v-model="inboxName"
          type="text"
          :placeholder="$t('INBOX_MGMT.ADD.WHATSAPP.INBOX_NAME.PLACEHOLDER')"
          @blur="v$.inboxName.$touch"
        />
        <span v-if="v$.inboxName.$error" class="message">
          {{ $t('INBOX_MGMT.ADD.WHATSAPP.INBOX_NAME.ERROR') }}
        </span>
      </label>
    </div>

    <div class="flex-shrink-0 flex-grow-0">
      <label :class="{ error: v$.phoneNumber.$error }">
        {{ $t('INBOX_MGMT.ADD.WHATSAPP.PHONE_NUMBER.LABEL') }}
        <input
          v-model="phoneNumber"
          type="text"
          :placeholder="$t('INBOX_MGMT.ADD.WHATSAPP.PHONE_NUMBER.PLACEHOLDER')"
          @blur="v$.phoneNumber.$touch"
        />
        <span v-if="v$.phoneNumber.$error" class="message">
          {{ $t('INBOX_MGMT.ADD.WHATSAPP.PHONE_NUMBER.ERROR') }}
        </span>
      </label>
    </div>

    <div class="flex-shrink-0 flex-grow-0">
      <label :class="{ error: v$.apiToken.$error }">
        {{ $t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.API_TOKEN.LABEL') }}
        <input
          v-model="apiToken"
          type="password"
          :placeholder="$t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.API_TOKEN.PLACEHOLDER')"
          @blur="v$.apiToken.$touch"
        />
        <span v-if="v$.apiToken.$error" class="message">
          {{ $t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.API_TOKEN.ERROR') }}
        </span>
      </label>
    </div>

    <div class="flex-shrink-0 flex-grow-0">
      <label :class="{ error: v$.instanceId.$error }">
        {{ $t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.INSTANCE_ID.LABEL') }}
        <input
          v-model="instanceId"
          type="text"
          :placeholder="$t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.INSTANCE_ID.PLACEHOLDER')"
          @blur="v$.instanceId.$touch"
        />
        <span v-if="v$.instanceId.$error" class="message">
          {{ $t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.INSTANCE_ID.ERROR') }}
        </span>
      </label>
    </div>

    <!-- Para futuro: Seção de QR Code -->
    <div v-if="showQrCode" class="mt-6 p-4 border border-n-weak rounded-lg">
      <h3 class="mb-2 text-md font-medium">
        {{ $t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.QR_CODE.TITLE') }}
      </h3>
      <p class="mb-4 text-sm text-n-slate-11">
        {{ $t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.QR_CODE.DESCRIPTION') }}
      </p>
      <div class="flex justify-center">
        <img v-if="qrCode" :src="qrCode" alt="QR Code" class="w-64 h-64" />
      </div>
    </div>

    <div class="mt-6">
      <NextButton
        type="submit"
        :is-loading="false"
        class="w-full"
      >
        {{ $t('INBOX_MGMT.ADD.WHATSAPP.SUBMIT_BUTTON') }}
      </NextButton>
    </div>
  </form>
</template>
```

#### 2.3. Registrar Componente no Whatsapp.vue

**Arquivo**: `app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Whatsapp.vue`

```vue
<script setup>
// ... imports existentes
import UazapiWhatsapp from './UazapiWhatsapp.vue'; // ADICIONAR

// ... código existente
</script>

<template>
  <div class="overflow-auto col-span-6 p-6 w-full h-full">
    <!-- ... código de seleção de provider -->
    
    <div v-else-if="showConfiguration">
      <div class="px-6 py-5 rounded-2xl border border-n-weak">
        <!-- Componentes existentes -->
        
        <!-- ADICIONAR -->
        <UazapiWhatsapp 
          v-else-if="selectedProvider === PROVIDER_TYPES.UAZAPI" 
        />
      </div>
    </div>
  </div>
</template>
```

---

### Fase 3: Internacionalização (i18n)

#### 3.1. Adicionar Traduções

**Arquivo**: `app/javascript/dashboard/i18n/locale/en/inboxMgmt.json`

```json
{
  "INBOX_MGMT": {
    "ADD": {
      "WHATSAPP": {
        "PROVIDERS": {
          "UAZAPI": "uazapi",
          "UAZAPI_DESC": "Conecte via uazapi com suporte a QR Code"
        },
        "UAZAPI": {
          "API_TOKEN": {
            "LABEL": "API Token",
            "PLACEHOLDER": "Insira o token da API uazapi",
            "ERROR": "Este campo é obrigatório"
          },
          "INSTANCE_ID": {
            "LABEL": "Instance ID",
            "PLACEHOLDER": "Insira o ID da instância uazapi",
            "ERROR": "Este campo é obrigatório"
          },
          "QR_CODE": {
            "TITLE": "Conectar via QR Code",
            "DESCRIPTION": "Escaneie este QR Code com seu WhatsApp para conectar",
            "GENERATE_BUTTON": "Gerar QR Code",
            "WAITING": "Aguardando conexão...",
            "SUCCESS": "Conectado com sucesso!",
            "ERROR": "Falha ao gerar QR Code"
          }
        }
      }
    }
  }
}
```

**Arquivo**: `config/locales/en.yml` (se necessário para backend)

```yaml
en:
  activerecord:
    models:
      channel/whatsapp:
        providers:
          uazapi: "uazapi"
```

---

### Fase 4: Implementação Futura - QR Code

#### 4.1. Backend - Endpoint para QR Code

**Arquivo**: `app/controllers/api/v1/accounts/channels/uazapi_controller.rb` (novo)

```ruby
class Api::V1::Accounts::Channels::UazapiController < Api::V1::Accounts::BaseController
  def generate_qr_code
    # Chamar API da uazapi para gerar QR Code
    response = Whatsapp::Providers::UazapiService.generate_qr_code(
      api_token: params[:api_token],
      instance_id: params[:instance_id]
    )
    
    render json: { qr_code: response['qr_code'], session_id: response['session_id'] }
  end

  def check_qr_status
    # Verificar se QR Code foi escaneado
    status = Whatsapp::Providers::UazapiService.check_qr_status(
      session_id: params[:session_id]
    )
    
    render json: { connected: status['connected'], phone_number: status['phone_number'] }
  end
end
```

**Adicionar rotas** em `config/routes.rb`:

```ruby
namespace :channels do
  resources :uazapi, only: [] do
    collection do
      post :generate_qr_code
      get :check_qr_status
    end
  end
end
```

#### 4.2. Frontend - Fluxo de QR Code

```javascript
// No componente UazapiWhatsapp.vue

const generateQrCode = async () => {
  try {
    isGeneratingQr.value = true;
    
    const response = await axios.post(
      `/api/v1/accounts/${accountId}/channels/uazapi/generate_qr_code`,
      {
        api_token: apiToken.value,
        instance_id: instanceId.value,
      }
    );
    
    qrCode.value = response.data.qr_code;
    sessionId.value = response.data.session_id;
    showQrCode.value = true;
    
    // Iniciar polling para verificar se foi escaneado
    startQrStatusPolling();
  } catch (error) {
    useAlert('Erro ao gerar QR Code');
  } finally {
    isGeneratingQr.value = false;
  }
};

const startQrStatusPolling = () => {
  qrStatusInterval.value = setInterval(async () => {
    try {
      const response = await axios.get(
        `/api/v1/accounts/${accountId}/channels/uazapi/check_qr_status`,
        { params: { session_id: sessionId.value } }
      );
      
      if (response.data.connected) {
        clearInterval(qrStatusInterval.value);
        phoneNumber.value = response.data.phone_number;
        useAlert('WhatsApp conectado com sucesso!');
        // Continuar com criação do inbox
        createChannel();
      }
    } catch (error) {
      clearInterval(qrStatusInterval.value);
      useAlert('Erro ao verificar status do QR Code');
    }
  }, 3000); // Verificar a cada 3 segundos
};
```

---

## 📋 Checklist de Implementação

### Backend
- [ ] Adicionar 'uazapi' ao array `PROVIDERS` em `Channel::Whatsapp`
- [ ] Criar `app/services/whatsapp/providers/uazapi_service.rb`
- [ ] Implementar métodos obrigatórios: `send_message`, `send_template`, `sync_templates`, `validate_provider_config`
- [ ] Atualizar método `provider_service` no model para incluir uazapi
- [ ] Criar testes unitários para `UazapiService`
- [ ] (Futuro) Criar controller para endpoints de QR Code
- [ ] (Futuro) Adicionar rotas para QR Code
- [ ] Configurar variável de ambiente `UAZAPI_BASE_URL`
- [ ] Atualizar webhooks se necessário

### Frontend
- [ ] Adicionar `UAZAPI` ao `PROVIDER_TYPES` em `Whatsapp.vue`
- [ ] Adicionar uazapi ao array `availableProviders`
- [ ] Criar componente `UazapiWhatsapp.vue`
- [ ] Registrar componente no template de `Whatsapp.vue`
- [ ] (Futuro) Implementar interface de QR Code
- [ ] (Futuro) Adicionar polling para status do QR Code
- [ ] Adicionar tratamento de erros específicos da uazapi

### i18n
- [ ] Adicionar traduções em `en/inboxMgmt.json`
- [ ] Adicionar traduções em `en.yml` (backend)

### Testes
- [ ] Criar specs para `UazapiService`
- [ ] Criar specs para validação de provider_config
- [ ] Testar criação de inbox via interface
- [ ] Testar envio de mensagens
- [ ] (Futuro) Testar fluxo de QR Code

### Documentação
- [ ] Documentar estrutura da `provider_config` para uazapi
- [ ] Documentar endpoints da API uazapi necessários
- [ ] Criar guia de configuração para usuários
- [ ] Atualizar README com instruções de setup

---

## 🔐 Configurações Necessárias

### Variáveis de Ambiente

Adicionar ao `.env`:

```bash
# uazapi Configuration
UAZAPI_BASE_URL=https://api.uazapi.com/v1
```

### Credenciais uazapi

Os usuários precisarão fornecer:
1. **API Token**: Token de autenticação da conta uazapi
2. **Instance ID**: ID da instância WhatsApp na uazapi
3. (Futuro) Dados para geração de QR Code

---

## 🚀 Ordem de Execução Recomendada

1. **Fase 1** - Backend básico (sem QR Code)
   - Implementar model, service e validações
   - Testar criação manual de inbox

2. **Fase 2** - Frontend básico (sem QR Code)
   - Criar interface de configuração
   - Adicionar à lista de providers

3. **Fase 3** - i18n
   - Adicionar todas as traduções necessárias

4. **Fase 4** - QR Code (futuro)
   - Implementar endpoints e lógica de QR Code
   - Adicionar interface interativa

---

## 📚 Referências

### Arquivos Importantes

**Backend:**
- `app/models/channel/whatsapp.rb` - Model principal
- `app/services/whatsapp/providers/base_service.rb` - Interface base
- `app/services/whatsapp/providers/whatsapp_360_dialog_service.rb` - Referência
- `app/services/whatsapp/providers/whatsapp_cloud_service.rb` - Referência
- `app/controllers/api/v1/accounts/inboxes_controller.rb` - Controller de inboxes

**Frontend:**
- `app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Whatsapp.vue` - Seletor
- `app/javascript/dashboard/routes/dashboard/settings/inbox/channels/360DialogWhatsapp.vue` - Referência
- `app/javascript/dashboard/routes/dashboard/settings/inbox/channels/CloudWhatsapp.vue` - Referência
- `app/javascript/dashboard/routes/dashboard/settings/inbox/inbox.routes.js` - Rotas
- `app/javascript/dashboard/i18n/locale/en/inboxMgmt.json` - Traduções

### Documentação API uazapi

⚠️ **Importante**: Consultar documentação oficial da uazapi para:
- Endpoints de autenticação
- Formato de envio de mensagens
- Webhooks de recebimento
- Geração e validação de QR Code
- Rate limits e quotas
- Formato de templates/mensagens

---

## ⚠️ Considerações Importantes

1. **Webhooks**: Verificar se a uazapi envia webhooks no mesmo formato que outras APIs WhatsApp
2. **Templates**: Confirmar se a uazapi suporta templates de mensagem e qual o formato
3. **Media**: Verificar como a uazapi lida com envio/recebimento de mídia (imagens, vídeos, áudios)
4. **Rate Limits**: Implementar controle de rate limiting se necessário
5. **Validação**: Garantir que `validate_provider_config` faça uma validação real das credenciais
6. **Enterprise**: Verificar se há necessidade de código específico em `enterprise/` (veja AGENTS.md)
7. **QR Code**: O QR Code deve ser implementado de forma assíncrona com feedback visual ao usuário
8. **Segurança**: Nunca expor tokens/credenciais no frontend; sempre fazer validações no backend

---

## 🐛 Troubleshooting

### Problemas Comuns

1. **Provider não aparece na lista**
   - Verificar se foi adicionado ao `PROVIDER_TYPES`
   - Verificar se foi adicionado ao `availableProviders`
   - Verificar traduções i18n

2. **Erro ao criar inbox**
   - Verificar se `PROVIDERS` inclui 'uazapi' no model
   - Verificar validação em `validate_provider_config?`
   - Checar logs Rails para detalhes do erro

3. **Mensagens não enviando**
   - Verificar implementação de `send_message` no service
   - Verificar autenticação API
   - Verificar formato do payload

4. **QR Code não funciona**
   - Verificar endpoints de QR Code
   - Verificar polling está rodando
   - Verificar formato da resposta da API uazapi

---

## 📝 Notas Finais

- Esta implementação segue o padrão já estabelecido no Chatwoot para providers WhatsApp
- O código deve ser mantido simples (MVP focus, conforme AGENTS.md)
- Usar Tailwind CSS para estilização (não criar CSS custom)
- Seguir convenções de código Ruby (RuboCop) e JavaScript (ESLint)
- Adicionar apenas traduções em `en.json` e `en.yml` (outros idiomas são mantidos pela comunidade)
- Considerar código Enterprise se necessário (`enterprise/` overlay)

---

**Data**: Janeiro 2026  
**Versão**: 1.0  
**Status**: Análise Completa - Pronto para Implementação
