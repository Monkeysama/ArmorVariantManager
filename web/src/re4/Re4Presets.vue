<script setup lang="ts">
import { computed, reactive, shallowRef } from 'vue';
import { ElButton, ElInput } from '@reff/ui';
import type { Re4Translate } from './i18n';
import type { Re4Fit, Re4Perform, Re4PresetEntry, Re4Snapshot } from './types';

// 预设页。当前配置是唯一生效的那份,预设只是套用的来源;套用前当前配置进自动保存。
// 模型变了时只提醒有没有更合适的预设,从不自动切换。可折叠的栏默认收起。
const props = defineProps<{ snapshot: Re4Snapshot; busy: boolean; perform: Re4Perform; t: Re4Translate }>();
const c = () => ({ character: props.snapshot.character });
const p = computed(() => props.snapshot.presets!);
// 预设库分两类:模组自带(只能加载)和自定义(自己存的,可覆盖 / 改名 / 删除);每类里不适用的收进折叠栏。
// 没有模组自带的预设时不显示那一类
const anyUsable = computed(() => p.value.list.some(e => e.match !== 'none'));
const categories = computed(() => (['mod', 'user'] as const).map(key => {
  const list = p.value.list.filter(e => e.source === key);
  return { key, list, usable: list.filter(e => e.match !== 'none'), unusable: list.filter(e => e.match === 'none') };
}).filter(g => g.key === 'user' || g.list.length > 0));
const folds = reactive(new Set<string>());
const toggle = (k: string) => { if (folds.has(k)) folds.delete(k); else folds.add(k); };
const applying = shallowRef('');
// 保存至预设(完全替换预设内容):完全适用的直接存,其他的先确认。'@current' 表示当前预设
const savingTo = shallowRef('');
const confirmingDelete = shallowRef('');
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
async function saveTo(id: string | undefined, fit: Re4Fit | undefined) {
  if (fit !== 'full' && savingTo.value !== (id ?? '@current')) { savingTo.value = id ?? '@current'; applying.value = ''; confirmingDelete.value = ''; return; }
  savingTo.value = '';
  await props.perform(id ? { kind: 'preset-update', ...c(), id } : { kind: 'preset-update', ...c() });
}
// 同状态组选项:名字就是输入框,点上就能改,回车或离开即改名,Esc 放弃;失败就恢复原名
async function rename(e: Re4PresetEntry, input: HTMLInputElement) {
  const name = input.value.trim();
  if (!name || name === e.name) { input.value = e.name; return; }
  if (!await props.perform({ kind: 'preset-rename', ...c(), id: e.id, name })) input.value = e.name;
}
function revert(ev: KeyboardEvent, e: Re4PresetEntry) { const el = ev.target as HTMLInputElement; el.value = e.name; el.blur(); }
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
        <span :class="p.source ? 're4-pname' : 're4-muted'">{{ p.source ? p.source.name : t('noSource') }}</span>
        <span v-if="p.current" class="re4-tag" :class="fitClass(p.current)">{{ t(FIT[p.current]) }}</span>
        <span v-if="p.source && p.dirty" class="re4-tag partial">{{ t('unsavedTag') }}</span>
      </div>
      <div class="re4-row">
        <ElButton v-if="p.source?.own" size="small" type="primary" :disabled="busy" @click="saveTo(undefined, p.current)">{{ t('savePreset') }}</ElButton>
        <ElInput v-model="newName" size="small" style="width:12em" :placeholder="t('newPresetName')" @keyup.enter="save" />
        <ElButton size="small" :disabled="busy || !newName.trim()" @click="save">{{ t('saveAsPreset') }}</ElButton>
        <ElButton size="small" :disabled="busy" @click="blanking = !blanking">{{ t('newBlank') }}</ElButton>
      </div>
      <div v-if="savingTo === '@current' && p.source" class="re4-pconfirm">
        <span>{{ t('saveToWarn', p.source.name) }}</span>
        <ElButton size="small" type="primary" :disabled="busy" @click="saveTo(undefined, p.current)">{{ t('confirmSave') }}</ElButton>
        <ElButton size="small" @click="savingTo = ''">{{ t('cancel') }}</ElButton>
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
        <span v-if="!anyUsable" class="re4-muted re4-small">{{ t('noUsable') }}</span>
        <div v-for="g in categories" :key="g.key" class="re4-pcat">
          <!-- 每类可折叠,默认展开(folds 里记的是收起的类) -->
          <button class="re4-pcat-title" :aria-expanded="!folds.has('closed:' + g.key)" @click="toggle('closed:' + g.key)">
            {{ folds.has('closed:' + g.key) ? '▸' : '▾' }} {{ g.key === 'mod' ? t('catMod') : t('catUser') }}（{{ g.list.length }}）</button>
          <template v-if="!folds.has('closed:' + g.key)">
          <span v-if="!g.list.length" class="re4-muted re4-small">{{ t('noCustom') }}</span>
          <template v-for="list in [g.usable, folds.has('unusable:' + g.key) ? g.unusable : []]" :key="list === g.usable ? 'u' : 'n'">
            <div v-for="e in list" :key="e.id" class="re4-prow">
              <input v-if="e.source === 'user'" class="re4-pname-input" :value="e.name" :aria-label="t('rename')" :title="t('rename')" :disabled="busy"
                @change="ev => rename(e, ev.target as HTMLInputElement)"
                @keydown.enter="ev => (ev.target as HTMLInputElement).blur()" @keydown.esc="ev => revert(ev, e)">
              <span v-else class="re4-pname">{{ e.name }}</span>
              <span v-if="p.source?.id === e.id" class="re4-muted re4-small">（{{ t('isSource') }}）</span>
              <span class="re4-tag" :class="fitClass(e.match)">{{ t(FIT[e.match]) }}</span>
              <span class="re4-spacer"></span>
              <ElButton size="small" :disabled="busy || e.match === 'none'" @click="applying = e.id; savingTo = ''">{{ t('apply') }}</ElButton>
              <template v-if="e.source === 'user'">
                <ElButton v-if="p.source?.id !== e.id" size="small" :disabled="busy" @click="saveTo(e.id, e.match)">{{ t('saveTo') }}</ElButton>
                <ElButton size="small" type="danger" plain :disabled="busy" @click="confirmingDelete = e.id">{{ t('delete') }}</ElButton>
              </template>
              <div v-if="applying === e.id" class="re4-pconfirm">
                <span>{{ t(!p.dirty ? 'applyWarn' : p.source ? 'applyDirty' : 'applyUnsaved', e.name) }}<template v-if="e.match === 'partial'"> {{ t('applyPartial') }}</template></span>
                <ElButton size="small" type="primary" @click="apply(e)">{{ t('confirmApply') }}</ElButton><ElButton size="small" @click="applying = ''">{{ t('cancel') }}</ElButton>
              </div>
              <div v-if="savingTo === e.id" class="re4-pconfirm">
                <span>{{ t('saveToWarn', e.name) }}</span>
                <ElButton size="small" type="primary" :disabled="busy" @click="saveTo(e.id, e.match)">{{ t('confirmSave') }}</ElButton><ElButton size="small" @click="savingTo = ''">{{ t('cancel') }}</ElButton>
              </div>
              <div v-if="confirmingDelete === e.id" class="re4-confirm" style="flex-basis:100%">
                <span>{{ t('delete') }}「{{ e.name }}」？</span>
                <ElButton size="small" type="danger" @click="confirmingDelete = ''; perform({ kind: 'preset-delete', ...c(), id: e.id })">{{ t('confirmDelete') }}</ElButton>
                <ElButton size="small" @click="confirmingDelete = ''">{{ t('cancel') }}</ElButton>
              </div>
            </div>
          </template>
          <button v-if="g.unusable.length" class="re4-link" :aria-expanded="folds.has('unusable:' + g.key)" @click="toggle('unusable:' + g.key)">
            {{ folds.has('unusable:' + g.key) ? '▾' : '▸' }} {{ t('unusable', g.unusable.length) }}</button>
          </template>
        </div>
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
.re4-pname-input { font: inherit; font-weight: 500; border: 1px solid transparent; border-radius: 4px; padding: 1px 5px; margin-left: -6px;
  background: transparent; color: inherit; field-sizing: content; min-width: 2em; max-width: 100%; cursor: text; }
.re4-pname-input:hover, .re4-pname-input:focus { border-color: var(--avm-line); }
.re4-pcat + .re4-pcat { margin-top: 12px; }
.re4-pcat-title { display: block; border: 0; background: none; cursor: pointer; font: inherit; font-size: 12.5px; font-weight: 600;
  color: var(--avm-muted); padding: 2px 0 4px; text-align: left; }
.re4-pcat-title:hover { color: var(--avm-ink); }
.re4-pconfirm { flex-basis: 100%; display: flex; flex-wrap: wrap; align-items: center; gap: 6px 10px; padding: 6px 10px; border-radius: 6px; background: var(--el-color-primary-light-9, var(--re4-soft)); font-size: 13px; }
</style>
