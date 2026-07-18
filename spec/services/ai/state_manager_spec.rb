require 'rails_helper'

RSpec.describe Ai::StateManager do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) do
    Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id)
  end
  let(:department) do
    dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Atendimento', status: 'active',
                                  behavior: {})
    dept.create_playbook!(active: true, steps: [
                            { 'name' => 'Coleta', 'group_delay_seconds' => 5,
                              'automations' => [{ 'type' => 'tag', 'params' => { 'label' => 'vip' } }] },
                            { 'name' => 'Proposta' },
                            { 'name' => 'Fechamento' }
                          ])
    dept
  end
  let(:run) do
    Ai::Run.create!(account_id: account.id, conversation_id: conversation.id, ai_agent_id: agent.id,
                    inbox_id: inbox.id, run_type: 'decision', mode: 'live', status: 'running')
  end
  let(:dispatcher) do
    Ai::ActionDispatcher.new(conversation: conversation, account: account, mode: 'live', acts_live: true)
  end
  subject(:manager) { described_class.new(conversation: conversation, agent: agent) }

  # current_step é intencionalmente ARBITRÁRIO nos testes: não é mais fonte de verdade (só log).
  def track(step_completed:, current_step: nil, with_context: true)
    decision = { 'current_step' => current_step, 'step_completed' => step_completed }
    if with_context
      manager.track_step(department, decision, dispatcher: dispatcher, run: run)
    else
      manager.track_step(department, decision)
    end
  end

  def step_index
    conversation.reload.additional_attributes['ai_step_index']
  end

  def set_index(idx)
    conversation.update!(additional_attributes: (conversation.additional_attributes || {}).merge('ai_step_index' => idx))
  end

  describe '#track_step — progressão determinística por índice' do
    it 'avança o índice em +1 quando step_completed é true' do
      expect { track(step_completed: true) }.to change { step_index }.from(nil).to(1)
    end

    it 'NÃO avança quando step_completed é false' do
      set_index(1)
      expect { track(step_completed: false) }.not_to(change { step_index })
      expect(step_index).to eq(1)
    end

    it 'trava no índice máximo (nunca ultrapassa steps.size - 1)' do
      set_index(2) # última etapa (Fechamento) de 3
      track(step_completed: true)
      expect(step_index).to eq(2)
    end

    it 'NUNCA retrocede, mesmo se o modelo relatar um current_step de etapa anterior' do
      set_index(1)
      # modelo "acha" que está na Coleta (etapa 0) e não concluiu -> índice permanece 1
      track(step_completed: false, current_step: 'Coleta')
      expect(step_index).to eq(1)
    end

    it 'começa em 0 quando não há índice salvo' do
      # step_completed false na primeira etapa: fixa o índice em 0 sem avançar
      track(step_completed: false)
      expect(step_index).to eq(0)
    end

    it 'grava o current_step relatado apenas como log (reported_name), sem virar fonte de verdade' do
      set_index(1)
      track(step_completed: false, current_step: 'Coleta')
      ai_step = conversation.reload.additional_attributes['ai_step']
      expect(ai_step['reported_name']).to eq('Coleta') # log
      expect(ai_step['name']).to eq('Proposta')        # nome REAL da etapa no índice 1
      expect(step_index).to eq(1)
    end

    it 'expõe o grouping_delay_seconds da etapa atual (após o avanço) para o MessageGrouping' do
      # etapa 0 (Coleta) tem delay 5; ao concluir avança para 1 (Proposta, sem delay -> nil)
      track(step_completed: false)
      expect(conversation.reload.additional_attributes.dig('ai_step', 'grouping_delay_seconds')).to eq(5)

      track(step_completed: true) # 0 -> 1
      expect(conversation.reload.additional_attributes.dig('ai_step', 'grouping_delay_seconds')).to be_nil
    end

    it 'é no-op quando o playbook não tem etapas' do
      department.playbook.update!(steps: [])
      expect { track(step_completed: true) }.not_to raise_error
      expect(conversation.reload.additional_attributes['ai_step_index']).to be_nil
    end
  end

  describe '#track_step — automação de etapa por transição de índice' do
    it 'dispara a automação da etapa concluída UMA vez por índice (idempotente via last_fired)' do
      runner = instance_double(Ai::StepAutomationRunner, run: nil)
      allow(Ai::StepAutomationRunner).to receive(:new).and_return(runner)

      track(step_completed: false) # etapa 0 em andamento -> não dispara
      track(step_completed: true)  # conclui etapa 0 -> dispara + avança para 1

      # força o índice de volta para 0 (não acontece no fluxo real, mas garante a idempotência)
      set_index(0)
      track(step_completed: true) # já disparou p/ o índice 0 -> NÃO dispara de novo

      expect(runner).to have_received(:run).once
    end

    it 'registra o último índice disparado (ai_step_last_fired_index)' do
      allow_any_instance_of(Ai::StepAutomationRunner).to receive(:run)

      track(step_completed: true) # conclui etapa 0

      expect(conversation.reload.additional_attributes['ai_step_last_fired_index']).to eq(0)
    end

    it 'não dispara automação sem dispatcher/run (shadow / sem contexto)' do
      expect(Ai::StepAutomationRunner).not_to receive(:new)

      track(step_completed: true, with_context: false)
    end
  end

  describe '#track_step — avanço DETERMINÍSTICO por slot (collect)' do
    let(:slot_department) do
      dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'ColetaSlot',
                                    status: 'active', behavior: {})
      dept.create_playbook!(active: true, steps: [
                              { 'name' => 'Nome',
                                'collect' => { 'attribute' => 'nome', 'type' => 'text', 'required' => true },
                                'automations' => [{ 'type' => 'tag', 'params' => { 'label' => 'coletado' } }] },
                              { 'name' => 'Planos', 'complete_when' => 'always' },
                              { 'name' => 'Fim' }
                            ])
      dept
    end

    def track_slot(decision)
      manager.track_step(slot_department, decision, dispatcher: dispatcher, run: run)
    end

    it 'avança quando o slot é preenchido no MESMO turno (decision[attributes]), mesmo com step_completed=false' do
      expect { track_slot('step_completed' => false, 'attributes' => { 'nome' => 'Jaque' }) }
        .to change { step_index }.from(nil).to(1)
    end

    it 'avança quando o slot já está em ai_collected_facts (turno anterior), sem attributes e sem step_completed' do
      conversation.update!(additional_attributes: { 'ai_step_index' => 0,
                                                     'ai_collected_facts' => { 'nome' => 'Jaque' } })
      track_slot('step_completed' => false)
      expect(step_index).to eq(1)
    end

    it 'NÃO avança com o slot vazio, mesmo se o modelo mandar step_completed=true (o código decide)' do
      track_slot('step_completed' => true, 'attributes' => {})
      expect(step_index).to eq(0)
    end

    it 'ignora valor em branco no slot (não avança)' do
      track_slot('step_completed' => false, 'attributes' => { 'nome' => '   ' })
      expect(step_index).to eq(0)
    end

    it 'etapa informativa (complete_when=always, sem collect) avança só pelo sinal do modelo' do
      set_index(1) # Planos
      track_slot('step_completed' => false)
      expect(step_index).to eq(1) # sem sinal -> fica
      track_slot('step_completed' => true)
      expect(step_index).to eq(2) # com sinal -> avança
    end

    it 'dispara a automação da etapa ao concluir POR SLOT (step_completed=false) — correção do gating' do
      runner = instance_double(Ai::StepAutomationRunner, run: nil)
      allow(Ai::StepAutomationRunner).to receive(:new).and_return(runner)

      track_slot('step_completed' => false, 'attributes' => { 'nome' => 'Jaque' })

      expect(runner).to have_received(:run).once
      expect(step_index).to eq(1)
    end

    it 'NÃO dispara a automação da etapa de slot enquanto o slot não é preenchido' do
      expect(Ai::StepAutomationRunner).not_to receive(:new)

      track_slot('step_completed' => true, 'attributes' => {}) # step_completed true é ignorado (slot vazio)
      expect(step_index).to eq(0)
    end
  end

  describe '#track_step — rede de segurança (Camada A extração + Camada B fallback)' do
    let(:safety_department) do
      dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Cadastro',
                                    status: 'active', behavior: {})
      dept.create_playbook!(active: true, steps: [
                              { 'name' => 'CPF',
                                'collect' => { 'attribute' => 'cpf', 'type' => 'cpf', 'required' => true } },
                              { 'name' => 'Nome',
                                'collect' => { 'attribute' => 'nome', 'type' => 'text', 'required' => true } },
                              { 'name' => 'Fim' }
                            ])
      dept
    end

    def track_msg(decision, text)
      manager.track_step(safety_department, decision, dispatcher: dispatcher, run: run, message_text: text)
    end

    def facts
      conversation.reload.additional_attributes['ai_collected_facts'] || {}
    end

    def stuck_turns
      conversation.reload.additional_attributes['ai_step_stuck_turns']
    end

    def events(type)
      Ai::Event.where(conversation_id: conversation.id, event_type: type)
    end

    describe 'Camada A / Parte 2 — captura do slot (extrator OU texto cru, sempre gravável)' do
      it 'extrai o CPF (tipo conhecido) e AVANÇA mesmo sem o modelo devolver attributes' do
        track_msg({ 'step_completed' => false }, 'meu cpf é 111.444.777-35')

        expect(facts['cpf']).to eq('111.444.777-35')
        expect(step_index).to eq(1)
        expect(events('slot.captured').last.payload).to include('attribute' => 'cpf', 'source' => 'extractor')
      end

      it 'captura o TEXTO CRU num slot de texto e AVANÇA (guarda e segue, sem reperguntar)' do
        set_index(1) # etapa Nome (type=text) — o extrator não pega, grava o cru

        track_msg({ 'step_completed' => false }, 'meu nome é Jaque')

        expect(facts['nome']).to eq('meu nome é Jaque')
        expect(step_index).to eq(2)
        expect(events('slot.captured').last.payload).to include('attribute' => 'nome', 'source' => 'raw')
      end
    end

    describe 'Camada B/#259 — handoff por trava só quando o cliente SOME (message_text vazio)' do
      def track_blank(limit)
        safety_department.update!(transfer_rules: { 'stuck_handoff_turns' => limit })
        manager.track_step(safety_department, { 'step_completed' => false },
                           dispatcher: dispatcher, run: run, message_text: '')
      end

      it 'cliente RESPONDENDO (mesmo junk) NÃO conta como trava — captura e avança' do
        set_index(1)
        safety_department.update!(transfer_rules: { 'stuck_handoff_turns' => 3 })

        sig = track_msg({ 'step_completed' => false }, 'oi')

        expect(sig).to be_nil
        expect(step_index).to eq(2)   # avançou (guarda e segue)
        expect(stuck_turns).to be_nil # nunca contou trava
      end

      it 'cliente SUMIDO (msg vazia): conta trava e no limite sinaliza stuck_handoff' do
        set_index(1)

        expect(track_blank(3)).to be_nil # turno 1
        expect(stuck_turns).to eq(1)
        expect(track_blank(3)).to be_nil # turno 2
        expect(stuck_turns).to eq(2)

        sig = track_blank(3) # turno 3 -> handoff
        expect(sig).to eq(stuck_handoff: { attribute: 'nome', step_name: 'Nome', turns: 3 })
        expect(step_index).to eq(1)
      end

      it 'X=0 desliga: cliente sumido nunca sinaliza handoff, permanece na etapa' do
        set_index(1)

        5.times { expect(track_blank(0)).to be_nil }
        expect(step_index).to eq(1)
      end

      it 'concorrência: o contador (msg vazia) não sobrescreve ai_step_index nem ai_collected_facts' do
        conversation.update!(additional_attributes: { 'ai_step_index' => 1,
                                                       'ai_collected_facts' => { 'x' => '1' } })

        track_blank(3) # etapa 1 (Nome/text), cliente sumido — fica parado

        attrs = conversation.reload.additional_attributes
        expect(attrs['ai_step_index']).to eq(1)
        expect(attrs['ai_collected_facts']).to eq({ 'x' => '1' })
        expect(attrs['ai_step_stuck_turns']).to eq(1)
      end
    end

    # === CONSERTO: slot inferido da instrução + confirmação-única de valor estranho ================
    describe 'conserto — slot inferido + confirma 1x se estranho, nunca fica preso' do
      let(:infer_department) do
        dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Cadastro2',
                                      status: 'active', behavior: {})
        # etapa SEM collect declarado; a instrução manda gravar no atributo email (criada antes do #259)
        dept.create_playbook!(active: true, steps: [
                                { 'name' => 'CADASTRO de email',
                                  'instructions' => 'Peça e grave o e-mail do cliente no atributo email.' },
                                { 'name' => 'Fim' }
                              ])
        dept
      end

      def track_infer(decision, text)
        infer_department.update!(transfer_rules: { 'stuck_handoff_turns' => 3 })
        manager.track_step(infer_department, decision, dispatcher: dispatcher, run: run, message_text: text)
      end

      it 'infere o slot "email" da instrução (sem collect, sem atributo personalizado)' do
        expect(Ai::StepSlot.required_attribute(infer_department.playbook.steps.first)).to eq('email')
      end

      it 'e-mail MALFORMADO + cliente TEIMA: confirma 1x, depois grava como veio e AVANÇA (sem loop)' do
        # turno 1: valor estranho -> confirma UMA vez (hold, não avança), grava o valor
        expect(track_infer({ 'step_completed' => false }, 'Hgdd@()(.com')).to be_nil
        expect(step_index).to eq(0)
        expect(facts['email']).to eq('Hgdd@()(.com')
        expect(conversation.reload.additional_attributes['ai_step_confirm_index']).to eq(0)

        # turno 2: cliente teima -> NÃO confirma de novo, grava como veio e AVANÇA
        expect(track_infer({ 'step_completed' => false }, 'já mandei')).to be_nil
        expect(step_index).to eq(1)             # avançou
        expect(facts['email']).to eq('Hgdd@()(.com') # manteve o valor original
      end

      it 'e-mail VÁLIDO: grava e avança direto, SEM confirmar' do
        track_infer({ 'step_completed' => false }, 'joao@empresa.com')

        expect(facts['email']).to eq('joao@empresa.com')
        expect(step_index).to eq(1)
        expect(conversation.reload.additional_attributes['ai_step_confirm_index']).to be_nil
      end

      it 'confirma no máximo UMA vez por etapa (nunca pergunta o mesmo dado uma 3ª vez)' do
        track_infer({ 'step_completed' => false }, 'aaa')   # estranho -> confirma (hold)
        track_infer({ 'step_completed' => false }, 'bbb')   # teima -> grava e avança
        # de volta forçado ao índice 0 não acontece no fluxo; garantimos que não houve 2º hold:
        expect(step_index).to eq(1)
      end

      # Reprodução da conv 358: etapa com a forma DIRETA "Grave endereco_completo ..." (sem "atributo").
      it 'conv 358: etapa "Grave endereco_completo com o texto fornecido." captura o endereço e AVANÇA' do
        dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Cadastro3',
                                      status: 'active', behavior: {}, transfer_rules: { 'stuck_handoff_turns' => 3 })
        dept.create_playbook!(active: true, steps: [
                                { 'name' => 'Endereço',
                                  'instructions' => 'Peça o endereço. Grave endereco_completo com o texto fornecido.' },
                                { 'name' => 'Fim' }
                              ])

        manager.track_step(dept, { 'step_completed' => false },
                           dispatcher: dispatcher, run: run, message_text: 'Rua das Flores 123, Maravilha')

        expect(facts['endereco_completo']).to eq('Rua das Flores 123, Maravilha')
        expect(step_index).to eq(1) # avançou (zero repergunta)
        # NÃO criou o slot lixo "personalizado"
        expect(facts).not_to have_key('personalizado')
      end

      # BUG 2 (conv 359): slot capturado (source raw) deve ESPELHAR para custom_attributes quando há
      # CustomAttributeDefinition — antes ficava só em ai_collected_facts (invisível no painel/Bitrix).
      it 'espelha o slot capturado para custom_attributes quando a chave tem campo cadastrado' do
        CustomAttributeDefinition.create!(account: account, attribute_key: 'cidade',
                                          attribute_display_name: 'Cidade', attribute_model: 'conversation_attribute',
                                          attribute_display_type: 'text')
        dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Cidade', status: 'active',
                                      behavior: {}, transfer_rules: { 'stuck_handoff_turns' => 3 })
        dept.create_playbook!(active: true, steps: [
                                { 'name' => 'Cidade', 'instructions' => 'Pergunte e grave a cidade conforme informado.' },
                                { 'name' => 'Fim' }
                              ])

        manager.track_step(dept, { 'step_completed' => false },
                           dispatcher: dispatcher, run: run, message_text: 'MARAVILHA')

        expect(facts['cidade']).to eq('MARAVILHA')                       # memória (ai_collected_facts)
        expect(conversation.reload.custom_attributes['cidade']).to eq('MARAVILHA') # painel/Bitrix
      end

      it 'slot capturado SEM campo cadastrado fica só em ai_collected_facts (não em custom_attributes)' do
        dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Cidade2', status: 'active',
                                      behavior: {}, transfer_rules: { 'stuck_handoff_turns' => 3 })
        dept.create_playbook!(active: true, steps: [
                                { 'name' => 'Cidade', 'instructions' => 'Pergunte e grave a cidade conforme informado.' },
                                { 'name' => 'Fim' }
                              ])

        manager.track_step(dept, { 'step_completed' => false },
                           dispatcher: dispatcher, run: run, message_text: 'MARAVILHA')

        expect(facts['cidade']).to eq('MARAVILHA')
        expect(conversation.reload.custom_attributes).not_to have_key('cidade')
      end
    end
  end

  describe '#persist_attributes — validação de chave' do
    def define_attr(key, display = key.capitalize)
      CustomAttributeDefinition.create!(
        account: account, attribute_key: key, attribute_display_name: display,
        attribute_model: 'conversation_attribute', attribute_display_type: 'text'
      )
    end

    def unknown_key_events
      Ai::Event.where(conversation_id: conversation.id, event_type: 'attributes.unknown_key')
    end

    it 'persiste normalmente uma chave que bate com um attribute_key real' do
      define_attr('cidade')

      manager.persist_attributes({ 'cidade' => 'Maravilha' }, department)

      expect(conversation.reload.custom_attributes['cidade']).to eq('Maravilha')
      expect(unknown_key_events).to be_empty
    end

    it 'NÃO persiste uma chave desconhecida e emite attributes.unknown_key com chave+valor' do
      define_attr('cidade')

      manager.persist_attributes({ 'cidade_usuario' => 'Maravilha' }, department)

      expect(conversation.reload.custom_attributes).not_to have_key('cidade_usuario')
      event = unknown_key_events.last
      expect(event.payload['key']).to eq('cidade_usuario')
      expect(event.payload['value']).to eq('Maravilha')
    end

    it 'na mistura de chaves, só as válidas persistem e o evento sai só para as inválidas' do
      define_attr('cidade')

      manager.persist_attributes({ 'cidade' => 'Maravilha', 'lixo' => 'x' }, department)

      attrs = conversation.reload.custom_attributes
      expect(attrs['cidade']).to eq('Maravilha')
      expect(attrs).not_to have_key('lixo')
      expect(unknown_key_events.pluck(:payload).map { |p| p['key'] }).to eq(['lixo'])
    end

    it 'não quebra quando a conta não tem nenhuma definição de atributo' do
      expect { manager.persist_attributes({ 'cidade' => 'Maravilha' }, department) }.not_to raise_error

      expect(conversation.reload.custom_attributes).not_to have_key('cidade')
      expect(unknown_key_events.last.payload['key']).to eq('cidade')
    end
  end

  describe '#persist_attributes — memória de fatos ao vivo (ai_collected_facts)' do
    def define_attr(key)
      CustomAttributeDefinition.create!(account: account, attribute_key: key, attribute_display_name: key.capitalize,
                                        attribute_model: 'conversation_attribute', attribute_display_type: 'text')
    end

    def collected_facts
      conversation.reload.additional_attributes['ai_collected_facts']
    end

    it 'grava dado SEM campo cadastrado em ai_collected_facts (não em custom_attributes)' do
      manager.persist_attributes({ 'tamanho_imovel' => '70m2' }, department) # sem CustomAttributeDefinition

      expect(conversation.reload.custom_attributes).not_to have_key('tamanho_imovel')
      expect(collected_facts['tamanho_imovel']).to eq('70m2')
    end

    it 'grava dado COM campo cadastrado nos DOIS (custom_attributes E ai_collected_facts)' do
      define_attr('cidade')

      manager.persist_attributes({ 'cidade' => 'Maravilha' }, department)

      expect(conversation.reload.custom_attributes['cidade']).to eq('Maravilha')
      expect(collected_facts['cidade']).to eq('Maravilha')
    end

    it 'rejeita valores vazios (não entram em ai_collected_facts)' do
      manager.persist_attributes({ 'vazio' => '   ', 'valido' => 'x' }, department)

      expect(collected_facts).to eq({ 'valido' => 'x' })
    end

    it 'preserva false/0 como fatos válidos (v.to_s.strip não os remove)' do
      manager.persist_attributes({ 'aparelhos_conectados' => 0, 'tem_wifi' => false }, department)

      expect(collected_facts['aparelhos_conectados']).to eq(0)
      expect(collected_facts['tem_wifi']).to be(false)
    end

    it 'acumula (merge) com fatos de turnos anteriores' do
      manager.persist_attributes({ 'cidade' => 'Maravilha' }, department)
      manager.persist_attributes({ 'tamanho_imovel' => '70m2' }, department)

      expect(collected_facts).to include('cidade' => 'Maravilha', 'tamanho_imovel' => '70m2')
    end

    it 'NÃO sobrescreve ai_step_index gravado por track_step no mesmo fluxo (concorrência)' do
      conversation.update!(additional_attributes: { 'ai_step_index' => 2 })

      manager.persist_attributes({ 'tamanho_imovel' => '70m2' }, department)

      attrs = conversation.reload.additional_attributes
      expect(attrs['ai_step_index']).to eq(2)                            # preservado
      expect(attrs['ai_collected_facts']['tamanho_imovel']).to eq('70m2') # adicionado
    end
  end
end
