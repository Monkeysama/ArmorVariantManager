<script setup lang="ts">
import { computed, shallowRef, watch } from 'vue';
import { ElButton, ElCheckbox, ElInput, ElRadio, ElRadioGroup, ElSwitch } from '@reff/ui';
import type { Re4Translate } from './i18n';
import type { Re4Layer, Re4Perform, Re4Slot, Re4Snapshot } from './types';

// 编辑：层 → 预设 / 状态 → 材质。语义与 REF 面板一致：
//   * 选中即生效再编辑 —— 编辑非生效的预设时，改动会被重算按生效的那个盖掉，屏幕上看不到在改什么
//   * 整套造型的材质是整份快照（开 / 关）；状态组是稀疏的三态（不管 / 关 / 开），不管 = 交给整套造型
//   * 删除、重新抓取会先留备份（「存档」页的「最近一次删除 / 覆写之前」）
const props = defineProps<{ snapshot: Re4Snapshot; busy: boolean; perform: Re4Perform; t: Re4Translate }>();
const layers = computed(() => [props.snapshot.base!, ...(props.snapshot.axes ?? [])]);
const editor = computed(() => props.snapshot.editor!);
const layerKey = shallowRef('');               // '' = 整套造型
const layer = computed(() => layers.value.find(item => (item.base ? '' : item.name) === layerKey.value) ?? layers.value[0]);
const editing = shallowRef('');
const confirm = shallowRef<{ kind: 'preset-delete' | 'preset-recapture' | 'axis-delete'; name: string } | null>(null);
const newAxis = shallowRef('');
const presetName = shallowRef('');
const axisName = shallowRef('');
const slotFilter = shallowRef('');            // '' = 全部部位
const notes = shallowRef(false);
const noteDrafts = shallowRef<Record<string, string>>({});

watch(layer, value => {
  if (!value.presets.includes(editing.value)) editing.value = value.presets.includes(value.active) ? value.active : '';
  axisName.value = value.base ? '' : value.name;
  confirm.value = null;
}, { immediate: true });
watch(editing, value => { presetName.value = value; confirm.value = null; }, { immediate: true });
// 层被别处（REF 面板）改名 / 删除时退回整套造型
watch(layers, value => { if (!value.some(item => (item.base ? '' : item.name) === layerKey.value)) layerKey.value = ''; });

const values = computed(() => layer.value.values[editing.value] ?? {});
const slots = computed(() => editor.value.slots.filter(slot => !slot.mirrored && (slotFilter.value === '' || slot.id === slotFilter.value)));
const mirroredSlot = computed(() => editor.value.slots.find(slot => slot.mirrored));

function target(extra: Record<string, unknown> = {}) {
  return { character: props.snapshot.character, ...(layer.value.base ? {} : { axis: layer.value.name }), ...extra };
}
async function select(name: string) {
  // 再点一次正在编辑的预设：收起编辑区但保持生效（同面板）
  if (editing.value === name) { editing.value = ''; return; }
  if (await props.perform({ kind: 'active', ...target(), preset: name })) editing.value = name;
}
async function create() {
  const before = new Set(layer.value.presets);
  if (await props.perform({ kind: 'preset-new', ...target() })) editing.value = layer.value.presets.find(name => !before.has(name)) ?? layer.value.active;
}
async function duplicate(name: string) {
  if (await props.perform({ kind: 'preset-duplicate', ...target(), preset: name })) editing.value = layer.value.active;
}
async function rename() {
  const name = presetName.value.trim();
  if (!name || name === editing.value) return;
  if (await props.perform({ kind: 'preset-rename', ...target(), preset: editing.value, name })) editing.value = name;
}
async function confirmed() {
  const value = confirm.value;
  if (!value) return;
  const ok = value.kind === 'axis-delete'
    ? await props.perform({ kind: 'axis-delete', character: props.snapshot.character, axis: value.name })
    : await props.perform({ kind: value.kind, ...target(), preset: value.name });
  if (ok) {
    confirm.value = null;
    if (value.kind === 'axis-delete') layerKey.value = '';
    else if (value.kind === 'preset-delete' && editing.value === value.name) editing.value = '';
  }
}
async function createAxis() {
  const name = newAxis.value.trim();
  if (name && await props.perform({ kind: 'axis-new', character: props.snapshot.character, name })) {
    newAxis.value = ''; layerKey.value = name; editing.value = '1';
  }
}
async function renameAxis() {
  const name = axisName.value.trim();
  if (!name || layer.value.base || name === layer.value.name) return;
  if (await props.perform({ kind: 'axis-rename', character: props.snapshot.character, axis: layer.value.name, name })) layerKey.value = name;
}

