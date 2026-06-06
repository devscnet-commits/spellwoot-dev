json.id flow.id
json.name flow.name
json.require_reason flow.require_reason
json.active flow.active
json.inbox_ids flow.inbox_ids
json.reasons flow.reasons.sort_by(&:position) do |reason|
  json.id reason.id
  json.result reason.result
  json.label reason.label
  json.position reason.position
  json.active reason.active
end
