require 'administrate/field/base'

# Slug: editável só na CRIAÇÃO. Trocar o slug de um plano existente desalinharia
# PLAN_FEATURE_TO_ACCOUNT_FLAG, COMMERCIAL_RANK e plans:seed, que localizam plano por slug — por isso
# a partial vira texto puro assim que o plano existe.
class PlanSlugField < Administrate::Field::Base
  def to_s
    data
  end
end
