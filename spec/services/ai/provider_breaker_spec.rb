require 'rails_helper'

# Fase 3 da frente provider-error: circuit breaker por (conta, provider). Prova de mutação por nome — cada
# teste morre se o parâmetro/estado correspondente for revertido. Rails.cache é null_store no teste (não
# persiste nem incrementa); troco por um MemoryStore real para exercitar o breaker de verdade.
RSpec.describe Ai::ProviderBreaker do
  let(:account) { create(:account) }
  subject(:breaker) { described_class.new(account: account, provider: 'openai') }

  before do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
  end

  describe '#record_failure — abre em 3 consecutivas' do
    it '3 falhas consecutivas ABREM o breaker (as 2 primeiras não)' do
      aggregate_failures do
        expect(breaker.record_failure).to be_nil # 1
        expect(breaker.record_failure).to be_nil # 2
        expect(breaker.record_failure).to include(consecutive_failures: 3, reopened: false) # 3 -> abre
        expect(breaker.state).to eq(:open)
      end
    end

    it 'sucesso NO MEIO zera o contador (só consecutivas contam): precisa de 3 NOVAS para abrir' do
      2.times { breaker.record_failure }
      expect(breaker.record_success).to be_nil # nada estava aberto -> sem evento, mas RESETA o contador

      aggregate_failures do
        expect(breaker.record_failure).to be_nil # 1 (recomeçou do zero)
        expect(breaker.record_failure).to be_nil # 2
        expect(breaker.record_failure).to include(consecutive_failures: 3) # só agora abre
      end
    end
  end

  describe '#state — cooldown e half-open' do
    before { 3.times { breaker.record_failure } } # abre

    it 'com o breaker aberto, o state é :open (pula a chamada) durante o cooldown' do
      expect(breaker.state).to eq(:open)
    end

    it 'depois do cooldown, UMA chamada passa (:half_open) e as demais seguem pulando (:open)' do
      travel(described_class::COOLDOWN + 1.minute) do
        aggregate_failures do
          expect(breaker.state).to eq(:half_open) # o 1º worker ganha o passe
          expect(breaker.state).to eq(:open)      # o 2º (concorrente) segue pulando — passe único
        end
      end
    end
  end

  describe 'half-open -> resolução' do
    before { 3.times { breaker.record_failure } }

    it 'sucesso no half-open FECHA e ZERA (via half_open); depois 2 falhas não reabrem' do
      travel(described_class::COOLDOWN + 1.minute) do
        expect(breaker.state).to eq(:half_open) # concede o passe
        expect(breaker.record_success).to eq(:half_open) # fecha
        aggregate_failures do
          expect(breaker.state).to eq(:closed)
          expect(breaker.record_failure).to be_nil # contador zerado
          expect(breaker.record_failure).to be_nil
        end
      end
    end

    it 'falha no half-open REABRE (novo cooldown)' do
      travel(described_class::COOLDOWN + 1.minute) do
        expect(breaker.state).to eq(:half_open) # concede o passe
        aggregate_failures do
          expect(breaker.record_failure).to include(reopened: true) # a falha do teste reabre
          expect(breaker.state).to eq(:open)
        end
      end
    end
  end

  describe 'kill-switch (saída de emergência)' do
    it 'ENV AI_PROVIDER_BREAKER=off força SEMPRE FECHADO (não abre, não pula)' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('AI_PROVIDER_BREAKER').and_return('off')

      aggregate_failures do
        expect(breaker.record_failure).to be_nil
        expect(breaker.record_failure).to be_nil
        expect(breaker.record_failure).to be_nil # 3 falhas e mesmo assim...
        expect(breaker.state).to eq(:closed)     # ...segue fechado
      end
    end

    # O caminho que DESARMA SEM DEPLOY: uma linha de InstallationConfig, flipável em runtime (super
    # admin/console), lida FRESCA a cada turno (find_by, sem cache). Prova de mutação: falha se o breaker
    # deixar de consultar o InstallationConfig.
    it 'InstallationConfig AI_PROVIDER_BREAKER=off força SEMPRE FECHADO (desarme em RUNTIME, sem deploy)' do
      create(:installation_config, name: 'AI_PROVIDER_BREAKER', value: 'off')

      aggregate_failures do
        expect(breaker.record_failure).to be_nil
        expect(breaker.record_failure).to be_nil
        expect(breaker.record_failure).to be_nil # 3 falhas...
        expect(breaker.state).to eq(:closed)     # ...segue fechado
      end
    end
  end
end