// 材质的当前取值：整套造型没写的算开；状态组没写的是「不管」
function tri(slot: string, material: string): 'none' | 'off' | 'on' {
  const value = values.value[slot]?.[material];
  return value === undefined ? 'none' : value ? 'on' : 'off';
}
const baseValue = (slot: string, material: string) => values.value[slot]?.[material] !== false;
function setMaterial(slot: string, material: string, value: boolean | 'none' | 'off' | 'on') {
  return props.perform({ kind: 'material', ...target(), preset: editing.value, slot, material, value });
}
function bulk(slot: string, op: 'all_on' | 'all_off' | 'invert' | 'claim' | 'release') {
  return props.perform({ kind: 'slot-bulk', ...target(), preset: editing.value, slot, op });
}
function counts(slot: Re4Slot) {
  const stored = values.value[slot.id] ?? {};
  const entries = Object.values(stored);
  return layer.value.base ? props.t('offCount', entries.filter(value => value === false).length) : props.t('ownedCount', entries.length);
}
function label(slot: string, material: string, note?: string) { return note ? `${note} (${material})` : material; }
function noteKey(slot: string, material: string) { return `${slot}/${material}`; }
function noteDraft(slot: string, material: string, note?: string) { return noteDrafts.value[noteKey(slot, material)] ?? note ?? ''; }
function editNote(slot: string, material: string, text: string) { noteDrafts.value = { ...noteDrafts.value, [noteKey(slot, material)]: text }; }
async function saveNote(slot: string, material: string, note?: string) {
  const key = noteKey(slot, material);
  const text = noteDrafts.value[key];
  if (text === undefined || text === (note ?? '')) return;
  if (await props.perform({ kind: 'note', character: props.snapshot.character, slot, material, text })) {
    const next = { ...noteDrafts.value }; delete next[key]; noteDrafts.value = next;
  }
}
const locate = (slot: string, material: string) => props.perform({ kind: 'locate', character: props.snapshot.character, slot, material });
const isLocating = (slot: string, material: string) => editor.value.locating?.slot === slot && editor.value.locating.material === material;
</script>

