json.payload @pipelines do |pipeline|
  json.partial! 'api/v1/accounts/pipelines/pipeline', pipeline: pipeline
end
