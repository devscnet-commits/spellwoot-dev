require 'rails_helper'

# Guard de SSRF compartilhado por todos os sinks de saída HTTP da IA (webhook/integração/crawl).
# Testa o bloqueio contra rede interna/metadados e a passagem de URLs públicas legítimas.
# IPs literais são resolvidos offline pelo Resolv (não batem na rede), então não precisam de stub.
RSpec.describe Ai::SafeHttp do
  before do
    # Só stuba a resolução de hostnames públicos usados nos testes; literais seguem offline.
    allow(Resolv).to receive(:getaddresses).and_call_original
    allow(Resolv).to receive(:getaddresses).with('public.example.com').and_return(['93.184.216.34'])
  end

  describe '.request — bloqueio de SSRF' do
    it 'bloqueia o metadata endpoint de nuvem (169.254.169.254)' do
      expect { described_class.request(:get, 'http://169.254.169.254/latest/meta-data/iam/security-credentials/') }
        .to raise_error(Ai::SafeHttp::BlockedUrlError)
    end

    it 'bloqueia faixa privada 10.0.0.0/8' do
      expect { described_class.request(:get, 'http://10.0.0.5/secret') }
        .to raise_error(Ai::SafeHttp::BlockedUrlError)
    end

    it 'bloqueia faixa privada 172.16.0.0/12' do
      expect { described_class.request(:get, 'http://172.16.10.10/secret') }
        .to raise_error(Ai::SafeHttp::BlockedUrlError)
    end

    it 'bloqueia faixa privada 192.168.0.0/16' do
      expect { described_class.request(:get, 'http://192.168.1.1/secret') }
        .to raise_error(Ai::SafeHttp::BlockedUrlError)
    end

    it 'bloqueia loopback 127.0.0.0/8' do
      expect { described_class.request(:get, 'http://127.0.0.1/secret') }
        .to raise_error(Ai::SafeHttp::BlockedUrlError)
    end

    it 'bloqueia hostname que resolve para IP privado (DNS rebinding)' do
      allow(Resolv).to receive(:getaddresses).with('evil.example.com').and_return(['10.0.0.1'])
      expect { described_class.request(:get, 'http://evil.example.com/secret') }
        .to raise_error(Ai::SafeHttp::BlockedUrlError)
    end

    it 'bloqueia REDIRECT que aponta para IP privado, mesmo com URL inicial pública' do
      stub_request(:get, 'http://public.example.com/redir')
        .to_return(status: 302, headers: { 'Location' => 'http://169.254.169.254/latest/meta-data/' })

      expect { described_class.request(:get, 'http://public.example.com/redir') }
        .to raise_error(Ai::SafeHttp::BlockedUrlError)
    end

    it 'bloqueia scheme não-HTTP (ex.: file://)' do
      expect { described_class.request(:get, 'file:///etc/passwd') }
        .to raise_error(Ai::SafeHttp::BlockedUrlError)
    end

    it 'rejeita método HTTP não suportado sem fazer requisição' do
      expect { described_class.request(:trace, 'http://public.example.com/') }
        .to raise_error(Ai::SafeHttp::BlockedUrlError, /não suportado/)
    end
  end

  describe '.request — URLs públicas legítimas' do
    it 'passa uma URL pública normal e devolve code (Integer) + body (String)' do
      stub_request(:get, 'http://public.example.com/ok')
        .to_return(status: 200, body: '{"ok":true}', headers: { 'Content-Type' => 'application/json' })

      res = described_class.request(:get, 'http://public.example.com/ok')
      expect(res.code).to eq(200)
      expect(res.body).to eq('{"ok":true}')
    end

    it 'envia corpo em POST e devolve o status' do
      stub_request(:post, 'http://public.example.com/hook')
        .with(body: '{"a":1}')
        .to_return(status: 201, body: 'created')

      res = described_class.request(:post, 'http://public.example.com/hook', body: '{"a":1}')
      expect(res.code).to eq(201)
      expect(res.body).to eq('created')
    end

    it 'mescla query em GET' do
      stub_request(:get, 'http://public.example.com/q')
        .with(query: { 'cpf' => '123' })
        .to_return(status: 200, body: 'ok')

      res = described_class.request(:get, 'http://public.example.com/q', query: { 'cpf' => '123' })
      expect(res.code).to eq(200)
    end
  end

  describe '.request — falha de rede (URL já validada)' do
    it 'mapeia timeout para RequestError (não BlockedUrlError)' do
      stub_request(:get, 'http://public.example.com/slow').to_raise(Net::OpenTimeout)

      expect { described_class.request(:get, 'http://public.example.com/slow') }
        .to raise_error(Ai::SafeHttp::RequestError)
    end
  end
end
