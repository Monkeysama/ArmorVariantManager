<script setup lang="ts">
import { computed, shallowRef, watch } from 'vue';
import { ElButton, ElCheckbox, ElConfigProvider, REFF_ELEMENT_LOCALES } from '@reff/ui';
import CatalogPane from './CatalogPane.vue';
import MaterialsPane from './MaterialsPane.vue';
import ConditionsPane from './ConditionsPane.vue';
import SettingsPane from './SettingsPane.vue';
import HelpPane from './HelpPane.vue';
import PortraitPane from './PortraitPane.vue';
import { useAvm } from './useAvm';
import { useText } from './i18n';

const tab = shallowRef<'parts' | 'conditions' | 'settings' | 'help'>('parts');
const { client, snapshot, busy, loading, error, notice, perform, connect, documentation, documentationLoading, documentationError, retryDocumentation, loadImports } = useAvm(computed(() => tab.value === 'help'));
const { t, english } = useText(snapshot);
const worldTheme = computed(() => ['white', 'black', 'glass'].includes(snapshot.value?.theme ?? ''));
const scaleWithPanel = computed(() => snapshot.value?.settings?.sections
  .find(section => section.id === 'general')?.fields.find(field => field.id === 'reff_scale_with_panel')?.value === true);
const panelScale = shallowRef(1);
watch(scaleWithPanel, (enabled, _, onCleanup) => {
  panelScale.value = 1;
  if (!enabled) return;
  // 观察未缩放的插件容器，避免字体和控件的尺寸变化反过来触发缩放。
  const host = document.getElementById('app')!;
  const resize = () => {
    const { clientWidth: width, clientHeight: height } = host;
    if (width && height) panelScale.value = Math.max(.75, Math.sqrt((width / 1050) * (height / 620)));
  };
  resize();
  const observer = new ResizeObserver(resize);
  observer.observe(host);
  onCleanup(() => observer.disconnect());
});
const disabled = computed(() => busy.value || !snapshot.value?.bodyId);
const backupWarning = computed(() => !!snapshot.value?.bodyId && snapshot.value.backupPending);
const previewOpen = computed(() => snapshot.value?.game === 'Wilds' && snapshot.value.preview?.enabled === true);
const previewIntent = shallowRef<boolean | null>(null);
async function setPreview(value: unknown) {
  previewIntent.value = value === true;
  try { await perform({ kind: 'setting', id: 'portrait_enabled', value: previewIntent.value }); }
  finally { previewIntent.value = null; }
}
watch(() => snapshot.value?.selectionMode, selecting => { if (selecting) tab.value = 'parts'; });
const restoreConfirmation = shallowRef(false);
watch([() => snapshot.value?.game, () => snapshot.value?.bodyId, () => snapshot.value?.weapon, tab], () => { restoreConfirmation.value = false; });
async function restore() {
  if (await perform({ kind: 'restore' })) restoreConfirmation.value = false;
}
async function dismissBackup() {
  if (await perform({ kind: 'dismiss-backup' })) restoreConfirmation.value = false;
}
</script>

