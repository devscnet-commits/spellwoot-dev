module ConversationRequiredAttributesNormalizer
  extend ActiveSupport::Concern

  # Always returns array of hashes regardless of saved format (string or hash)
  def normalized_required_attributes
    raw = settings&.dig('conversation_required_attributes') || []
    raw.map do |item|
      if item.is_a?(String)
        { 'key' => item, 'rule' => 'always' }
      else
        item
      end
    end
  end
end
