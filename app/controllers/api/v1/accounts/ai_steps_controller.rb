# Suporte ao editor de etapa (dev-time): infere o slot que uma instrução declara, usando a MESMA
# lógica do runtime (Ai::StepSlot.infer) — sem duplicar a regex no front. Read-only: não grava nada,
# não altera a etapa. Alimenta a "faixa de feedback" do AiStepForm (mostra o que o sistema entendeu).
class Api::V1::Accounts::AiStepsController < Api::V1::Accounts::BaseController
  def infer_slot
    render json: { attribute: ::Ai::StepSlot.infer('instructions' => params[:instructions].to_s) }
  end
end
