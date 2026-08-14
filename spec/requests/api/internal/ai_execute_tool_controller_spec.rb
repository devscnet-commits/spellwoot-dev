require 'rails_helper'

# Cenário 2 (execução) e Cenário 3 (segurança) da ponte Python -> Rails: simula o webhook que o
# orquestrador Python chama de volta para executar uma tool Rails-side, sem subir o Python real.
RSpec.describe 'Api::Internal::AiExecuteToolController', type: :request do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:operation_profile) do
    Ai::OperationProfile.create!(account: account, name: 'padrão', supervisor_provider: 'openai', supervisor_model: 'gpt-4o')
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Assistente', ai_operation_profile_id: operation_profile.id) }
  let(:department) { Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Comercial') }
  let!(:tool) do
    Ai::Tool.create!(account: account, ai_department_id: department.id, name: 'conversation.add_label',
                     implementation_type: 'capability', capability_key: 'conversation.add_label', status: 'active')
  end
  let(:correct_token) { 'internal-test-token' }

  # Nome SANITIZADO — é isto que o Python realmente manda (Ai::PythonOrchestratorClient sanitiza todo
  # nome de tool antes de chegar na OpenAI; ver Ai::ToolNameSanitizer). O tool real no banco continua
  # com o ponto ('conversation.add_label') — o controller precisa resolver um pro outro.
  def call_webhook(headers: {})
    with_modified_env INTERNAL_AI_TOKEN: correct_token do
      post '/api/internal/ai_execute_tool',
           params: { ticket_id: conversation.id, ai_department_id: department.id, tool_name: 'conversation_add_label',
                      arguments: { label: 'Cliente em Negociação' }, mode: 'live' },
           headers: headers, as: :json
    end
  end

  describe 'POST /api/internal/ai_execute_tool' do
    context 'com o Bearer token correto (chamada simulada do Python pedindo o nome SANITIZADO conversation_add_label)' do
      it 'resolve "conversation_add_label" -> "conversation.add_label" e executa via Ai::ToolExecutor, devolve { result: ... }' do
        call_webhook(headers: { 'Authorization' => "Bearer #{correct_token}" })

        expect(response).to have_http_status(:success)
        # a etiqueta foi realmente persistida na conversa (não só "intencionada")
        expect(conversation.reload.label_list).to include('Cliente em Negociação')

        json = response.parsed_body
        expect(json['status']).to eq('executed')
        expect(json['result']).to be_present
        expect(json['result']['labels']).to include('Cliente em Negociação')
      end

      it 'tool desconhecida (não é controle, capture nem tool real — nem sanitizada nem não) devolve 404' do
        with_modified_env INTERNAL_AI_TOKEN: correct_token do
          post '/api/internal/ai_execute_tool',
               params: { ticket_id: conversation.id, ai_department_id: department.id, tool_name: 'tool_que_nao_existe',
                          arguments: {}, mode: 'live' },
               headers: { 'Authorization' => "Bearer #{correct_token}" }, as: :json
        end

        expect(response).to have_http_status(:not_found)
      end
    end

    def call_tool(tool_name, arguments: {}, mode: 'live')
      with_modified_env INTERNAL_AI_TOKEN: correct_token do
        post '/api/internal/ai_execute_tool',
             params: { ticket_id: conversation.id, ai_department_id: department.id, tool_name: tool_name,
                        arguments: arguments, mode: mode },
             headers: { 'Authorization' => "Bearer #{correct_token}" }, as: :json
      end
    end

    context 'chamada de uma capture tool "registrar_*" (Ai::StepCaptureTool — etapa do playbook, não uma Ai::Tool real)' do
      before do
        Ai::Playbook.create!(department: department,
                             steps: [{ 'name' => 'Endereço', 'collect' => { 'attribute' => 'endereco', 'type' => 'text' } }])
      end

      it 'grava o valor em ai_collected_facts via Ai::StateManager, SEM criar uma Ai::CapabilityExecution' do
        expect { call_tool('registrar_endereco', arguments: { endereco: 'Rua X, 123' }) }
          .not_to change(Ai::CapabilityExecution, :count)

        expect(response).to have_http_status(:success)
        expect(conversation.reload.additional_attributes['ai_collected_facts']).to eq('endereco' => 'Rua X, 123')
        json = response.parsed_body
        expect(json['status']).to eq('executed')
        expect(json['result']).to eq('endereco' => 'Rua X, 123')
      end

      it 'upsert: chamar de novo com outro valor ATUALIZA (não duplica)' do
        call_tool('registrar_endereco', arguments: { endereco: 'Rua X, 123' })
        call_tool('registrar_endereco', arguments: { endereco: 'Rua Y, 456' })

        expect(conversation.reload.additional_attributes['ai_collected_facts']).to eq('endereco' => 'Rua Y, 456')
      end

      it 'em modo shadow, NÃO grava nada (mesmo gate de Ai::ToolExecutor)' do
        call_tool('registrar_endereco', arguments: { endereco: 'Rua X, 123' }, mode: 'shadow')

        expect(response).to have_http_status(:success)
        expect(response.parsed_body['status']).to eq('skipped')
        expect(conversation.reload.additional_attributes['ai_collected_facts']).to be_nil
      end
    end

    context 'chamada de "avancar_etapa" (avanço agentic — a IA decide, não um índice travado)' do
      before do
        Ai::Playbook.create!(department: department, steps: [
          { 'name' => 'Boas-vindas' },
          { 'name' => 'Endereço', 'collect' => { 'attribute' => 'endereco' } },
          { 'name' => 'Fim' }
        ])
      end

      it 'incrementa ai_step_index e zera ai_step_turns' do
        conversation.update!(additional_attributes: { 'ai_step_index' => 0, 'ai_step_turns' => 3 })

        call_tool('avancar_etapa')

        expect(response).to have_http_status(:success)
        attrs = conversation.reload.additional_attributes
        expect(attrs['ai_step_index']).to eq(1)
        expect(attrs['ai_step_turns']).to eq(0)
        expect(response.parsed_body['status']).to eq('executed')
      end

      it 'trava na última etapa (não estoura o array)' do
        conversation.update!(additional_attributes: { 'ai_step_index' => 2 })

        call_tool('avancar_etapa')

        expect(conversation.reload.additional_attributes['ai_step_index']).to eq(2)
      end

      it 'em modo shadow, não avança nada' do
        conversation.update!(additional_attributes: { 'ai_step_index' => 0 })

        call_tool('avancar_etapa', mode: 'shadow')

        expect(conversation.reload.additional_attributes['ai_step_index']).to eq(0)
        expect(response.parsed_body['status']).to eq('skipped')
      end
    end

    # REPRODUÇÃO — bug ticket 557 (achado 13/08, patch escrito depois de confirmar contra o código
    # atual): #advance_step avança por ÍNDICE puro (current_index + 1), sem checar se a etapa que está
    # sendo deixada tem o dado obrigatório (step['collect']['attribute']) em ai_collected_facts.
    # Ai::StateManager#track_step — que faria essa validação (toda a máquina de recusa de slot, Gap
    # 1-4) — só é chamado pelo Ai::Gateway#run LEGADO, deletado na eliminação de hoje; o caminho
    # Python nunca passou por ali.
    #
    # Invariante implementado (#missing_required_attributes + varredura em #advance_step):
    #   current_step = steps[index]
    #   se current_step exige collect/required E o dado não está em ai_collected_facts
    #     -> NÃO altera ai_step_index (se for a etapa de PARTIDA), status 'blocked_missing_data'
    #   se o requisito da etapa atual está satisfeito -> avança, e CONTINUA avançando através de
    #     quantas etapas seguintes JÁ estiverem satisfeitas na mesma chamada (varredura — cliente que
    #     adianta várias respostas não fica preso etapa por etapa), parando na primeira insatisfeita
    #   se não há requisito aplicável na etapa atual -> comportamento atual, sem mudança (já coberto
    #     pelos 8 testes acima, que continuam passando)
    context 'validação de dado obrigatório antes de avançar (bug ticket 557)' do
      before do
        Ai::Playbook.create!(department: department, steps: [
          { 'name' => 'nome_cliente', 'collect' => { 'attribute' => 'nome_cliente' } },
          { 'name' => 'cidade', 'collect' => { 'attribute' => 'cidade' } },
          { 'name' => 'escolha_caminho', 'collect' => { 'attribute' => 'escolha_caminho' } },
          { 'name' => 'tamanho_imovel', 'collect' => { 'attribute' => 'tamanho_imovel' } },
          { 'name' => 'aparelhos_conectados', 'collect' => { 'attribute' => 'aparelhos_conectados' } },
          { 'name' => 'mostrar_planos' }
        ])
      end

      def with_facts(facts)
        conversation.update!(additional_attributes: (conversation.additional_attributes || {})
          .merge('ai_collected_facts' => facts))
      end

      # Cenário A — reprodução exata do ticket 557: nome_cliente e cidade já foram adiantados/
      # capturados (front-loaded), escolha_caminho/tamanho_imovel/aparelhos_conectados NUNCA foram
      # perguntados. UMA chamada de avancar_etapa varre nome_cliente E cidade (ambos já satisfeitos) e
      # trava exatamente em escolha_caminho — nunca chega em mostrar_planos, nem insistindo depois.
      it 'A: uma chamada varre nome_cliente+cidade (dado presente) e trava em escolha_caminho (dado ausente), mesmo insistindo' do
        with_facts('nome_cliente' => 'Jaqueline', 'cidade' => 'Maravilha')
        conversation.update!(additional_attributes: conversation.additional_attributes.merge('ai_step_index' => 0))

        call_tool('avancar_etapa') # varre nome_cliente(0) + cidade(1), trava em escolha_caminho(2)
        expect(conversation.reload.additional_attributes['ai_step_index']).to eq(2)
        expect(response.parsed_body['status']).to eq('executed') # houve progresso real (0 -> 2)

        call_tool('avancar_etapa') # escolha_caminho SEM dado, e é a etapa de PARTIDA agora -> bloqueia
        expect(conversation.reload.additional_attributes['ai_step_index']).to eq(2)
        expect(response.parsed_body['status']).to eq('blocked_missing_data')

        call_tool('avancar_etapa') # insistir de novo não deveria empurrar pra frente
        expect(conversation.reload.additional_attributes['ai_step_index']).to eq(2)
        expect(response.parsed_body['status']).to eq('blocked_missing_data')
      end

      # Cenário B — separa "o modelo PEDIU" de "o sistema APLICOU". B1 (orchestrator.py, decisão do
      # modelo é sempre repassada) fica no pytest do ai-orchestrator. Aqui (B2, lado Rails): o webhook
      # recebe o pedido normalmente (sucesso HTTP, não é rejeitado/autenticação/erro de transporte) —
      # é o BACKEND que decide não aplicar, não uma falha da chamada em si.
      it 'B2: o pedido do modelo chega e é processado (sucesso HTTP) mesmo quando o backend não aplica o avanço' do
        with_facts({}) # nome_cliente ausente
        conversation.update!(additional_attributes: conversation.additional_attributes.merge('ai_step_index' => 0))

        call_tool('avancar_etapa')

        expect(response).to have_http_status(:success) # pedido RECEBIDO e processado, não um erro
        expect(response.parsed_body['status']).to eq('blocked_missing_data') # mas NÃO aplicado
        expect(conversation.reload.additional_attributes['ai_step_index']).to eq(0)
      end

      # Cenário C — dado ERRADO na etapa errada: existe dado em ai_collected_facts, mas não é o dado
      # que a etapa ATUAL pede. Garante que o patch valida o campo CERTO (step['collect']['attribute']
      # da etapa atual), não "qualquer coisa presente em ai_collected_facts". Quando nome_cliente
      # finalmente aparece, a varredura TAMBÉM pega cidade (já presente desde o início) na mesma
      # chamada — não para em cidade esperando outra chamada.
      it 'C: cidade presente não satisfaz a etapa nome_cliente — só nome_cliente aparecendo libera o avanço (e varre cidade também)' do
        with_facts('cidade' => 'Maravilha') # sem nome_cliente
        conversation.update!(additional_attributes: conversation.additional_attributes.merge('ai_step_index' => 0))

        call_tool('avancar_etapa')

        expect(conversation.reload.additional_attributes['ai_step_index']).to eq(0) # não avançou
        expect(response.parsed_body['status']).to eq('blocked_missing_data')

        with_facts('cidade' => 'Maravilha', 'nome_cliente' => 'Jaqueline') # agora sim, o dado CERTO chegou
        call_tool('avancar_etapa')

        expect(conversation.reload.additional_attributes['ai_step_index']).to eq(2) # varreu cidade também
        expect(response.parsed_body['status']).to eq('executed')
      end

      # Múltiplos campos obrigatórios na MESMA etapa: mesmo que o playbook de hoje não use isso (cada
      # etapa só tem 1 collect.attribute na tela), o código tem que exigir TODOS, não só o primeiro —
      # Array() em collect.attribute aceita string OU array sem precisar de um campo novo no schema.
      it 'etapa com múltiplos campos obrigatórios (collect.attribute como array): só A presente NÃO libera — precisa de A e B' do
        department.playbook.update!(steps: [
          { 'name' => 'dados_duplos', 'collect' => { 'attribute' => %w[nome_cliente cidade] } },
          { 'name' => 'fim' }
        ])
        with_facts('nome_cliente' => 'Jaqueline') # falta cidade
        conversation.update!(additional_attributes: conversation.additional_attributes.merge('ai_step_index' => 0))

        call_tool('avancar_etapa')
        expect(conversation.reload.additional_attributes['ai_step_index']).to eq(0)
        expect(response.parsed_body['status']).to eq('blocked_missing_data')

        with_facts('nome_cliente' => 'Jaqueline', 'cidade' => 'Maravilha') # agora os DOIS
        call_tool('avancar_etapa')
        expect(conversation.reload.additional_attributes['ai_step_index']).to eq(1)
        expect(response.parsed_body['status']).to eq('executed')
      end

      # Varredura através de MAIS de 2 etapas numa chamada só (cliente adianta 3 respostas de uma vez):
      # nome_cliente sem dado seria bloqueado, então parte de index 1 (cidade) já satisfeito, com
      # escolha_caminho/tamanho_imovel TAMBÉM já adiantados — uma chamada varre os 3 e trava em
      # aparelhos_conectados (o único ainda sem dado).
      it 'varre 3 etapas seguintes já satisfeitas numa chamada só (cliente adiantou tudo de uma vez)' do
        with_facts('cidade' => 'Maravilha', 'escolha_caminho' => 'compra', 'tamanho_imovel' => '120m2')
        conversation.update!(additional_attributes: conversation.additional_attributes.merge('ai_step_index' => 1))

        call_tool('avancar_etapa')

        expect(conversation.reload.additional_attributes['ai_step_index']).to eq(4) # aparelhos_conectados
        expect(response.parsed_body['status']).to eq('executed')
      end

      # Item 5 — decisão CONFIRMADA (não é mais assunção pendente): campo opcional (slot_required:
      # false) NUNCA trava o avanço, esteja o dado presente ou não — cliente respondeu (salva, fora do
      # escopo de advance_step) ou não respondeu / disse "prefiro não informar" (tanto faz, sem sinal
      # novo do modelo pra distinguir os dois casos), a etapa segue de qualquer jeito.
      context 'campo opcional (slot_required: false) — item 5, decisão confirmada' do
        before do
          department.playbook.update!(steps: [
            { 'name' => 'telefone_secundario', 'collect' => { 'attribute' => 'telefone_secundario' },
              'slot_required' => false },
            { 'name' => 'fim' }
          ])
          conversation.update!(additional_attributes: conversation.additional_attributes.to_h.merge('ai_step_index' => 0))
        end

        it 'cliente NÃO respondeu (dado ausente): avança normalmente mesmo assim' do
          with_facts({}) # telefone_secundario ausente — nunca perguntado ou ignorado, tanto faz

          call_tool('avancar_etapa')

          expect(conversation.reload.additional_attributes['ai_step_index']).to eq(1)
          expect(response.parsed_body['status']).to eq('executed')
        end

        it 'cliente disse explicitamente "prefiro não informar" (mesmo efeito: dado ausente): avança normalmente' do
          # Não existe sinal distinto de "recusa explícita" vs "nunca perguntado" no contrato hoje — os
          # dois chegam aqui do MESMO jeito (chave ausente de ai_collected_facts). O teste documenta que
          # isso é intencional: slot opcional não precisa distinguir os dois casos pra decidir avançar.
          with_facts({})

          call_tool('avancar_etapa')

          expect(conversation.reload.additional_attributes['ai_step_index']).to eq(1)
          expect(response.parsed_body['status']).to eq('executed')
        end

        it 'cliente respondeu (dado presente): avança normalmente também — não é bloqueio condicional' do
          with_facts('telefone_secundario' => '(49) 99999-0000')

          call_tool('avancar_etapa')

          expect(conversation.reload.additional_attributes['ai_step_index']).to eq(1)
          expect(response.parsed_body['status']).to eq('executed')
        end
      end
    end

    # Gap achado em auditoria (13/08): on_complete (desfecho declarado NA ETAPA — "Encerrar o
    # atendimento") nunca era lido no caminho Python; avancar_etapa só incrementava o índice, o
    # desfecho configurado nunca disparava. Espelha Ai::Gateway#force_conclusion (motor legado).
    context 'chamada de "avancar_etapa" numa etapa com on_complete declarado (desfecho, não índice)' do
      let!(:incoming_message) do
        create(:message, account: account, inbox: conversation.inbox, conversation: conversation, message_type: 'incoming')
      end

      it 'action=close: resolve a conversa, SEM avançar o índice' do
        Ai::Playbook.create!(department: department, steps: [
          { 'name' => 'Finalização', 'on_complete' => { 'action' => 'close' } }
        ])
        conversation.update!(additional_attributes: { 'ai_step_index' => 0 }, status: 'open')

        call_tool('avancar_etapa')

        expect(response).to have_http_status(:success)
        expect(conversation.reload.status).to eq('resolved')
        expect(conversation.additional_attributes['ai_step_index']).to eq(0) # NÃO foi um avanço de índice normal
        expect(response.parsed_body['result']['conclusion']).to eq('close')
      end

      it 'action=handoff_human (default): transfere e atribui, SEM avançar o índice' do
        team = create(:team, account: account)
        create(:team_member, team: team, user: create(:user, account: account))
        agent.update!(handoff_team_ids: [team.id])
        department.reload # limpa a associação :agent memoizada — a validação do Playbook precisa ver o update acima
        Ai::Playbook.create!(department: department, steps: [
          { 'name' => 'Finalização', 'on_complete' => { 'action' => 'handoff_human', 'team_id' => team.id } }
        ])
        conversation.update!(additional_attributes: { 'ai_step_index' => 0 }, status: 'open')

        call_tool('avancar_etapa')

        expect(response).to have_http_status(:success)
        expect(conversation.reload.additional_attributes['ai_handoff']).to eq(true) # assign_human rodou
        expect(conversation.team_id).to eq(team.id)
        expect(conversation.additional_attributes['ai_step_index']).to eq(0)
        expect(response.parsed_body['result']['conclusion']).to eq('handoff_human')
      end

      it 'action=handoff_ai: roteia pra outra IA (ai_routed_agent_id), SEM avançar o índice' do
        target_agent = Ai::Agent.create!(account: account, name: 'Vendas', status: 'active',
                                         ai_operation_profile_id: operation_profile.id)
        Ai::AgentInbox.create!(ai_agent_id: target_agent.id, inbox_id: conversation.inbox_id, mode: 'live', active: true)
        agent.update!(handoff_agent_ids: [target_agent.id])
        Ai::Playbook.create!(department: department, steps: [
          { 'name' => 'Finalização', 'on_complete' => { 'action' => 'handoff_ai', 'target' => 'Vendas' } }
        ])
        conversation.update!(additional_attributes: { 'ai_step_index' => 0 }, status: 'open')

        call_tool('avancar_etapa')

        expect(response).to have_http_status(:success)
        expect(conversation.reload.additional_attributes['ai_routed_agent_id']).to eq(target_agent.id)
        expect(conversation.additional_attributes['ai_step_index']).to eq(0)
        json = response.parsed_body
        expect(json['result']['conclusion']).to eq('handoff_ai')
        expect(json['result']['routed']).to eq(true)
      end

      it 'em modo shadow, NÃO executa o desfecho (mesmo gate live? das outras control tools)' do
        Ai::Playbook.create!(department: department, steps: [
          { 'name' => 'Finalização', 'on_complete' => { 'action' => 'close' } }
        ])
        conversation.update!(additional_attributes: { 'ai_step_index' => 0 }, status: 'open')

        call_tool('avancar_etapa', mode: 'shadow')

        expect(conversation.reload.status).to eq('open')
        expect(response.parsed_body['status']).to eq('skipped')
      end

      it 'etapa SEM on_complete continua avançando o índice normalmente (não regride o caminho comum)' do
        Ai::Playbook.create!(department: department, steps: [
          { 'name' => 'Boas-vindas' },
          { 'name' => 'Fim' }
        ])
        conversation.update!(additional_attributes: { 'ai_step_index' => 0 })

        call_tool('avancar_etapa')

        expect(conversation.reload.additional_attributes['ai_step_index']).to eq(1)
        expect(response.parsed_body['result']['conclusion']).to be_nil
      end
    end

    # Achado 14/08 (auditoria, item 2.3): nenhum teste cobria o que acontece se a IA chama
    # "avancar_etapa" DE NOVO depois que on_complete já disparou — ai_step_index nunca avança pra
    # além da etapa de desfecho (por design, ver os testes acima), então nada no código impede
    # execute_step_conclusion de rodar uma SEGUNDA vez pro mesmo turno de conclusão. EXPLORATÓRIO:
    # sem asserção de "certo/errado" fixada a priori — observa o resultado real (erro, duplicação de
    # side effect, ou no-op) pra decidir DEPOIS se precisa de guard.
    context 'EXPLORATÓRIO: chamar "avancar_etapa" DE NOVO depois que on_complete já disparou (achado 2.3)' do
      let!(:incoming_message) do
        create(:message, account: account, inbox: conversation.inbox, conversation: conversation, message_type: 'incoming')
      end

      it 'action=close chamado duas vezes: observa se a 2ª chamada erra, duplica ou é no-op' do
        Ai::Playbook.create!(department: department, steps: [
          { 'name' => 'Finalização', 'on_complete' => { 'action' => 'close' } }
        ])
        conversation.update!(additional_attributes: { 'ai_step_index' => 0 }, status: 'open')

        call_tool('avancar_etapa')
        first_status = response.status
        first_body = response.parsed_body

        call_tool('avancar_etapa')
        second_status = response.status
        second_body = response.parsed_body

        puts "\n[EXPLORATÓRIO close] 1ª chamada: HTTP #{first_status} #{first_body.inspect}"
        puts "[EXPLORATÓRIO close] 2ª chamada: HTTP #{second_status} #{second_body.inspect}"
        puts "[EXPLORATÓRIO close] conversation.status final: #{conversation.reload.status.inspect}"
        puts "[EXPLORATÓRIO close] Ai::CapabilityExecution count: #{Ai::CapabilityExecution.where(conversation: conversation).count}"
      end

      it 'action=handoff_human chamado duas vezes: observa se reatribui/reexecuta assign_human' do
        team = create(:team, account: account)
        create(:team_member, team: team, user: create(:user, account: account))
        agent.update!(handoff_team_ids: [team.id])
        department.reload
        Ai::Playbook.create!(department: department, steps: [
          { 'name' => 'Finalização', 'on_complete' => { 'action' => 'handoff_human', 'team_id' => team.id } }
        ])
        conversation.update!(additional_attributes: { 'ai_step_index' => 0 }, status: 'open')

        handoff_summary_job_count = -> { enqueued_jobs.count { |j| j[:job] == Ai::HandoffSummaryJob } }

        call_tool('avancar_etapa')
        first_status = response.status
        first_body = response.parsed_body
        first_assignee_id = conversation.reload.assignee_id
        jobs_after_first = handoff_summary_job_count.call

        call_tool('avancar_etapa')
        second_status = response.status
        second_body = response.parsed_body
        jobs_after_second = handoff_summary_job_count.call

        puts "\n[EXPLORATÓRIO handoff_human] 1ª chamada: HTTP #{first_status} #{first_body.inspect}"
        puts "[EXPLORATÓRIO handoff_human] assignee após 1ª: #{first_assignee_id.inspect}"
        puts "[EXPLORATÓRIO handoff_human] Ai::HandoffSummaryJob enfileirados após 1ª: #{jobs_after_first}"
        puts "[EXPLORATÓRIO handoff_human] 2ª chamada: HTTP #{second_status} #{second_body.inspect}"
        puts "[EXPLORATÓRIO handoff_human] assignee após 2ª: #{conversation.reload.assignee_id.inspect}"
        puts "[EXPLORATÓRIO handoff_human] Ai::HandoffSummaryJob enfileirados após 2ª: #{jobs_after_second}"
        puts "[EXPLORATÓRIO handoff_human] team_id final: #{conversation.reload.team_id.inspect}"
      end

      # Segundo membro no time: se assign_human reassinala de verdade a cada chamada (em vez de ser
      # no-op quando já atribuído), a 2ª chamada pode trocar o assignee mesmo sem nenhum gatilho novo —
      # diferente do teste acima (1 membro só), onde "mesmo assignee" nas duas chamadas não prova nada.
      it 'action=handoff_human com DOIS membros no time: observa se a 2ª chamada troca o assignee sem motivo' do
        team = create(:team, account: account)
        member_a = create(:user, account: account)
        member_b = create(:user, account: account)
        create(:team_member, team: team, user: member_a)
        create(:team_member, team: team, user: member_b)
        agent.update!(handoff_team_ids: [team.id])
        department.reload
        Ai::Playbook.create!(department: department, steps: [
          { 'name' => 'Finalização', 'on_complete' => { 'action' => 'handoff_human', 'team_id' => team.id } }
        ])
        conversation.update!(additional_attributes: { 'ai_step_index' => 0 }, status: 'open')

        call_tool('avancar_etapa')
        first_assignee_id = conversation.reload.assignee_id

        call_tool('avancar_etapa')
        second_assignee_id = conversation.reload.assignee_id

        puts "\n[EXPLORATÓRIO handoff_human 2-membros] assignee após 1ª: #{first_assignee_id.inspect}"
        puts "[EXPLORATÓRIO handoff_human 2-membros] assignee após 2ª: #{second_assignee_id.inspect}"
        puts "[EXPLORATÓRIO handoff_human 2-membros] trocou? #{first_assignee_id != second_assignee_id}"
      end

      it 'action=handoff_ai chamado duas vezes: observa se reroteia (ai_routed_agent_id) sem erro' do
        target_agent = Ai::Agent.create!(account: account, name: 'Vendas', status: 'active',
                                         ai_operation_profile_id: operation_profile.id)
        Ai::AgentInbox.create!(ai_agent_id: target_agent.id, inbox_id: conversation.inbox_id, mode: 'live', active: true)
        agent.update!(handoff_agent_ids: [target_agent.id])
        Ai::Playbook.create!(department: department, steps: [
          { 'name' => 'Finalização', 'on_complete' => { 'action' => 'handoff_ai', 'target' => 'Vendas' } }
        ])
        conversation.update!(additional_attributes: { 'ai_step_index' => 0 }, status: 'open')

        call_tool('avancar_etapa')
        first_status = response.status
        first_body = response.parsed_body

        call_tool('avancar_etapa')
        second_status = response.status
        second_body = response.parsed_body

        puts "\n[EXPLORATÓRIO handoff_ai] 1ª chamada: HTTP #{first_status} #{first_body.inspect}"
        puts "[EXPLORATÓRIO handoff_ai] 2ª chamada: HTTP #{second_status} #{second_body.inspect}"
        puts "[EXPLORATÓRIO handoff_ai] ai_routed_agent_id final: #{conversation.reload.additional_attributes['ai_routed_agent_id'].inspect}"
      end
    end

    # Bug real ao vivo: a IA respondia só com texto e nunca chamava nenhuma tool, então o
    # ai_step_index nunca avançava. orchestrator.py passou a mandar tool_choice="required" — esta tool
    # é o escape-valve: um no-op puro pra quando a IA só quer falar (perguntar/cumprimentar/responder)
    # sem registrar dado nem avançar etapa. NUNCA toca o banco, em NENHUM modo.
    context 'chamada de "continuar_conversa" (no-op — sustenta tool_choice="required" no orchestrator.py)' do
      it 'devolve { result: "ok", status: "executed" } SEM tocar a conversa nem criar Ai::CapabilityExecution' do
        expect { call_tool('continuar_conversa') }
          .not_to change(Ai::CapabilityExecution, :count)

        expect(response).to have_http_status(:success)
        json = response.parsed_body
        expect(json['result']).to eq('ok')
        expect(json['status']).to eq('executed')
        expect(json['error']).to be_nil
      end

      it 'não muda additional_attributes (nem ai_step_index, nem ai_collected_facts)' do
        before_attrs = conversation.additional_attributes

        call_tool('continuar_conversa')

        expect(conversation.reload.additional_attributes).to eq(before_attrs)
      end

      # Diferente de avancar_etapa/registrar_*/salvar_memoria_ia (que "skipam" em shadow): não há
      # side effect nenhum a distinguir, então NÃO é gated por live/shadow — sempre "executed".
      it 'em modo shadow, ainda devolve "executed" (não há efeito colateral a distinguir)' do
        call_tool('continuar_conversa', mode: 'shadow')

        expect(response.parsed_body['status']).to eq('executed')
      end
    end

    context 'chamada de "salvar_memoria_ia" (catch-all de memória — híbrido com registrar_*)' do
      it 'grava chave/valor em ai_collected_facts via Ai::StateManager, SEM criar uma Ai::CapabilityExecution' do
        expect { call_tool('salvar_memoria_ia', arguments: { chave: 'nome_do_pet', valor: 'Rex' }) }
          .not_to change(Ai::CapabilityExecution, :count)

        expect(response).to have_http_status(:success)
        expect(conversation.reload.additional_attributes['ai_collected_facts']).to eq('nome_do_pet' => 'Rex')
        expect(response.parsed_body['status']).to eq('executed')
      end

      it 'upsert: chamar de novo com outro valor pra mesma chave ATUALIZA (não duplica)' do
        call_tool('salvar_memoria_ia', arguments: { chave: 'nome_do_pet', valor: 'Rex' })
        call_tool('salvar_memoria_ia', arguments: { chave: 'nome_do_pet', valor: 'Totó' })

        expect(conversation.reload.additional_attributes['ai_collected_facts']).to eq('nome_do_pet' => 'Totó')
      end

      it 'chave vazia/ausente não grava nada' do
        call_tool('salvar_memoria_ia', arguments: { valor: 'sem chave' })

        expect(response).to have_http_status(:success)
        expect(response.parsed_body['status']).to eq('skipped')
        expect(conversation.reload.additional_attributes['ai_collected_facts']).to be_nil
      end

      it 'em modo shadow, NÃO grava nada (mesmo gate de Ai::ToolExecutor)' do
        call_tool('salvar_memoria_ia', arguments: { chave: 'nome_do_pet', valor: 'Rex' }, mode: 'shadow')

        expect(response.parsed_body['status']).to eq('skipped')
        expect(conversation.reload.additional_attributes['ai_collected_facts']).to be_nil
      end

      it 'se a chave livre coincidir com um CustomAttributeDefinition real, espelha em custom_attributes igual a qualquer escrita :trusted (sem proteção especial)' do
        CustomAttributeDefinition.create!(account: account, attribute_key: 'cidade', attribute_display_name: 'Cidade',
                                          attribute_model: 'conversation_attribute', attribute_display_type: 'text')

        call_tool('salvar_memoria_ia', arguments: { chave: 'cidade', valor: 'Chapecó' })

        expect(conversation.reload.custom_attributes['cidade']).to eq('Chapecó')
      end
    end

    context 'chamada de "conversation.resolve"/"conversation.transfer" (tools de controle, sempre disponíveis)' do
      it 'conversation.resolve chama Ai::CapabilityRegistry e marca a conversa como resolvida' do
        call_tool('conversation_resolve')

        expect(response).to have_http_status(:success)
        expect(conversation.reload.status).to eq('resolved')
        expect(response.parsed_body['status']).to eq('executed')
      end

      it 'conversation.transfer chama Ai::CapabilityRegistry e reabre/desatribui a conversa' do
        conversation.update!(status: 'resolved', assignee_id: nil)

        call_tool('conversation_transfer')

        expect(response).to have_http_status(:success)
        expect(conversation.reload.status).to eq('open')
      end

      it 'conversation.transfer salva o handoff_summary da IA em additional_attributes' do
        call_tool('conversation_transfer', arguments: { handoff_summary: 'Cliente já forneceu nome e cidade, falta CPF' })

        expect(response).to have_http_status(:success)
        expect(conversation.reload.additional_attributes['handoff_summary'])
          .to eq('Cliente já forneceu nome e cidade, falta CPF')
      end

      it 'conversation.transfer sem handoff_summary (vazio/ausente) não grava nada, mas ainda transfere' do
        call_tool('conversation_transfer', arguments: {})

        expect(response).to have_http_status(:success)
        expect(conversation.reload.additional_attributes['handoff_summary']).to be_nil
      end

      it 'em modo shadow, não salva handoff_summary nem transfere (mesmo gate de live?)' do
        call_tool('conversation_transfer', arguments: { handoff_summary: 'não deveria salvar' }, mode: 'shadow')

        expect(conversation.reload.additional_attributes['handoff_summary']).to be_nil
        expect(response.parsed_body['status']).to eq('skipped')
      end

      # BUG achado ao vivo (13/08, conv 556): "transferir_humano": true no meio da conversa (não via
      # on_complete) executava a capability (status executed, sem erro) mas NUNCA fazia o handoff de
      # verdade — sem Ai::HandoffCoordinator#assign_human, additional_attributes['ai_handoff'] nunca
      # era setado, e é essa flag que Ai::ReplyPolicy#effective_reply_state lê pra parar de responder
      # (reply_policy.rb:45). Resultado real: a IA seguia respondendo normalmente nos turnos seguintes,
      # como se a transferência nunca tivesse acontecido.
      it 'marca ai_handoff (o que realmente para a IA de responder — Ai::ReplyPolicy) e desatribui a conversa' do
        conversation.update!(assignee_id: create(:user, account: account).id)

        call_tool('conversation_transfer', arguments: { handoff_summary: 'Cliente quer falar com atendente' })

        expect(response.parsed_body['status']).to eq('executed')
        conversation.reload
        expect(conversation.additional_attributes['ai_handoff']).to be true
        expect(conversation.assignee_id).to be_nil
        expect(Ai::ReplyPolicy.effective_reply_state(mode: 'live', department: department, conversation: conversation))
          .not_to eq(:live)
      end

      it 'em modo shadow, nenhuma das duas muda a conversa' do
        call_tool('conversation_resolve', mode: 'shadow')

        expect(conversation.reload.status).to eq('open')
        expect(response.parsed_body['status']).to eq('skipped')
      end
    end

    # RAG agentic: a IA chama esta tool NO MEIO do turno (function-calling de verdade, ver comentário de
    # Ai::PythonOrchestratorClient#knowledge_tool) — o resultado tem que voltar como function_call_output
    # pra ela ler ANTES de montar a resposta final. Sem gate por etapa, sem query/tipo pré-configurado.
    context 'chamada de "consultar_conhecimento" (RAG agentic — tool real, sempre disponível)' do
      it 'devolve os trechos encontrados, SEM criar Ai::CapabilityExecution' do
        allow(Ai::KnowledgeRetriever).to receive(:retrieve)
          .with(query: 'quanto custa o plano fibra?', account_id: account.id, department_id: department.id)
          .and_return(['Plano Fibra 500MB: R$ 99,90/mês'])

        expect { call_tool('consultar_conhecimento', arguments: { pergunta: 'quanto custa o plano fibra?' }) }
          .not_to change(Ai::CapabilityExecution, :count)

        expect(response).to have_http_status(:success)
        json = response.parsed_body
        expect(json['status']).to eq('executed')
        expect(json['result']['encontrado']).to be true
        expect(json['result']['conteudo']).to include('Plano Fibra 500MB: R$ 99,90/mês')
      end

      # Fecha o gap identificado: base vazia devolve uma RESPOSTA que a IA precisa processar (um
      # function_call_output real), nunca um bloco de prompt silenciosamente ausente.
      it 'sem resultado, devolve "encontrado: false" com uma mensagem explícita — nunca silêncio' do
        allow(Ai::KnowledgeRetriever).to receive(:retrieve).and_return([])

        call_tool('consultar_conhecimento', arguments: { pergunta: 'algo que não existe na base' })

        expect(response).to have_http_status(:success)
        json = response.parsed_body
        expect(json['status']).to eq('executed')
        expect(json['result']['encontrado']).to be false
        expect(json['result']['conteudo']).to eq('Nada encontrado na base de conhecimento para essa pergunta.')
      end

      it 'pergunta vazia/ausente não busca nada' do
        call_tool('consultar_conhecimento', arguments: {})

        expect(response.parsed_body['status']).to eq('skipped')
      end

      # Leitura pura, sem efeito colateral: diferente de registrar_*/avancar_etapa/conversation.transfer,
      # roda IGUAL em shadow — shadow existe pra proteger contra ESCRITA vazando pra conversa real, não
      # pra impedir a IA de ler a base de conhecimento durante uma avaliação/piloto.
      it 'em modo shadow, ainda busca e devolve o resultado normalmente' do
        allow(Ai::KnowledgeRetriever).to receive(:retrieve).and_return(['Plano X: R$ 50/mês'])

        call_tool('consultar_conhecimento', arguments: { pergunta: 'plano x' }, mode: 'shadow')

        expect(response.parsed_body['status']).to eq('executed')
        expect(response.parsed_body['result']['conteudo']).to include('Plano X: R$ 50/mês')
      end

      # Antes: uma falha aqui subia como 500 cru pro Python (sem rescue nenhum em #search_knowledge),
      # travando o turno inteiro em vez de deixar a IA seguir a conversa. Equivalente ao knowledge_timeout
      # do motor legado (Ai::Run::ERROR_TYPES ainda lista a categoria).
      it 'timeout na busca: NÃO sobe 500 — devolve status failed com a categoria "knowledge_timeout"' do
        allow(Ai::KnowledgeRetriever).to receive(:retrieve).and_raise(Net::ReadTimeout, 'execution expired')

        call_tool('consultar_conhecimento', arguments: { pergunta: 'quanto custa o plano fibra?' })

        expect(response).to have_http_status(:success)
        json = response.parsed_body
        expect(json['status']).to eq('failed')
        expect(json['error']).to eq('knowledge_timeout')
      end

      it 'erro genérico (não-timeout) na busca: status failed com a categoria "knowledge_search_failed"' do
        allow(Ai::KnowledgeRetriever).to receive(:retrieve).and_raise(StandardError, 'embedding provider 500')

        call_tool('consultar_conhecimento', arguments: { pergunta: 'quanto custa o plano fibra?' })

        expect(response).to have_http_status(:success)
        json = response.parsed_body
        expect(json['status']).to eq('failed')
        expect(json['error']).to eq('knowledge_search_failed')
      end
    end

    context 'validação de segurança do webhook' do
      it 'retorna 401 quando nenhum Bearer token é enviado' do
        call_webhook(headers: {})

        expect(response).to have_http_status(:unauthorized)
        expect(conversation.reload.label_list).not_to include('Cliente em Negociação')
      end

      it 'retorna 401 quando o Bearer token é inválido' do
        call_webhook(headers: { 'Authorization' => 'Bearer token-invalido' })

        expect(response).to have_http_status(:unauthorized)
        expect(conversation.reload.label_list).not_to include('Cliente em Negociação')
      end

      it 'retorna 403 quando o ai_department_id não pertence à account do ticket_id (guard multi-tenant)' do
        other_account = create(:account)
        other_operation_profile = Ai::OperationProfile.create!(account: other_account, name: 'padrão',
                                                                supervisor_provider: 'openai', supervisor_model: 'gpt-4o')
        other_agent = Ai::Agent.create!(account: other_account, name: 'Assistente',
                                        ai_operation_profile_id: other_operation_profile.id)
        other_department = Ai::Department.create!(account: other_account, ai_agent_id: other_agent.id, name: 'Outra conta')

        with_modified_env INTERNAL_AI_TOKEN: correct_token do
          post '/api/internal/ai_execute_tool',
               params: { ticket_id: conversation.id, ai_department_id: other_department.id, tool_name: 'conversation_add_label',
                          arguments: { label: 'Cliente em Negociação' }, mode: 'live' },
               headers: { 'Authorization' => "Bearer #{correct_token}" }, as: :json
        end

        expect(response).to have_http_status(:forbidden)
        expect(conversation.reload.label_list).not_to include('Cliente em Negociação')
      end
    end
  end
end
