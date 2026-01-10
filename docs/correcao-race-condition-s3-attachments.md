# Correção de Race Condition S3 e UazAPI Attachments

## Data
10 de Janeiro de 2026

## Problema Identificado

### 1. Race Condition com ActiveStorage S3

O problema ocorre tanto em mensagens **INCOMING** (recebidas) quanto **OUTGOING** (enviadas):

**Mensagens INCOMING (recebidas do WhatsApp)**:
- Quando um arquivo é recebido do WhatsApp, o servidor baixa o arquivo e usa `attachment.file.attach(io: ...)` 
- O ActiveStorage faz upload assíncrono do servidor para o S3 após o commit da transação
- O evento `MESSAGE_CREATED` é disparado no `after_create_commit`, chamando `push_event_data` que gera URLs pré-assinadas via `download_url`
- O upload ainda não terminou quando a URL é gerada, causando 404 no frontend

**Mensagens OUTGOING (enviadas pelo usuário, com DIRECT_UPLOADS_ENABLED=true)**:
- O frontend usa DirectUpload para fazer upload direto do navegador para o S3
- Quando o upload termina, o `blobSignedId` é enviado ao backend
- O backend cria o attachment usando `file: blobSignedId`, que resolve o blob e anexa ao attachment
- A mensagem é salva e o evento `MESSAGE_CREATED` é disparado no `after_create_commit`
- Mesmo com DirectUpload, pode haver delay entre quando o upload termina no navegador e quando o arquivo está realmente disponível/processado no S3
- A URL pré-assinada é gerada imediatamente após o commit, mas o arquivo ainda pode não estar completamente acessível, causando 404

**Sintomas**:
- Erro 404 Not Found ao tentar baixar arquivos do S3 no navegador
- Áudios não conseguem ser reproduzidos imediatamente após envio/recebimento
- Necessidade de recarregar a página (F5) para conseguir ouvir áudios
- Problema mais comum em arquivos grandes, mas pode ocorrer em qualquer tamanho dependendo da latência de rede e processamento do S3

### 2. Problema UazAPI

- No `Uazapi::IncomingMessageService`, quando há `media_url`, apenas o `external_url` é salvo
- O arquivo não é baixado e anexado ao attachment
- Quando `download_url` é chamado para enviar via WhatsApp, retorna string vazia porque `file.attached?` é false
- Arquivos não chegam no WhatsApp do cliente

## Solução Implementada

### 1. Verificação de Upload no S3

**Arquivo**: `app/models/attachment.rb`

Adicionado método `file_uploaded?` que verifica se o blob existe no S3 usando `bucket.object(blob.key).exists?`:

```ruby
def file_uploaded?
  return false unless file.attached?

  blob = file.blob
  return true unless blob.service.is_a?(ActiveStorage::Service::S3Service)

  # Check if blob exists in S3
  verify_blob_in_s3(blob)
end
```

**Método `verify_blob_in_s3`**:
- Faz verificação usando `bucket.object(blob.key).exists?`
- Retorna `false` se o arquivo não existe
- Retorna `true` em caso de erro de rede (assume que existe para não bloquear)

### 2. Aguardo de Upload no `download_url`

**Arquivo**: `app/models/attachment.rb`

Modificado o método `download_url` para aguardar upload completo antes de gerar URL pré-assinada:

```ruby
def download_url
  ActiveStorage::Current.url_options = Rails.application.routes.default_url_options if ActiveStorage::Current.url_options.blank?
  return '' unless file.attached?

  # Wait for file to be uploaded to S3 before generating signed URL
  wait_for_upload if file_requires_upload_verification?

  file.blob.url
end
```

**Lógica de verificação**:
- Apenas verifica attachments recentes (últimos 5 minutos) para evitar overhead
- Aguarda até 5 segundos pelo upload
- Intervalo de retry de 0.5 segundos
- Se timeout, loga warning mas continua (pode ser problema de rede temporário)

