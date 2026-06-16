json.payload do
  json.array! @inbox_members do |inbox_member|
    json.partial! 'api/v1/models/agent', formats: [:json], resource: inbox_member.user
    json.eligible_for_assignment inbox_member.eligible_for_assignment
  end
end
