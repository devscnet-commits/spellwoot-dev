// Escopo de uma fonte de conhecimento na UI. A fonte da verdade é a coluna `ai_agent_id`
// (nil = compartilhado/account-wide; setado = restrito àquele agente). `a` vem do endpoint
// `agents` ({ id, name }) — fusão Departamento -> Agente (19/08): antes havia um nome de
// departamento e um nome de agente que podiam divergir; agora é só o agente, um nome só.

// Rótulo de uma opção de escopo (dropdown de criação + chips de filtro + badge do card).
export const scopeOptionLabel = a => (a ? a.name : '');

// Classifica o escopo de uma fonte para o badge do card. Separa o caso órfão (ai_agent_id
// aponta para um agente que não existe mais) do compartilhado real — antes ambos caíam em
// "Compartilhado" silenciosamente.
//   { status: 'shared' }          -> ai_agent_id nulo (visível a todos os agentes)
//   { status: 'scoped', label }   -> restrito a um agente existente
//   { status: 'orphan' }          -> aponta para agente inexistente (deletado)
export const sourceScope = (source, agents = []) => {
  if (source == null || source.ai_agent_id == null) return { status: 'shared' };
  const a = agents.find(x => x.id === source.ai_agent_id);
  return a
    ? { status: 'scoped', label: scopeOptionLabel(a) }
    : { status: 'orphan' };
};

// Monta os chips do filtro de escopo da biblioteca. Lista TODOS os agentes da conta (vindos do
// endpoint `agents`, os mesmos do dropdown de criação) — NÃO só os que já têm fonte. Um agente
// novo/vazio precisa aparecer com contagem 0, que é justamente quando o usuário mais quer o
// filtro (confirmar que está vazio e começar a preencher). Ordem: Todos, Compartilhado, cada
// agente (na ordem de `agents`) e "Fonte órfã" só se houver fonte apontando p/ agente sumido.
// `labels` traz os textos i18n ({ all, shared, orphan }) para manter o helper puro (sem vue-i18n).
export const buildScopeChips = (agents = [], sources = [], labels = {}) => {
  const list = Array.isArray(sources) ? sources : [];
  const agentList = Array.isArray(agents) ? agents : [];
  const chips = [
    { value: 'all', label: labels.all, count: list.length },
    {
      value: 'shared',
      label: labels.shared,
      count: list.filter(s => s.ai_agent_id == null).length,
    },
  ];
  agentList.forEach(a => {
    chips.push({
      value: String(a.id),
      label: scopeOptionLabel(a),
      count: list.filter(s => s.ai_agent_id === a.id).length,
    });
  });
  const knownIds = new Set(agentList.map(a => a.id));
  const orphanCount = list.filter(
    s => s.ai_agent_id != null && !knownIds.has(s.ai_agent_id)
  ).length;
  if (orphanCount > 0) {
    chips.push({ value: 'orphan', label: labels.orphan, count: orphanCount });
  }
  return chips;
};

// Mesma lógica/contagem de buildScopeChips, já formatada como options do <Select> do filtro: a
// contagem entra no label ("Todos (19)", "Maya v5.0 (0)") e o value é idêntico (all|shared|orphan|
// <agentId>). Presentação separada do dado para o dropdown reaproveitar sem duplicar a contagem.
export const buildScopeOptions = (agents = [], sources = [], labels = {}) =>
  buildScopeChips(agents, sources, labels).map(chip => ({
    value: chip.value,
    label: `${chip.label} (${chip.count})`,
  }));