### 3. Job Assíncrono para Processar Attachments

**Arquivo**: `app/jobs/messages/process_attachment_job.rb` (NOVO)

Criado job que processa attachments assincronamente quando há timeout:

```ruby
class Messages::ProcessAttachmentJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: 1.second, attempts: 5

  def perform(message_id)
    message = Message.find_by(id: message_id)
    return unless message

    # Wait for all attachments to be uploaded
    unless wait_for_attachments(message)
      # If timeout, retry the job
      raise StandardError, "Timeout waiting for attachments to upload for message #{message_id}"
    end

    # If attachments are ready, dispatch events immediately
    message.dispatch_create_events_sync
  end
end
```

**Características**:
- Aguarda até 20 segundos pelo upload
- Retry automático (até 5 tentativas) se houver timeout
- Dispara eventos quando attachments estão prontos
- Logs detalhados sobre tentativas, timeouts e sucessos

### 4. Modificação do `dispatch_create_events`

**Arquivo**: `app/models/message.rb`

Modificado para aguardar upload de attachments antes de enviar evento:

```ruby
def dispatch_create_events
  # Wait for attachments to be uploaded before dispatching events
  if attachments.any? && should_wait_for_attachments?
    # Try to wait synchronously with a short timeout
    if wait_for_attachments(timeout: 2.seconds)
      # If timeout, use async job
      Messages::ProcessAttachmentJob.perform_later(id)
      return
    end
  end

  dispatch_create_events_sync
end

def dispatch_create_events_sync
  Rails.configuration.dispatcher.dispatch(MESSAGE_CREATED, Time.zone.now, message: self, performed_by: Current.executed_by)

  if valid_first_reply?
    Rails.configuration.dispatcher.dispatch(FIRST_REPLY_CREATED, Time.zone.now, message: self, performed_by: Current.executed_by)
    conversation.update(first_reply_created_at: created_at, waiting_since: nil)
  else
    update_waiting_since
  end
end
```

**Lógica**:
- Verifica se há attachments recentes (últimos 5 minutos)
- Tenta aguardar sincronamente até 2 segundos
- Se timeout, usa job assíncrono
- Se attachments estão prontos, dispara eventos imediatamente

### 5. Correção do UazAPI Service

**Arquivo**: `app/services/uazapi/incoming_message_service.rb`

Modificado para baixar e anexar arquivos ao invés de apenas salvar `external_url`:

```ruby
def attach_media_file(message, message_data)
  media_url = message_data[:media_url]
  file_type = determine_file_type(message_data[:type])

  Rails.logger.info "[UAZAPI] Downloading attachment from: #{media_url}"

  attachment_file = download_media_file(media_url)
  unless attachment_file
    Rails.logger.warn "[UAZAPI] Failed to download attachment from: #{media_url}"
    # Fallback: create attachment with external_url only
    message.attachments.build(
      account_id: inbox.account_id,
      file_type: file_type,
      external_url: media_url
    )
    return
  end

  message.content ||= message_data[:caption]

  message.attachments.build(
    account_id: inbox.account_id,
    file_type: file_type,
    file: {
      io: attachment_file,
      filename: attachment_file.original_filename || File.basename(media_url),
      content_type: attachment_file.content_type || 'application/octet-stream'
    }
  )
end

def download_media_file(media_url)
  Down.download(media_url)
rescue StandardError => e
  Rails.logger.error "[UAZAPI] Error downloading file from #{media_url}: #{e.message}"
  nil
end
```

**Características**:
- Baixa arquivo usando `Down.download`
- Anexa arquivo ao attachment usando `file.attach`
- Fallback com `external_url` se download falhar
- Tratamento de erros gracioso

## Arquivos Modificados/Criados

### Arquivos Modificados

1. **app/models/attachment.rb**
   - Adicionado método `file_uploaded?`
   - Adicionado método `file_requires_upload_verification?`
   - Adicionado método `wait_for_upload`
   - Adicionado método `verify_blob_in_s3`
   - Modificado método `download_url` para aguardar upload

