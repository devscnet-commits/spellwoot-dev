json.pipeline do
  json.partial! 'api/v1/accounts/pipelines/pipeline', pipeline: @pipeline
end
json.columns @columns
