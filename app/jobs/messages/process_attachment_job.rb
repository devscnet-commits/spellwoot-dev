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

  private

  def wait_for_attachments(message, max_wait: 5.seconds, retry_interval: 0.5.seconds)
    return true unless message.attachments.any?

    start_time = Time.current
    while Time.current - start_time < max_wait
      return true if all_attachments_uploaded?(message)

      sleep(retry_interval)
    end

    # Timeout - will retry
    false
  end

  def all_attachments_uploaded?(message)
    message.attachments.all?(&:file_uploaded?)
  end
end
