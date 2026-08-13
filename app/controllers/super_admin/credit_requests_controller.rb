class SuperAdmin::CreditRequestsController < SuperAdmin::ApplicationController
  # O Administrate inferiria o modelo `CreditRequest` do nome do controller; o modelo real é
  # AiCreditRequest (casa com AiCreditBalance). Override explícito p/ index/show/requested_resource.
  def resource_class
    AiCreditRequest
  end

  # Aprova: credita os créditos solicitados nos extra_credits da conta + marca approved.
  def approve
    requested_resource.approve!(by: current_super_admin)
    # rubocop:disable Rails/I18nLocaleTexts
    redirect_to super_admin_credit_request_path(requested_resource),
                notice: "Solicitação ##{requested_resource.id} aprovada — #{requested_resource.amount_requested} créditos adicionados."
    # rubocop:enable Rails/I18nLocaleTexts
  rescue StandardError => e
    redirect_to super_admin_credit_request_path(requested_resource), alert: "Não foi possível aprovar: #{e.message}"
  end

  # Rejeita: marca rejected (não credita). review_note = motivo opcional.
  def reject
    requested_resource.reject!(by: current_super_admin, note: params[:review_note])
    # rubocop:disable Rails/I18nLocaleTexts
    redirect_to super_admin_credit_request_path(requested_resource),
                notice: "Solicitação ##{requested_resource.id} rejeitada."
    # rubocop:enable Rails/I18nLocaleTexts
  rescue StandardError => e
    redirect_to super_admin_credit_request_path(requested_resource), alert: "Não foi possível rejeitar: #{e.message}"
  end
end
