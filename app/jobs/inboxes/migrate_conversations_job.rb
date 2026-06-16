class Inboxes::MigrateConversationsJob < ApplicationJob
  queue_as :default

  # Moves all conversations (and their messages/events/contact_inboxes) from source_inbox to
  # target_inbox in bulk. Runs in the background so large inboxes never time out the request.
  def perform(source_inbox, target_inbox, user = nil, delete_source = false)
    @user = user
    backup_migration_data(source_inbox)

    ActiveRecord::Base.transaction do
      # 1. Bulk-update messages and events — 1 query each, regardless of volume
      Message.where(inbox_id: source_inbox.id).update_all(inbox_id: target_inbox.id)
      ReportingEvent.where(inbox_id: source_inbox.id).update_all(inbox_id: target_inbox.id)
      SlaEvent.where(inbox_id: source_inbox.id).update_all(inbox_id: target_inbox.id) if defined?(SlaEvent)

      # 2. Unique contact → contact_inbox pairs (integers only, no AR objects).
      #    Orphan conversations (contact deleted → contact_id nil) are excluded here and
      #    moved separately in step 4b, since they can't map to a ContactInbox.
      unique_contacts = source_inbox.conversations
                                    .where.not(contact_id: nil)
                                    .pluck(:contact_id, :contact_inbox_id)
                                    .each_with_object({}) { |(cid, ciid), h| h[cid] ||= ciid }

      # 3. Find or reuse the target ContactInbox for each unique contact. The (inbox_id,
      #    source_id) pair is unique, so if the source's source_id is already taken in the
      #    target by another (e.g. duplicated) contact, fall back to a fresh id instead of
      #    aborting the whole migration.
      contact_inbox_map = unique_contacts.each_with_object({}) do |(contact_id, source_ci_id), map|
        target_ci = ContactInbox.find_by(contact_id: contact_id, inbox_id: target_inbox.id)
        unless target_ci
          source_id = ContactInbox.where(id: source_ci_id).pick(:source_id)
          if source_id.blank? || ContactInbox.exists?(inbox_id: target_inbox.id, source_id: source_id)
            source_id = SecureRandom.uuid
          end
          target_ci = ContactInbox.create!(contact_id: contact_id, inbox_id: target_inbox.id, source_id: source_id)
        end
        map[contact_id] = target_ci
      end

      # 4a. Bulk-update conversations grouped by contact — 1 query per unique contact
      contact_inbox_map.each do |contact_id, target_ci|
        Conversation.where(inbox_id: source_inbox.id, contact_id: contact_id)
                    .update_all(inbox_id: target_inbox.id, contact_inbox_id: target_ci.id)
      end

      # 4b. Move anything still on the source (orphan/contact-less conversations): switch the
      #     inbox and drop the stale contact_inbox link (it points at a source ContactInbox
      #     about to be removed; the column is nullable).
      Conversation.where(inbox_id: source_inbox.id)
                  .update_all(inbox_id: target_inbox.id, contact_inbox_id: nil)

      # 5. Remove old contact_inboxes (conversations already point to the new ones)
      ContactInbox.where(inbox_id: source_inbox.id).destroy_all
    end

    redirect_uazapi_to_target(source_inbox, target_inbox)

    # Source inbox has no conversations left now, so deleting it is safe. Mirrors the previous
    # flow (migrate → redirect UazAPI → delete) but without blocking the request.
    DeleteObjectJob.perform_later(source_inbox, @user, nil) if delete_source

    Rails.logger.info "[MIGRATE] Completed inbox=#{source_inbox.id} -> #{target_inbox.id}"
  rescue StandardError => e
    Rails.logger.error "[MIGRATE] Job failed inbox=#{source_inbox&.id}: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
    raise
  end

  private

  def backup_migration_data(inbox)
    timestamp = Time.current.strftime('%Y%m%d%H%M%S')
    key = "migration_backup_inbox_#{inbox.id}_#{timestamp}"

    data = {
      inbox: inbox.attributes,
      conversation_ids: inbox.conversations.pluck(:id),
      contact_inbox_ids: inbox.contact_inboxes.pluck(:id),
      message_count: Message.where(inbox_id: inbox.id).count,
      migrated_at: Time.current,
      migrated_by: @user&.id
    }

    Redis::Alfred.set(key, data.to_json)
    Redis::Alfred.expire(key, 30.days.to_i)
  rescue StandardError => e
    Rails.logger.warn "[MIGRATE] Backup skipped: #{e.message}"
  end

  def redirect_uazapi_to_target(source_inbox, target_inbox)
    return unless source_inbox.channel.is_a?(Channel::Api)

    instance_token = source_inbox.channel.additional_attributes&.dig('uazapi_instance_token')
    return unless instance_token.present?

    access_token = @user&.access_token&.token
    frontend_url = ENV.fetch('FRONTEND_URL', nil)
    return unless access_token.present? && frontend_url.present?

    Whatsapp::Providers::UazapiService.configure_chatwoot_integration(
      instance_token,
      {
        enabled: true,
        url: frontend_url,
        access_token: access_token,
        account_id: source_inbox.account_id,
        inbox_id: target_inbox.id,
        ignore_groups: false,
        sign_messages: true,
        create_new_conversation: true
      }
    )
  rescue StandardError => e
    Rails.logger.error "[MIGRATE] Falha ao redirecionar UazAPI: #{e.message}"
  end
end
