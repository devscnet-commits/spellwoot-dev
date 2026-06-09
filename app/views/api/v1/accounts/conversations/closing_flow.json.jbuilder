if @operational_flow
  json.partial! 'api/v1/accounts/operational_flows/operational_flow', flow: @operational_flow
else
  json.null!
end
