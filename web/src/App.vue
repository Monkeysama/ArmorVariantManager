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
const disabled = computed(() => busy.value || !snapshot.value?.bodyId);
const backupWarning = computed(() => !!snapshot.value?.bodyId && snapshot.value.backupPending);
const previewOpen = computed(() => snapshot.value?.game === 'Wilds' && snapshot.value.preview?.enabled === true);
const previewIntent = shallowRef<boolean | null>(null);
async function setPreview(value: unknown) {
  previewIntent.value = value === true;
  try { await perform({ kind: 'setting', id: 'portrait_enabled', value: previewIntent.value }); }
  finally { previewIntent.value = null; }
}
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
    <main class="avm" :class="{ 'help-open': tab === 'help', 'preview-open': previewOpen }" :data-theme="snapshot?.theme ?? 'custom'" :aria-busy="busy || loading">
      <header class="avm-header">
        <div class="identity"><h1>{{ t('title') }}</h1><span class="equipment-id">{{ snapshot?.bodyId || '—' }}</span></div>
        <div class="mode-switch" :aria-label="t('armor') + ' / ' + t('weapon')">
          <ElButton :class="{ selected: !snapshot?.weapon }" :disabled="busy || !snapshot" :aria-pressed="!snapshot?.weapon" @click="perform({ kind: 'mode', weapon: false })">{{ t('armor') }}</ElButton>
          <ElButton :class="{ selected: snapshot?.weapon }" :disabled="busy || !snapshot" :aria-pressed="!!snapshot?.weapon" @click="perform({ kind: 'mode', weapon: true })">{{ t('weapon') }}</ElButton>
        </div>
        <ElCheckbox v-if="snapshot?.game === 'Wilds' && snapshot.preview" :model-value="previewIntent ?? previewOpen" :disabled="busy" @change="setPreview">{{ t('preview') }}</ElCheckbox>
        <div class="game-identity"><span>{{ snapshot?.game === 'Wilds' ? (english ? 'WILDS' : '荒野') : snapshot?.game === 'Rise' ? (english ? 'RISE' : '崛起') : 'REFF' }}</span><span class="version">{{ snapshot?.version }}</span></div>
      </header>
      <div class="avm-body">
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
        <div v-show="tab === 'parts'" class="workspace">
          <CatalogPane :active="tab === 'parts'" :snapshot="snapshot" :busy="busy" :perform="perform" :load-imports="loadImports" :t="t" @notice="notice = $event" />
          <MaterialsPane :snapshot="snapshot" :busy="busy" :perform="perform" :t="t" />
        </div>
        <ConditionsPane v-show="tab === 'conditions'" :key="snapshot.bodyId" :conditions="snapshot.conditions" :busy="busy" :perform="perform" :t="t" />
        <SettingsPane v-show="tab === 'settings'" :snapshot="snapshot" :busy="busy" :perform="perform" :t="t" />
        <HelpPane v-show="tab === 'help'" :documentation="documentation" :loading="documentationLoading" :error="documentationError" :t="t" @retry="retryDocumentation" />
      </template>
      </div>
      </div>
      <footer class="avm-footer">
        <div class="status" role="status"><span v-if="busy" class="active-dot"></span>{{ busy ? t('saving') : notice || (snapshot?.suspended ? t('suspended') : '') }}</div>
        <nav class="footer-tabs" :aria-label="t('title')">
          <button v-for="item in (['parts', 'conditions', 'settings', 'help'] as const)" :key="item" :aria-current="tab === item ? 'page' : undefined" @click="tab = item">{{ t(item) }}</button>
        </nav>
      </footer>
    </main>
  </ElConfigProvider>
</template>
