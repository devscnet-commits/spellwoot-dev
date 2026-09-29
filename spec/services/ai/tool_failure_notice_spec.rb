require 'rails_helper'

# Ferramenta da IA que falha deixa nota interna legível na conversa — antes a falha era silenciosa para a
# equipe (ferramenta de viabilidade fora do ar por dias sem ninguém saber).
RSpec.describe Ai::ToolFailureNotice do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:tool) do
    Ai::Tool.create!(account: account, name: 'consultar_viabilidade', implementation_type: 'webhook', status: 'active',
                     webhook_config: { 'url' => 'https://viabilidade.exemplo.com/consulta', 'method' => 'POST' })
  end

  def run_tool(mode: 'live')
    Ai::ToolExecutor.new(tool: tool, input: { 'cep' => '89800000' }, conversation: conversation, mode: mode).perform
  end

  def notes
    conversation.messages.where(private: true)
  end

  it 'sistema externo fora do ar: nota interna com o motivo e o detalhe técnico' do
    allow(Ai::SafeHttp).to receive(:request).and_raise(Errno::ECONNREFUSED)

    expect(run_tool.status).to eq('failed')
    expect(notes.count).to eq(1)
    expect(notes.last.content).to include('consultar_viabilidade', 'fora do ar ou inacessível', 'Detalhe técnico')
  end

  it 'HTTP 404: explica que o endereço configurado não existe' do
    allow(Ai::SafeHttp).to receive(:request).and_return(instance_double(HTTParty::Response, code: 404, body: 'not found'))

    run_tool

    expect(notes.last.content).to include('endereço configurado não existe')
  end

  it 'várias tentativas seguidas da mesma ferramenta geram uma nota só' do
    allow(Ai::SafeHttp).to receive(:request).and_raise(Net::ReadTimeout)

    3.times { run_tool }

    expect(notes.count).to eq(1)
    expect(notes.last.content).to include('não respondeu a tempo')
  end

  it 'ferramenta que funcionou não gera nota' do
    allow(Ai::SafeHttp).to receive(:request).and_return(instance_double(HTTParty::Response, code: 200, body: '{"ok":true}'))

    expect(run_tool.status).to eq('executed')
    expect(notes).to be_empty
  end

  it 'ferramenta de controle (sem registro de auditoria) também avisa' do
    described_class.post(conversation: conversation, tool_name: 'conversation.resolve', error: 'RuntimeError: boom')

    expect(notes.last.content).to include('conversation.resolve', 'erro inesperado', 'RuntimeError: boom')
  end

  it 'modo sombra não executa nem avisa' do
    run_tool(mode: 'shadow')

    expect(notes).to be_empty
  end
end
