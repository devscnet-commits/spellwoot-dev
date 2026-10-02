json.payload @automations do |automation|
  json.partial! 'api/v1/accounts/operational_flows/pipeline_automations/pipeline_automation', automation: automation
end
