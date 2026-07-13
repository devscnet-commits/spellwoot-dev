# Solicitação de mais créditos de IA pelo cliente (billing Fase 1). Escopado à conta atual; a tela
# de plano (/settings/plan, admin) consome. `create` gera o pedido pending e notifica a SCNET;
# `index` lista os pedidos recentes (a UI usa pra mostrar/bloquear quando já há um pending).
class Api::V1::Accounts::CreditRequestsController < Api::V1::Accounts::BaseController
  def index
    requests = Current.account.ai_credit_requests.recent_first.limit(20)
    render json: requests.map { |r| serialize(r) }
  end

  def create
    credit_request = Current.account.ai_credit_requests.new(credit_request_params.merge(requested_by: Current.user))

    if credit_request.save
      AdministratorNotifications::CreditRequestMailer.new_request(credit_request).deliver_later
      render json: serialize(credit_request), status: :created
    else
      render json: { errors: credit_request.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  def credit_request_params
    params.require(:credit_request).permit(:amount_requested, :reason)
  end

  def serialize(request)
    {
      id: request.id,
      amount_requested: request.amount_requested,
      reason: request.reason,
      status: request.status,
      requested_by: request.requested_by&.name,
      created_at: request.created_at,
      reviewed_at: request.reviewed_at
    }
  end
end
