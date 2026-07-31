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

  # Regressão do bug do double-claim intra-run (PR #281/#282): com o worker ligado, o Gateway faz um
  # EARLY-CLAIM (claim_turn) antes do track_step; o claim interno do track_step reencontrava o id em
  # @claimed e retornava FALSE, abortando ANTES de persist_step_state -> ai_step_index ficava nil e a
  # etapa travava na 0. Fix: claim já-vencido vira no-op-TRUE (Ai::TurnCapture#claim).
  describe '#track_step — after claim_turn (regressão double-claim / PR #281)' do
    let(:message) do
      create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :incoming, content: 'oi')
    end

    it 'claim_turn vencedor SEGUIDO de track_step PERSISTE ai_step_index (não aborta)' do
      expect(manager.claim_turn(message)).to be(true) # early-claim do worker vence

      manager.track_step(department, { 'step_completed' => true }, message: message)

      expect(step_index).to eq(1) # avançou; NÃO ficou nil
    end

    it 'o claim reivindicado uma vez não impede o avanço quando a etapa conclui' do
      manager.claim_turn(message)
      manager.track_step(department, { 'step_completed' => true }, message: message)
      expect(conversation.reload.additional_attributes['ai_step_index']).not_to be_nil
    end

    it 'worker OFF (sem early-claim): track_step persiste normalmente (comportamento intacto)' do
      manager.track_step(department, { 'step_completed' => true }, message: message)
      expect(step_index).to eq(1)
    end
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

  # Contrato pergunta↔etapa (item 2 do #304 + HOTFIX #304/conv 397): persist_step_state guarda o slot que a
  # reply_text DESTE turno pediu. HOTFIX: asked_slot "" LIMPA o estado — ele não pode sobreviver ao turno que
  # o produziu (asked_slot vem "" justamente nos turnos em que o modelo capturou algo).
  describe '#track_step — ai_last_asked_slot (contrato pergunta↔etapa)' do
    def last_asked
      conversation.reload.additional_attributes['ai_last_asked_slot']
    end

    def req_dept
      dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'ReqSlots', status: 'active',
                                    behavior: {}, transfer_rules: { 'stuck_handoff_turns' => 5 })
      dept.create_playbook!(active: true, steps: [
                              { 'name' => 'A', 'collect' => { 'attribute' => 'campo_a', 'type' => 'text', 'required' => true } },
                              { 'name' => 'B', 'collect' => { 'attribute' => 'campo_b', 'type' => 'text', 'required' => true } }
                            ])
      dept
    end

    def incoming(text)
      create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :incoming, content: text)
    end

    it 'grava ai_last_asked_slot quando decision.asked_slot vem preenchido' do
      manager.track_step(department, { 'step_completed' => false, 'asked_slot' => 'campo_b' },
                         dispatcher: dispatcher, run: run)

      expect(last_asked).to eq('campo_b')
    end

    it 'asked_slot "" LIMPA ai_last_asked_slot (não preserva a pergunta anterior)' do
      conversation.update!(additional_attributes: { 'ai_step_index' => 0, 'ai_last_asked_slot' => 'campo_b' })

      manager.track_step(department, { 'step_completed' => false, 'asked_slot' => '' },
                         dispatcher: dispatcher, run: run)

      expect(conversation.reload.additional_attributes).not_to have_key('ai_last_asked_slot')
    end

    # Regressão #304/conv 397 ponta a ponta: sem a limpeza, o asked_slot VELHO (slot já preenchido) fazia a
    # guarda de confirmação disparar, o capture_signal perder o {declined}, e o token "__sem_valor__" avançar
    # um slot OBRIGATÓRIO. Com o item 1, o turno de captura LIMPA o velho e o turno do token vira RECUSA.
    it 'asked_slot "" limpo faz o turno com {slot => ABSENT} em slot OBRIGATÓRIO recusar e NÃO avançar' do
      dept = req_dept
      conversation.update!(additional_attributes: { 'ai_step_index' => 1,
                                                    'ai_collected_facts' => { 'campo_a' => 'valor' },
                                                    'ai_last_asked_slot' => 'campo_a' })

      # turno de captura (asked_slot "") -> item 1 LIMPA o asked_slot velho (falha aqui se voltar a preservar)
      manager.track_step(dept, { 'step_completed' => false, 'asked_slot' => '' },
                         dispatcher: dispatcher, run: run, message_text: 'ok', message: incoming('ok'))
      expect(conversation.reload.additional_attributes).not_to have_key('ai_last_asked_slot')

      # turno do token no slot obrigatório corrente (campo_b), mensagem NÃO-recusa: sem asked_slot velho é RECUSA
      manager.track_step(dept, { 'step_completed' => false, 'asked_slot' => '',
                                 'attributes' => { 'campo_b' => Ai::StepSlot::ABSENT } },
                         dispatcher: dispatcher, run: run, message_text: 'ok', message: incoming('ok'))

      expect(conversation.reload.additional_attributes['ai_step_index']).to eq(1)              # NÃO avançou
      expect(conversation.reload.additional_attributes['ai_collected_facts']).not_to have_key('campo_b') # token não persistido
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

    # conserto conv 369: mark_fired só depois de confirmar que HÁ automação — senão uma etapa sem
    # automação grava last_fired e bloqueia para sempre uma automação adicionada depois (pior na última
    # etapa, onde o clamp prende o índice).
    def events(type)
      Ai::Event.where(conversation_id: conversation.id, event_type: type)
    end

    def dept_with(name, steps)
      dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: name, status: 'active', behavior: {})
      dept.create_playbook!(active: true, steps: steps)
      dept
    end

    def change_team_step(name, team)
      { 'name' => name, 'automations' => [{ 'type' => 'change_team', 'params' => { 'team_id' => team.id } }] }
    end

    def conclude(dept)
      manager.track_step(dept, { 'step_completed' => true }, dispatcher: dispatcher, run: run)
    end

    it 'etapa SEM automação concluída NÃO grava ai_step_last_fired_index' do
      set_index(1) # Proposta (sem automação) na base department
      expect(Ai::StepAutomationRunner).not_to receive(:new)

      track(step_completed: true)

      expect(conversation.reload.additional_attributes['ai_step_last_fired_index']).to be_nil
    end

    it 'etapa que GANHA automação depois: dispara (change_team) e só então marca' do
      team = create(:team, account: account)
      dept = dept_with('CT-later', [{ 'name' => 'A' }, { 'name' => 'Fim' }])

      conclude(dept) # etapa 0 SEM automação -> não marca
      expect(conversation.reload.additional_attributes['ai_step_last_fired_index']).to be_nil

      dept.playbook.update!(steps: [change_team_step('A', team), { 'name' => 'Fim' }])
      set_index(0)
      conclude(dept)

      expect(events('step_automation.change_team').last.payload).to include('team_id' => team.id)
      expect(conversation.reload.additional_attributes['ai_step_last_fired_index']).to eq(0)
      expect(conversation.reload.team_id).to eq(team.id)
    end

    it 'etapa COM automação concluída DUAS vezes: executa UMA vez (idempotência preservada)' do
      team = create(:team, account: account)
      dept = dept_with('CT-idem', [change_team_step('A', team), { 'name' => 'Fim' }])

      conclude(dept)
      set_index(0)
      conclude(dept)

      expect(events('step_automation.change_team').count).to eq(1)
    end

    it 'automação na ÚLTIMA etapa (índice preso pelo clamp): dispara 1x e não repete nos turnos seguintes' do
      team = create(:team, account: account)
      dept = dept_with('CT-last', [{ 'name' => 'A' }, change_team_step('Fim', team)])
      set_index(1) # última etapa

      conclude(dept) # conclui -> dispara
      conclude(dept) # turno seguinte, índice ainda 1 (clamp) -> NÃO repete

      expect(events('step_automation.change_team').count).to eq(1)
      expect(step_index).to eq(1)
    end
  end

  # (item 5) O avanço lê o VEREDITO do gate, não o cru do modelo. Antes, valor cru PRESENTE contava como
  # preenchido mesmo se o gate o rejeitasse (conv 397: comprovante obrigatório rejeitado como 'declined', a
  # etapa concluiu sem ele). Agora avanço e persistência decidem pelo mesmo julgamento. Prova de mutação por
  # nome — cada teste morre se o resolver voltar a contar o cru pré-gate. (Slot phone: o gate valida formato.)
  describe '#track_step — avanço lê o gate, não o cru (item 5)' do
    let(:phone_department) do
      dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'ColetaFone',
                                    status: 'active', behavior: {})
      dept.create_playbook!(active: true, steps: [
                              { 'name' => 'Telefone',
                                'collect' => { 'attribute' => 'telefone', 'type' => 'phone', 'required' => true } },
                              { 'name' => 'Fim' }
                            ])
      dept
    end

    def track_phone(decision)
      manager.track_step(phone_department, decision, dispatcher: dispatcher, run: run)
    end

    def facts
      conversation.reload.additional_attributes.to_h['ai_collected_facts'].to_h
    end

    it 'slot obrigatório com valor REJEITADO pelo gate (invalid_value) NÃO avança' do
      # 'dia 10' não é telefone -> o gate daria invalid_value; antes o cru PRESENTE avançava (bug).
      track_phone('step_completed' => false, 'attributes' => { 'telefone' => 'dia 10' })
      aggregate_failures do
        expect(step_index).to eq(0) # NÃO avançou
        expect(facts).not_to include('telefone') # e não persistiu (avanço e persistência concordam)
      end
    end

    it 'token __sem_valor__ em slot OBRIGATÓRIO NÃO avança (a forma exata da conv 397)' do
      track_phone('step_completed' => false, 'attributes' => { 'telefone' => Ai::StepSlot::ABSENT })
      expect(step_index).to eq(0)
    end

    it 'slot obrigatório com valor VÁLIDO avança (o gate aceita)' do
      expect { track_phone('step_completed' => false, 'attributes' => { 'telefone' => '(49) 99856-4780' }) }
        .to change { step_index }.from(nil).to(1)
    end

    it 'slot JÁ PERSISTIDO avança mesmo sem attributes (turno anterior / anexo / confirmação — metade preservada)' do
      conversation.update!(additional_attributes: { 'ai_step_index' => 0,
                                                     'ai_collected_facts' => { 'telefone' => '(49) 99856-4780' } })
      track_phone('step_completed' => false, 'attributes' => {})
      expect(step_index).to eq(1)
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
      conversation.reload.additional_attributes['ai_step_turns']
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

        sig = track_blank(3) # turno 3 -> handoff (Gap 4: vazio conta no teto ABSOLUTO, reason max_turns)
        expect(sig).to eq(stuck_handoff: { attribute: 'nome', step_name: 'Nome', turns: 3, reason: 'max_turns' })
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
        expect(attrs['ai_step_turns']).to eq(1)
      end
    end

    # === CONSERTO: slot inferido da instrução + confirmação-única de valor estranho ================
    describe 'conserto — slot inferido + confirma 1x se estranho, nunca fica preso' do
      let(:infer_department) do
        dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Cadastro2',
                                      status: 'active', behavior: {})
        # etapa SEM collect declarado; a instrução manda gravar no atributo email (criada antes do #259)
        dept.create_playbook!(active: true, steps: [
                                { 'name' => 'CADASTRO de email', 'collect' => { 'attribute' => 'email' },
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
        expect(Ai::StepSlot.attribute(infer_department.playbook.steps.first)).to eq('email')
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
        # Valores COM "@" (tentativa de e-mail malformada); sem "@" seriam no_attempt e não capturariam.
        track_infer({ 'step_completed' => false }, 'a@b')   # estranho -> confirma (hold)
        track_infer({ 'step_completed' => false }, 'c@d')   # teima -> grava e avança
        # de volta forçado ao índice 0 não acontece no fluxo; garantimos que não houve 2º hold:
        expect(step_index).to eq(1)
      end

      # Reprodução da conv 358: etapa com a forma DIRETA "Grave endereco_completo ..." (sem "atributo").
      it 'conv 358: etapa "Grave endereco_completo com o texto fornecido." captura o endereço e AVANÇA' do
        dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Cadastro3',
                                      status: 'active', behavior: {}, transfer_rules: { 'stuck_handoff_turns' => 3 })
        dept.create_playbook!(active: true, steps: [
                                { 'name' => 'Endereço', 'collect' => { 'attribute' => 'endereco_completo' },
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
                                { 'name' => 'Cidade', 'collect' => { 'attribute' => 'cidade' },
                                  'instructions' => 'Pergunte e grave a cidade conforme informado.' },
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
                                { 'name' => 'Cidade', 'collect' => { 'attribute' => 'cidade' },
                                  'instructions' => 'Pergunte e grave a cidade conforme informado.' },
                                { 'name' => 'Fim' }
                              ])

        manager.track_step(dept, { 'step_completed' => false },
                           dispatcher: dispatcher, run: run, message_text: 'MARAVILHA')

        expect(facts['cidade']).to eq('MARAVILHA')
        expect(conversation.reload.custom_attributes).not_to have_key('cidade')
      end
    end
  end

  # BUG 1 (conv 359): a MESMA mensagem preenchia DOIS slots num mesmo run (o texto cru caía no slot da
  # etapa corrente E o modelo gravava a chave certa) — valores trocados indo pro painel/Bitrix. Opção B:
  # se o modelo devolveu attributes, ELE é dono do turno; o texto cru só entra quando o modelo é mudo.
  describe '#track_step — BUG 1: precedência do modelo (Opção B) + idempotência por mensagem' do
    let(:cascade_department) do
      dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Cascata', status: 'active',
                                    behavior: {}, transfer_rules: { 'stuck_handoff_turns' => 3 })
      dept.create_playbook!(active: true, steps: [
                              { 'name' => 'Caminho',
                                'collect' => { 'attribute' => 'escolha_caminho', 'type' => 'text', 'required' => true } },
                              { 'name' => 'Cidade',
                                'collect' => { 'attribute' => 'cidade', 'type' => 'text', 'required' => true } },
                              { 'name' => 'Fim' }
                            ])
      dept
    end

    def facts
      conversation.reload.additional_attributes['ai_collected_facts'] || {}
    end

    def events(type)
      Ai::Event.where(conversation_id: conversation.id, event_type: type)
    end

    def incoming(text)
      create(:message, conversation: conversation, account: account, inbox: inbox,
                       message_type: :incoming, content: text)
    end

    it 'MISMATCH: modelo devolve attributes cuja chave NÃO é o slot corrente — NÃO grava o texto cru no slot' do
      # etapa 0 = escolha_caminho; modelo grava {cidade:'MARAVILHA'} (o valor ecoa, mas é de OUTRO slot).
      msg = incoming('MARAVILHA')
      manager.track_step(cascade_department, { 'step_completed' => false, 'attributes' => { 'cidade' => 'MARAVILHA' } },
                         dispatcher: dispatcher, run: run, message_text: 'MARAVILHA', message: msg)

      expect(facts).not_to have_key('escolha_caminho') # a cascata NÃO aconteceu (era o bug)
      expect(step_index).to eq(0)                       # não avançou (slot corrente não foi preenchido)
      expect(events('slot.model_key_mismatch').last.payload)
        .to include('expected' => 'escolha_caminho', 'got' => ['cidade'])
    end

    it 'ALINHADO: modelo devolve a chave DO slot corrente — não grava cru (modelo é dono) e avança' do
      msg = incoming('opcao A')
      expect do
        manager.track_step(cascade_department,
                           { 'step_completed' => false, 'attributes' => { 'escolha_caminho' => 'opcao A' } },
                           dispatcher: dispatcher, run: run, message_text: 'opcao A', message: msg)
      end.to change { step_index }.from(nil).to(1)

      expect(events('slot.captured')).to be_empty         # não houve captura de texto cru
      expect(events('slot.model_key_mismatch')).to be_empty
    end

    it 'MUDO: modelo sem attributes — fallback grava o texto cru no slot corrente (safety net Parte 2)' do
      msg = incoming('Jaqueline')
      manager.track_step(cascade_department, { 'step_completed' => false },
                         dispatcher: dispatcher, run: run, message_text: 'Jaqueline', message: msg)

      expect(facts['escolha_caminho']).to eq('Jaqueline')
      expect(step_index).to eq(1)
    end

    # CONTRATO ATUAL — mudado DE PROPÓSITO no commit 89006af85 ("fix(ai): claim already-won evita abortar
    # track_step (ai_step_index nil)"): a reivindicação REPETIDA da MESMA instância é um no-op-WIN, não um
    # no-op-block. Um 2º track_step no MESMO manager PROSSEGUE (não aborta no claim). Isso é deliberado: o
    # Gateway faz um early claim_turn e DEPOIS o claim interno do track_step no MESMO turn_capture
    # memoizado — se o reclaim devolvesse false, o track_step abortaria ANTES de persistir o índice e o
    # ai_step_index ficava nil (a etapa travava na 0). NÃO é bug. Ver Ai::TurnCapture#claim.
    #
    # ⚠️ Isto NÃO é a idempotência de produção: o Gateway chama track_step UMA vez por run (um claim_turn +
    # um track_step). A idempotência que importa — re-run do Sidekiq / 2º binding = OUTRA instância — é
    # atômica no Postgres e está travada no exemplo 'IDEMPOTÊNCIA ATÔMICA' logo abaixo.
    #
    # DÍVIDA CONHECIDA (opção B, NÃO descartada): com o no-op-WIN, o TurnCapture deixou de ser
    # auto-idempotente contra um track_step repetido na MESMA instância — a invariante "≤1 captura por
    # mensagem" passou a depender da disciplina do Gateway (um track_step por run), não do TurnCapture.
    # Fechar exige marcar "capturado" separado de "reivindicado". Correlato: a chave
    # ai_last_captured_message_id é setada no CLAIM, não na CAPTURA — o nome não descreve o comportamento;
    # indo ao (B), as duas coisas se resolvem juntas. Quando isso acontecer, ESTE exemplo muda.
    it 'CONTRATO: reclaim intra-instância é no-op-WIN — 2º track_step no mesmo manager PROSSEGUE (89006af85)' do
      msg = incoming('Jaqueline')

      # 1º track_step: vence o claim, captura o slot 0 (escolha_caminho) e avança.
      manager.track_step(cascade_department, { 'step_completed' => false },
                         dispatcher: dispatcher, run: run, message_text: 'Jaqueline', message: msg)
      expect(facts['escolha_caminho']).to eq('Jaqueline')
      expect(step_index).to eq(1)

      # 2º track_step, MESMA instância e MESMA msg: o reclaim é no-op-WIN (não aborta), então PROSSEGUE e
      # captura o slot 1 (cidade), avançando de novo. No contrato ANTIGO (pré-89006af85) o reclaim devolvia
      # false e este 2º track_step seria no-op — cidade ausente, índice preso em 1.
      manager.track_step(cascade_department, { 'step_completed' => false },
                         dispatcher: dispatcher, run: run, message_text: 'Jaqueline', message: msg)
      expect(facts['cidade']).to eq('Jaqueline')
      expect(step_index).to eq(2)
    end

    it 'IDEMPOTÊNCIA ATÔMICA: marca ai_last_captured_message_id e um 2º run/binding (outro manager) é no-op' do
      msg = incoming('Jaqueline')
      manager.track_step(cascade_department, { 'step_completed' => false },
                         dispatcher: dispatcher, run: run, message_text: 'Jaqueline', message: msg)

      expect(conversation.reload.additional_attributes['ai_last_captured_message_id']).to eq(msg.id.to_s)

      # binding/run concorrente: instância nova (guard em memória vazio) — só o UPDATE atômico segura.
      other = described_class.new(conversation: conversation, agent: agent)
      other.track_step(cascade_department, { 'step_completed' => false },
                       dispatcher: dispatcher, run: run, message_text: 'Jaqueline', message: msg)

      expect(facts).not_to have_key('cidade') # o 2º binding não capturou nada
      expect(step_index).to eq(1)             # nem re-avançou
    end

    it 'mensagem sem id (follow-up/teste) processa normalmente (sem idempotência)' do
      manager.track_step(cascade_department, { 'step_completed' => false },
                         dispatcher: dispatcher, run: run, message_text: 'Jaqueline')

      expect(facts['escolha_caminho']).to eq('Jaqueline')
      expect(step_index).to eq(1)
    end
  end

  # BUG 3 (conv 359/360): anexos (localização, comprovante) chegavam mas NUNCA viravam dado — a IA
  # reperguntava algo já recebido. Agora o anexo grava fatos determinísticos e preenche o slot da etapa.
  describe '#track_step — BUG 3: anexo vira dado' do
    let(:attach_department) do
      dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Anexos', status: 'active',
                                    behavior: {}, transfer_rules: { 'stuck_handoff_turns' => 3 })
      dept.create_playbook!(active: true, steps: [
                              { 'name' => 'Localização' }, # etapa informativa (sem slot)
                              { 'name' => 'Comprovante',
                                'collect' => { 'attribute' => 'comprovante', 'type' => 'text', 'required' => true } },
                              { 'name' => 'Fim' }
                            ])
      dept
    end

    def facts
      conversation.reload.additional_attributes['ai_collected_facts'] || {}
    end

    def events(type)
      Ai::Event.where(conversation_id: conversation.id, event_type: type)
    end

    def incoming_with(attrs)
      msg = create(:message, conversation: conversation, account: account, inbox: inbox,
                             message_type: :incoming, content: '')
      msg.attachments.create!(attrs.merge(account_id: account.id))
      msg
    end

    it 'LOCALIZAÇÃO (etapa sem slot): grava fatos determinísticos, sem preencher slot de texto' do
      msg = incoming_with(file_type: :location, coordinates_lat: -26.77, coordinates_long: -53.05,
                          external_url: 'https://maps.example/x')
      att = msg.attachments.first
      manager.track_step(attach_department, { 'step_completed' => false },
                         dispatcher: dispatcher, run: run, message_text: '', message: msg)

      expect(facts['localizacao_recebida']).to be(true)
      expect(facts['localizacao_coordenadas']).to eq("#{att.coordinates_lat},#{att.coordinates_long}")
      expect(facts['localizacao_link']).to eq('https://maps.example/x')
      expect(events('attachment.captured').last.payload).to include('kind' => 'location')
    end

    it 'COMPROVANTE (etapa com slot): grava fatos do documento, PREENCHE o slot e AVANÇA' do
      set_index(1) # etapa Comprovante
      msg = incoming_with(file_type: :file, fallback_title: 'comprovante.pdf')

      manager.track_step(attach_department, { 'step_completed' => false },
                         dispatcher: dispatcher, run: run, message_text: '', message: msg)

      expect(facts['documento_recebido']).to be(true)
      expect(facts['documento_arquivo']).to eq('comprovante.pdf')
      expect(facts['comprovante']).to eq('comprovante.pdf') # slot preenchido pelo anexo
      expect(step_index).to eq(2)                            # avançou
      expect(events('attachment.captured').last.payload).to include('kind' => 'file', 'attribute' => 'comprovante')
    end

    it 'reprodução: localização e DEPOIS comprovante — ambos viram fato (a IA para de reperguntar)' do
      loc = incoming_with(file_type: :location, coordinates_lat: -26.5, coordinates_long: -53.0,
                          external_url: 'https://maps.example/y')
      manager.track_step(attach_department, { 'step_completed' => false },
                         dispatcher: dispatcher, run: run, message_text: '', message: loc)

      set_index(1)
      doc = incoming_with(file_type: :file, fallback_title: 'recibo.pdf')
      manager.track_step(attach_department, { 'step_completed' => false },
                         dispatcher: dispatcher, run: run, message_text: '', message: doc)

      expect(facts['localizacao_recebida']).to be(true)
      expect(facts['documento_recebido']).to be(true)
      expect(facts['documento_arquivo']).to eq('recibo.pdf')
    end
  end

  # Conserto do FALLBACK CRU: em etapa SEM collect (slot inferido), o tipo é derivado do NOME da chave
  # (cpf/email/telefone) e o cru só é gravado quando houve TENTATIVA de resposta. Turno sem tentativa é
  # recusado (slot.no_attempt), não avança e NÃO conta travamento. Slot 'text' fica inalterado.
  describe '#track_step — fallback cru: tipo derivado da chave + distinção de tentativa' do
    def facts
      conversation.reload.additional_attributes['ai_collected_facts'] || {}
    end

    def events(type)
      Ai::Event.where(conversation_id: conversation.id, event_type: type)
    end

    def stuck
      conversation.reload.additional_attributes['ai_step_turns']
    end

    def incoming(text)
      create(:message, conversation: conversation, account: account, inbox: inbox,
                       message_type: :incoming, content: text)
    end

    # Etapa SEM collect: o slot é inferido da instrução ("grave <chave> conforme informado.").
    def infer_dept(name, instruction)
      # Gap 4 v2: teto de recusa = stuck_limit (12) — MESMO limiar do absoluto. Depts de PERGUNTA não
      # transferem cedo; o absoluto (12) só é atingido nos testes que iteram até lá.
      dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: name, status: 'active',
                                    behavior: {}, transfer_rules: { 'stuck_handoff_turns' => 12 })
      # collect DECLARADO: a chave é decodificada da instrução do teste (conjunto FIXO destes specs —
      # "grave <k>" ou "no atributo <k>"). NÃO é o infer de produção (removido); é só o decoder do fixture.
      attribute = instruction[/no atributo (\w+)/, 1] || instruction[/grave (?:o )?(\w+)/, 1]
      dept.create_playbook!(active: true, steps: [
                              { 'name' => 'Coleta', 'collect' => { 'attribute' => attribute },
                                'instructions' => instruction },
                              { 'name' => 'Fim' }
                            ])
      dept
    end

    def run_turn(dept, text)
      msg = incoming(text)
      manager.track_step(dept, { 'step_completed' => false },
                         dispatcher: dispatcher, run: run, message_text: text, message: msg)
    end

    it 'cpf: pergunta do cliente ("quais os valores?") NÃO é tentativa — não grava, emite slot.no_attempt, não avança, não conta trava' do
      dept = infer_dept('CPF-A', 'Peça e grave cpf conforme informado.')
      run_turn(dept, 'quais os valores?')

      expect(facts).not_to have_key('cpf')
      expect(step_index).to eq(0)
      expect(stuck).to eq(1) # Gap 4: :no_attempt agora CONTA no teto absoluto (mas 1 << teto 12)
      expect(events('slot.no_attempt').last.payload).to include('attribute' => 'cpf', 'type' => 'cpf')
      expect(events('slot.captured')).to be_empty
    end

    it 'cpf: tentativa malformada com dígitos ("meu cpf é 123") grava como veio (source raw); hold NÃO conta trava' do
      dept = infer_dept('CPF-B', 'Peça e grave cpf conforme informado.')
      run_turn(dept, 'meu cpf é 123')

      expect(facts['cpf']).to eq('meu cpf é 123')
      expect(events('slot.captured').last.payload).to include('attribute' => 'cpf', 'source' => 'raw')
      expect(events('slot.no_attempt')).to be_empty
      expect(stuck).to eq(1)      # Gap 4: confirmação-única conta no teto absoluto (1 << teto)
      expect(step_index).to eq(0) # confirmação-única segura este turno (não é 3ª pergunta)
    end

    it 'cpf: CPF válido é extraído e normalizado (source extractor) e avança' do
      dept = infer_dept('CPF-C', 'Peça e grave cpf conforme informado.')
      run_turn(dept, 'segue meu cpf 111.444.777-35 obrigado')

      expect(facts['cpf']).to eq('111.444.777-35')
      expect(events('slot.captured').last.payload).to include('attribute' => 'cpf', 'source' => 'extractor')
      expect(step_index).to eq(1)
    end

    it 'email: texto sem "@" não é tentativa (não grava); com "@" válido é extraído e avança' do
      dept = infer_dept('Email-A', 'Peça e grave o e-mail do cliente no atributo email.')

      run_turn(dept, 'aguardando os planos')
      expect(facts).not_to have_key('email')
      expect(events('slot.no_attempt').last.payload).to include('attribute' => 'email', 'type' => 'email')

      run_turn(dept, 'jaque@x.com')
      expect(facts['email']).to eq('jaque@x.com')
      expect(events('slot.captured').last.payload).to include('source' => 'extractor')
      expect(step_index).to eq(1)
    end

    it 'telefone: "dia 5" TEM dígito (é tentativa) e grava como veio (source raw) — comportamento esperado/documentado' do
      dept = infer_dept('Fone-A', 'Peça e grave o telefone_secundario conforme informado.')
      run_turn(dept, 'dia 5')

      expect(facts['telefone_secundario']).to eq('dia 5')
      expect(events('slot.captured').last.payload).to include('attribute' => 'telefone_secundario', 'source' => 'raw')
      expect(events('slot.no_attempt')).to be_empty
    end

    it "text (endereco_completo): sem tipo derivável, grava o cru como hoje e avança (regressão INALTERADA)" do
      dept = infer_dept('Endereco-A', 'Peça e grave endereco_completo conforme informado.')
      run_turn(dept, 'pode ser')

      expect(facts['endereco_completo']).to eq('pode ser')
      expect(events('slot.captured').last.payload).to include('attribute' => 'endereco_completo', 'source' => 'raw')
      expect(events('slot.no_attempt')).to be_empty
      expect(step_index).to eq(1)
    end
  end

  # attempt? para slot 'choice' desacoplado do sucesso da extração. Antes, valor fora das options virava
  # :no_attempt -> resolve_empty_slot NÃO contava travamento -> loop infinito numa etapa choice (contra
  # a decisão "nunca travar", #259/decisão 3). Agora é tentativa: grava cru (source raw) e AVANÇA; a rede
  # de sumiço (#259) segue protegendo a etapa quando o cliente some (msg vazia).
  describe '#track_step — slot choice: tentativa independe do sucesso da extração' do
    def facts
      conversation.reload.additional_attributes['ai_collected_facts'] || {}
    end

    def events(type)
      Ai::Event.where(conversation_id: conversation.id, event_type: type)
    end

    def choice_dept
      dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Choice-A', status: 'active',
                                    behavior: {}, transfer_rules: { 'stuck_handoff_turns' => 3 })
      dept.create_playbook!(active: true, steps: [
                              { 'name' => 'Período',
                                'collect' => { 'attribute' => 'periodo', 'type' => 'choice',
                                               'options' => %w[manhã tarde], 'required' => true } },
                              { 'name' => 'Fim' }
                            ])
      dept
    end

    def run_turn(dept, text)
      msg = create(:message, conversation: conversation, account: account, inbox: inbox,
                             message_type: :incoming, content: text)
      manager.track_step(dept, { 'step_completed' => false },
                         dispatcher: dispatcher, run: run, message_text: text, message: msg)
    end

    def track_blank(dept)
      manager.track_step(dept, { 'step_completed' => false }, dispatcher: dispatcher, run: run, message_text: '')
    end

    it 'valor que casa uma option: extrai a canônica (source extractor) e avança' do
      dept = choice_dept
      run_turn(dept, 'pode ser de manhã')

      expect(facts['periodo']).to eq('manhã')
      expect(events('slot.captured').last.payload).to include('attribute' => 'periodo', 'source' => 'extractor')
      expect(step_index).to eq(1)
    end

    it 'valor FORA das options: grava como veio (source raw), SEM slot.no_attempt, e NÃO gira em falso (avança)' do
      dept = choice_dept
      run_turn(dept, 'de noite')

      expect(facts['periodo']).to eq('de noite')
      expect(events('slot.captured').last.payload).to include('attribute' => 'periodo', 'source' => 'raw')
      expect(events('slot.no_attempt')).to be_empty # antes virava :no_attempt -> loop sem rede
      expect(step_index).to eq(1)                    # não fica preso na etapa choice
    end

    it 'rede #259 viva para choice: cliente que SOME (msg vazia) conta trava e no limite dispara stuck_handoff' do
      dept = choice_dept

      expect(track_blank(dept)).to be_nil # turno 1
      expect(track_blank(dept)).to be_nil # turno 2
      sig = track_blank(dept)             # turno 3 -> handoff

      expect(sig).to eq(stuck_handoff: { attribute: 'periodo', step_name: 'Período', turns: 3, reason: 'max_turns' })
      expect(step_index).to eq(0)
    end
  end

  # Worker de julgamento de captura (Ai::Workers::CaptureJudge): opt-in, DESLIGADO por padrão. Cobre os
  # slots SEM formato validável (endereco_completo) e o caso "para o dia 10" (tem dígito, o #269 gravaria
  # cru). O worker é stubado aqui — o teste unitário do worker vive em workers/capture_judge_spec.rb.
  describe '#track_step — worker de julgamento de captura' do
    def facts
      conversation.reload.additional_attributes['ai_collected_facts'] || {}
    end

    def events(type)
      Ai::Event.where(conversation_id: conversation.id, event_type: type)
    end

    def stuck
      conversation.reload.additional_attributes['ai_step_turns']
    end

    def incoming(text)
      create(:message, conversation: conversation, account: account, inbox: inbox,
                       message_type: :incoming, content: text)
    end

    def infer_dept(name, instruction)
      # Gap 4 v2: teto de recusa = stuck_limit (12) — MESMO limiar do absoluto. Depts de PERGUNTA não
      # transferem cedo; o absoluto (12) só é atingido nos testes que iteram até lá.
      dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: name, status: 'active',
                                    behavior: {}, transfer_rules: { 'stuck_handoff_turns' => 12 })
      # collect DECLARADO: a chave é decodificada da instrução do teste (conjunto FIXO destes specs —
      # "grave <k>" ou "no atributo <k>"). NÃO é o infer de produção (removido); é só o decoder do fixture.
      attribute = instruction[/no atributo (\w+)/, 1] || instruction[/grave (?:o )?(\w+)/, 1]
      dept.create_playbook!(active: true, steps: [
                              { 'name' => 'Coleta', 'collect' => { 'attribute' => attribute },
                                'instructions' => instruction },
                              { 'name' => 'Fim' }
                            ])
      dept
    end

    def enable_judge(mode = 'when_silent')
      profile.update!(worker_overrides: { 'capture_judge' => { 'mode' => mode } })
    end

    def run_turn(dept, text)
      manager.track_step(dept, { 'step_completed' => false },
                         dispatcher: dispatcher, run: run, message_text: text, message: incoming(text))
    end

    it 'DESLIGADO (default): worker NÃO roda, cai no caminho determinístico do #269 (regressão)' do
      expect(Ai::Workers::CaptureJudge).not_to receive(:judge)
      dept = infer_dept('J-off', 'Peça e grave endereco_completo conforme informado.')

      run_turn(dept, 'pode ser')

      expect(facts['endereco_completo']).to eq('pode ser') # #269: slot text grava cru, inalterado
      expect(step_index).to eq(1)
    end

    it 'LIGADO + not_an_answer (endereco_completo, "qual plano?"): não grava, não avança, não conta trava' do
      enable_judge
      allow(Ai::Workers::CaptureJudge).to receive(:judge).and_return({ status: 'not_an_answer' })
      dept = infer_dept('J-na', 'Peça e grave endereco_completo conforme informado.')

      run_turn(dept, 'qual plano?')

      expect(facts).not_to have_key('endereco_completo')
      expect(step_index).to eq(0)
      expect(stuck).to eq(1) # Gap 4: not_an_answer conta no teto absoluto (1 << teto)
      expect(refusals).to be_nil # Gap 4 v2: not_an_answer NÃO é recusa (nunca toca o contador)
      expect(events('slot.no_attempt').last.payload).to include('attribute' => 'endereco_completo', 'type' => 'not_an_answer')
    end

    it 'LIGADO + not_an_answer (telefone_secundario, "para o dia 10" — TEM dígito): não grava (motivo do PR)' do
      enable_judge
      allow(Ai::Workers::CaptureJudge).to receive(:judge).and_return({ status: 'not_an_answer' })
      dept = infer_dept('J-fone-na', 'Peça e grave o telefone_secundario conforme informado.')

      run_turn(dept, 'para o dia 10')

      expect(facts).not_to have_key('telefone_secundario')
      expect(events('slot.no_attempt')).not_to be_empty
    end

    it 'LIGADO + answered (telefone_secundario, "4998564780"): grava normalizado, source judge, avança' do
      enable_judge
      allow(Ai::Workers::CaptureJudge).to receive(:judge).and_return({ status: 'answered', value: '4998564780' })
      dept = infer_dept('J-ans', 'Peça e grave o telefone_secundario conforme informado.')

      run_turn(dept, 'meu numero: 4998564780')

      expect(facts['telefone_secundario']).to eq('4998564780') # normalizado pelo extractor (phone)
      expect(events('slot.captured').last.payload).to include('attribute' => 'telefone_secundario', 'source' => 'judge', 'status' => 'answered')
      expect(step_index).to eq(1)
    end

    it 'LIGADO + malformed (documento_cpf, "meu cpf é 123"): tipo errado -> gate REJEITA, não grava (MUDANÇA)' do
      # MUDANÇA DE COMPORTAMENTO: antes gravava cru (judge_raw) e a confirmação-única segurava; agora o juiz
      # persiste pelo MESMO gate (:supervisor) e valor de tipo errado vira invalid_value -> não grava, repergunta.
      enable_judge
      allow(Ai::Workers::CaptureJudge).to receive(:judge).and_return({ status: 'malformed', value: 'meu cpf é 123' })
      dept = infer_dept('J-mal', 'Peça e grave documento_cpf conforme informado.')

      run_turn(dept, 'meu cpf é 123')

      aggregate_failures do
        expect(facts).not_to have_key('documento_cpf')     # gate barrou; nada gravado cru
        expect(events('slot.captured')).to be_empty        # não emite "captured" sem gravar
        expect(events('facts.rejected').last.payload).to include('attribute' => 'documento_cpf', 'reason' => 'invalid_value')
        expect(step_index).to eq(0)
      end
    end

    it 'LIGADO + failed (worker falhou): judge.failed, não grava, não avança' do
      enable_judge
      allow(Ai::Workers::CaptureJudge).to receive(:judge).and_return({ status: 'failed', reason: 'invalid_json' })
      dept = infer_dept('J-fail', 'Peça e grave endereco_completo conforme informado.')

      run_turn(dept, 'rua qualquer 123')

      expect(facts).not_to have_key('endereco_completo')
      expect(step_index).to eq(0)
      expect(events('judge.failed').last.payload).to include('attribute' => 'endereco_completo', 'reason' => 'invalid_json')
    end

    it 'modelo devolveu attributes válidos: worker NÃO é chamado (Opção B intacta)' do
      enable_judge
      expect(Ai::Workers::CaptureJudge).not_to receive(:judge)
      dept = infer_dept('J-model', 'Peça e grave endereco_completo conforme informado.')

      manager.track_step(dept, { 'step_completed' => false, 'attributes' => { 'endereco_completo' => 'Rua X 1' } },
                         dispatcher: dispatcher, run: run, message_text: 'Rua X 1', message: incoming('Rua X 1'))

      expect(step_index).to eq(1)
    end

    # Gap 4 v2 (conserto da conv 389): not_an_answer (pergunta/digressão) e judge_failed (erro de sistema)
    # NÃO são recusa — viram :no_attempt (não tocam ai_slot_refusals). Quem transfere quem só pergunta é o
    # teto ABSOLUTO (ai_step_turns) com reason 'max_turns'. A rede de RECUSA passa a ser alimentada só por
    # declínio genuíno (Ai::SlotAbsence), testada nos blocos Gap 1/Gap 3.
    def refusals
      conversation.reload.additional_attributes['ai_slot_refusals']
    end

    it 'not_an_answer consecutivo NÃO alimenta a rede de recusa (vira :no_attempt); o absoluto conta' do
      enable_judge
      allow(Ai::Workers::CaptureJudge).to receive(:judge).and_return({ status: 'not_an_answer' })
      dept = infer_dept('J-na-below', 'Peça e grave endereco_completo conforme informado.')

      5.times { expect(run_turn(dept, 'qual plano?')).to be_nil }

      expect(refusals).to be_nil    # conserto do bug: pergunta nunca toca o contador de recusa
      expect(stuck).to eq(5)        # o teto ABSOLUTO conta o turno (5 < 12, não transfere)
      expect(step_index).to eq(0)
    end

    it 'só perguntas (not_an_answer): transfere pelo ABSOLUTO (reason max_turns), nunca por recusa' do
      enable_judge
      allow(Ai::Workers::CaptureJudge).to receive(:judge).and_return({ status: 'not_an_answer' })
      dept = infer_dept('J-na-abs', 'Peça e grave endereco_completo conforme informado.')

      11.times { expect(run_turn(dept, 'qual plano?')).to be_nil } # 11 < teto absoluto 12
      sig = run_turn(dept, 'e o preço?')                            # 12 -> absoluto

      expect(sig[:stuck_handoff]).to include(reason: 'max_turns', turns: 12)
      expect(sig[:stuck_handoff]).not_to have_key(:refusals) # sem declínio no meio
      expect(refusals).to be_nil
    end

    it 'judge_failed vira :no_attempt (erro de sistema ≠ recusa): não conta recusa, emite judge.failed' do
      enable_judge
      allow(Ai::Workers::CaptureJudge).to receive(:judge).and_return({ status: 'failed', reason: 'invalid_json' })
      dept = infer_dept('J-fail-na', 'Peça e grave endereco_completo conforme informado.')

      3.times { expect(run_turn(dept, 'rua x')).to be_nil }

      expect(refusals).to be_nil
      expect(stuck).to eq(3) # conta no absoluto, não na recusa
      expect(events('judge.failed')).not_to be_empty
    end

    it 'captura bem-sucedida no meio da sequência ZERA o teto absoluto (ai_step_turns)' do
      enable_judge
      dept = infer_dept('J-zero', 'Peça e grave o telefone_secundario conforme informado.')

      allow(Ai::Workers::CaptureJudge).to receive(:judge).and_return({ status: 'not_an_answer' })
      2.times { run_turn(dept, 'qual plano?') }
      expect(stuck).to eq(2)

      allow(Ai::Workers::CaptureJudge).to receive(:judge).and_return({ status: 'answered', value: '4998564780' })
      run_turn(dept, 'meu numero 4998564780')

      expect(facts['telefone_secundario']).to eq('4998564780')
      expect(stuck).to eq(0) # o avanço zera o absoluto
      expect(step_index).to eq(1)
    end

    it 'stuck_handoff_turns = 0: absoluto e recusa DESLIGADOS; perguntas nunca transferem' do
      enable_judge
      allow(Ai::Workers::CaptureJudge).to receive(:judge).and_return({ status: 'not_an_answer' })
      dept = infer_dept('J-off', 'Peça e grave endereco_completo conforme informado.')
      dept.update!(transfer_rules: { 'stuck_handoff_turns' => 0 })

      10.times { expect(run_turn(dept, 'qual plano?')).to be_nil }

      expect(step_index).to eq(0)
    end
  end

  # Anexo preenche o slot corrente SÓ quando a chave aceita anexo (não às cegas com o nome do arquivo).
  # conv 365: documento_cpf recebia "CNH-e.pdf.pdf" por cima do CPF do OCR. Regra determinística pela chave.
  describe '#track_step — anexo preenche slot só quando a chave aceita' do
    def facts
      conversation.reload.additional_attributes['ai_collected_facts'] || {}
    end

    def events(type)
      Ai::Event.where(conversation_id: conversation.id, event_type: type)
    end

    def stuck
      conversation.reload.additional_attributes['ai_step_turns']
    end

    def refusals
      conversation.reload.additional_attributes['ai_slot_refusals']
    end

    def infer_dept(name, instruction)
      # Gap 4 v2: teto de recusa = stuck_limit (12) — MESMO limiar do absoluto. Depts de PERGUNTA não
      # transferem cedo; o absoluto (12) só é atingido nos testes que iteram até lá.
      dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: name, status: 'active',
                                    behavior: {}, transfer_rules: { 'stuck_handoff_turns' => 12 })
      # collect DECLARADO: a chave é decodificada da instrução do teste (conjunto FIXO destes specs —
      # "grave <k>" ou "no atributo <k>"). NÃO é o infer de produção (removido); é só o decoder do fixture.
      attribute = instruction[/no atributo (\w+)/, 1] || instruction[/grave (?:o )?(\w+)/, 1]
      dept.create_playbook!(active: true, steps: [
                              { 'name' => 'Coleta', 'collect' => { 'attribute' => attribute },
                                'instructions' => instruction },
                              { 'name' => 'Fim' }
                            ])
      dept
    end

    def run_attach(dept, file_type:, name: nil, content: '', **att)
      msg = create(:message, conversation: conversation, account: account, inbox: inbox,
                             message_type: :incoming, content: content)
      msg.attachments.create!({ account_id: account.id, file_type: file_type, fallback_title: name }.merge(att))
      manager.track_step(dept, { 'step_completed' => false },
                         dispatcher: dispatcher, run: run, message_text: content, message: msg)
    end

    it 'documento_cpf + PDF: NÃO grava o nome no slot (chave é tipo cpf); grava os fatos; evento attribute nil' do
      dept = infer_dept('A-cpf', 'Peça e grave documento_cpf conforme informado.')
      run_attach(dept, file_type: :file, name: 'CNH-e.pdf.pdf')

      expect(facts).not_to have_key('documento_cpf')
      expect(facts['documento_recebido']).to be(true)
      expect(facts['documento_arquivo']).to eq('CNH-e.pdf.pdf')
      expect(events('attachment.captured').last.payload).to include('kind' => 'file', 'attribute' => nil)
    end

    it 'email_cliente + PDF: NÃO grava o nome no slot (chave é tipo email)' do
      dept = infer_dept('A-email', 'Peça e grave o e-mail no atributo email_cliente.')
      run_attach(dept, file_type: :file, name: 'doc.pdf')

      expect(facts).not_to have_key('email_cliente')
      expect(facts['documento_recebido']).to be(true)
    end

    it 'comprovante_residencia + PDF: grava o nome no slot (regra 2) e AVANÇA' do
      dept = infer_dept('A-comp', 'Peça e grave comprovante_residencia conforme informado.')
      run_attach(dept, file_type: :file, name: 'conta-luz.pdf')

      expect(facts['comprovante_residencia']).to eq('conta-luz.pdf')
      expect(events('attachment.captured').last.payload).to include('attribute' => 'comprovante_residencia')
      expect(step_index).to eq(1)
    end

    it 'endereco_completo + imagem: NÃO grava no slot (regra 3, chave não aceita anexo)' do
      dept = infer_dept('A-end', 'Peça e grave endereco_completo conforme informado.')
      run_attach(dept, file_type: :image, name: 'foto.jpg')

      expect(facts).not_to have_key('endereco_completo')
      expect(events('attachment.captured').last.payload).to include('attribute' => nil)
    end

    it '(a) anexo COM legenda em slot que não aceita: a legenda é capturada pelo caminho de texto' do
      dept = infer_dept('A-cap', 'Peça e grave endereco_completo conforme informado.')
      run_attach(dept, file_type: :image, name: 'foto.jpg', content: 'Rua das Flores 123')

      expect(facts['endereco_completo']).to eq('Rua das Flores 123')
      expect(step_index).to eq(1)
    end

    it '(b) anexo SEM legenda em slot que não aceita: não sinaliza; vira :no_attempt (absoluto), NÃO recusa' do
      dept = infer_dept('A-none', 'Peça e grave endereco_completo conforme informado.')
      sig = run_attach(dept, file_type: :image, name: 'foto.jpg')

      expect(sig).to be_nil            # abaixo do teto: não sinaliza handoff
      expect(facts).not_to have_key('endereco_completo')
      expect(stuck).to eq(1)           # Gap 4 v2: anexo-sem-slot conta no teto ABSOLUTO (1 << teto)
      expect(refusals).to be_nil       # não é declínio -> nunca toca o contador de recusa
      expect(step_index).to eq(0)
    end

    it 'localização: comportamento INALTERADO (só fatos, nunca preenche o slot)' do
      dept = infer_dept('A-loc', 'Peça e grave endereco_completo conforme informado.')
      run_attach(dept, file_type: :location, coordinates_lat: -26.5, coordinates_long: -53.0)

      expect(facts['localizacao_recebida']).to be(true)
      expect(facts).not_to have_key('endereco_completo')
      expect(events('attachment.captured').last.payload).to include('kind' => 'location', 'attribute' => nil)
    end

    # Gap 4 v2: o só-anexo repetido não fica preso — mas agora é o teto ABSOLUTO (ai_step_turns) que conta e
    # transfere, não a rede de recusa (anexo-sem-slot é não-resposta, não declínio).
    it 'localização repetida (sem texto) ABAIXO do teto absoluto: não transfere' do
      dept = infer_dept('A-rep', 'Peça e grave endereco_completo conforme informado.')

      5.times do
        sig = run_attach(dept, file_type: :location, coordinates_lat: -26.5, coordinates_long: -53.0)
        expect(sig).to be_nil
      end

      expect(refusals).to be_nil
      expect(stuck).to eq(5) # o teto absoluto conta (5 < 12)
      expect(step_index).to eq(0)
    end

    it 'localização repetida: ao ATINGIR o teto ABSOLUTO (12ª) sinaliza stuck_handoff com reason max_turns' do
      dept = infer_dept('A-rep2', 'Peça e grave endereco_completo conforme informado.')

      11.times { run_attach(dept, file_type: :location, coordinates_lat: -26.5, coordinates_long: -53.0) }
      sig = run_attach(dept, file_type: :location, coordinates_lat: -26.5, coordinates_long: -53.0)

      expect(sig[:stuck_handoff]).to include(reason: 'max_turns', turns: 12)
      expect(sig[:stuck_handoff]).not_to have_key(:refusals) # anexo-sem-slot não é declínio
    end

    it 'captura bem-sucedida no meio ZERA o teto absoluto do só-anexo' do
      dept = infer_dept('A-rep3', 'Peça e grave comprovante_residencia conforme informado.')

      2.times { run_attach(dept, file_type: :location, coordinates_lat: -26.5, coordinates_long: -53.0) }
      expect(stuck).to eq(2)

      run_attach(dept, file_type: :file, name: 'conta-luz.pdf') # regra 2: preenche o slot -> avança

      expect(facts['comprovante_residencia']).to eq('conta-luz.pdf')
      expect(stuck).to eq(0) # o avanço zera o absoluto
      expect(step_index).to eq(1)
    end

    it 'stuck_handoff_turns = 0: teto DESLIGADO, só-anexo repetido nunca transfere' do
      dept = infer_dept('A-rep4', 'Peça e grave endereco_completo conforme informado.')
      dept.update!(transfer_rules: { 'stuck_handoff_turns' => 0 })

      10.times do
        expect(run_attach(dept, file_type: :location, coordinates_lat: -26.5, coordinates_long: -53.0)).to be_nil
      end

      expect(step_index).to eq(0)
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

  describe '#persist_attributes — normalização de valor para atributo tipo LIST' do
    def define_list(key, values)
      CustomAttributeDefinition.create!(
        account: account, attribute_key: key, attribute_display_name: key.capitalize,
        attribute_model: 'conversation_attribute', attribute_display_type: 'list', attribute_values: values
      )
    end

    def define_text(key)
      CustomAttributeDefinition.create!(
        account: account, attribute_key: key, attribute_display_name: key.capitalize,
        attribute_model: 'conversation_attribute', attribute_display_type: 'text'
      )
    end

    before { define_list('cidade', %w[Chapecó Maravilha]) }

    it 'grava a opção CANÔNICA quando o valor casa ignorando caixa (maravilha -> Maravilha)' do
      manager.persist_attributes({ 'cidade' => 'maravilha' }, department)

      expect(conversation.reload.custom_attributes['cidade']).to eq('Maravilha')
    end

    it 'NÃO normaliza ai_collected_facts — a memória mantém o valor cru do cliente' do
      manager.persist_attributes({ 'cidade' => 'maravilha' }, department)

      expect(conversation.reload.additional_attributes['ai_collected_facts']['cidade']).to eq('maravilha')
    end

    it 'casa ignorando acento (chapeco -> Chapecó)' do
      manager.persist_attributes({ 'cidade' => 'chapeco' }, department)

      expect(conversation.reload.custom_attributes['cidade']).to eq('Chapecó')
    end

    it 'casa ignorando espaços nas pontas (trim antes de comparar)' do
      manager.persist_attributes({ 'cidade' => ' Maravilha ' }, department)

      expect(conversation.reload.custom_attributes['cidade']).to eq('Maravilha')
    end

    it 'grava como veio quando não casa com nenhuma opção' do
      manager.persist_attributes({ 'cidade' => 'São Miguel do Oeste' }, department)

      expect(conversation.reload.custom_attributes['cidade']).to eq('São Miguel do Oeste')
    end

    it 'MAIÚSCULAS casam por igualdade normalizada (MARAVILHA -> Maravilha)' do
      manager.persist_attributes({ 'cidade' => 'MARAVILHA' }, department)

      expect(conversation.reload.custom_attributes['cidade']).to eq('Maravilha')
    end

    it 'frase que MENCIONA uma opção não casa por substring — grava como veio (nega chapecó falso)' do
      manager.persist_attributes({ 'cidade' => 'não é maravilha, é chapecó' }, department)

      expect(conversation.reload.custom_attributes['cidade']).to eq('não é maravilha, é chapecó')
    end

    it 'frase contendo a opção não casa (moro em maravilha -> grava como veio)' do
      manager.persist_attributes({ 'cidade' => 'moro em maravilha' }, department)

      expect(conversation.reload.custom_attributes['cidade']).to eq('moro em maravilha')
    end

    it 'não normaliza definição de tipo text (grava exatamente como veio)' do
      define_text('observacao')

      manager.persist_attributes({ 'observacao' => 'maravilha' }, department)

      expect(conversation.reload.custom_attributes['observacao']).to eq('maravilha')
    end

    it 'chave sem CustomAttributeDefinition continua não espelhando (#265 preservado)' do
      manager.persist_attributes({ 'bairro' => 'centro' }, department)

      expect(conversation.reload.custom_attributes).not_to have_key('bairro')
      expect(conversation.reload.additional_attributes['ai_collected_facts']['bairro']).to eq('centro')
    end

    it 'continua emitindo attributes.updated com as chaves espelhadas' do
      manager.persist_attributes({ 'cidade' => 'maravilha' }, department)

      event = Ai::Event.where(conversation_id: conversation.id, event_type: 'attributes.updated').last
      expect(event.payload['keys']).to eq(['cidade'])
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

  describe '#persist_attributes — gate anti-contaminação (source: :supervisor)' do
    def define_attr(key)
      CustomAttributeDefinition.create!(account: account, attribute_key: key, attribute_display_name: key.capitalize,
                                        attribute_model: 'conversation_attribute', attribute_display_type: 'text')
    end

    def collected_facts
      conversation.reload.additional_attributes.to_h['ai_collected_facts']
    end

    def rejected_events
      Ai::Event.where(conversation_id: conversation.id, event_type: 'facts.rejected')
    end

    it 'descarta chave INESPERADA e emite facts.rejected(unexpected_key)' do
      manager.persist_attributes({ 'plano' => 'Premium' }, department, source: :supervisor)

      expect(collected_facts).to be_nil
      event = rejected_events.last
      expect(event.payload['attribute']).to eq('plano')
      expect(event.payload['reason']).to eq('unexpected_key')
    end

    it 'descarta chave esperada com VALOR INVÁLIDO para tipo conhecido (telefone = "dia 10")' do
      define_attr('telefone') # esperada (CustomAttributeDefinition); type_for_key -> phone

      manager.persist_attributes({ 'telefone' => 'dia 10' }, department, source: :supervisor)

      expect(collected_facts).to be_nil
      event = rejected_events.last
      expect(event.payload['attribute']).to eq('telefone')
      expect(event.payload['reason']).to eq('invalid_value')
    end

    it 'GRAVA chave esperada com valor válido (proteção conv 350/352 preservada)' do
      define_attr('cidade')

      manager.persist_attributes({ 'cidade' => 'Maravilha' }, department, source: :supervisor)

      expect(collected_facts['cidade']).to eq('Maravilha')
      expect(rejected_events).to be_empty
    end

    it 'GRAVA chave esperada de tipo conhecido quando o valor passa no extractor (telefone válido)' do
      define_attr('telefone')

      manager.persist_attributes({ 'telefone' => '(49) 99856-4780' }, department, source: :supervisor)

      expect(collected_facts['telefone']).to eq('(49) 99856-4780') # gate só valida, não transforma o fato
      expect(rejected_events).to be_empty
    end

    it 'aceita chave vinda de lead_variable do department (sem CustomAttributeDefinition)' do
      Ai::LeadVariable.create!(account: account, department: department, name: 'origem', var_type: 'texto', values: [])

      manager.persist_attributes({ 'origem' => 'Instagram' }, department, source: :supervisor)

      expect(collected_facts['origem']).to eq('Instagram')
      expect(rejected_events).to be_empty
    end

    it 'aceita a chave do SLOT da etapa atual mesmo sem CustomAttributeDefinition/lead_variable' do
      dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Slot', status: 'active',
                                    behavior: {})
      dept.create_playbook!(active: true, steps: [{ 'name' => 'Doc', 'collect' => { 'attribute' => 'documento_extra' } }])
      conversation.update!(additional_attributes: { 'ai_step_index' => 0 })

      manager.persist_attributes({ 'documento_extra' => 'RG 123' }, dept, source: :supervisor)

      expect(collected_facts['documento_extra']).to eq('RG 123')
      expect(rejected_events).to be_empty
    end

    it 'na mistura, só a chave esperada entra em ai_collected_facts; a inesperada é rejeitada' do
      define_attr('cidade')

      manager.persist_attributes({ 'cidade' => 'Maravilha', 'plano' => 'Premium' }, department, source: :supervisor)

      expect(collected_facts).to eq({ 'cidade' => 'Maravilha' })
      expect(rejected_events.map { |e| e.payload['attribute'] }).to eq(['plano'])
    end

    it 'source default (:trusted) grava TUDO sem gate — caminho do juiz, inclusive malformed' do
      # valores que FALHARIAM o gate do supervisor entram normalmente pela fonte confiável (regressão zero)
      manager.persist_attributes({ 'telefone' => 'dia 10' }, department) # malformed do juiz
      manager.persist_attributes({ 'plano' => 'Premium' }, department)   # chave "inesperada"

      expect(collected_facts).to include('telefone' => 'dia 10', 'plano' => 'Premium')
      expect(rejected_events).to be_empty
    end
  end

  # Correção da ordem (fix/supervisor-gate-preadvance-slot): o Gateway chama track_step (que AVANÇA o
  # ai_step_index) ANTES do persist do supervisor. O gate do #284 lia current_slot DEPOIS do avanço, então
  # validava o valor recém-coletado contra o slot da PRÓXIMA etapa -> unexpected_key -> descarte. Agora o
  # Gateway passa expected_step (a etapa PRÉ-AVANÇO) e o gate valida contra ela.
  describe '#persist_attributes — ordem: expected_step (etapa pré-avanço)' do
    def collected_facts
      conversation.reload.additional_attributes.to_h['ai_collected_facts']
    end

    def rejected_events
      Ai::Event.where(conversation_id: conversation.id, event_type: 'facts.rejected')
    end

    def define_attr(key)
      CustomAttributeDefinition.create!(account: account, attribute_key: key, attribute_display_name: key.capitalize,
                                        attribute_model: 'conversation_attribute', attribute_display_type: 'text')
    end

    # Funil de 3 etapas de coleta; nenhuma chave é CustomAttributeDefinition da conta (legítimas por
    # construção via collect['attribute'] — é o caso da conv 387).
    def funnel_department
      dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Funil', status: 'active',
                                    behavior: {}, transfer_rules: { 'stuck_handoff_turns' => 3 })
      dept.create_playbook!(active: true, steps: [
                              { 'name' => 'Email', 'collect' => { 'attribute' => 'email_cliente', 'type' => 'text', 'required' => true } },
                              { 'name' => 'CPF', 'collect' => { 'attribute' => 'documento_cpf', 'type' => 'text', 'required' => true } },
                              { 'name' => 'Plano', 'collect' => { 'attribute' => 'plano_escolhido', 'type' => 'text', 'required' => true } }
                            ])
      dept
    end

    # INVARIANTE central (mais forte que testar o gate isolado): se a etapa AVANÇOU porque o slot foi
    # preenchido, o valor TEM que estar em ai_collected_facts. Era isto que a regressão do #284 quebrava —
    # o funil andava (ai_step_index=14 na conv 387) com a memória quase vazia: estado e memória divergindo
    # em silêncio. Reproduz a ORDEM do Gateway: captura o slot pré-avanço, track_step avança, o persist do
    # supervisor valida contra o pré-avanço.
    it 'INVARIANTE: etapa avançou por slot preenchido => o valor está em ai_collected_facts' do
      dept = funnel_department
      conversation.update!(additional_attributes: { 'ai_step_index' => 0 })
      pre_step = dept.playbook.steps[0] # etapa ATIVA no início do turno (e-mail)
      msg = create(:message, conversation: conversation, account: account, inbox: inbox,
                             message_type: :incoming, content: 'joao@exemplo.com')
      decision = { 'attributes' => { 'email_cliente' => 'joao@exemplo.com' }, 'step_completed' => false }

      manager.track_step(dept, decision, dispatcher: dispatcher, run: run, message_text: 'joao@exemplo.com', message: msg)
      expect(conversation.reload.additional_attributes['ai_step_index']).to eq(1) # o funil AVANÇOU
      manager.persist_attributes(decision['attributes'], dept, source: :supervisor, expected_step: pre_step)

      expect(collected_facts).to include('email_cliente' => 'joao@exemplo.com') # ...e a memória NÃO ficou vazia
    end

    it 'aceita o valor do slot PRÉ-AVANÇO mesmo com o índice já apontando para a próxima etapa' do
      dept = funnel_department
      conversation.update!(additional_attributes: { 'ai_step_index' => 1 }) # índice JÁ na etapa CPF
      email_step = dept.playbook.steps[0]                                    # mas o turno coletou e-mail

      manager.persist_attributes({ 'email_cliente' => 'a@b.com' }, dept, source: :supervisor, expected_step: email_step)

      expect(collected_facts).to include('email_cliente' => 'a@b.com')
      expect(rejected_events).to be_empty
    end

    it 'chave inventada FORA do playbook continua rejeitada (unexpected_key)' do
      dept = funnel_department
      email_step = dept.playbook.steps[0]

      manager.persist_attributes({ 'xyz_inventado' => 'lixo' }, dept, source: :supervisor, expected_step: email_step)

      expect(collected_facts).to be_nil
      expect(rejected_events.last.payload).to include('attribute' => 'xyz_inventado', 'reason' => 'unexpected_key')
    end

    # (5) INVERTE o (ii): um slot DECLARADO no playbook, mesmo NÃO-ativo, agora está no allowlist. Um slot
    # de TEXTO (sem formato/options) é aceito — é o que destrava a correção de etapa passada / dado
    # adiantado. A proteção anti-alucinação segue no acoplamento (tipo/options do step declarante) e na
    # rejeição de chave FORA do playbook (teste abaixo). Ver describe "gate (5)".
    it '(5): slot DECLARADO de TEXTO NÃO-ativo agora é ACEITO (allowlist índice-independente)' do
      dept = funnel_department
      email_step = dept.playbook.steps[0] # slot ATIVO = email_cliente; plano_escolhido é etapa futura

      manager.persist_attributes({ 'plano_escolhido' => 'Combo' }, dept, source: :supervisor, expected_step: email_step)

      expect(collected_facts).to include('plano_escolhido' => 'Combo')
      expect(rejected_events).to be_empty
    end

    it 'preserva #284: tipo conhecido com valor inválido é rejeitado mesmo com expected_step (invalid_value)' do
      dept = funnel_department
      define_attr('telefone') # esperada; type_for_key -> phone
      email_step = dept.playbook.steps[0]

      manager.persist_attributes({ 'telefone' => 'dia 10' }, dept, source: :supervisor, expected_step: email_step)

      expect(collected_facts).to be_nil
      expect(rejected_events.last.payload).to include('attribute' => 'telefone', 'reason' => 'invalid_value')
    end
  end

  # (5) known_slot_keys no allowlist + validação ACOPLADA ao step declarante. Contrato: corrigir dado de
  # etapa PASSADA e adiantar dado de etapa FUTURA passam; chave fora do playbook/conta/lead continua
  # barrada; o valor ainda é validado pelo tipo/options do step QUE DECLARA a chave (não do slot corrente),
  # então valor fora das options de um slot choice cai mesmo com a etapa dele inativa. Prova de mutação
  # por nome: cada teste morre se o acoplamento (5) for revertido ou desacoplado.
  describe '#persist_attributes — gate (5): allowlist de slots declarados + validação acoplada' do
    def collected_facts
      conversation.reload.additional_attributes.to_h['ai_collected_facts']
    end

    def rejected_events
      Ai::Event.where(conversation_id: conversation.id, event_type: 'facts.rejected')
    end

    # Funil com um slot CHOICE (plano) no MEIO — nenhuma chave é CustomAttributeDefinition da conta: todas
    # legítimas só por serem declaradas no collect (é o caso da conv da evidência).
    def funnel_with_choice
      dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Funil5', status: 'active',
                                    behavior: {})
      dept.create_playbook!(active: true, steps: [
                              { 'name' => 'Email', 'collect' => { 'attribute' => 'email_cliente', 'type' => 'text' } },
                              { 'name' => 'Plano', 'collect' => { 'attribute' => 'plano_escolhido', 'type' => 'choice',
                                                                  'options' => ['Internet Fibra 600 Mega', 'Combo Fibra + Wi-Fi Mesh'] } },
                              { 'name' => 'Telefone', 'collect' => { 'attribute' => 'telefone_secundario', 'type' => 'text' } }
                            ])
      dept
    end

    it 'correção de slot de etapa ANTERIOR é aceita (etapa ativa já é posterior ao slot)' do
      dept = funnel_with_choice
      conversation.update!(additional_attributes: { 'ai_step_index' => 2 }) # ativo = telefone; plano ficou pra trás
      active = dept.playbook.steps[2]

      manager.persist_attributes({ 'plano_escolhido' => 'Combo Fibra + Wi-Fi Mesh' }, dept,
                                 source: :supervisor, expected_step: active)

      expect(collected_facts).to include('plano_escolhido' => 'Combo Fibra + Wi-Fi Mesh')
      expect(rejected_events).to be_empty
    end

    it 'dado ADIANTADO de etapa FUTURA é aceito (cliente responde antes de o funil chegar lá)' do
      dept = funnel_with_choice
      conversation.update!(additional_attributes: { 'ai_step_index' => 0 }) # ativo = email; plano é etapa futura
      active = dept.playbook.steps[0]

      manager.persist_attributes({ 'plano_escolhido' => 'Internet Fibra 600 Mega' }, dept,
                                 source: :supervisor, expected_step: active)

      expect(collected_facts).to include('plano_escolhido' => 'Internet Fibra 600 Mega')
      expect(rejected_events).to be_empty
    end

    it 'chave FORA do playbook/conta/lead continua rejeitada (unexpected_key)' do
      dept = funnel_with_choice
      active = dept.playbook.steps[0]

      manager.persist_attributes({ 'campo_inventado' => 'lixo' }, dept, source: :supervisor, expected_step: active)

      expect(collected_facts).to be_nil
      expect(rejected_events.last.payload).to include('attribute' => 'campo_inventado', 'reason' => 'unexpected_key')
    end

    # PROVA DO ACOPLAMENTO: plano está no allowlist (não é unexpected_key), mas 'Premium' não é uma das
    # options declaradas no step do plano -> invalid_value, MESMO com a etapa ativa sendo o e-mail. Se o
    # (5) for desacoplado (options do slot corrente, ou []), este valor passaria e o teste morre.
    it 'valor fora das options é rejeitado mesmo quando a etapa NÃO é a corrente (invalid_value)' do
      dept = funnel_with_choice
      conversation.update!(additional_attributes: { 'ai_step_index' => 0 }) # ativo = email, NÃO o plano
      active = dept.playbook.steps[0]

      manager.persist_attributes({ 'plano_escolhido' => 'Premium' }, dept, source: :supervisor, expected_step: active)

      expect(collected_facts).to be_nil
      expect(rejected_events.last.payload).to include('attribute' => 'plano_escolhido', 'reason' => 'invalid_value')
    end

    it 'eco IDÊNTICO de um fato já coletado é no-op (não reescreve, não rejeita)' do
      dept = funnel_with_choice
      conversation.update!(additional_attributes: {
                             'ai_step_index' => 0,
                             'ai_collected_facts' => { 'plano_escolhido' => 'Combo Fibra + Wi-Fi Mesh' }
                           })
      active = dept.playbook.steps[0]
      # mutação: se o guard de idempotência (persist_collected_facts) sumir, haverá update! e o teste morre.
      expect(conversation).not_to receive(:update!)

      manager.persist_attributes({ 'plano_escolhido' => 'Combo Fibra + Wi-Fi Mesh' }, dept,
                                 source: :supervisor, expected_step: active)

      expect(rejected_events).to be_empty
    end
  end

  # Gap 1 (recusa/ausência de slot): detecção ortogonal ao tipo, ANTES do formato; opcional satisfaz com
  # a sentinela e avança, obrigatório conta recusa e transfere no teto. Simula a ORDEM do Gateway.
  describe '#track_step — Gap 1: recusa/ausência de slot' do
    def collected_facts
      conversation.reload.additional_attributes.to_h['ai_collected_facts']
    end

    def rejected_events
      Ai::Event.where(conversation_id: conversation.id, event_type: 'facts.rejected')
    end

    def idx
      conversation.reload.additional_attributes.to_h['ai_step_index']
    end

    def refusals
      conversation.reload.additional_attributes.to_h['ai_slot_refusals']
    end

    def gap1_dept(required:, slot: 'email_cliente', type: 'text')
      collect = { 'attribute' => slot, 'type' => type }
      collect['required'] = false unless required
      dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: "G#{SecureRandom.hex(3)}",
                                    status: 'active', behavior: {}, transfer_rules: { 'stuck_handoff_turns' => 12 })
      dept.create_playbook!(active: true, steps: [{ 'name' => 'Slot', 'collect' => collect }, { 'name' => 'Fim' }])
      dept
    end

    # Ordem do Gateway: track_step (roteia/avança) + persist do supervisor (gated contra o slot pré-avanço).
    def run_turn(dept, attrs:, text:, message: nil)
      pre = dept.playbook.steps[idx.to_i]
      msg = message || create(:message, conversation: conversation, account: account, inbox: inbox,
                                        message_type: :incoming, content: text)
      decision = { 'attributes' => attrs, 'step_completed' => false }
      sig = manager.track_step(dept, decision, dispatcher: dispatcher, run: run, message_text: text, message: msg)
      manager.persist_attributes(decision['attributes'], dept, source: :supervisor, expected_step: pre)
      sig
    end

    before { conversation.update!(additional_attributes: { 'ai_step_index' => 0 }) }

    it 'OPCIONAL/formato conhecido: recusa (sentinela A) -> ABSENT em facts, avança, custom vazio' do
      dept = gap1_dept(required: false) # email_cliente text -> deriva email
      run_turn(dept, attrs: { 'email_cliente' => Ai::StepSlot::ABSENT }, text: 'não tenho email')

      expect(collected_facts['email_cliente']).to eq(Ai::StepSlot::ABSENT)
      expect(conversation.reload.custom_attributes).to eq({}) # token NUNCA no espelho
      expect(idx).to eq(1)
    end

    it 'OPCIONAL/texto: recusa por TEXTO (modelo mudo) -> ABSENT, avança' do
      dept = gap1_dept(required: false, slot: 'observacao', type: 'text')
      run_turn(dept, attrs: {}, text: 'não tenho')

      expect(collected_facts['observacao']).to eq(Ai::StepSlot::ABSENT)
      expect(idx).to eq(1)
    end

    it 'OBRIGATÓRIO/formato conhecido: recusa -> não preenche, conta recusa, não avança' do
      dept = gap1_dept(required: true)
      run_turn(dept, attrs: { 'email_cliente' => 'não informado' }, text: 'não possuo')

      expect(collected_facts).to be_nil
      expect(refusals).to eq(1)
      expect(idx).to eq(0)
    end

    # Prova que o efeito colateral do gate fix (nome="não informado" em texto obrigatório) está fechado.
    # Alvo da prova de mutação: desligar o guard 'declined' do gated_facts faz este exemplo falhar.
    it 'OBRIGATÓRIO/texto: recusa NÃO grava "não informado" no slot' do
      dept = gap1_dept(required: true, slot: 'nome_cliente', type: 'text')
      run_turn(dept, attrs: { 'nome_cliente' => 'não informado' }, text: 'não tenho')

      expect(collected_facts).to be_nil
      expect(refusals).to eq(1)
      expect(idx).to eq(0)
    end

    it 'OBRIGATÓRIO: recusas consecutivas atingem o teto -> handoff com reason declined' do
      dept = gap1_dept(required: true) # Gap 4 v2: teto de recusa = stuck_limit (12); declínio vence o empate
      sig = nil
      12.times { sig = run_turn(dept, attrs: { 'email_cliente' => 'não informado' }, text: 'não possuo') }

      expect(sig).to be_a(Hash)
      expect(sig[:stuck_handoff]).to include(reason: 'declined')
    end

    it 'OBRIGATÓRIO: valor válido DEPOIS de recusar preenche e reseta (recusa não bloqueia a correção)' do
      dept = gap1_dept(required: true)
      run_turn(dept, attrs: { 'email_cliente' => 'não informado' }, text: 'não possuo')
      expect(refusals).to eq(1)

      run_turn(dept, attrs: { 'email_cliente' => 'joao@x.com' }, text: 'joao@x.com')
      expect(collected_facts['email_cliente']).to eq('joao@x.com')
      expect(idx).to eq(1)
      expect(refusals).to eq(0)
    end

    it 'gate do supervisor rejeita a sentinela crua (declined) e aceita valor válido depois' do
      dept = gap1_dept(required: true)
      email_step = dept.playbook.steps[0]
      manager.persist_attributes({ 'email_cliente' => 'não informado' }, dept, source: :supervisor, expected_step: email_step)
      expect(collected_facts).to be_nil
      expect(rejected_events.last.payload).to include('reason' => 'declined')

      manager.persist_attributes({ 'email_cliente' => 'joao@x.com' }, dept, source: :supervisor, expected_step: email_step)
      expect(collected_facts['email_cliente']).to eq('joao@x.com')
    end

    it 'digressão (pergunta) num slot obrigatório NÃO conta recusa (:no_attempt preservado)' do
      dept = gap1_dept(required: true)
      run_turn(dept, attrs: {}, text: 'e qual o horário de instalação?')

      expect(refusals).to be_nil # não incrementou o contador de recusas
      expect(idx).to eq(0)
    end

    it 'o token de ausência NUNCA vai para custom_attributes (mesmo com CustomAttributeDefinition)' do
      CustomAttributeDefinition.create!(account: account, attribute_key: 'email_cliente', attribute_display_name: 'Email',
                                        attribute_model: 'conversation_attribute', attribute_display_type: 'text')
      dept = gap1_dept(required: false)
      run_turn(dept, attrs: { 'email_cliente' => Ai::StepSlot::ABSENT }, text: 'não tenho email')

      expect(collected_facts['email_cliente']).to eq(Ai::StepSlot::ABSENT)
      expect(conversation.reload.custom_attributes).not_to have_key('email_cliente')
    end

    it '(13) anexo que preenche o slot + texto de recusa na mesma msg -> ANEXO vence' do
      dept = gap1_dept(required: true, slot: 'comprovante', type: 'text') # ATTACHMENT_KEY_RE casa "comprovante"
      msg = create(:message, conversation: conversation, account: account, inbox: inbox,
                             message_type: :incoming, content: 'não tenho')
      msg.attachments.create!(account_id: account.id, file_type: :file, fallback_title: 'comprovante.pdf')

      run_turn(dept, attrs: {}, text: 'não tenho', message: msg)

      expect(collected_facts['comprovante']).to be_present
      expect(collected_facts['comprovante']).not_to eq(Ai::StepSlot::ABSENT)
      expect(idx).to eq(1)
    end

    it '(14) texto de recusa contendo valor válido -> captura o VALOR, não a ausência (guard d)' do
      dept = gap1_dept(required: true)
      run_turn(dept, attrs: {}, text: 'não tenho email mas pode usar joao@x.com')

      expect(collected_facts['email_cliente']).to eq('joao@x.com')
      expect(idx).to eq(1)
    end

    # Gap 3 (buraco FECHADO — evidência no diff): o fill malformado da confirmação-única deixou de zerar
    # ai_slot_refusals. Antes zerava (a alternância recusa/malformado nunca atingia o teto); agora SEGURA.
    it 'Gap 3: fill malformado (confirmação-única) ENTRE recusas NÃO zera ai_slot_refusals (SEGURA)' do
      dept = gap1_dept(required: true)
      run_turn(dept, attrs: { 'email_cliente' => 'não informado' }, text: 'não possuo')
      expect(refusals).to eq(1)

      # valor não-ausência e não-válido -> slot_filled?(decision) passa -> confirmação-única
      run_turn(dept, attrs: { 'email_cliente' => 'joao arroba x' }, text: 'joao arroba x')
      expect(refusals).to eq(1) # Gap 3: malformado SEGURA o orçamento (antes zerava para 0)
    end
  end

  # Gap 2 (semântica de opcional em slot INFERIDO — o caso real: 0 playbooks usam collect). optional? lê
  # step['slot_required']; a captura passa a ser por StepSlot.attribute, então slot opcional é capturado
  # e avança determinísticamente, e o fill_absent (opcional-declinado) deixa de ser inalcançável.
  describe '#track_step — Gap 2: opcional em slot INFERIDO (sem collect)' do
    def collected_facts
      conversation.reload.additional_attributes.to_h['ai_collected_facts']
    end

    def idx
      conversation.reload.additional_attributes.to_h['ai_step_index']
    end

    def refusals
      conversation.reload.additional_attributes.to_h['ai_slot_refusals']
    end

    # Etapa com slot INFERIDO da instrução (sem collect). optional -> acrescenta slot_required:false.
    def inferred_dept(optional:)
      step = { 'name' => 'Email', 'collect' => { 'attribute' => 'email_cliente' },
               'instructions' => 'Peça e grave o email_cliente conforme informado.' }
      step['slot_required'] = false if optional
      dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: "I#{SecureRandom.hex(3)}",
                                    status: 'active', behavior: {}, transfer_rules: { 'stuck_handoff_turns' => 3 })
      dept.create_playbook!(active: true, steps: [step, { 'name' => 'Fim' }])
      dept
    end

    def run_turn(dept, attrs:, text:)
      pre = dept.playbook.steps[idx.to_i]
      msg = create(:message, conversation: conversation, account: account, inbox: inbox,
                             message_type: :incoming, content: text)
      decision = { 'attributes' => attrs, 'step_completed' => false }
      manager.track_step(dept, decision, dispatcher: dispatcher, run: run, message_text: text, message: msg)
      manager.persist_attributes(decision['attributes'], dept, source: :supervisor, expected_step: pre)
    end

    before { conversation.update!(additional_attributes: { 'ai_step_index' => 0 }) }

    # PROVA de que o fill_absent deixou de ser inalcançável — com slot INFERIDO (não sintético com collect).
    it 'OPCIONAL inferido + recusa -> fill_absent (token) e AVANÇA' do
      dept = inferred_dept(optional: true)
      expect(Ai::StepSlot.attribute(dept.playbook.steps[0])).to eq('email_cliente') # veio da inferência
      expect(Ai::StepSlot.optional?(dept.playbook.steps[0])).to be(true)

      run_turn(dept, attrs: { 'email_cliente' => Ai::StepSlot::ABSENT }, text: 'não tenho email')

      expect(collected_facts['email_cliente']).to eq(Ai::StepSlot::ABSENT)
      expect(idx).to eq(1)
    end

    it 'OPCIONAL inferido + valor válido -> captura determinística e AVANÇA (captura destravada)' do
      dept = inferred_dept(optional: true)
      run_turn(dept, attrs: {}, text: 'meu email é joao@x.com') # modelo mudo -> captura determinística

      expect(collected_facts['email_cliente']).to eq('joao@x.com')
      expect(idx).to eq(1)
    end

    it 'OBRIGATÓRIO inferido + recusa -> conta recusa, NÃO avança' do
      dept = inferred_dept(optional: false)
      run_turn(dept, attrs: { 'email_cliente' => 'não informado' }, text: 'não possuo')

      expect(collected_facts).to be_nil
      expect(refusals).to eq(1)
      expect(idx).to eq(0)
    end

    it 'OBRIGATÓRIO inferido + valor válido -> captura e AVANÇA' do
      dept = inferred_dept(optional: false)
      run_turn(dept, attrs: {}, text: 'joao@x.com')

      expect(collected_facts['email_cliente']).to eq('joao@x.com')
      expect(idx).to eq(1)
    end

    it 'digressão num slot inferido NÃO conta recusa (:no_attempt preservado)' do
      dept = inferred_dept(optional: false)
      run_turn(dept, attrs: {}, text: 'e qual o horário de instalação?')

      expect(refusals).to be_nil
      expect(idx).to eq(0)
    end

    it 'o token de ausência (opcional inferido) NUNCA vai para custom_attributes' do
      dept = inferred_dept(optional: true)
      run_turn(dept, attrs: { 'email_cliente' => Ai::StepSlot::ABSENT }, text: 'não tenho email')

      expect(collected_facts['email_cliente']).to eq(Ai::StepSlot::ABSENT)
      expect(conversation.reload.custom_attributes).not_to have_key('email_cliente')
    end

    # Ajuste 3: o juiz está LIGADO em produção (perfil #4, mode 'always'). run_turn_judge passa a enxergar
    # o slot OPCIONAL inferido (era required_attribute -> nil p/ opcional). Verifica os dois: o juiz recebe
    # o slot E o fill_absent acontece no declínio.
    it 'juiz LIGADO: enxerga o slot opcional inferido no run_turn_judge e o declínio faz fill_absent' do
      judge_profile = Ai::OperationProfile.create!(account_id: account.id, name: 'juiz',
                                                   supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini',
                                                   worker_overrides: { 'capture_judge' => { 'mode' => 'always' } })
      judge_agent = Ai::Agent.create!(account: account, name: 'BotJuiz', status: 'active',
                                      ai_operation_profile_id: judge_profile.id)
      judge_manager = described_class.new(conversation: conversation, agent: judge_agent)
      dept = inferred_dept(optional: true)
      step = dept.playbook.steps[0]

      seen_slot = nil
      allow(Ai::Workers::CaptureJudge).to receive(:judge) do |kwargs|
        seen_slot = kwargs[:slot]
        { status: 'not_an_answer' }
      end

      jr = judge_manager.run_turn_judge(step, 'não tenho email')
      expect(seen_slot).to eq('email_cliente') # o juiz VÊ o slot opcional inferido (era nil antes do Gap 2)

      msg = create(:message, conversation: conversation, account: account, inbox: inbox,
                             message_type: :incoming, content: 'não tenho email')
      judge_manager.track_step(dept, { 'attributes' => {}, 'step_completed' => false },
                               dispatcher: dispatcher, run: run, message_text: 'não tenho email',
                               message: msg, judge_result: jr)

      expect(collected_facts['email_cliente']).to eq(Ai::StepSlot::ABSENT) # declínio -> fill_absent
      expect(idx).to eq(1)
    end
  end

  # Gap 3 (reset do orçamento de recusas). Slot INFERIDO obrigatório (o caso que roda em produção — nada
  # seta slot_required:false ainda). Só a captura genuína que AVANÇA zera ai_slot_refusals; malformado
  # (confirmação-única) SEGURA; a alternância recusa/malformado passa a atingir o teto.
  describe '#track_step — Gap 3: reset do orçamento de recusas (slot inferido obrigatório)' do
    def idx
      conversation.reload.additional_attributes.to_h['ai_step_index']
    end

    def refusals
      conversation.reload.additional_attributes.to_h['ai_slot_refusals']
    end

    def collected_facts
      conversation.reload.additional_attributes.to_h['ai_collected_facts']
    end

    def inferred_dept(optional: false, turns: 3)
      step = { 'name' => 'Email', 'collect' => { 'attribute' => 'email_cliente' },
               'instructions' => 'Peça e grave o email_cliente conforme informado.' }
      step['slot_required'] = false if optional
      dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: "R#{SecureRandom.hex(3)}",
                                    status: 'active', behavior: {}, transfer_rules: { 'stuck_handoff_turns' => turns })
      dept.create_playbook!(active: true, steps: [step, { 'name' => 'Fim' }])
      dept
    end

    def set_refusals(n)
      a = conversation.additional_attributes || {}
      conversation.update!(additional_attributes: a.merge('ai_slot_refusals' => n))
    end

    # Devolve o SINAL do track_step (stuck_handoff quando atinge o teto).
    def run_turn(dept, attrs:, text:)
      pre = dept.playbook.steps[idx.to_i]
      msg = create(:message, conversation: conversation, account: account, inbox: inbox,
                             message_type: :incoming, content: text)
      decision = { 'attributes' => attrs, 'step_completed' => false }
      sig = manager.track_step(dept, decision, dispatcher: dispatcher, run: run, message_text: text, message: msg)
      manager.persist_attributes(decision['attributes'], dept, source: :supervisor, expected_step: pre)
      sig
    end

    def refuse(dept)
      run_turn(dept, attrs: { 'email_cliente' => 'não informado' }, text: 'não possuo')
    end

    def malformed(dept)
      run_turn(dept, attrs: { 'email_cliente' => 'joao arroba x' }, text: 'joao arroba x')
    end

    before { conversation.update!(additional_attributes: { 'ai_step_index' => 0 }) }

    # Acréscimo 1: malformado SEGURA — não zera E não incrementa; sequência só de malformados não transfere.
    it 'malformado (confirmação-única) SEGURA o orçamento: não zera nem incrementa, e não transfere' do
      dept = inferred_dept
      set_refusals(2)

      sig = malformed(dept)

      expect(refusals).to eq(2)     # segurou: nem 0 (não zerou) nem 3 (não incrementou)
      expect(sig).to be_nil         # confirmação-única não sinaliza handoff
      expect(idx).to eq(0)          # e não avançou (hold)
    end

    # Gap 4 v2: o malformado SEGURA a recusa (não zera nem incrementa) mas CONTA no absoluto. Como o teto de
    # recusa agora == o absoluto, a alternância transfere pelo ABSOLUTO (max_turns): o malformado dilui a
    # contagem de recusa mas não a de turnos. (Recusa consecutiva pura -> declined é o teste do bloco Gap 1.)
    it 'alternância recusa/malformado transfere pelo ABSOLUTO (max_turns); o malformado segura a recusa' do
      dept = inferred_dept(turns: 12) # absoluto 12 == teto de recusa 12
      5.times { refuse(dept) }        # absoluto 1..5, refusals 1..5
      malformed(dept)                 # absoluto 6, refusals SEGURA em 5 (hold)
      expect(refusals).to eq(5)
      sig = nil
      6.times { sig = refuse(dept) }  # absoluto 7..12 -> 12 dispara; refusals 6..11 (< 12)

      expect(sig[:stuck_handoff]).to include(reason: 'max_turns')
    end

    # Reset legítimo (Q2 caminho 1): captura genuína que avança zera o orçamento.
    it 'valor VÁLIDO avança e ZERA o orçamento (o reset legítimo)' do
      dept = inferred_dept(turns: 12) # teto de recusa 12: 2 recusas não transferem antes do valor válido
      refuse(dept); refuse(dept)
      expect(refusals).to eq(2)

      run_turn(dept, attrs: { 'email_cliente' => 'joao@x.com' }, text: 'joao@x.com')

      expect(collected_facts['email_cliente']).to eq('joao@x.com')
      expect(idx).to eq(1)      # avançou
      expect(refusals).to eq(0) # e zerou
    end

    # Acréscimo 2 — INVARIANTE: ao SAIR (avançar) de um slot obrigatório com o contador CHEIO, ele foi
    # zerado. Se um caminho de saída novo avançar sem zerar, este teste quebra (em vez de carry-over em prod).
    it 'INVARIANTE: avançar um slot obrigatório com o contador cheio => ai_slot_refusals foi zerado' do
      dept = inferred_dept
      set_refusals(3)

      run_turn(dept, attrs: { 'email_cliente' => 'joao@x.com' }, text: 'joao@x.com')

      expect(idx).to eq(1)      # saiu do slot (avançou)
      expect(refusals).to eq(0) # ...e o contador foi zerado nesse avanço
    end

    # Acréscimo 3 (ponta solta do Gap 2 FECHADA): opcional não-declinado NÃO zera o orçamento.
    it 'opcional inferido, turno não-declinado (:no_attempt) NÃO zera o orçamento' do
      dept = inferred_dept(optional: true)
      set_refusals(2)

      run_turn(dept, attrs: {}, text: 'e qual o horário de instalação?') # digressão -> :no_attempt

      expect(refusals).to eq(2) # segurou (não zerou sem avanço)
      expect(idx).to eq(0)
    end
  end

  # Gap 4: TETO ABSOLUTO de turnos por etapa (o campo da tela "travar por X mensagens"). Conta TODO turno
  # não-produtivo (recusa, :no_attempt, confirmação, vazio) -> ai_step_turns; é a ÚLTIMA rede, depois da
  # recusa. Pega o cliente que só faz PERGUNTAS (:no_attempt não tinha contador). Slot INFERIDO.
  describe '#track_step — Gap 4: teto absoluto de turnos por etapa' do
    def idx
      conversation.reload.additional_attributes.to_h['ai_step_index']
    end

    def turns
      conversation.reload.additional_attributes.to_h['ai_step_turns']
    end

    def refusals
      conversation.reload.additional_attributes.to_h['ai_slot_refusals']
    end

    def collected_facts
      conversation.reload.additional_attributes.to_h['ai_collected_facts']
    end

    def abs_dept(absolute)
      dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: "T#{SecureRandom.hex(3)}",
                                    status: 'active', behavior: {}, transfer_rules: { 'stuck_handoff_turns' => absolute })
      dept.create_playbook!(active: true, steps: [
                              { 'name' => 'Email', 'collect' => { 'attribute' => 'email_cliente' },
                                'instructions' => 'Peça e grave o email_cliente conforme informado.' },
                              { 'name' => 'Fim' }
                            ])
      dept
    end

    def run_turn(dept, attrs:, text:)
      pre = dept.playbook.steps[idx.to_i]
      msg = create(:message, conversation: conversation, account: account, inbox: inbox,
                             message_type: :incoming, content: text)
      sig = manager.track_step(dept, { 'attributes' => attrs, 'step_completed' => false },
                               dispatcher: dispatcher, run: run, message_text: text, message: msg)
      manager.persist_attributes(attrs, dept, source: :supervisor, expected_step: pre)
      sig
    end

    # slot e-mail (formato conhecido): 'qual o preço?' não tem '@' -> :no_attempt (não recusa).
    def question(dept)
      run_turn(dept, attrs: {}, text: 'qual o preço do plano?')
    end

    def decline(dept)
      run_turn(dept, attrs: {}, text: 'não tenho email')
    end

    before { conversation.update!(additional_attributes: { 'ai_step_index' => 0 }) }

    # O GANHO do Gap 4: o cliente que SÓ faz perguntas (:no_attempt não contava nada -> loop eterno) agora
    # é pego pelo teto absoluto e transferido.
    it 'só-perguntas (:no_attempt) conta no teto absoluto e transfere no limite -> reason max_turns' do
      dept = abs_dept(3)
      question(dept)
      question(dept)
      expect(turns).to eq(2)

      sig = question(dept) # 3 -> teto absoluto
      expect(sig[:stuck_handoff]).to include(reason: 'max_turns', turns: 3)
      expect(sig[:stuck_handoff]).not_to have_key(:refusals) # sem recusas no meio -> não carrega refusals
    end

    # Gap 4 v2: recusa consecutiva (declínio genuíno via SlotAbsence) dispara a rede de RECUSA com reason
    # 'declined' no limiar stuck_limit (== o absoluto), VENCENDO o empate (resolve_slot roda antes do absoluto).
    it 'recusas consecutivas -> declined (a recusa vence o empate com o absoluto)' do
      dept = abs_dept(12) # teto de recusa = 12 == absoluto = 12
      11.times { decline(dept) }
      sig = decline(dept) # 12ª recusa -> declined (não max_turns)

      expect(sig[:stuck_handoff]).to include(reason: 'declined', turns: 12)
    end

    # O CASO MISTO (achado do usuário): mais perguntas que recusas. O absoluto sobe todo turno; as recusas
    # (< ceiling) não disparam a rede de recusa. Então quem dispara é o max_turns — mas carrega refusals: N
    # para a telemetria de "quais etapas travam mais" não sumir com as recusas do meio. Escolha DELIBERADA.
    it 'MISTO (mais perguntas que recusas): dispara max_turns com refusals: N junto (telemetria preservada)' do
      dept = abs_dept(10) # teto de recusa = 10 == absoluto = 10
      7.times { question(dept) }   # turns 1..7, refusals 0 (pergunta = :no_attempt)
      decline(dept)                # refusals 1, turns 8
      decline(dept)                # refusals 2, turns 9
      expect(refusals).to eq(2)

      sig = decline(dept)          # refusals 3 (< teto 10), turns 10 -> ABSOLUTO dispara
      expect(sig[:stuck_handoff]).to include(reason: 'max_turns', turns: 10, refusals: 3)
    end

    # Q4 / INVARIANTE: avançar (captura genuína) ZERA o contador absoluto. Se um caminho de saída novo
    # avançar sem zerar, este teste quebra em vez de o carry-over vazar para produção.
    it 'INVARIANTE: valor válido avança e ZERA ai_step_turns' do
      dept = abs_dept(10)
      question(dept)
      question(dept)
      expect(turns).to eq(2)

      run_turn(dept, attrs: { 'email_cliente' => 'joao@x.com' }, text: 'joao@x.com')

      expect(collected_facts['email_cliente']).to eq('joao@x.com')
      expect(idx).to eq(1)   # avançou
      expect(turns).to eq(0) # ...e o teto absoluto zerou
    end

    it 'stuck_handoff_turns = 0: teto absoluto DESLIGADO — perguntas nunca transferem' do
      dept = abs_dept(0)
      10.times { expect(question(dept)).to be_nil }
      expect(idx).to eq(0)
    end
  end

  # Gap 4 v2 (conserto conv 394): turno PRODUTIVO (pergunta legítima respondida) NÃO conta no teto
  # IMPRODUTIVO — vai p/ um teto de perguntas SEPARADO e maior (stuck_limit × 3). Silêncio/ruído conta.
  # Passa judge_result explicitamente (como o Gateway faz na :175) — é ele que traz o asks_about.
  describe '#track_step — Gap 4 v2: produtivo (pergunta) vs improdutivo no teto' do
    def st_idx; conversation.reload.additional_attributes.to_h['ai_step_index']; end
    def st_turns; conversation.reload.additional_attributes.to_h['ai_step_turns']; end
    def st_questions; conversation.reload.additional_attributes.to_h['ai_step_questions']; end

    def q_dept(stuck)
      dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: "Q#{SecureRandom.hex(3)}",
                                    status: 'active', behavior: {}, transfer_rules: { 'stuck_handoff_turns' => stuck })
      dept.create_playbook!(active: true, steps: [
                              { 'name' => 'Endereco', 'collect' => { 'attribute' => 'endereco_completo' },
                                'instructions' => 'Peça e grave o endereco_completo.' },
                              { 'name' => 'Fim' }
                            ])
      dept
    end

    def do_turn(dept, judge_result:, decision_kind: 'reply', text: 'msg')
      msg = create(:message, conversation: conversation, account: account, inbox: inbox,
                             message_type: :incoming, content: text)
      manager.track_step(dept, { 'decision' => decision_kind, 'step_completed' => false },
                         dispatcher: dispatcher, run: run, message_text: text, message: msg, judge_result: judge_result)
    end

    # Pergunta legítima respondida = juiz diz asks_about != 'nada' + decisão reply.
    def ask(dept, asks: 'produto')
      do_turn(dept, judge_result: { status: 'not_an_answer', asks_about: asks, query: 'x' }, text: 'qual o preço?')
    end

    # Improdutivo = silêncio/ruído (juiz asks_about 'nada').
    def noise(dept)
      do_turn(dept, judge_result: { status: 'not_an_answer', asks_about: 'nada', query: '' }, text: '???')
    end

    before do
      profile.update!(worker_overrides: { 'capture_judge' => { 'mode' => 'when_silent' } }) # juiz ON: asks_about existe
      conversation.update!(additional_attributes: { 'ai_step_index' => 0 })
    end

    # O CONSERTO da 394: cliente que só se informa não é transferido. Alvo da prova de mutação por nome.
    it '394: 3 perguntas respondidas na MESMA etapa NÃO transferem (produtivo não conta no teto improdutivo)' do
      dept = q_dept(3)
      3.times { expect(ask(dept)).to be_nil }

      expect(st_turns).to be_nil       # teto IMPRODUTIVO intacto
      expect(st_questions).to eq(3)    # contadas no teto de PERGUNTAS (folgado: 3×3=9)
      expect(st_idx.to_i).to eq(0)     # não avançou, não transferiu
    end

    it 'oposto: 3 turnos improdutivos (silêncio) atingem o teto -> max_turns' do
      dept = q_dept(3)
      noise(dept); noise(dept)
      sig = noise(dept) # 3 -> teto improdutivo

      expect(sig[:stuck_handoff]).to include(reason: 'max_turns', turns: 3)
      expect(st_questions).to be_nil # nada foi produtivo
    end

    it 'KB vazio / qualquer asks_about != nada é PRODUTIVO (não depende de achar conhecimento)' do
      dept = q_dept(3)
      ask(dept, asks: 'faq') # FAQ, mesmo que o KB não devolvesse nada -> ainda produtivo

      expect(st_turns).to be_nil
      expect(st_questions).to eq(1)
    end

    it 'brecha fechada: perguntas até o teto de PERGUNTAS (stuck_limit × 3) -> max_questions' do
      dept = q_dept(2) # teto de perguntas = 2×3 = 6
      5.times { expect(ask(dept)).to be_nil }
      sig = ask(dept) # 6ª -> teto de perguntas

      expect(sig[:stuck_handoff]).to include(reason: 'max_questions', turns: 6)
      expect(st_turns).to be_nil # o teto improdutivo nunca subiu
    end

    it 'INVARIANTE: captura genuína (avanço) ZERA os dois contadores' do
      dept = q_dept(3)
      ask(dept); noise(dept)
      expect(st_questions).to eq(1)
      expect(st_turns).to eq(1)

      do_turn(dept, judge_result: { status: 'answered', value: 'Rua X, 100', asks_about: 'nada', query: '' },
                    text: 'Rua X, 100')

      expect(st_idx.to_i).to eq(1)       # avançou
      expect(st_turns.to_i).to eq(0)     # zerou
      expect(st_questions.to_i).to eq(0)
    end
  end

  # (b)-core — conclude_ready?: os slots OBRIGATÓRIOS ATÉ o índice preenchidos (ABSENT-aware); opcional NÃO
  # gateia; obrigatório DEPOIS do índice NÃO gateia (fronteira ≤ índice = conclusão de ramo). Private -> send.
  describe '#conclude_ready? (fronteira ≤ índice, ABSENT-aware)' do
    let(:manager) { described_class.new(conversation: conversation, agent: agent) }
    let(:steps) do
      [
        { 'name' => 'A', 'collect' => { 'attribute' => 'nome', 'required' => true } },   # 0: obrigatório
        { 'name' => 'B', 'collect' => { 'attribute' => 'email', 'required' => false } }, # 1: opcional
        { 'name' => 'Fim', 'on_complete' => { 'action' => 'handoff_human', 'team_id' => 1 } }, # 2: terminal
        { 'name' => 'Depois', 'collect' => { 'attribute' => 'cpf', 'required' => true } }  # 3: obrigatório DEPOIS
      ]
    end

    def ready?(facts)
      conversation.update!(additional_attributes: { 'ai_collected_facts' => facts })
      manager.send(:conclude_ready?, steps, 2, steps[2])
    end

    it 'obrigatórios ≤ índice preenchidos -> true (opcional e obrigatório-DEPOIS não gateiam)' do
      expect(ready?({ 'nome' => 'João' })).to be(true)
    end

    it 'obrigatório ≤ índice vazio -> false' do
      expect(ready?({})).to be(false)
    end

    it 'obrigatório ≤ índice com token ABSENT -> false (ABSENT bloqueia obrigatório)' do
      expect(ready?({ 'nome' => Ai::StepSlot::ABSENT })).to be(false)
    end

    it 'opcional ABSENT não bloqueia -> true (conta como preenchido)' do
      expect(ready?({ 'nome' => 'João', 'email' => Ai::StepSlot::ABSENT })).to be(true)
    end

    it 'etapa corrente SEM on_complete -> false (guarda: nunca conclui fora do contrato)' do
      conversation.update!(additional_attributes: { 'ai_collected_facts' => { 'nome' => 'João' } })
      expect(manager.send(:conclude_ready?, steps, 0, steps[0])).to be(false)
    end
  end

  # Wrapper público usado pela 3ª guarda do TrivialTurnGate: resolve a etapa corrente (ai_step_index) e
  # delega ao conclude_ready?. on_complete 'close' (sem team_id) p/ não acionar a validação H6 no save.
  describe '#conclude_ready_for_current? (wrapper do TrivialTurnGate)' do
    let(:dept) do
      d = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'W', status: 'active', behavior: {})
      d.create_playbook!(active: true, steps: [
                           { 'name' => 'Nome', 'collect' => { 'attribute' => 'nome', 'required' => true } }, # 0
                           { 'name' => 'Fim', 'on_complete' => { 'action' => 'close' } }                     # 1 terminal
                         ])
      d
    end

    def at_index(index, facts)
      conversation.update!(additional_attributes: { 'ai_step_index' => index, 'ai_collected_facts' => facts })
    end

    it 'na etapa terminal (índice 1) + obrigatório preenchido -> true' do
      at_index(1, { 'nome' => 'João' })
      expect(manager.conclude_ready_for_current?(dept)).to be(true)
    end

    it 'na etapa terminal mas obrigatório anterior VAZIO -> false' do
      at_index(1, {})
      expect(manager.conclude_ready_for_current?(dept)).to be(false)
    end

    it 'fora da etapa terminal (índice 0, ainda tem slot) -> false' do
      at_index(0, { 'nome' => 'João' })
      expect(manager.conclude_ready_for_current?(dept)).to be(false)
    end
  end
end
