class SuperAdmin::PlansController < SuperAdmin::ApplicationController
  # :slug só na CRIAÇÃO — trocá-lo depois desalinharia PLAN_FEATURE_TO_ACCOUNT_FLAG/COMMERCIAL_RANK/
  # plans:seed, que localizam o plano por slug. A partial do PlanSlugField já vira texto puro num
  # plano existente; aqui é a garantia de servidor.
  #
  # :new/:create passaram a existir: o motivo de não existirem era "features/limites só via
  # plans:seed", e isso deixou de valer agora que a grade é editável nesta tela.
  #
  # feature_grid/limit_grid NÃO entram aqui: as partials as enviam como campos de topo
  # (plan_feature_keys[] / plan_limits[...]), fora do namespace `plan[...]`, e quem grava é #update
  # abaixo. Assim o Administrate nunca tenta atribuí-las ao model.
  def resource_params
    permitted = params.require(:plan).permit(
      :name, :description, :active, :visible_to_new_subscribers, :courtesy,
      :monthly_price_cents, :annual_price_cents, :setup_fee_cents,
      :promo_price_cents, :promo_months_count,
      :ai_credits_included, :ai_credit_overage_price_cents
    )
    permitted[:slug] = params[:plan_slug].to_s.strip if action_name == 'create'
    permitted
  end

  # Um plano recém-criado sem grade é exatamente o que colocou `pro`/`standard` em produção sem
  # feature nenhuma e sem lugar para corrigir. Aqui a grade é gravada junto da criação.
  def create
    super
    return if requested_resource.blank? || !requested_resource.persisted?

    apply_grids
  end

  # O super do Administrate salva o plano e redireciona (ou re-renderiza o form com erros). As grades
  # só são gravadas quando o plano em si salvou — senão uma validação reprovada deixaria features
  # novas gravadas junto de um plano que o usuário ainda vai corrigir.
  def update
    super
    return if requested_resource.errors.any? || params[:plan_grid_submitted].blank?

    apply_grids
    flash[:notice] = "Plano atualizado. #{sync_active_accounts} conta(s) ativa(s) sincronizada(s)."
  end

  private

  # "Liberar tudo" sobrepõe as marcações individuais: é um preset, não um acréscimo — quem marca
  # espera o plano interno/ilimitado inteiro, não a união com o que estava marcado.
  def apply_grids
    if params[:plan_unlock_all].present?
      requested_resource.unlock_everything!
      return
    end

    requested_resource.apply_feature_grid!(params[:plan_feature_keys])
    requested_resource.apply_limit_grid!(params.fetch(:plan_limits, {}).permit!.to_h)
  end

  # A regra de negócio já lê o plano ao vivo (FeatureGate), então isto é para a UI: o bitmask da conta
  # é o que gateia sidebar e rotas, e só era reescrito no after_save da Subscription — sem isto, mudar
  # o plano aqui não mudaria nada na tela do cliente até a próxima renovação.
  # Falha de uma conta não derruba as outras nem o salvamento do plano.
  def sync_active_accounts
    synced = 0
    Subscription.where(plan_id: requested_resource.id).where.not(status: :canceled)
                .includes(:account).find_each do |subscription|
      next if subscription.account.blank?

      requested_resource.sync_features_to!(subscription.account)
      synced += 1
    rescue StandardError => e
      Rails.logger.error "[SuperAdmin::PlansController] sync conta=#{subscription.account_id}: #{e.class}: #{e.message}"
    end
    synced
  end
end
