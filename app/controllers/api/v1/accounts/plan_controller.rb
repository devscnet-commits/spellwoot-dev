# frozen_string_literal: true

class Api::V1::Accounts::PlanController < Api::V1::Accounts::BaseController
  before_action :fetch_plan_data

  def limits
    render json: @plan_data
  end

  private

  def fetch_plan_data
    subscription = current_account.subscriptions.current.first
    return render json: { error: 'No active subscription' }, status: :not_found unless subscription

    plan = subscription.plan
    ai_credit_balance = current_account.ai_credit_balance

    # current_value por limite via fonte única de contagem (Billing::LimitUsage). Chaves sem fonte
    # (ex.: crm_pipelines => nil) caem em 0, preservando o contrato atual da API.
    limits_data = plan.plan_limits.map do |limit|
      current_value = Billing::LimitUsage.current_count(current_account, limit.key) || 0
      {
        key: limit.key,
        max_value: limit.max_value,
        current_value: current_value,
        unlimited: limit.unlimited?,
        overflow_behavior: limit.overflow_behavior,
        percentage_used: limit.max_value ? (current_value.to_f / limit.max_value * 100).round(2) : nil
      }
    end

    @plan_data = {
      plan: {
        id: plan.id,
        name: plan.name,
        slug: plan.slug,
        ai_credits_included: plan.ai_credits_included,
        # Preço: nullable (valores provisórios, ainda não confirmados). Front trata nil.
        monthly_price_cents: plan.monthly_price_cents,
        setup_fee_cents: plan.setup_fee_cents
      },
      ai_credit_balance: {
        plan_credits: ai_credit_balance&.plan_credits || 0,
        extra_credits: ai_credit_balance&.extra_credits || 0,
        total: ai_credit_balance&.total || 0
      },
      subscription: {
        started_at: subscription.started_at,
        next_renewal_at: subscription.next_renewal_at,
        status: subscription.status,
        ends_at: subscription.ends_at
      },
      limits: limits_data,
      overage_charges: recent_overage_charges
    }
  end

  # Histórico recente de cobranças de excedente (só exibição; mais novas primeiro, teto de 12).
  def recent_overage_charges
    current_account.overage_charges
                   .order(cycle_end: :desc, id: :desc)
                   .limit(12)
                   .map do |charge|
      {
        plan_limit_key: charge.plan_limit_key,
        cycle_start: charge.cycle_start,
        cycle_end: charge.cycle_end,
        average_excess: charge.average_excess.to_f,
        total_cents: charge.total_cents,
        status: charge.status
      }
    end
  end
end