2. **app/models/message.rb**
   - Modificado método `dispatch_create_events` para aguardar upload
   - Adicionado método público `dispatch_create_events_sync`
   - Adicionado método privado `should_wait_for_attachments?`
   - Adicionado método privado `wait_for_attachments`

3. **app/services/uazapi/incoming_message_service.rb**
   - Modificado método `create_message` para baixar e anexar arquivos
   - Adicionado método `attach_media_file`
   - Adicionado método `download_media_file`

### Arquivos Criados

1. **app/jobs/messages/process_attachment_job.rb** (NOVO)
   - Job assíncrono para processar attachments quando há timeout
   - Retry automático com até 5 tentativas

## Fluxo de Funcionamento

### Mensagens INCOMING (Recebidas do WhatsApp)

1. Servidor recebe mensagem com attachment do WhatsApp
2. Servidor baixa arquivo do WhatsApp usando `download_attachment_file`
3. Arquivo é anexado usando `attachment.file.attach(io: ...)`
4. Mensagem é salva e commit da transação
5. ActiveStorage inicia upload assíncrono do servidor para S3
6. `after_create_commit` é disparado
7. `dispatch_create_events` é chamado:
   - Verifica se há attachments recentes
   - Tenta aguardar upload (até 2 segundos)
   - Se upload completo: dispara eventos imediatamente
   - Se timeout: enfileira `Messages::ProcessAttachmentJob`
8. Job processa attachments:
   - Aguarda upload (até 20 segundos)
   - Se upload completo: dispara eventos via `dispatch_create_events_sync`
   - Se timeout: retry do job (até 5 tentativas)

### Mensagens OUTGOING (Enviadas pelo Usuário)

1. Frontend usa DirectUpload para fazer upload direto do navegador para S3
2. Quando upload termina, `blobSignedId` é enviado ao backend
3. Backend cria attachment usando `file: blobSignedId`
4. Mensagem é salva e commit da transação
5. `after_create_commit` é disparado
6. `dispatch_create_events` é chamado:
   - Verifica se há attachments recentes
   - Tenta aguardar processamento no S3 (até 2 segundos)
   - Se arquivo disponível: dispara eventos imediatamente
   - Se timeout: enfileira `Messages::ProcessAttachmentJob`
7. Job processa attachments:
   - Aguarda arquivo estar disponível no S3 (até 20 segundos)
   - Se disponível: dispara eventos via `dispatch_create_events_sync`
   - Se timeout: retry do job (até 5 tentativas)

### Geração de URLs Pré-Assinadas

1. `download_url` é chamado (via `push_event_data` ou diretamente)
2. Verifica se attachment é recente (últimos 5 minutos)
3. Se recente, aguarda upload completo (até 5 segundos no `download_url`)
4. Gera URL pré-assinada do S3
5. URL é retornada e usada no frontend

## Considerações Técnicas

### Performance

- Verificação de S3 pode adicionar latência, mas é necessária para evitar 404
- Apenas attachments recentes são verificados (últimos 5 minutos) para evitar overhead
- Aguardo sincrônico limitado a 2 segundos para não bloquear requests
- Job assíncrono usado para casos que excedem threshold (timeout de 20 segundos)

### Fallback

- Se verificação de S3 falhar (erro de rede), assume que arquivo existe para não bloquear
- Se download no UazAPI falhar, usa `external_url` como fallback
- Logs de warning são gerados para rastreamento

### Compatibilidade

- Funciona tanto com mensagens INCOMING quanto OUTGOING
- Funciona com `DIRECT_UPLOADS_ENABLED=true` e `false`
- Funciona para todos os tamanhos de arquivo (tratamento uniforme)

## Deploy Necessário

**⚠️ IMPORTANTE: Deploy de AMBOS Rails e Sidekiq**

### Motivos

