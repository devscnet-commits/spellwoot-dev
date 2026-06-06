json.array! @operational_flows do |flow|
  json.partial! 'operational_flow', flow: flow
end
