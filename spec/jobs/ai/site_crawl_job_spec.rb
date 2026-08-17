require 'rails_helper'

RSpec.describe Ai::SiteCrawlJob do
  include ActiveJob::TestHelper

  let(:job) { described_class.new }

  describe '#perform (guard SSRF)' do
    let(:account) { create(:account) }

    def website_source(url, raw: 'antigo')
      Ai::KnowledgeSource.create!(account: account, kind: 'website', title: url, raw: raw, status: 'active')
    end

    before do
      allow(Resolv).to receive(:getaddresses).and_call_original
      allow(Resolv).to receive(:getaddresses).with('blog.example.com').and_return(['93.184.216.34'])
    end

    it 'faz o crawl de um site público e ingere o texto' do
      stub_request(:get, 'http://blog.example.com/')
        .to_return(status: 200, body: '<html><body><p>Planos a partir de R$ 99</p></body></html>',
                   headers: { 'Content-Type' => 'text/html' })
      source = website_source('http://blog.example.com/')

      expect { described_class.new.perform(source.id) }
        .to have_enqueued_job(Ai::KnowledgeIngestJob)
      expect(source.reload.raw).to include('Planos a partir de R$ 99')
    end

    it 'NÃO busca uma URL que resolve para o metadata endpoint (não trava, não ingere)' do
      source = website_source('http://169.254.169.254/latest/meta-data/')

      expect { described_class.new.perform(source.id) }.not_to raise_error
      expect(source.reload.raw).to eq('antigo') # não atualizado
      expect(Ai::KnowledgeIngestJob).not_to have_been_enqueued
    end

    it 'bloqueia REDIRECT de site público para IP privado (não ingere)' do
      stub_request(:get, 'http://blog.example.com/')
        .to_return(status: 302, headers: { 'Location' => 'http://10.0.0.1/interno' })
      source = website_source('http://blog.example.com/')

      expect { described_class.new.perform(source.id) }.not_to raise_error
      expect(source.reload.raw).to eq('antigo')
    end
  end

  describe '#extract_text' do
    it 'returns visible text and drops script/style' do
      html = '<html><head><title>x</title></head><body>' \
             '<script>bad()</script><p>Olá mundo</p><style>.a{}</style></body></html>'
      text = job.send(:extract_text, html)
      expect(text).to include('Olá mundo')
      expect(text).not_to include('bad()')
    end
  end

  describe '#normalize_url' do
    it 'prefixes https when the scheme is missing' do
      expect(job.send(:normalize_url, 'site.com.br')).to eq('https://site.com.br')
    end

    it 'keeps an explicit scheme' do
      expect(job.send(:normalize_url, 'http://x.com')).to eq('http://x.com')
    end

    it 'is blank for blank input' do
      expect(job.send(:normalize_url, '')).to eq('')
    end
  end
end
