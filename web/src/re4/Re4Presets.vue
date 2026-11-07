<script setup lang="ts">
import { computed, reactive, ref, shallowRef } from 'vue';
import { ElButton, ElInput } from '@reff/ui';
import type { Re4Translate } from './i18n';
import type { Re4Fit, Re4Perform, Re4PresetEntry, Re4Snapshot } from './types';

// 预设页。当前配置是唯一生效的那份,预设只是套用的来源;套用前当前配置进自动保存。
// 模型变了时只提醒有没有更合适的预设,从不自动切换。可折叠的栏默认收起。
const props = defineProps<{ snapshot: Re4Snapshot; busy: boolean; perform: Re4Perform; t: Re4Translate }>();
const c = () => ({ character: props.snapshot.character });
const p = computed(() => props.snapshot.presets!);
const usable = computed(() => p.value.list.filter(e => e.match !== 'none'));
const unusable = computed(() => p.value.list.filter(e => e.match === 'none'));
const folds = reactive(new Set<string>());
const toggle = (k: string) => { if (folds.has(k)) folds.delete(k); else folds.add(k); };
const applying = shallowRef('');
const confirmingDelete = shallowRef('');
// 必须是 ref:v-model 改的是对象里的 value,shallowRef 不会因此重绘(打字看不到变化)
const renaming = ref<{ id: string; value: string } | null>(null);
const newName = shallowRef('');
// 新建空白配置:二次确认,默认同时抓取当前外观作为整套造型
const blanking = shallowRef(false);
const blankCapture = shallowRef(true);
const FIT: Record<Re4Fit, 'fitFull' | 'fitPartial' | 'fitNone'> = { full: 'fitFull', partial: 'fitPartial', none: 'fitNone' };
const fitClass = (m: Re4Fit) => m === 'full' ? 'ok' : m === 'partial' ? 'partial' : '';
const showBetter = computed(() => p.value.current !== 'full' && p.value.better.length > 0 && !p.value.dismissed);

async function save() {
  const name = newName.value.trim();
  if (name && await props.perform({ kind: 'preset-save', ...c(), name })) newName.value = '';
}
async function apply(e: Re4PresetEntry) {
  applying.value = '';
  await props.perform({ kind: 'preset-apply', ...c(), id: e.id });
}
async function rename(e: Re4PresetEntry) {
  const r = renaming.value; renaming.value = null;
  const name = r?.value.trim();
  if (name && name !== e.name) await props.perform({ kind: 'preset-rename', ...c(), id: e.id, name });
}
const time = (s: number) => s > 0 ? new Date(s * 1000).toLocaleString() : '';
</script>

