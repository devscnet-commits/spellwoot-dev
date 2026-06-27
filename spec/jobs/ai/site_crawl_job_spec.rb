require 'rails_helper'

RSpec.describe Ai::SiteCrawlJob do
  let(:job) { described_class.new }

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
