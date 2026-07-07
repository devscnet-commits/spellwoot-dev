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

    # Calcular current_value para cada limite baseado nas chaves reais do PlanLimit
    limits_data = plan.plan_limits.map do |limit|
      current_value = calculate_current_value(limit.key)
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
        ai_credits_included: plan.ai_credits_included
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
      limits: limits_data
    }
  end

  def calculate_current_value(key)
    case key
    when 'users'
      current_account.users.count
    when 'inboxes'
      current_account.inboxes.count
    when 'ai_agents'
      Ai::Agent.where(account_id: current_account.id).count
    when 'crm_pipelines'
      # Placeholder: implementar quando CRM module existir
      0
    else
      0
    end
  end
end