<template>
  <div class="re4-main">
    <div v-if="showBetter" class="re4-banner info" role="status">
      <span>{{ t('betterHint', p.better.length, p.better.map(b => '「' + b.name + '」').join('')) }}</span>
      <ElButton size="small" :disabled="busy" @click="perform({ kind: 'preset-dismiss', ...c() })">{{ t('notNow') }}</ElButton>
    </div>

    <section class="re4-panel re4-panel-body">
      <div class="re4-panel-title">{{ t('current') }}</div>
      <div class="re4-row">
        <span>{{ p.source ? t('fromPreset', p.source.name) : t('noSource') }}</span>
        <span v-if="p.current" class="re4-tag" :class="fitClass(p.current)">{{ t(FIT[p.current]) }}</span>
      </div>
      <div class="re4-row">
        <ElInput v-model="newName" size="small" style="width:12em" :placeholder="t('newPresetName')" @keyup.enter="save" />
        <ElButton size="small" type="primary" :disabled="busy || !newName.trim()" @click="save">{{ t('saveAsPreset') }}</ElButton>
        <ElButton v-if="p.source?.own" size="small" :disabled="busy" @click="perform({ kind: 'preset-update', ...c() })">{{ t('saveBack', p.source.name) }}</ElButton>
        <ElButton size="small" :disabled="busy" @click="blanking = !blanking">{{ t('newBlank') }}</ElButton>
      </div>
      <div v-if="blanking" class="re4-pconfirm">
        <span>{{ t('blankWarn') }}</span>
        <label class="re4-row re4-small"><input v-model="blankCapture" type="checkbox">{{ t('blankCapture') }}</label>
        <ElButton size="small" type="primary" :disabled="busy" @click="blanking = false; perform({ kind: 'preset-blank', ...c(), capture: blankCapture })">{{ t('confirmBlank') }}</ElButton>
        <ElButton size="small" @click="blanking = false">{{ t('cancel') }}</ElButton>
      </div>
    </section>

    <section class="re4-panel">
      <div class="re4-panel-head"><span class="re4-panel-title">{{ t('library') }}</span></div>
      <div class="re4-panel-body">
        <span v-if="!usable.length" class="re4-muted re4-small">{{ t('noUsable') }}</span>
        <template v-for="list in [usable, folds.has('unusable') ? unusable : []]" :key="list === usable ? 'u' : 'n'">
          <div v-for="e in list" :key="e.id" class="re4-prow">
            <template v-if="renaming?.id === e.id">
              <ElInput v-model="renaming.value" size="small" style="width:12em" @keyup.enter="rename(e)" />
              <ElButton size="small" type="primary" @click="rename(e)">{{ t('done') }}</ElButton>
              <ElButton size="small" @click="renaming = null">{{ t('cancel') }}</ElButton>
            </template>
            <span v-else class="re4-pname">{{ e.name }}<span v-if="p.source?.id === e.id" class="re4-muted re4-small">（{{ t('isSource') }}）</span></span>
            <span class="re4-tag">{{ e.source === 'mod' ? t('srcMod') : t('srcUser') }}</span>
            <span class="re4-tag" :class="fitClass(e.match)">{{ t(FIT[e.match]) }}</span>
            <span class="re4-spacer"></span>
            <ElButton size="small" :disabled="busy || e.match === 'none'" @click="applying = e.id">{{ t('apply') }}</ElButton>
            <template v-if="e.source === 'user' && renaming?.id !== e.id">
              <ElButton size="small" :disabled="busy" @click="renaming = { id: e.id, value: e.name }">{{ t('rename') }}</ElButton>
              <ElButton size="small" type="danger" plain :disabled="busy" @click="confirmingDelete = e.id">{{ t('delete') }}</ElButton>
            </template>
            <div v-if="applying === e.id" class="re4-pconfirm">
              <span>{{ t('applyWarn', e.name) }}<template v-if="e.match === 'partial'"> {{ t('applyPartial') }}</template></span>
              <ElButton size="small" type="primary" @click="apply(e)">{{ t('confirmApply') }}</ElButton><ElButton size="small" @click="applying = ''">{{ t('cancel') }}</ElButton>
            </div>
            <div v-if="confirmingDelete === e.id" class="re4-confirm" style="flex-basis:100%">
              <span>{{ t('delete') }}「{{ e.name }}」？</span>
              <ElButton size="small" type="danger" @click="confirmingDelete = ''; perform({ kind: 'preset-delete', ...c(), id: e.id })">{{ t('confirmDelete') }}</ElButton>
              <ElButton size="small" @click="confirmingDelete = ''">{{ t('cancel') }}</ElButton>
            </div>
          </div>
        </template>
        <button v-if="unusable.length" class="re4-link" :aria-expanded="folds.has('unusable')" @click="toggle('unusable')">
          {{ folds.has('unusable') ? '▾' : '▸' }} {{ t('unusable', unusable.length) }}</button>
      </div>
    </section>

    <section class="re4-panel">
      <div class="re4-panel-head">
        <button class="re4-caret" :aria-expanded="folds.has('autosave')" @click="toggle('autosave')">{{ folds.has('autosave') ? '▾' : '▸' }}</button>
        <span class="re4-panel-title" :title="t('autosaveHint')">{{ t('autosaves', p.autosaves.length) }}</span>
      </div>
      <div v-if="folds.has('autosave')" class="re4-panel-body">
        <span v-if="!p.autosaves.length" class="re4-muted re4-small">{{ t('noAutosaves') }}</span>
        <div v-for="(a, k) in p.autosaves" :key="k" class="re4-prow">
          <span class="re4-pname">{{ a.name }}</span><span class="re4-muted re4-small">{{ time(a.time) }}</span><span class="re4-spacer"></span>
          <ElButton size="small" :disabled="busy" @click="perform({ kind: 'autosave-restore', ...c(), index: k + 1 })">{{ t('restore') }}</ElButton>
          <ElButton size="small" :disabled="busy" @click="perform({ kind: 'autosave-promote', ...c(), index: k + 1, name: a.name })">{{ t('promote') }}</ElButton>
        </div>
      </div>
    </section>

    <section class="re4-panel">
      <div class="re4-panel-head">
        <button class="re4-caret" :aria-expanded="folds.has('restore')" @click="toggle('restore')">{{ folds.has('restore') ? '▾' : '▸' }}</button>
        <span class="re4-panel-title">{{ t('restorePoints') }}</span>
      </div>
      <div v-if="folds.has('restore')" class="re4-panel-body re4-row">
        <ElButton size="small" :disabled="busy || !snapshot.backups?.hasBackup" @click="perform({ kind: 'restore', ...c(), which: 'backup' })">{{ t('restoreBackup') }}</ElButton>
        <ElButton size="small" :disabled="busy || !snapshot.backups?.hasOnload" @click="perform({ kind: 'restore', ...c(), which: 'onload' })">{{ t('restoreOnload') }}</ElButton>
      </div>
    </section>
  </div>
</template>

<style>
.re4-prow { display: flex; flex-wrap: wrap; align-items: center; gap: 6px 10px; padding: 5px 0; }
.re4-prow + .re4-prow { border-top: 1px solid var(--avm-line); }
.re4-prow .el-button + .el-button { margin-left: 0; }
.re4-pname { font-weight: 500; }
.re4-pconfirm { flex-basis: 100%; display: flex; flex-wrap: wrap; align-items: center; gap: 6px 10px; padding: 6px 10px; border-radius: 6px; background: var(--el-color-primary-light-9, var(--re4-soft)); font-size: 13px; }
</style>
