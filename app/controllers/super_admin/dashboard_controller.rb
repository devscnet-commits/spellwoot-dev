class SuperAdmin::DashboardController < SuperAdmin::ApplicationController
  include ActionView::Helpers::NumberHelper

  def index
    @data = Conversation.unscoped.group_by_day(:created_at, range: 30.days.ago..2.seconds.ago).count.to_a
    @accounts_count = number_with_delimiter(Account.count)
    @users_count = number_with_delimiter(User.count)
    @inboxes_count = number_with_delimiter(Inbox.count)
    @conversations_count = number_with_delimiter(Conversation.count)
    @mrr = number_to_currency(mrr_cents / 100.0, unit: 'R$', separator: ',', delimiter: '.')
    @active_subscriptions_count = number_with_delimiter(Subscription.active.count)
  end

  private

  # Soma monthly_price_cents das assinaturas ativas. Planos sem preço fixo (interno do grupo,
  # Enterprise "sob consulta") somam 0 — MRR real de Enterprise fica de fora até ter preço no
  # sistema, o que é a limitação conhecida de reportar algo negociado fora da plataforma.
  def mrr_cents
    Subscription.active.joins(:plan).sum('plans.monthly_price_cents')
  end
end