<template>
  <ElConfigProvider :locale="REFF_ELEMENT_LOCALES[english ? 'en-US' : 'zh-CN']">
    <main class="avm" :style="scaleWithPanel ? { zoom: panelScale } : undefined" :class="{ 'world-theme': worldTheme, 'help-open': tab === 'help', 'preview-open': previewOpen }" :data-theme="snapshot?.theme ?? 'custom'" :aria-busy="busy || loading">
      <header class="avm-header"><div class="identity"><span class="signal-bar"></span><h1>{{ t('title') }}</h1></div><div class="game-identity"><strong>{{ snapshot?.game === 'Rise' ? (english ? 'RISE' : '崛起') : snapshot?.game === 'Wilds' ? (english ? 'WILDS' : '荒野') : 'REFF' }}</strong><span class="version">v{{ snapshot?.version }}</span></div></header>
      <div class="context-strip"><div class="mode-switch" :aria-label="t('armor') + ' / ' + t('weapon')">
          <ElButton :class="{ selected: !snapshot?.weapon }" :disabled="busy || !snapshot" :aria-pressed="!snapshot?.weapon" @click="perform({ kind: 'mode', weapon: false })">{{ t('armor') }}</ElButton>
          <ElButton :class="{ selected: snapshot?.weapon }" :disabled="busy || !snapshot" :aria-pressed="!!snapshot?.weapon" @click="perform({ kind: 'mode', weapon: true })">{{ t('weapon') }}</ElButton>
        </div><span class="equipment-id">{{ snapshot?.bodyId || '—' }}</span><ElCheckbox v-if="snapshot?.game === 'Wilds' && snapshot.preview" :model-value="previewIntent ?? previewOpen" :disabled="busy" @change="setPreview">{{ t('preview') }}</ElCheckbox></div>
      <div id="file-tools" class="file-tools"></div><div class="avm-body">
      <PortraitPane v-if="previewOpen && snapshot?.preview" :client="client" :preview="snapshot.preview" :t="t" />
      <div class="avm-content">
      <div v-if="error" class="error-banner" role="alert"><span>{{ error }}</span><ElButton v-if="!snapshot" :disabled="loading" @click="connect">{{ t('retry') }}</ElButton><button v-else class="dismiss-error" aria-label="关闭 / Dismiss" @click="error = ''">×</button></div>
      <div v-if="!snapshot" class="connection-state"><span v-if="loading" class="connection-dot"></span>{{ loading ? t('loading') : t('wait') }}</div>
      <template v-else>
        <div v-if="!snapshot.bodyId" class="state-banner equipment-loading" role="status">{{ t(snapshot.weapon ? 'weaponLoading' : 'armorLoading') }}</div>
        <div v-if="backupWarning" class="backup-warning state-banner" role="status">
          <p>{{ t('backupChanged') }}</p>
          <div v-if="!restoreConfirmation" class="button-pair backup-actions"><ElButton :disabled="disabled" @click="restoreConfirmation = true">{{ t('restore') }}</ElButton><ElButton :disabled="disabled" @click="dismissBackup">{{ t('ignore') }}</ElButton></div>
          <div v-else class="delete-confirm restore-confirm" role="alert">
            <p>{{ t('confirmRestore') }}</p>
            <div class="button-pair"><ElButton :disabled="busy" @click="restoreConfirmation = false">{{ t('cancel') }}</ElButton><ElButton :disabled="disabled" @click="restore">{{ t('restore') }}</ElButton></div>
          </div>
        </div>
        <div class="workspace">
          <CatalogPane :active="true" :snapshot="snapshot" :busy="busy" :perform="perform" :load-imports="loadImports" :t="t" @notice="notice = $event" />
          <div class="detail-column"><nav class="footer-tabs" :aria-label="t('title')">
          <button v-for="item in (['parts', 'conditions', 'settings', 'help'] as const)" :key="item" :aria-current="tab === item ? 'page' : undefined" @click="tab = item">{{ t(item) }}</button>
        </nav><MaterialsPane v-show="tab === 'parts'" :snapshot="snapshot" :busy="busy" :perform="perform" :t="t" />
        <ConditionsPane v-show="tab === 'conditions'" :key="snapshot.bodyId" :world-theme="worldTheme" :conditions="snapshot.conditions" :busy="busy" :perform="perform" :t="t" />
        <SettingsPane v-show="tab === 'settings'" :snapshot="snapshot" :busy="busy" :perform="perform" :t="t" />
        <HelpPane v-show="tab === 'help'" :documentation="documentation" :loading="documentationLoading" :error="documentationError" :t="t" @retry="retryDocumentation" />
        </div></div>
      </template>
      </div>
      </div>
      <footer class="avm-footer">
        <div class="status" role="status"><span v-if="busy" class="active-dot"></span>{{ busy ? t('saving') : notice || (snapshot?.suspended ? t('suspended') : '') }}</div>
        <span class="equipment-id">{{ snapshot?.selectedPreset }}</span>
      </footer>
    </main>
  </ElConfigProvider>
</template>