<template>
  <div class="re4-editor">
    <nav class="re4-editor-col re4-editor-layers" :aria-label="t('layers')">
      <button v-for="item in layers" :key="item.base ? '' : item.name" class="catalog-row"
        :aria-pressed="(item.base ? '' : item.name) === layerKey" @click="layerKey = item.base ? '' : item.name">
        <span class="row-name">{{ item.name }}</span>
        <span class="row-tag">{{ item.presets.length }}</span>
      </button>
      <div class="re4-inline">
        <ElInput v-model="newAxis" :placeholder="t('newAxisName')" :disabled="busy" size="small" @keydown.enter="createAxis" />
        <ElButton size="small" :disabled="busy || !newAxis.trim()" @click="createAxis">{{ t('createAxis') }}</ElButton>
      </div>
      <div v-if="editor.conflicts.length > 0" class="re4-warning" role="status">
        <p>{{ t('conflicts') }}</p>
        <p v-for="item in editor.conflicts" :key="item.key">{{ item.key }}：{{ item.parts.map(part => `${part.axis}(${[part.on ? t('triOn') : '', part.off ? t('triOff') : ''].filter(Boolean).join('/')})`).join(', ') }}</p>
      </div>
    </nav>

    <section class="re4-editor-col re4-editor-presets">
      <h2 class="re4-section-title">{{ layer.base ? t('presets') : t('states') }}</h2>
      <template v-if="layer.base">
        <ElSwitch :model-value="editor.armorMirror" :disabled="busy" :active-text="t('armorMirror')"
          @change="value => perform({ kind: 'armor-mirror', character: snapshot.character, enabled: value === true })" />
        <p class="re4-note">{{ t('armorMirrorHint') }}</p>
      </template>
      <p v-if="layer.presets.length === 0" class="re4-muted">{{ layer.base ? t('noPresets') : t('noStates') }}</p>
      <ul class="re4-preset-list">
        <li v-for="(name, index) in layer.presets" :key="name" :class="{ editing: name === editing }">
          <button class="re4-preset-name" :aria-pressed="name === editing" :disabled="busy" @click="select(name)">
            <span v-if="name === layer.active" class="active-dot" :title="t('activeNow')"></span>{{ name }}
          </button>
          <span v-if="layer.match?.[name]?.status === 'mismatch'" class="avm-tag tag-global el-tag el-tag--small"><span class="el-tag__content">{{ t('mismatch') }}</span></span>
          <span v-else-if="layer.match?.[name]?.status === 'partial'" class="avm-tag tag-global el-tag el-tag--small"><span class="el-tag__content">{{ t('partial') }}: {{ layer.match[name].skipped.join(' ') }}</span></span>
          <span class="re4-preset-actions">
            <ElButton size="small" :disabled="busy || index === 0" :aria-label="t('moveUp')" @click="perform({ kind: 'preset-move', ...target(), preset: name, offset: -1 })">↑</ElButton>
            <ElButton size="small" :disabled="busy || index === layer.presets.length - 1" :aria-label="t('moveDown')" @click="perform({ kind: 'preset-move', ...target(), preset: name, offset: 1 })">↓</ElButton>
            <ElButton size="small" :disabled="busy" @click="duplicate(name)">{{ t('duplicate') }}</ElButton>
            <ElButton size="small" :disabled="busy" @click="confirm = { kind: 'preset-delete', name }">{{ t('delete') }}</ElButton>
          </span>
        </li>
      </ul>
      <p v-if="layer.presets.length >= 2 && layer.rules.length > 0" class="re4-note">{{ t('priorityHint') }}</p>
      <ElButton :disabled="busy" @click="create">{{ layer.base ? t('newPreset') : t('newState') }}</ElButton>

      <div v-if="confirm" class="delete-confirm" role="alert">
        <p>{{ confirm.kind === 'preset-recapture' ? t('confirmRecapture') : confirm.kind === 'axis-delete' ? t('confirmDeleteAxis') : t('confirmDelete') }} {{ confirm.name }}</p>
        <div class="button-pair"><ElButton :disabled="busy" @click="confirm = null">{{ t('cancel') }}</ElButton><ElButton type="primary" :disabled="busy" @click="confirmed">{{ t('confirm') }}</ElButton></div>
      </div>

      <template v-if="editing">
        <div class="re4-inline">
          <ElInput v-model="presetName" :disabled="busy" size="small" :aria-label="t('name')" @keydown.enter="rename" />
          <ElButton size="small" :disabled="busy || !presetName.trim() || presetName.trim() === editing" @click="rename">{{ t('rename') }}</ElButton>
        </div>
        <ElButton v-if="layer.base" size="small" :disabled="busy" @click="confirm = { kind: 'preset-recapture', name: editing }">{{ t('recapture') }}</ElButton>
      </template>

      <template v-if="!layer.base">
        <h3 class="re4-subtitle">{{ t('axisSettings') }}</h3>
        <div class="re4-inline">
          <ElInput v-model="axisName" :disabled="busy" size="small" :aria-label="t('axisName')" @keydown.enter="renameAxis" />
          <ElButton size="small" :disabled="busy || !axisName.trim() || axisName.trim() === layer.name" @click="renameAxis">{{ t('renameAxis') }}</ElButton>
        </div>
        <ElButton size="small" :disabled="busy" @click="confirm = { kind: 'axis-delete', name: layer.name }">{{ t('deleteAxis') }}</ElButton>
      </template>
    </section>

    <section class="re4-editor-col re4-editor-materials">
      <p v-if="!editing" class="re4-muted">{{ t('selectPreset') }}</p>
      <template v-else>
        <div class="re4-materials-head">
          <h2 class="re4-section-title">{{ t('editingPreset') }}：{{ editing }}</h2>
          <ElCheckbox v-model="notes">{{ t('notesMode') }}</ElCheckbox>
        </div>
        <p v-if="!layer.base" class="re4-note">{{ t('axisEditorHint') }}</p>
        <p v-if="mirroredSlot" class="re4-note">{{ t('mirroredHint') }}</p>
        <ElRadioGroup v-model="slotFilter" size="small" class="re4-slot-filter">
          <ElRadio value="">{{ t('slotAll') }}</ElRadio>
          <ElRadio v-for="slot in editor.slots.filter(item => !item.mirrored)" :key="slot.id" :value="slot.id">{{ slot.label }}</ElRadio>
        </ElRadioGroup>
        <p v-if="editor.slots.length === 0" class="re4-muted">{{ t('noSlots') }}</p>
        <div v-for="slot in slots" :key="slot.id" class="re4-slot">
          <div class="re4-slot-head">
            <strong>{{ slot.label }}</strong>
            <span class="count">{{ t('materialsCount', slot.materials.length) }} · {{ counts(slot) }}</span>
            <span class="re4-slot-actions">
              <template v-if="layer.base">
                <ElButton size="small" :disabled="busy" @click="bulk(slot.id, 'all_on')">{{ t('allOn') }}</ElButton>
                <ElButton size="small" :disabled="busy" @click="bulk(slot.id, 'all_off')">{{ t('allOff') }}</ElButton>
                <ElButton size="small" :disabled="busy" @click="bulk(slot.id, 'invert')">{{ t('invert') }}</ElButton>
              </template>
              <template v-else>
                <ElButton size="small" :disabled="busy" @click="bulk(slot.id, 'claim')">{{ t('claim') }}</ElButton>
                <ElButton size="small" :disabled="busy" @click="bulk(slot.id, 'release')">{{ t('release') }}</ElButton>
              </template>
            </span>
          </div>
          <ul class="re4-material-list">
            <li v-for="material in slot.materials" :key="material.name" :class="{ locating: isLocating(slot.id, material.name) }">
              <template v-if="notes">
                <ElButton size="small" :disabled="busy" @click="locate(slot.id, material.name)">{{ isLocating(slot.id, material.name) ? t('locating') : t('locate') }}</ElButton>
                <span class="re4-material-name">{{ material.name }}</span>
                <ElInput :model-value="noteDraft(slot.id, material.name, material.note)" :placeholder="t('notePlaceholder')" :disabled="busy" size="small"
                  @update:model-value="value => editNote(slot.id, material.name, String(value))" @blur="saveNote(slot.id, material.name, material.note)" @keydown.enter="saveNote(slot.id, material.name, material.note)" />
              </template>
              <ElCheckbox v-else-if="layer.base" :model-value="baseValue(slot.id, material.name)" :disabled="busy"
                @change="value => setMaterial(slot.id, material.name, value === true)">{{ label(slot.id, material.name, material.note) }}</ElCheckbox>
              <template v-else>
                <ElRadioGroup :model-value="tri(slot.id, material.name)" size="small" :disabled="busy" class="re4-tri"
                  @change="value => setMaterial(slot.id, material.name, value as 'none' | 'off' | 'on')">
                  <ElRadio value="none">{{ t('triNone') }}</ElRadio>
                  <ElRadio value="off">{{ t('triOff') }}</ElRadio>
                  <ElRadio value="on">{{ t('triOn') }}</ElRadio>
                </ElRadioGroup>
                <span class="re4-material-name">{{ label(slot.id, material.name, material.note) }}</span>
              </template>
            </li>
          </ul>
        </div>
      </template>
    </section>
  </div>
