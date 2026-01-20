class Messages::ProcessAttachmentJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: 1.second, attempts: 5

  def perform(message_id)
    message = Message.find_by(id: message_id)
    return unless message

    attempt = executions + 1
    max_attempts = 5 + 1 # retry_on attempts: 5 means 5 retries + 1 initial attempt
    Rails.logger.info "[ProcessAttachmentJob] Starting processing for message_id=#{message_id} (attempt=#{attempt}/#{max_attempts})"

    # Wait for all attachments to be uploaded
    unless wait_for_attachments(message)
      # If timeout, retry the job
      Rails.logger.warn "[ProcessAttachmentJob] Timeout waiting for attachments to upload for message_id=#{message_id} after 20s (attempt=#{attempt}/#{max_attempts}, will retry)"
      raise StandardError, "Timeout waiting for attachments to upload for message #{message_id}"
    end

    # If attachments are ready, dispatch events immediately
    begin
      Rails.logger.info "[ProcessAttachmentJob] All attachments uploaded successfully for message_id=#{message_id}, dispatching events"
      message.dispatch_create_events_sync
    rescue ActiveStorage::FileNotFoundError => e
      # Log error but don't retry - the attachment may have been purged
      Rails.logger.error "[ProcessAttachmentJob] FileNotFoundError while dispatching events for message_id=#{message_id}: #{e.message}"
      Rails.logger.error "[ProcessAttachmentJob] Attempting to dispatch events anyway (attachment may have external_url fallback)"
      # Try to dispatch anyway - push_event_data should handle missing files gracefully
      begin
        message.dispatch_create_events_sync
      rescue => retry_error
        Rails.logger.error "[ProcessAttachmentJob] Failed to dispatch events after FileNotFoundError: #{retry_error.message}"
        # Don't raise - let the job complete to avoid infinite retries
      end
    end
  end

  private

  def wait_for_attachments(message, max_wait: 20.seconds, retry_interval: 0.5.seconds)
    return true unless message.attachments.any?

    attachment_count = message.attachments.count
    Rails.logger.info "[ProcessAttachmentJob] Waiting for #{attachment_count} attachment(s) to be uploaded for message_id=#{message.id} (max_wait=#{max_wait}s)"

    start_time = Time.current
    check_count = 0
    while Time.current - start_time < max_wait
      elapsed = Time.current - start_time
      if all_attachments_uploaded?(message)
        Rails.logger.info "[ProcessAttachmentJob] All attachments uploaded successfully for message_id=#{message.id} after #{elapsed.round(2)}s (#{check_count} checks)"
        return true
      end

      check_count += 1
      sleep(retry_interval)
    end

    elapsed = Time.current - start_time
    Rails.logger.warn "[ProcessAttachmentJob] Timeout waiting for attachments for message_id=#{message.id} after #{elapsed.round(2)}s (#{check_count} checks, max_wait=#{max_wait}s)"
    # Timeout - will retry
    false
  end

  def all_attachments_uploaded?(message)
    message.attachments.all?(&:file_uploaded?)
  end
end
