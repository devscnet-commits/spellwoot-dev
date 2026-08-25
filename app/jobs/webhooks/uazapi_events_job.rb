# frozen_string_literal: true

class Webhooks::UazapiEventsJob < ApplicationJob
  queue_as :low

  def perform(params = {})
    channel_id = params[:channel_id]
    channel = Channel::Api.find_by(id: channel_id)

    if channel.blank?
      Rails.logger.warn "[UAZAPI] Channel not found for channel_id=#{channel_id}"
      return
    end

    inbox = channel.inbox
    if inbox.blank?
      Rails.logger.warn "[UAZAPI] Inbox not found for channel_id=#{channel_id}"
      return
    end

    Rails.logger.info "[UAZAPI] Processing webhook event for inbox_id=#{inbox.id}, channel_id=#{channel.id}"

    Uazapi::IncomingMessageService.new(inbox: inbox, params: params.except(:channel_id)).perform
  rescue StandardError => e
    Rails.logger.error "[UAZAPI] Error processing webhook event: #{e.message}"
    Rails.logger.error "[UAZAPI] #{e.backtrace.join("\n")}"
  end
end


