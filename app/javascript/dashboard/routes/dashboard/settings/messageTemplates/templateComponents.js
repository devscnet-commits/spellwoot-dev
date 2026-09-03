// Parses Meta's raw `components` array (as returned by the WhatsApp template
// list/get endpoints) into the plain shapes the template builder UI works
// with. Shared between EditTemplateModal (which needs the full editable
// shape) and any read-only preview of an existing template.
export const findComponent = (components, type) =>
  (components || []).find(component => component.type === type);

export const normalizeTemplateHeader = component => {
  if (!component) return { type: 'NONE', text: '', handle: '', fileName: '' };
  if (component.format === 'TEXT') {
    return {
      type: 'TEXT',
      text: component.text || '',
      handle: '',
      fileName: '',
    };
  }
  return {
    type: component.format,
    text: '',
    handle: component.example?.header_handle?.[0] || '',
    fileName: '',
  };
};

const buttonExample = button => {
  if (button.type === 'COPY_CODE') return button.example || '';
  if (button.type === 'URL' && button.example?.length) return button.example[0];
  return '';
};

export const normalizeTemplateButton = button => ({
  type: button.type,
  text: button.text || '',
  url: button.type === 'URL' ? button.url || '' : '',
  phone_number: button.type === 'PHONE_NUMBER' ? button.phone_number || '' : '',
  example: buttonExample(button),
  flow_id: button.type === 'FLOW' ? button.flow_id || '' : '',
  navigate_screen: button.type === 'FLOW' ? button.navigate_screen || '' : '',
});

// Builds the props TemplateWhatsAppPreview expects directly from a template's
// raw `components` array.
export const templateToPreviewProps = components => {
  const bodyComponent = findComponent(components, 'BODY');
  const sampleValues = bodyComponent?.example?.body_text?.[0] || [];

  return {
    header: normalizeTemplateHeader(findComponent(components, 'HEADER')),
    body: bodyComponent?.text || '',
    footer: findComponent(components, 'FOOTER')?.text || '',
    buttons: (findComponent(components, 'BUTTONS')?.buttons || []).map(
      normalizeTemplateButton
    ),
    samples: Object.fromEntries(
      sampleValues.map((value, index) => [index + 1, value])
    ),
  };
};
