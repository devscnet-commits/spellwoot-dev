module Enterprise::Audit::Conversation
  extend ActiveSupport::Concern

  included do
    audited only: %i[result result_reason], on: %i[update destroy]
  end
end
