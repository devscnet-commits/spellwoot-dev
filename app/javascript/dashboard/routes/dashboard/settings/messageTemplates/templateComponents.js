// Parses Meta's raw `components` array (as returned by the WhatsApp template
// list/get endpoints) into the plain shapes the template builder UI works
// with. Shared between EditTemplateModal (which needs the full editable
// shape) and any read-only preview of an existing template.
export const findComponent = (components, type) =>
  (components || []).find(component => component.type === type);

export const normalizeTemplateHeader = component => {
  if (!component) return { type: 'NONE', text: '', handle: '', fileName: '', sample: '' };
  if (component.format === 'TEXT') {
    return {
      type: 'TEXT',
      text: component.text || '',
      handle: '',
      fileName: '',
      sample: component.example?.header_text?.[0] || '',
    };
  }
  return {
    type: component.format,
    text: '',
    handle: component.example?.header_handle?.[0] || '',
    fileName: '',
    sample: '',
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

// Meta returns a NAMED template's body samples as body_text_named_params
// ([{param_name, example}]) instead of the positional body_text ([[...]]) array.
export const bodySamplesFromComponent = bodyComponent => {
  const namedParams = bodyComponent?.example?.body_text_named_params;
  if (namedParams?.length) {
    return Object.fromEntries(
      namedParams.map(({ param_name: name, example }) => [name, example])
    );
  }

  const positionalValues = bodyComponent?.example?.body_text?.[0] || [];
  return Object.fromEntries(
    positionalValues.map((value, index) => [index + 1, value])
  );
};

// Builds the props TemplateWhatsAppPreview expects directly from a template's
// raw `components` array.
export const templateToPreviewProps = components => {
  const bodyComponent = findComponent(components, 'BODY');

  return {
    header: normalizeTemplateHeader(findComponent(components, 'HEADER')),
    body: bodyComponent?.text || '',
    footer: findComponent(components, 'FOOTER')?.text || '',
    buttons: (findComponent(components, 'BUTTONS')?.buttons || []).map(
      normalizeTemplateButton
    ),
    samples: bodySamplesFromComponent(bodyComponent),
  };
};
