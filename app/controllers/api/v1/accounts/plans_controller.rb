# frozen_string_literal: true

class Api::V1::Accounts::PlansController < Api::V1::Accounts::BaseController
  before_action :fetch_plan_data, only: [:limits]

  # Chaves de limite sem model/contador real ainda (Billing::LimitUsage sempre devolve nil pra
  # elas) — escondidas da tela em vez de mostrar um "0 / N" que não representa nada de verdade.
  LIMIT_KEYS_WITHOUT_MODULE = %w[crm_pipelines].freeze

  def limits
    render json: @plan_data
  end

  # Não existe troca de plano pelo cliente: o plano só muda depois do pagamento confirmado — hoje pelo
  # Super Admin, quando houver provedor de pagamento pelo webhook dele. Até lá, o botão de upgrade da
  # tela leva o cliente ao WhatsApp da Conexiia (upgrade_contact).

  private

  def fetch_plan_data
    subscription = current_account.subscriptions.current.first
    return render json: { error: 'No active subscription' }, status: :not_found unless subscription

    plan = subscription.plan
    ai_credit_balance = current_account.ai_credit_balance

    # current_value por limite via fonte única de contagem (Billing::LimitUsage). Chaves sem módulo
    # real (LIMIT_KEYS_WITHOUT_MODULE) nem entram na lista — ver constante acima.
    limits_data = plan.plan_limits.reject { |limit| LIMIT_KEYS_WITHOUT_MODULE.include?(limit.key) }.map do |limit|
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
      overage_charges: recent_overage_charges,
      available_upgrades: available_upgrades(plan),
      upgrade_contact: { whatsapp_number: upgrade_whatsapp_number },
      ai_key: ai_key_status(subscription)
    }
  end

  # Mesmas regras que decidem a cobrança em runtime (Ai::Gateway#billing_balance e
  # Ai::ActionDispatcher#consume_credit): só leitura de banco, nenhuma chamada ao provedor.
  def ai_key_status(subscription)
    {
      own_key_allowed: FeatureGate.enabled?(current_account, 'custom_llm_api_key'),
      using_own_key: Ai::ModelRouter.account_byok?(current_account.id),
      replies_this_cycle: replies_this_cycle(subscription)
    }
  end

  # Respostas da IA efetivamente enviadas ao cliente no ciclo atual. Conta o mesmo evento que
  # Ai::ActionDispatcher#reply grava junto com o débito de crédito ('reply.sent', um por resposta),
  # então é a mesma base da cobrança — só que em quantidade, não em créditos. Com chave própria é o
  # único número de uso que existe aqui (o custo em dinheiro fica na conta do cliente no provedor).
  def replies_this_cycle(subscription)
    renewal = subscription.next_renewal_at
    cycle_start = [renewal && (renewal - 1.month), subscription.started_at].compact.max
    scope = Ai::Event.where(account_id: current_account.id, event_type: 'reply.sent')
    scope = scope.where(created_at: cycle_start..) if cycle_start
    scope.count
  end

  # Número da Conexiia que recebe os pedidos de upgrade (Super Admin → Settings → General). Só dígitos,
  # que é o que o link wa.me aceita. nil quando não configurado — a tela mostra "fale com o suporte".
  def upgrade_whatsapp_number
    GlobalConfigService.load('PLAN_UPGRADE_WHATSAPP_NUMBER', nil).to_s.gsub(/\D/, '').presence
  end

  # Planos comerciais visíveis com rank maior que o atual — únicos elegíveis a upgrade self-service
  # (Plan::ChangeSubscriptionService#upgrade!, que roda quando o pagamento é confirmado). Plano sem rank (courtesy/internal_unlimited) não
  # oferece upgrade por aqui: nil <=> Integer nunca casa, então current.nil? vira o filtro de fato.
  def available_upgrades(current_plan)
    current_rank = current_plan.commercial_rank
    return [] if current_rank.nil?

    Plan.active.where(visible_to_new_subscribers: true).select do |candidate|
      candidate.commercial_rank && candidate.commercial_rank > current_rank
    end.sort_by(&:commercial_rank).map do |candidate|
      {
        slug: candidate.slug,
        name: candidate.name,
        description: candidate.description,
        monthly_price_cents: candidate.monthly_price_cents
      }
    end
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
