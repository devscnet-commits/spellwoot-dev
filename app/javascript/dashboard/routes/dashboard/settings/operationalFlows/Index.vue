<script setup>
import SettingsLayout from '../SettingsLayout.vue';
import OperationalFlowsManager from './OperationalFlowsManager.vue';
</script>

<template>
  <SettingsLayout :no-records-found="false">
    <template #body>
      <OperationalFlowsManager />
    </template>
  </SettingsLayout>
</template>
