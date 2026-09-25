// Meta's WhatsApp Cloud API lets a template's body use either positional variables ({{1}},
// {{2}}, sequential from 1) or named ones ({{customer_name}}, lowercase snake_case) — the
// template's `parameter_format`. The two shapes can't mix within a template.
export const PARAMETER_FORMATS = { POSITIONAL: 'POSITIONAL', NAMED: 'NAMED' };

const TOKEN_PATTERN = {
  [PARAMETER_FORMATS.POSITIONAL]: '\\d+',
  [PARAMETER_FORMATS.NAMED]: '[a-z][a-z0-9_]*',
};

export function detectVariables(body, parameterFormat) {
  const pattern = TOKEN_PATTERN[parameterFormat] || TOKEN_PATTERN.POSITIONAL;
  const regex = new RegExp(`\\{\\{(${pattern})\\}\\}`, 'g');
  const matches = [...body.matchAll(regex)].map(match => match[1]);
  const unique = [...new Set(matches)];

  return parameterFormat === PARAMETER_FORMATS.NAMED
    ? unique
    : unique.map(Number).sort((a, b) => a - b);
}

// Meta treats a variable as leading/trailing even with punctuation stuck to it (e.g. "...{{2}}."
// is still rejected) — matches Whatsapp::MessageTemplateValidator#dangling_variable? server-side.
export function hasDanglingVariable(body) {
  return (
    /^[\p{P}\s]*\{\{[a-zA-Z0-9_]+\}\}/u.test(body) ||
    /\{\{[a-zA-Z0-9_]+\}\}[\p{P}\s]*$/u.test(body)
  );
}

export function nextVariableToken(existingKeys, parameterFormat) {
  if (parameterFormat !== PARAMETER_FORMATS.NAMED) {
    const numbers = existingKeys.map(Number);
    return numbers.length > 0 ? Math.max(...numbers) + 1 : 1;
  }

  const taken = new Set(existingKeys);
  let index = existingKeys.length + 1;
  let name = `variavel_${index}`;
  while (taken.has(name)) {
    index += 1;
    name = `variavel_${index}`;
  }
  return name;
}