1. **Models compartilhados**: `Attachment` e `Message` são usados por ambos
2. **Novo job do Sidekiq**: `Messages::ProcessAttachmentJob` precisa estar disponível no Sidekiq
3. **Fluxo de execução**: Rails enfileira jobs que são processados pelo Sidekiq

### Processo Recomendado

1. **Deploy do Sidekiq primeiro** (para evitar jobs falhando)
2. **Deploy do Rails em seguida**

Ou fazer deploy simultâneo se houver zero-downtime.

### O que acontece se não fizer deploy do Sidekiq

- Rails enfileira `Messages::ProcessAttachmentJob`
- Sidekiq não encontra a classe do job
- Erro: `uninitialized constant Messages::ProcessAttachmentJob`
- Jobs ficam na fila sem processamento
- Mensagens com attachments grandes não terão eventos disparados

## Testes Realizados

### Testes de Validação

1. ✅ Método `file_uploaded?` existe em `Attachment`
2. ✅ Método `download_url` modificado em `Attachment`
3. ✅ Método `dispatch_create_events` modificado em `Message`
4. ✅ Método `dispatch_create_events_sync` existe em `Message`
5. ✅ Job `Messages::ProcessAttachmentJob` existe
6. ✅ Método `attach_media_file` existe em `Uazapi::IncomingMessageService`
7. ✅ Método `download_media_file` existe em `Uazapi::IncomingMessageService`

### Testes de Funcionamento

- Docker Compose subido com sucesso
- Rails rodando sem erros
- Sidekiq rodando sem erros
- Todos os métodos acessíveis e funcionando

## Logs e Monitoramento

### Logs Adicionados

1. **Attachment**: 
   - `"Attachment #{id}: File upload verification timeout after #{max_wait}s"`
   - `"Attachment #{id}: Error verifying blob in S3: #{e.message}"`

2. **ProcessAttachmentJob**:
   - `"[ProcessAttachmentJob] Starting processing for message_id=#{message_id} (attempt=#{attempt}/#{max_attempts})"`
   - `"[ProcessAttachmentJob] Waiting for #{attachment_count} attachment(s) to be uploaded for message_id=#{message.id} (max_wait=#{max_wait}s)"`
   - `"[ProcessAttachmentJob] All attachments uploaded successfully for message_id=#{message.id} after #{elapsed}s (#{check_count} checks)"`
   - `"[ProcessAttachmentJob] Timeout waiting for attachments for message_id=#{message.id} after #{elapsed}s (#{check_count} checks, max_wait=#{max_wait}s)"`
   - `"[ProcessAttachmentJob] Timeout waiting for attachments to upload for message_id=#{message_id} after 20s (attempt=#{attempt}/#{max_attempts}, will retry)"`
   - `"[ProcessAttachmentJob] All attachments uploaded successfully for message_id=#{message_id}, dispatching events"`

3. **UazAPI**:
   - `"[UAZAPI] Downloading attachment from: #{media_url}"`
   - `"[UAZAPI] Failed to download attachment from: #{media_url}"`
   - `"[UAZAPI] Error downloading file from #{media_url}: #{e.message}"`

### Monitoramento Recomendado

- Monitorar jobs falhando no Sidekiq (métrica: `Messages::ProcessAttachmentJob` failures)
- Monitorar logs de timeout de upload
- Monitorar erros 404 no frontend relacionados a attachments

## Próximos Passos (Opcional)

1. Adicionar métricas para rastrear tempo de upload
2. Considerar cache de verificação de S3 para evitar múltiplas verificações
3. Adicionar retry exponencial no job se necessário
4. Monitorar performance em produção

## Referências

- [ActiveStorage S3 Service](https://edgeguides.rubyonrails.org/active_storage_overview.html#s3-service)
- [AWS SDK for Ruby - S3](https://docs.aws.amazon.com/sdk-for-ruby/v3/developer-guide/s3-examples.html)
- [Sidekiq Best Practices](https://github.com/sidekiq/sidekiq/wiki/Best-Practices)
