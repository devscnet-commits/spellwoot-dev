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
