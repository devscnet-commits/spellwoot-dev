# Namespace for the AI Core domain. All tables are prefixed `ai_` so the boundary with the
# human-agent domain (users) is unmistakable.
module Ai
  def self.table_name_prefix
    'ai_'
  end
end
