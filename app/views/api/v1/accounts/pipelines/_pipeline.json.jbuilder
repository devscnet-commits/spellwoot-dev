json.id pipeline.id
json.name pipeline.name
json.category pipeline.category
json.value_attribute_key pipeline.value_attribute_key
json.stages pipeline.ordered_stages do |stage|
  json.id stage.id
  json.canonical_key stage.canonical_key
  json.display_label stage.display_label
  json.polarity stage.polarity
  json.color stage.color
  json.is_default stage.is_default
  json.sort_order stage.sort_order
end
json.closing_requirements pipeline.closing_requirements do |requirement|
  json.id requirement.id
  json.attribute_key requirement.attribute_key
  json.condition requirement.condition
end
