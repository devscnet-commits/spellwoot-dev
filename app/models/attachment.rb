# == Schema Information
#
# Table name: attachments
#
#  id               :integer          not null, primary key
#  coordinates_lat  :float            default(0.0)
#  coordinates_long :float            default(0.0)
#  extension        :string
#  external_url     :string
#  fallback_title   :string
#  file_type        :integer          default("image")
#  meta             :jsonb
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  account_id       :integer          not null
#  message_id       :integer          not null
#
# Indexes
#
#  index_attachments_on_account_id  (account_id)
#  index_attachments_on_message_id  (message_id)
#

class Attachment < ApplicationRecord
  include Rails.application.routes.url_helpers

  ACCEPTABLE_FILE_TYPES = %w[
    text/csv text/plain text/rtf
    application/json application/pdf
    application/zip application/x-7z-compressed application/vnd.rar application/x-tar
    application/msword application/vnd.ms-excel application/vnd.ms-powerpoint application/rtf
    application/vnd.oasis.opendocument.text
    application/vnd.openxmlformats-officedocument.presentationml.presentation
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
  ].freeze
  belongs_to :account
  belongs_to :message
  has_one_attached :file
  validate :acceptable_file
  validates :external_url, length: { maximum: Limits::URL_LENGTH_LIMIT }
  enum file_type: { :image => 0, :audio => 1, :video => 2, :file => 3, :location => 4, :fallback => 5, :share => 6, :story_mention => 7,
                    :contact => 8, :ig_reel => 9, :ig_post => 10, :ig_story => 11, :embed => 12 }

  def push_event_data
    return unless file_type

    base_data.merge(metadata_for_file_type)
  end

  # NOTE: the URl returned does a 301 redirect to the actual file
  def file_url
    file.attached? ? url_for(file) : ''
  end

  # NOTE: for External services use this methods since redirect doesn't work effectively in a lot of cases
  def download_url
    ActiveStorage::Current.url_options = Rails.application.routes.default_url_options if ActiveStorage::Current.url_options.blank?
    return '' unless file.attached?

    # Wait for file to be uploaded to S3 before generating signed URL
    wait_for_upload if file_requires_upload_verification?

    file.blob.url
  end

  def file_uploaded?
    return false unless file.attached?

    blob = file.blob
    return true unless blob.service.is_a?(ActiveStorage::Service::S3Service)

    # Check if blob exists in S3
    verify_blob_in_s3(blob)
  end

  private

  def file_requires_upload_verification?
    return false unless file.attached?

    blob = file.blob
    return false unless blob.service.is_a?(ActiveStorage::Service::S3Service)

    # Only verify for recently created attachments (within last 5 minutes)
    # This avoids unnecessary checks for old attachments
    created_at > 5.minutes.ago
  end

  def wait_for_upload(max_wait: 5.seconds, retry_interval: 0.5.seconds)
    return unless file_requires_upload_verification?

    start_time = Time.current
    while Time.current - start_time < max_wait
      return if file_uploaded?

      sleep(retry_interval)
    end

    # If still not uploaded after max_wait, log warning but continue
    Rails.logger.warn "Attachment #{id}: File upload verification timeout after #{max_wait}s"
  end

  def verify_blob_in_s3(blob)
    return false unless blob.service.is_a?(ActiveStorage::Service::S3Service)

    begin
      service = blob.service
      bucket = service.bucket
      bucket.object(blob.key).exists?
    rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
      false
    rescue StandardError => e
      # On network errors or other exceptions, assume file exists to avoid blocking
      Rails.logger.warn "Attachment #{id}: Error verifying blob in S3: #{e.message}"
      true
    end
  end

  def thumb_url
    return '' unless file.attached? && image?

    begin
      url_for(file.representation(resize_to_fill: [250, nil]))
    rescue ActiveStorage::UnrepresentableError => e
      Rails.logger.warn "Unrepresentable image attachment: #{id} (#{file.filename}) - #{e.message}"
      ''
    end
  end

  def with_attached_file?
    [:image, :audio, :video, :file].include?(file_type.to_sym)
  end

  private

  def metadata_for_file_type
    case file_type.to_sym
    when :location
      location_metadata
    when :fallback
      fallback_data
    when :contact
      contact_metadata
    when :audio
      audio_metadata
    when :embed
      embed_data
    else
      file_metadata
    end
  end

  def embed_data
    {
      data_url: external_url
    }
  end

  def audio_metadata
    audio_file_data = base_data.merge(file_metadata)
    audio_file_data.merge(
      {
        transcribed_text: meta&.[]('transcribed_text') || ''
      }
    )
  end

  def file_metadata
    metadata = {
      extension: extension,
      data_url: file_url,
      thumb_url: thumb_url,
      file_size: file.byte_size,
      width: file.metadata[:width],
      height: file.metadata[:height]
    }

    metadata[:data_url] = metadata[:thumb_url] = external_url if message.inbox.instagram? && message.incoming?
    metadata
  end

  def location_metadata
    {
      coordinates_lat: coordinates_lat,
      coordinates_long: coordinates_long,
      fallback_title: fallback_title,
      data_url: external_url
    }
  end

  def fallback_data
    {
      fallback_title: fallback_title,
      data_url: external_url
    }
  end

  def base_data
    {
      id: id,
      message_id: message_id,
      file_type: file_type,
      account_id: account_id
    }
  end

  def contact_metadata
    {
      fallback_title: fallback_title,
      meta: meta || {}
    }
  end

  def should_validate_file?
    return unless file.attached?
    # we are only limiting attachment types in case of website widget
    return unless message.inbox.channel_type == 'Channel::WebWidget'

    true
  end

  def acceptable_file
    return unless should_validate_file?

    validate_file_size(file.byte_size)
    validate_file_content_type(file.content_type)
  end

  def validate_file_content_type(file_content_type)
    errors.add(:file, 'type not supported') unless media_file?(file_content_type) || ACCEPTABLE_FILE_TYPES.include?(file_content_type)
  end

  def validate_file_size(byte_size)
    limit_mb = GlobalConfigService.load('MAXIMUM_FILE_UPLOAD_SIZE', 40).to_i
    limit_mb = 40 if limit_mb <= 0

    errors.add(:file, 'size is too big') if byte_size > limit_mb.megabytes
  end

  def media_file?(file_content_type)
    file_content_type.start_with?('image/', 'video/', 'audio/')
  end
end

Attachment.include_mod_with('Concerns::Attachment')
