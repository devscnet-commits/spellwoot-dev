// Escopo de uma fonte de conhecimento na UI. A fonte da verdade é a coluna `ai_department_id`
// (nil = compartilhado/account-wide; setado = restrito àquele department). Como o modelo de UI é
// "1 agente = 1 department default de mesmo nome", rotulamos pelo AGENTE, colapsando o "· dept"
// quando os nomes coincidem (o caso comum) e só desambiguando quando o agente tem um dept
// renomeado/extra. `d` vem do endpoint `departments`: { id, name (dept), agent (assistant_name) }.

// Rótulo de uma opção de escopo (dropdown de criação + chips de filtro + badge do card).
export const scopeOptionLabel = d => {
  if (!d) return '';
  if (!d.agent) return d.name;
  return d.name === d.agent ? d.agent : `${d.agent} · ${d.name}`;
};

// Classifica o escopo de uma fonte para o badge do card. Separa o caso órfão (ai_department_id
// aponta para um department que não existe mais) do compartilhado real — antes ambos caíam em
// "Compartilhado" silenciosamente.
//   { status: 'shared' }          -> ai_department_id nulo (visível a todos os agentes)
//   { status: 'scoped', label }   -> restrito a um agente/department existente
//   { status: 'orphan' }          -> aponta para department inexistente (deletado)
export const sourceScope = (source, departments = []) => {
  if (source == null || source.ai_department_id == null)
    return { status: 'shared' };
  const d = departments.find(x => x.id === source.ai_department_id);
  return d
    ? { status: 'scoped', label: scopeOptionLabel(d) }
    : { status: 'orphan' };
};

// Monta os chips do filtro de escopo da biblioteca. Lista TODOS os agentes/departments da conta
// (vindos do endpoint `departments`, os mesmos do dropdown de criação) — NÃO só os que já têm
// fonte. Um agente novo/vazio precisa aparecer com contagem 0, que é justamente quando o usuário
// mais quer o filtro (confirmar que está vazio e começar a preencher). Ordem: Todos, Compartilhado,
// cada agente (na ordem de `departments`) e "Fonte órfã" só se houver fonte apontando p/ dept sumido.
// `labels` traz os textos i18n ({ all, shared, orphan }) para manter o helper puro (sem vue-i18n).
export const buildScopeChips = (
  departments = [],
  sources = [],
  labels = {}
) => {
  const list = Array.isArray(sources) ? sources : [];
  const depts = Array.isArray(departments) ? departments : [];
  const chips = [
    { value: 'all', label: labels.all, count: list.length },
    {
      value: 'shared',
      label: labels.shared,
      count: list.filter(s => s.ai_department_id == null).length,
    },
  ];
  depts.forEach(d => {
    chips.push({
      value: String(d.id),
      label: scopeOptionLabel(d),
      count: list.filter(s => s.ai_department_id === d.id).length,
    });
  });
  const knownIds = new Set(depts.map(d => d.id));
  const orphanCount = list.filter(
    s => s.ai_department_id != null && !knownIds.has(s.ai_department_id)
  ).length;
  if (orphanCount > 0) {
    chips.push({ value: 'orphan', label: labels.orphan, count: orphanCount });
  }
  return chips;
};
