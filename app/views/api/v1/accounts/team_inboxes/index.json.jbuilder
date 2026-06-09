json.array! @inboxes do |inbox|
  json.id inbox.id
  json.name inbox.name
  json.channel_type inbox.channel_type
end
