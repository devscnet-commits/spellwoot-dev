<script>
import SnackbarContainer from './components/SnackBar/Container.vue';
import { LocalStorage } from 'shared/helpers/localStorage';
import { LOCAL_STORAGE_KEYS } from 'dashboard/constants/localStorage';

export default {
  components: { SnackbarContainer },
  data() {
    return { theme: 'light' };
  },
  mounted() {
    this.setColorTheme();
    this.listenToThemeChanges();
    this.setLocale(window.chatwootConfig.selectedLocale);
  },
  methods: {
    isDarkMode(isOSOnDarkMode) {
      const selectedColorScheme =
        LocalStorage.get(LOCAL_STORAGE_KEYS.COLOR_SCHEME) || 'auto';
      return (
        (selectedColorScheme === 'auto' && isOSOnDarkMode) ||
        selectedColorScheme === 'dark'
      );
    },
    setColorTheme() {
      const isDark = this.isDarkMode(
        window.matchMedia('(prefers-color-scheme: dark)').matches
      );
      this.theme = isDark ? 'dark' : 'light';
      document.documentElement.classList.toggle('dark', isDark);
    },
    listenToThemeChanges() {
      const mql = window.matchMedia('(prefers-color-scheme: dark)');

      mql.onchange = e => {
        const isDark = this.isDarkMode(e.matches);
        this.theme = isDark ? 'dark' : 'light';
        document.documentElement.classList.toggle('dark', isDark);
      };
    },
    setLocale(locale) {
      if (locale) {
        this.$root.$i18n.locale = locale;
      }
    },
  },
};
</script>

<template>
  <div class="h-full min-h-screen w-full antialiased" :class="theme">
    <router-view />
    <SnackbarContainer />
  </div>
</template>

<style lang="scss">
@tailwind base;
@tailwind components;
@tailwind utilities;

@import '../dashboard/assets/scss/next-colors';

html,
body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto,
    Oxygen-Sans, Ubuntu, Cantarell, 'Helvetica Neue', sans-serif;
  @apply h-full w-full;

  input,
  select {
    outline: none;
  }
}

.text-link {
  @apply text-n-brand font-medium hover:text-n-blue-10;
}

.v-popper--theme-tooltip .v-popper__inner {
  background: black !important;
  font-size: 0.75rem;
  padding: 4px 8px !important;
  border-radius: 6px;
  font-weight: 400;
}

.v-popper--theme-tooltip .v-popper__arrow-container {
  display: none;
}
</style>
