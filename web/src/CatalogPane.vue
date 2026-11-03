<script setup lang="ts">
import { computed, shallowRef, watch } from 'vue';
import { ElButton, ElCheckbox, ElInput } from '@reff/ui';
import ImportPresetPane from './ImportPresetPane.vue';
import type { Imports, Perform, Snapshot } from './types';
import type { Translate } from './i18n';

const props = defineProps<{ snapshot: Snapshot; busy: boolean; perform: Perform; loadImports: () => Promise<Imports>; t: Translate }>();
const emit = defineEmits<{ notice: [message: string] }>();
const groupName = shallowRef('');
const global = shallowRef(false);
const presetName = shallowRef(props.snapshot.selectedPreset);
const confirmation = shallowRef<{ kind: 'delete-group' | 'delete-preset'; name: string } | null>(null);
const disabled = computed(() => props.busy || !props.snapshot.bodyId);
const groups = computed(() => [
  ...props.snapshot.groups.filter(item => item.name === ''),
  ...props.snapshot.groups.filter(item => item.name !== '' && item.global),
  ...props.snapshot.groups.filter(item => item.name !== '' && !item.global),
]);
const customGroups = computed(() => groups.value.filter(item => item.name !== '' && !item.global));
type List = 'group' | 'preset';
const dragging = shallowRef<{ list: List; name: string } | null>(null);
const dropTarget = shallowRef<{ list: List; name: string; after: boolean } | null>(null);
const group = computed(() => props.snapshot.groups.find(item => item.name === props.snapshot.group));
const selected = computed(() => props.snapshot.presets.find(item => item.name === props.snapshot.selectedPreset));
const selectionCount = computed(() => Object.values(props.snapshot.pending).reduce((total, part) => total + Object.values(part).filter(Boolean).length, 0));
watch([() => props.snapshot.bodyId, () => props.snapshot.group], () => { confirmation.value = null; });
watch([() => props.snapshot.game, () => props.snapshot.bodyId, () => props.snapshot.weapon, () => props.snapshot.selectionMode], () => {
  groupName.value = ''; global.value = false;
});
watch([() => props.snapshot.game, () => props.snapshot.bodyId, () => props.snapshot.weapon, () => props.snapshot.group,
  () => props.snapshot.selectionMode, () => props.snapshot.suspended, () => props.busy], cancelDrag, { flush: 'sync' });

function sortable(list: List, name: string) {
  return !disabled.value && (list === 'group' ? customGroups.value : props.snapshot.presets).some(item => item.name === name);
}
function cancelDrag() { dragging.value = null; dropTarget.value = null; }
function beginDrag(event: DragEvent, list: List, name: string) {
  if (!sortable(list, name) || !event.dataTransfer) { event.preventDefault(); return; }
  dragging.value = { list, name };
  event.dataTransfer.effectAllowed = 'move';
  event.dataTransfer.setData('text/plain', name);
}
function previewDrop(event: DragEvent, list: List, name: string) {
  if (dragging.value?.list !== list || dragging.value.name === name || !sortable(list, name)) {
    dropTarget.value = null; return;
  }
  event.preventDefault();
  if (event.dataTransfer) event.dataTransfer.dropEffect = 'move';
  const rect = (event.currentTarget as HTMLElement).getBoundingClientRect();
  dropTarget.value = { list, name, after: event.clientY >= rect.top + rect.height / 2 };
}
async function finishDrag(event: DragEvent, list: List, name: string) {
  event.preventDefault();
  const source = dragging.value, target = dropTarget.value;
  cancelDrag();
  if (!source || source.list !== list || !target || target.list !== list || target.name !== name
    || !sortable(list, source.name) || !sortable(list, name)) return;
  await props.perform({ kind: list === 'group' ? 'reorder-group' : 'reorder-preset', name: source.name,
    target: name, after: target.after, group: props.snapshot.group, weapon: props.snapshot.weapon });
}
function rowClass(list: List, name: string) {
  return { 'is-dragging': dragging.value?.list === list && dragging.value.name === name,
    'drop-before': dropTarget.value?.list === list && dropTarget.value.name === name && !dropTarget.value.after,
    'drop-after': dropTarget.value?.list === list && dropTarget.value.name === name && dropTarget.value.after };
}
function leaveList(event: DragEvent) {
  if (!(event.relatedTarget instanceof Node) || !(event.currentTarget as HTMLElement).contains(event.relatedTarget)) dropTarget.value = null;
}
async function moveWithKey(event: KeyboardEvent, list: List, name: string) {
  if (!event.altKey || (event.key !== 'ArrowUp' && event.key !== 'ArrowDown') || !sortable(list, name)) return;
  event.preventDefault();
  const names = (list === 'group' ? customGroups.value : props.snapshot.presets).map(item => item.name);
  const index = names.indexOf(name), target = names[index + (event.key === 'ArrowUp' ? -1 : 1)];
  if (target) await props.perform({ kind: list === 'group' ? 'reorder-group' : 'reorder-preset', name,
    target, after: event.key === 'ArrowDown', group: props.snapshot.group, weapon: props.snapshot.weapon });
}

