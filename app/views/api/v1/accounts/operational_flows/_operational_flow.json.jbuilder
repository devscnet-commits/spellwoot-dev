json.id flow.id
json.name flow.name
json.category flow.category
json.require_reason flow.require_reason
json.active flow.active
json.meta_enabled flow.meta_enabled
json.inbox_ids flow.inbox_ids
json.reasons flow.reasons.sort_by(&:position) do |reason|
  json.id reason.id
  json.result reason.result
  json.label reason.label
  json.position reason.position
  json.active reason.active
  json.resolution_state_id reason.resolution_state_id
end
json.resolution_states flow.resolution_states do |state|
  json.id state.id
  json.canonical_key state.canonical_key
  json.display_label state.display_label
  json.polarity state.polarity
  json.requires_reason state.requires_reason
  json.meta_event_type state.meta_event_type
  json.meta_value_attr state.meta_value_attr
  json.sort_order state.sort_order
  json.reasons state.reasons.where(active: true).order(:position) do |reason|
    json.id reason.id
    json.label reason.label
    json.position reason.position
  end
end
json.closing_requirements flow.closing_requirements do |requirement|
  json.id requirement.id
  json.attribute_key requirement.attribute_key
  json.condition requirement.condition
  json.sort_order requirement.sort_order
end
