class SuperAdmin::CreditRequestsController < SuperAdmin::ApplicationController
  # Aprova: credita os créditos solicitados nos extra_credits da conta + marca approved.
  def approve
    requested_resource.approve!(by: current_super_admin)
    # rubocop:disable Rails/I18nLocaleTexts
    redirect_back(fallback_location: [namespace, requested_resource],
                  notice: "Solicitação ##{requested_resource.id} aprovada — #{requested_resource.amount_requested} créditos adicionados.")
    # rubocop:enable Rails/I18nLocaleTexts
  rescue StandardError => e
    redirect_back(fallback_location: [namespace, requested_resource], alert: "Não foi possível aprovar: #{e.message}")
  end

  # Rejeita: marca rejected (não credita). review_note = motivo opcional.
  def reject
    requested_resource.reject!(by: current_super_admin, note: params[:review_note])
    # rubocop:disable Rails/I18nLocaleTexts
    redirect_back(fallback_location: [namespace, requested_resource],
                  notice: "Solicitação ##{requested_resource.id} rejeitada.")
    # rubocop:enable Rails/I18nLocaleTexts
  rescue StandardError => e
    redirect_back(fallback_location: [namespace, requested_resource], alert: "Não foi possível rejeitar: #{e.message}")
  end
end
