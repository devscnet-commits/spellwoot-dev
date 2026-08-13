class ChangeAssistantAvatarToText < ActiveRecord::Migration[7.1]
  # Avatars are stored inline as base64 data URLs, which overflow varchar(255).
  # Widen to text so a (client-side downscaled) avatar fits. A custom length
  # validation on the model keeps it bounded against oversized payloads.
  def up
    change_column :ai_agents, :assistant_avatar, :text
  end

  def down
    change_column :ai_agents, :assistant_avatar, :string
  end
end
