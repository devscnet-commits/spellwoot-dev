json.array! @rules do |rule|
  json.partial! 'flow_assignment_rule', rule: rule
end
