import { escapeHtml } from 'shared/helpers/HTMLSanitizer';

// Wraps (or, with no selection, inserts an empty pair of) a WhatsApp markdown
// marker around the given selection range, returning the new text and where
// the cursor/selection should land afterwards.
export const wrapSelection = (text, start, end, marker) => {
  const selected = text.slice(start, end);
  const before = text.slice(0, start);
  const after = text.slice(end);
  const wrapped = `${marker}${selected}${marker}`;

  return {
    text: `${before}${wrapped}${after}`,
    cursorStart: start + marker.length,
    cursorEnd: start + marker.length + selected.length,
  };
};

// Inserts a snippet at the cursor position, with no selection remaining.
export const insertAtCursor = (text, start, end, snippet) => {
  const before = text.slice(0, start);
  const after = text.slice(end);

  return {
    text: `${before}${snippet}${after}`,
    cursorStart: start + snippet.length,
    cursorEnd: start + snippet.length,
  };
};

const MARKDOWN_RULES = [
  { pattern: /\*([^*\n]+)\*/g, tag: 'strong' },
  { pattern: /_([^_\n]+)_/g, tag: 'em' },
  { pattern: /~([^~\n]+)~/g, tag: 's' },
  { pattern: /```([^`\n]+)```/g, tag: 'code' },
];

// Escapes the raw body text, substitutes {{n}} placeholders with sample
// values, then converts WhatsApp's plain-text markdown into safe HTML for
// the live preview panel (rendered via v-dompurify-html by the caller).
export const renderWhatsAppMarkdown = (text, samples = {}) => {
  const withSamples = text.replace(
    /\{\{(\d+)\}\}/g,
    (match, number) => samples[number] || match
  );

  let html = escapeHtml(withSamples).replace(/\n/g, '<br>');
  MARKDOWN_RULES.forEach(({ pattern, tag }) => {
    html = html.replace(pattern, `<${tag}>$1</${tag}>`);
  });

  return html;
};