async function startGroup() {
  if (await props.perform({ kind: 'selection', enabled: true })) confirmation.value = null;
}

async function chooseGroup(name: string) {
  if (await props.perform({ kind: 'group', name })) presetName.value = '';
}
async function choosePreset(name: string) {
  if (await props.perform({ kind: 'preset', name })) presetName.value = name;
}
async function create() {
  const name = groupName.value.trim();
  if (name && await props.perform({ kind: 'create-group', name, global: global.value })) {
    groupName.value = ''; emit('notice', `${props.t('created')} · ${name}`);
  }
}
async function save() {
  const name = presetName.value.trim();
  if (name && await props.perform({ kind: 'save', name })) emit('notice', `${props.t('saved')} · ${name}`);
}
async function remove() {
  const target = confirmation.value;
  if (target && await props.perform(target)) {
    confirmation.value = null;
    if (target.kind === 'delete-preset') presetName.value = '';
  }
}
</script>

<template>
  <section class="pane groups-pane" :aria-label="t('groups')">
    <div class="pane-heading"><h2>{{ t('groups') }}</h2><span class="count">{{ snapshot.groups.length }}</span></div>
    <div class="catalog-list" @dragleave="leaveList">
      <div v-for="item in groups" :key="item.name" class="sortable-row" :class="rowClass('group', item.name)"
        @dragover="previewDrop($event, 'group', item.name)" @drop="finishDrag($event, 'group', item.name)">
      <button class="catalog-row" :aria-pressed="snapshot.group === item.name" :disabled="disabled"
        :draggable="sortable('group', item.name)" :aria-keyshortcuts="item.name && !item.global ? 'Alt+ArrowUp Alt+ArrowDown' : undefined"
        @dragstart="beginDrag($event, 'group', item.name)" @dragend="cancelDrag"
        @keydown="moveWithKey($event, 'group', item.name)" @click="chooseGroup(item.name)">
        <svg v-if="item.name && !item.global" class="drag-handle" viewBox="0 0 16 16" :aria-label="t('sort')" role="img"><path d="M5 3h1m4 0h1M5 8h1m4 0h1M5 13h1m4 0h1" /></svg>
        <span class="row-name" :title="item.label">{{ item.label }}</span><span v-if="item.global" class="row-tag">{{ t('global') }}</span><span class="row-arrow" aria-hidden="true">›</span>
      </button>
      </div>
    </div>
    <div class="pane-actions">
      <ElButton v-if="!snapshot.selectionMode" class="new-group-button" :disabled="disabled" @click="startGroup">{{ t('newGroup') }}</ElButton>
      <template v-else>
        <p class="field-note">{{ t('selected') }} {{ selectionCount }} · {{ t('selectionHelp') }}</p>
        <label for="group-name" class="field-label">{{ t('groupName') }}</label>
        <ElInput id="group-name" v-model="groupName" :disabled="disabled" @keyup.enter="create" />
        <ElCheckbox v-model="global" class="global-group-toggle" :disabled="disabled">{{ t('global') }}</ElCheckbox>
        <div class="button-pair">
          <ElButton class="create-group-button" :disabled="disabled || !groupName.trim()" @click="create">{{ t('create') }}</ElButton>
          <ElButton class="cancel-group-button" :disabled="disabled" @click="perform({ kind: 'selection', enabled: false })">{{ t('cancel') }}</ElButton>
        </div>
      </template>
      <ElButton class="quiet-danger" :disabled="disabled || snapshot.group === ''" @click="confirmation = { kind: 'delete-group', name: snapshot.group }">{{ t('delete') }}{{ ' · ' + (group?.label ?? '') }}</ElButton>
      <div v-if="confirmation?.kind === 'delete-group'" class="delete-confirm" role="alert">
        <p>{{ t('confirmDelete') }}「{{ confirmation.name }}」？</p>
        <div class="button-pair"><ElButton @click="confirmation = null">{{ t('cancel') }}</ElButton><ElButton :disabled="disabled" @click="remove">{{ t('confirm') }}</ElButton></div>
      </div>
    </div>
  </section>
  <section class="pane presets-pane" :aria-label="t('presets')">
    <div class="pane-heading"><h2>{{ t('presets') }}</h2><span class="count">{{ snapshot.presets.length }}</span></div>
    <div class="group-caption">{{ group?.label ?? t('main') }}</div>
    <div class="catalog-list" @dragleave="leaveList">
      <div v-for="item in snapshot.presets" :key="item.name" class="sortable-row" :class="rowClass('preset', item.name)"
        @dragover="previewDrop($event, 'preset', item.name)" @drop="finishDrag($event, 'preset', item.name)">
      <button class="catalog-row preset-row" :aria-pressed="snapshot.selectedPreset === item.name" :disabled="disabled"
        :draggable="sortable('preset', item.name)" aria-keyshortcuts="Alt+ArrowUp Alt+ArrowDown"
        @dragstart="beginDrag($event, 'preset', item.name)" @dragend="cancelDrag"
        @keydown="moveWithKey($event, 'preset', item.name)" @click="choosePreset(item.name)">
        <svg class="drag-handle" viewBox="0 0 16 16" :aria-label="t('sort')" role="img"><path d="M5 3h1m4 0h1M5 8h1m4 0h1M5 13h1m4 0h1" /></svg>
        <span class="row-name" :title="item.name">{{ item.name }}</span><svg v-if="item.default" class="default-star" viewBox="0 0 16 16" :aria-label="t('default')" role="img"><title>{{ t('default') }}</title><path d="m8 1.5 1.9 4 4.4.6-3.2 3.1.8 4.4L8 11.5l-3.9 2.1.8-4.4-3.2-3.1 4.4-.6Z" /></svg><span v-if="item.active" class="active-dot" :title="t('active')" :aria-label="t('active')"></span>
      </button>
      </div>
      <p v-if="!snapshot.presets.length" class="empty-note">{{ t('none') }}</p>
    </div>
    <form class="pane-actions" @submit.prevent="save">
      <label for="preset-name" class="field-label">{{ t('presetName') }}</label>
      <div class="preset-save-line">
        <ElInput id="preset-name" v-model="presetName" :disabled="disabled" />
        <ElButton type="primary" native-type="submit" :disabled="disabled || !presetName.trim()">{{ t('save') }}</ElButton>
      </div>
      <div class="button-pair">
        <ElButton :disabled="disabled || !selected" @click="confirmation = { kind: 'delete-preset', name: snapshot.selectedPreset }">{{ t('delete') }}</ElButton>
        <ElButton :disabled="disabled || !selected" @click="perform({ kind: 'default', name: snapshot.selectedPreset })">{{ t('setDefault') }}</ElButton>
      </div>
      <div v-if="confirmation?.kind === 'delete-preset'" class="delete-confirm" role="alert">
        <p>{{ t('confirmDelete') }}「{{ confirmation.name }}」？</p>
        <div class="button-pair"><ElButton @click="confirmation = null">{{ t('cancel') }}</ElButton><ElButton :disabled="disabled" @click="remove">{{ t('confirm') }}</ElButton></div>
      </div>
      <ElButton :disabled="disabled" @click="perform({ kind: 'find' })">{{ t('find') }}</ElButton>
    </form>
    <ImportPresetPane v-if="snapshot.game === 'Rise' && snapshot.canImport" :snapshot="snapshot" :busy="busy" :perform="perform" :load-imports="loadImports" :t="t" @imported="presetName = ''" />
  </section>
</template>
