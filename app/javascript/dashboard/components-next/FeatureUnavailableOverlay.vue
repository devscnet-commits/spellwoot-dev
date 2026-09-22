<script setup>
// Desliga visualmente uma tela que saiu do ar mas cujo histórico continua valendo a pena mostrar:
// o conteúdo vira fundo apagado, sem clique nem foco (`inert`), e um aviso discreto explica por quê.
// Não substitui o desligamento no servidor — é só o que o cliente vê.
defineProps({
  title: { type: String, required: true },
  description: { type: String, required: true },
});
</script>

<template>
  <div class="relative">
    <div
      class="pointer-events-none select-none opacity-25 grayscale"
      aria-hidden="true"
      inert
    >
      <slot />
    </div>

    <div class="absolute inset-x-0 top-0 flex justify-center px-4 pt-28">
      <div
        role="status"
        class="max-w-sm rounded-lg bg-n-solid-1 px-6 py-4 text-center"
      >
        <p class="text-sm font-medium text-n-slate-11">{{ title }}</p>
        <p class="mt-1 text-sm leading-relaxed text-n-slate-10">
          {{ description }}
        </p>
      </div>
    </div>
  </div>
</template>
