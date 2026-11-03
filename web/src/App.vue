<script setup lang="ts">
import { computed, shallowRef, watch } from 'vue';
import { ElButton, ElConfigProvider, ElRadio, ElRadioGroup, REFF_ELEMENT_LOCALES } from '@reff/ui';
import CatalogPane from './CatalogPane.vue';
import MaterialsPane from './MaterialsPane.vue';
import { useAvm } from './useAvm';
import { useText } from './i18n';

const { snapshot, busy, loading, error, notice, perform, connect } = useAvm();
const { t, english } = useText(snapshot);
const tab = shallowRef<'parts' | 'settings' | 'help'>('parts');
const disabled = computed(() => busy.value || !snapshot.value?.bodyId);
const restoreConfirmation = shallowRef(false);
watch([() => snapshot.value?.bodyId, () => tab.value], () => { restoreConfirmation.value = false; });
async function restore() {
  if (await perform({ kind: 'restore' })) restoreConfirmation.value = false;
}
</script>

<template>
  <ElConfigProvider :locale="REFF_ELEMENT_LOCALES[english ? 'en-US' : 'zh-CN']">
    <main class="avm" :data-theme="snapshot?.theme ?? 'custom'" :aria-busy="busy || loading">
      <header class="avm-header">
        <div class="identity"><h1>{{ t('title') }}</h1><span class="equipment-id">{{ snapshot?.bodyId || '—' }}</span></div>
        <div class="mode-switch" :aria-label="t('armor') + ' / ' + t('weapon')">
          <ElButton :class="{ selected: !snapshot?.weapon }" :disabled="busy || !snapshot" :aria-pressed="!snapshot?.weapon" @click="perform({ kind: 'mode', weapon: false })">{{ t('armor') }}</ElButton>
          <ElButton :class="{ selected: snapshot?.weapon }" :disabled="busy || !snapshot" :aria-pressed="!!snapshot?.weapon" @click="perform({ kind: 'mode', weapon: true })">{{ t('weapon') }}</ElButton>
        </div>
        <div class="game-identity"><span>{{ snapshot?.game === 'Wilds' ? (english ? 'WILDS' : '荒野') : snapshot?.game === 'Rise' ? (english ? 'RISE' : '崛起') : 'REFF' }}</span><span class="version">{{ snapshot?.version }}</span></div>
      </header>
      <div v-if="error" class="error-banner" role="alert"><span>{{ error }}</span><ElButton v-if="!snapshot" :disabled="loading" @click="connect">{{ t('retry') }}</ElButton><button v-else class="dismiss-error" aria-label="关闭 / Dismiss" @click="error = ''">×</button></div>
      <div v-if="!snapshot" class="connection-state"><span v-if="loading" class="connection-dot"></span>{{ loading ? t('loading') : t('wait') }}</div>
      <template v-else>
        <div v-if="!snapshot.bodyId" class="state-banner">{{ t('wait') }}</div>
        <div v-show="tab === 'parts'" class="workspace">
          <CatalogPane :snapshot="snapshot" :busy="busy" :perform="perform" :t="t" @notice="notice = $event" />
          <MaterialsPane :snapshot="snapshot" :busy="busy" :perform="perform" :t="t" />
        </div>
        <section v-show="tab === 'settings'" class="information settings-page" :aria-label="t('settings')">
          <div class="section-kicker">{{ t('settings') }}</div><h2>{{ t('theme') }}</h2>
          <ElRadioGroup :model-value="snapshot.theme" :disabled="busy" @change="(value: string | number | boolean | undefined) => perform({ kind: 'theme', value: value as 'custom' | 'reff' })">
            <ElRadio value="custom">{{ t('custom') }}</ElRadio><ElRadio value="reff">{{ t('follow') }}</ElRadio>
          </ElRadioGroup>
          <p>{{ t('themeHelp') }}</p><p class="muted">{{ t('scope') }}</p>
          <div class="native-note">{{ t('nativeHelp') }}</div>
        </section>
        <section v-show="tab === 'help'" class="information help-page" :aria-label="t('help')">
          <div class="section-kicker">{{ t('help') }}</div><h2>{{ t('helpTitle') }}</h2>
          <p>{{ t('helpGroups') }}</p><p>{{ t('helpSave') }}</p><p>{{ t('helpSelection') }}</p><p>{{ t('helpRestore') }}</p>
          <div class="native-note">{{ t('nativeHelp') }}</div>
        </section>
      </template>
      <footer class="avm-footer">
        <template v-if="tab === 'parts'">
          <ElButton v-if="!restoreConfirmation" class="restore-button" :disabled="disabled" @click="restoreConfirmation = true">{{ t('restore') }}</ElButton>
          <div v-else class="delete-confirm restore-confirm" role="alert">
            <p>{{ t('confirmRestore') }}</p>
            <div class="button-pair"><ElButton @click="restoreConfirmation = false">{{ t('cancel') }}</ElButton><ElButton :disabled="disabled" @click="restore">{{ t('restore') }}</ElButton></div>
          </div>
        </template>
        <div class="status" role="status"><span v-if="busy" class="active-dot"></span>{{ busy ? t('saving') : notice || (snapshot?.suspended ? t('suspended') : '') }}</div>
        <nav class="footer-tabs" :aria-label="t('title')">
          <button v-for="item in (['parts', 'settings', 'help'] as const)" :key="item" :aria-current="tab === item ? 'page' : undefined" @click="tab = item">{{ t(item) }}</button>
        </nav>
      </footer>
    </main>
  </ElConfigProvider>
</template>
