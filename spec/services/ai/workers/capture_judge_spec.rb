require 'rails_helper'

RSpec.describe Ai::Workers::CaptureJudge do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:step) { { 'name' => 'Telefone', 'instructions' => 'Peça e grave o telefone_secundario.' } }

  def stub_model(text:, status: 'recorded', tokens_in: 120, tokens_out: 30, error: nil)
    allow(Ai::ModelRouter).to receive(:call_model).and_return(
      { text: text, tokens_in: tokens_in, tokens_out: tokens_out, status: status, error: error }
    )
  end

  def judge(message_text)
    described_class.judge(step: step, slot: 'telefone_secundario', message_text: message_text,
                          profile: profile, conversation: conversation)
  end

  def judge_runs
    Ai::Run.where(run_type: 'capture_judge')
  end

  describe '.judge' do
    it 'answered: devolve status + value do parse' do
      stub_model(text: '{"status":"answered","value":"4998564780"}')
      expect(judge('meu numero 4998564780')).to eq(status: 'answered', value: '4998564780')
    end

    it 'answered: debita UM Ai::Run capture_judge com provider/model/tokens/cost (item F)' do
      stub_model(text: '{"status":"answered","value":"4998564780"}')

      expect { judge('meu numero 4998564780') }.to change(judge_runs, :count).by(1)

      run = judge_runs.last
      expect(run.worker).to eq('capture_judge')
      expect(run.mode).to eq('worker')
      expect(run.status).to eq('recorded')
      expect(run.tokens_in).to eq(120)
      expect(run.tokens_out).to eq(30)
      expect(run.cost).to be > 0
    end

    it 'malformed: devolve o value exatamente como veio' do
      stub_model(text: '{"status":"malformed","value":"para o dia 10"}')
      expect(judge('para o dia 10')).to eq(status: 'malformed', value: 'para o dia 10')
    end

    it 'not_an_answer' do
      stub_model(text: '{"status":"not_an_answer"}')
      expect(judge('qual o plano?')).to eq(status: 'not_an_answer')
    end

    it 'JSON inválido (texto livre) -> failed' do
      stub_model(text: 'desculpe, não entendi')
      expect(judge('x')[:status]).to eq('failed')
    end

    it 'status desconhecido -> failed' do
      stub_model(text: '{"status":"talvez","value":"x"}')
      expect(judge('x')[:status]).to eq('failed')
    end

    it 'answered com value vazio -> failed (não deixa gravar vazio)' do
      stub_model(text: '{"status":"answered","value":"   "}')
      expect(judge('x')[:status]).to eq('failed')
    end

    it 'erro/timeout do provider -> failed e Ai::Run gravado com status error' do
      stub_model(text: nil, status: 'error', error: 'Net::ReadTimeout')
      expect(judge('x')[:status]).to eq('failed')
      expect(judge_runs.last.status).to eq('error')
    end

    it 'mensagem vazia -> failed SEM chamar o modelo nem criar Ai::Run' do
      expect(Ai::ModelRouter).not_to receive(:call_model)
      expect { expect(judge('   ')[:status]).to eq('failed') }.not_to change(judge_runs, :count)
    end
  end

  describe '.worker_config' do
    it 'usa o worker do perfil e faz fallback pro supervisor' do
      profile.update!(worker_overrides: { 'capture_judge' => { 'provider' => 'anthropic', 'model' => 'claude-x' } })
      expect(described_class.worker_config(profile)).to eq(%w[anthropic claude-x])
    end

    it 'sem worker configurado, cai no supervisor' do
      expect(described_class.worker_config(profile)).to eq(%w[openai gpt-4.1-mini])
    end
  end
end
