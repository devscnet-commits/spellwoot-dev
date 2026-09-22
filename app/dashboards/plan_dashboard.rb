require 'administrate/base_dashboard'

class PlanDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    name: Field::String,
    slug: Field::String,
    description: Field::Text,
    active: Field::Boolean,
    visible_to_new_subscribers: Field::Boolean,
    courtesy: Field::Boolean,
    monthly_price_cents: Field::Number,
    annual_price_cents: Field::Number,
    setup_fee_cents: Field::Number,
    promo_price_cents: Field::Number,
    promo_months_count: Field::Number,
    ai_credits_included: Field::Number,
    ai_credit_overage_price_cents: Field::Number,
    feature_grid: PlanFeaturesField,
    limit_grid: PlanLimitsField,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    name
    slug
    active
    monthly_price_cents
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    name
    slug
    description
    active
    visible_to_new_subscribers
    courtesy
    monthly_price_cents
    annual_price_cents
    setup_fee_cents
    promo_price_cents
    promo_months_count
    ai_credits_included
    ai_credit_overage_price_cents
    feature_grid
    limit_grid
    created_at
    updated_at
  ].freeze

  # Sem :slug — mudá-lo depois de criado quebraria PLAN_FEATURE_TO_ACCOUNT_FLAG/plans:seed (que
  # localizam o plano por slug).
  #
  # feature_grid/limit_grid são grades montadas pelo model (Plan#feature_grid/#limit_grid) e gravadas
  # por SuperAdmin::PlansController — as partials usam campos *_tag com nome próprio, FORA do
  # namespace `plan[...]`, então o update do Administrate não as enxerga e não tenta atribuí-las.
  FORM_ATTRIBUTES = %i[
    name
    description
    active
    visible_to_new_subscribers
    courtesy
    monthly_price_cents
    annual_price_cents
    setup_fee_cents
    promo_price_cents
    promo_months_count
    ai_credits_included
    ai_credit_overage_price_cents
    feature_grid
    limit_grid
  ].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(plan)
    plan.name
  end
end
