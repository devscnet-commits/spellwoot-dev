import { mount } from '@vue/test-utils';
import { describe, it, expect } from 'vitest';
import { createI18n } from 'vue-i18n';
import messages from 'dashboard/i18n';
import TemplateBodyField from '../TemplateBodyField.vue';

// O bloco de valores de exemplo só renderiza DEPOIS que existe uma variável no corpo, e é ele que
// compila VARIABLES.PLACEHOLDER. Com chave dupla ali, o compilador do vue-i18n levanta
// "Not allowed nest placeholder" e o Vue derruba a subárvore inteira — o campo de corpo sumia da
// tela ao clicar em "Add variable". Montar com o corpo VAZIO não pega isso.
describe('TemplateBodyField com variável no corpo', () => {
  const montar = (modelValue, locale) => {
    const erros = [];
    const wrapper = mount(TemplateBodyField, {
      props: { modelValue, samples: {} },
      global: {
        plugins: [
          createI18n({
            legacy: false,
            locale,
            messages,
            missingWarn: false,
            fallbackWarn: false,
          }),
        ],
        config: { errorHandler: e => erros.push(e) },
        stubs: { EmojiInput: true },
      },
    });
    return { wrapper, erros };
  };

  it.each([
    ['en', 'Sample value for 1'],
    ['pt_BR', 'Valor de exemplo para 1'],
  ])('renderiza o corpo e interpola o exemplo em %s', (locale, esperado) => {
    const { wrapper, erros } = montar(
      'Olá {{1}}, tudo certo por aqui.',
      locale
    );

    expect(erros).toEqual([]);
    expect(wrapper.find('textarea').exists()).toBe(true);
    // A asserção que guarda de verdade: com chave dupla o compilador falha e devolve a string CRUA,
    // sem substituir o número. Só olhar se o campo existe não pega a regressão.
    expect(wrapper.find('input').attributes('placeholder')).toBe(esperado);
  });

  it('numera um campo de exemplo por variável', () => {
    const { wrapper, erros } = montar(
      'Oi {{1}}, seu pedido {{2}} saiu para entrega.',
      'pt_BR'
    );

    expect(erros).toEqual([]);
    expect(wrapper.findAll('input')).toHaveLength(2);
  });
});
