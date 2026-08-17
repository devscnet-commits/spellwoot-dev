require 'rails_helper'

RSpec.describe Ai::Embedder do
  describe '#enabled?' do
    it 'desligado quando não há chave configurada' do
      allow(described_class).to receive(:resolve_key).and_return(nil)
      expect(described_class.new.enabled?).to be(false)
    end

    it 'ligado quando há chave' do
      allow(described_class).to receive(:resolve_key).and_return('sk-test')
      expect(described_class.new.enabled?).to be(true)
    end
  end

  describe '#embed — classificação de erro (auth vs transitório)' do
    let(:context) { double('rubyllm_context') }

    before do
      allow(described_class).to receive(:resolve_key).and_return('sk-test')
      allow(RubyLLM).to receive(:context).and_return(context)
    end

    it 'retorna o vetor quando a API responde' do
      allow(context).to receive(:embed).and_return(double(vectors: [0.1, 0.2, 0.3]))
      expect(described_class.new.embed('oi')).to eq([0.1, 0.2, 0.3])
    end

    it 'texto em branco: retorna nil sem chamar a API' do
      expect(context).not_to receive(:embed)
      expect(described_class.new.embed('   ')).to be_nil
    end

    # PERMANENTE -> AuthError (o caller degrada, não re-tenta)
    [
      ['401 UnauthorizedError', -> { RubyLLM::UnauthorizedError.new(nil, 'Invalid API key') }],
      ['403 ForbiddenError', -> { RubyLLM::ForbiddenError.new(nil, 'forbidden') }],
      ['402 PaymentRequiredError', -> { RubyLLM::PaymentRequiredError.new(nil, 'payment') }],
      ['400 BadRequestError', -> { RubyLLM::BadRequestError.new(nil, 'bad request') }]
    ].each do |label, builder|
      it "mapeia #{label} para AuthError" do
        allow(context).to receive(:embed).and_raise(builder.call)
        expect { described_class.new.embed('oi') }.to raise_error(Ai::Embedder::AuthError)
      end
    end

    # TRANSITÓRIO -> TransientError (re-tentável pelo Sidekiq)
    [
      ['429 RateLimitError', -> { RubyLLM::RateLimitError.new(nil, 'rate limit') }],
      ['5xx ServerError', -> { RubyLLM::ServerError.new(nil, 'server error') }],
      ['503 ServiceUnavailableError', -> { RubyLLM::ServiceUnavailableError.new(nil, 'unavailable') }],
      ['timeout de rede', -> { Net::ReadTimeout.new }]
    ].each do |label, builder|
      it "mapeia #{label} para TransientError" do
        allow(context).to receive(:embed).and_raise(builder.call)
        expect { described_class.new.embed('oi') }.to raise_error(Ai::Embedder::TransientError)
      end
    end
  end

  describe '.embed (atalho degradável — usado pelo retriever)' do
    it 'retorna nil quando não há chave (não levanta)' do
      allow(described_class).to receive(:resolve_key).and_return(nil)
      expect(described_class.embed('oi')).to be_nil
    end

    it 'degrada AuthError (chave inválida) em nil — não quebra a busca' do
      allow(described_class).to receive(:resolve_key).and_return('sk-test')
      ctx = double('rubyllm_context')
      allow(RubyLLM).to receive(:context).and_return(ctx)
      allow(ctx).to receive(:embed).and_raise(RubyLLM::UnauthorizedError.new(nil, 'bad key'))
      expect(described_class.embed('oi')).to be_nil
    end

    it 'deixa TransientError propagar (o caller decide degradar)' do
      allow(described_class).to receive(:resolve_key).and_return('sk-test')
      ctx = double('rubyllm_context')
      allow(RubyLLM).to receive(:context).and_return(ctx)
      allow(ctx).to receive(:embed).and_raise(RubyLLM::RateLimitError.new(nil, '429'))
      expect { described_class.embed('oi') }.to raise_error(Ai::Embedder::TransientError)
    end
  end
end