</template>

<style>
.re4-editor { display: grid; grid-template-columns: minmax(9em, 13em) minmax(12em, 18em) minmax(0, 1fr); flex: 1; min-height: 0; padding: 6px 0 10px; }
.re4-editor-col { min-width: 0; overflow: auto; padding: 0 12px; border-right: 1px solid var(--avm-line); }
.re4-editor-col:last-child { border-right: 0; }
.re4-editor-layers { display: flex; flex-direction: column; gap: 1px; }
.re4-inline { display: flex; gap: 6px; margin: 6px 0; min-width: 0; }
.re4-inline > .el-input { flex: 1 1 6em; min-width: 0; }
.re4-warning { margin-top: 8px; padding: 6px 8px; border: 1px solid color-mix(in srgb, var(--el-color-warning, #e6a23c) 45%, var(--avm-line)); color: var(--avm-ink); font-size: var(--reff-font-size-xs, 12px); }
.re4-warning p { margin: 0 0 2px; overflow-wrap: anywhere; }
.re4-preset-list { list-style: none; margin: 6px 0; padding: 0; }
.re4-preset-list li { display: flex; flex-wrap: wrap; align-items: center; gap: 4px 6px; padding: 3px 0; border-bottom: 1px solid var(--avm-line); }
.re4-preset-list li.editing { background: var(--avm-active); }
.re4-preset-name { display: inline-flex; align-items: center; gap: 6px; flex: 1 1 6em; min-width: 0; padding: 2px 4px; color: var(--avm-ink); background: none; border: 0; text-align: left; overflow-wrap: anywhere; }
.re4-preset-name[aria-pressed='true'] { color: var(--avm-accent); }
.re4-preset-actions { display: inline-flex; gap: 2px; }
.re4-materials-head { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
.re4-slot-filter { margin: 4px 0 8px; flex-wrap: wrap; }
.re4-slot { margin-bottom: 10px; }
.re4-slot-head { display: flex; flex-wrap: wrap; align-items: center; gap: 4px 10px; padding: 4px 0; border-bottom: 1px solid var(--avm-line); }
.re4-slot-actions { display: inline-flex; gap: 4px; margin-left: auto; }
.re4-material-list { list-style: none; margin: 0; padding: 0; }
.re4-material-list li { display: flex; align-items: center; gap: 6px 10px; min-height: 28px; padding: 1px 0; }
.re4-material-list li.locating { background: var(--avm-active); }
.re4-material-name { flex: 1; min-width: 0; overflow-wrap: anywhere; }
.re4-material-list .el-input { flex: 1 1 10em; min-width: 0; }
.avm .re4-tri.el-radio-group { flex-wrap: nowrap; gap: 0 8px; }
.avm .re4-tri .el-radio { margin-right: 0; }
@media (max-width: 900px) { .re4-editor { grid-template-columns: minmax(0, 1fr); } .re4-editor-col { border-right: 0; border-bottom: 1px solid var(--avm-line); padding-bottom: 8px; } }
</style>
