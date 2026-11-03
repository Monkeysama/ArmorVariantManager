<script setup lang="ts">
import { computed, onBeforeUnmount, shallowRef, watch } from 'vue';
import { ElButton } from '@reff/ui';
import type { ImportFile, Imports, Perform, Snapshot } from './types';
import type { Translate } from './i18n';

const props = defineProps<{ snapshot: Snapshot; busy: boolean; perform: Perform; loadImports: () => Promise<Imports>; t: Translate }>();
const emit = defineEmits<{ imported: [] }>();
const opened = shallowRef(false);
const loading = shallowRef(false);
const error = shallowRef('');
const files = shallowRef<ImportFile[]>([]);
const selectedPath = shallowRef('');
const disabled = computed(() => props.busy || !props.snapshot.bodyId);
const selected = computed(() => files.value.find(file => file.path === selectedPath.value));
let requestId = 0;

function close() {
  requestId += 1;
  opened.value = false;
  loading.value = false;
  error.value = '';
  files.value = [];
  selectedPath.value = '';
}
async function refresh() {
  if (loading.value || disabled.value) return;
  const id = ++requestId;
  loading.value = true;
  error.value = '';
  try {
    const result = await props.loadImports();
    if (id !== requestId) return;
    if (result.bodyId !== props.snapshot.bodyId) throw new Error(props.t('importEquipmentChanged'));
    files.value = result.files;
    if (!selected.value) selectedPath.value = '';
  } catch (reason) {
    if (id === requestId) error.value = reason instanceof Error ? reason.message : String(reason);
  } finally { if (id === requestId) loading.value = false; }
}
function open() {
  opened.value = true;
  void refresh();
}
async function confirm() {
  if (selected.value && await props.perform({ kind: 'import-preset', path: selected.value.path })) {
    close();
    emit('imported');
  }
}
watch([() => props.snapshot.bodyId, () => props.snapshot.weapon, () => props.snapshot.game], close);
onBeforeUnmount(close);
</script>

<template>
  <div class="import-workflow">
    <ElButton class="import-trigger" :disabled="disabled" :aria-expanded="opened" @click="opened ? close() : open()">{{ t('importPreset') }}</ElButton>
    <section v-if="opened" class="import-picker" :aria-label="t('importPreset')" :aria-busy="loading" @keydown.esc.stop.prevent="!busy && close()">
      <p class="import-warning">{{ t('importWarning') }}</p>
      <ElButton class="import-refresh" :disabled="disabled || loading" @click="refresh">{{ t('refreshImports') }}</ElButton>
      <p v-if="loading" class="import-status" role="status">{{ t('loadingImports') }}</p>
      <p v-if="error" class="import-error" role="alert">{{ error }}</p>
      <fieldset v-if="files.length" class="import-files" :disabled="disabled || loading">
        <legend class="import-legend">{{ t('importFiles') }}</legend>
        <div class="import-file-list">
          <label v-for="file in files" :key="file.path" class="import-file" :class="{ selected: selectedPath === file.path }" :title="file.path">
            <input v-model="selectedPath" type="radio" name="preset-import-file" :value="file.path" />
            <span>{{ file.name }}</span>
          </label>
        </div>
      </fieldset>
      <p v-else-if="!loading && !error" class="import-status">{{ t('noImports') }}</p>
      <div class="import-actions">
        <ElButton :disabled="busy" @click="close">{{ t('cancel') }}</ElButton>
        <ElButton type="primary" :disabled="disabled || loading || !!error || !selected" @click="confirm">{{ t('confirmImport') }}</ElButton>
      </div>
    </section>
  </div>
</template>

<style scoped>
.import-workflow { display: flex; flex-direction: column; margin-top: 9px; }
.import-picker { margin-top: 12px; border-top: 1px solid var(--avm-line); padding-top: 12px; min-width: 0; }
.import-warning { margin: 0 0 12px; overflow-wrap: anywhere; }
.import-refresh { width: 100%; }
.import-status { color: var(--avm-muted); margin: 12px 0; }
.import-error { color: var(--avm-ink); border: 1px solid var(--avm-line); padding: 8px; overflow-wrap: anywhere; }
.import-files { padding: 0; margin: 12px 0; border: 0; min-width: 0; }
.import-legend { color: var(--avm-muted); padding: 0 0 6px; }
.import-file-list { max-height: 240px; overflow: auto; scrollbar-color: var(--avm-line) var(--avm-bg); }
.import-file { display: flex; gap: 8px; align-items: flex-start; padding: 9px 6px; border-bottom: 1px solid var(--avm-line); cursor: pointer; }
.import-file:hover { background: var(--avm-panel); }
.import-file.selected { background: var(--avm-active); color: var(--avm-accent); }
.import-file > input { flex: 0 0 auto; margin: 4px 0 0; accent-color: var(--avm-accent); }
.import-file > span { min-width: 0; overflow-wrap: anywhere; }
.import-files:disabled .import-file { opacity: .55; cursor: not-allowed; }
.import-actions { display: flex; flex-wrap: wrap; gap: 7px; margin-top: 12px; }
.import-actions > .el-button { flex: 1 1 90px; min-width: 0; }
</style>
