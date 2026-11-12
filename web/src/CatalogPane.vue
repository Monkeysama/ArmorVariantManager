<script setup lang="ts">
import { computed, shallowRef, watch } from 'vue';
import { ElButton, ElCheckbox, ElInput, ElTag } from '@reff/ui';
import ImportPresetPane from './ImportPresetPane.vue';
import type { Imports, Perform, Snapshot } from './types';
import type { Translate } from './i18n';
import { useCatalogSort, type CatalogList } from './useCatalogSort';

const props = defineProps<{ snapshot: Snapshot; active: boolean; busy: boolean; perform: Perform; loadImports: () => Promise<Imports>; t: Translate }>();
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
const group = computed(() => props.snapshot.groups.find(item => item.name === props.snapshot.group));
const selected = computed(() => props.snapshot.presets.find(item => item.name === props.snapshot.selectedPreset));
const selectionCount = computed(() => Object.values(props.snapshot.pending).reduce((total, part) => total + Object.values(part).filter(Boolean).length, 0));
watch([() => props.snapshot.bodyId, () => props.snapshot.group], () => { confirmation.value = null; });
watch([() => props.snapshot.game, () => props.snapshot.bodyId, () => props.snapshot.weapon, () => props.snapshot.selectionMode], () => {
  groupName.value = ''; global.value = false;
});

function sortable(list: CatalogList, name: string) {
  return props.active && !props.snapshot.suspended && !disabled.value
    && (list === 'group' ? customGroups.value : props.snapshot.presets).some(item => item.name === name);
}
const { begin: beginDrag, cancel: cancelDrag, acceptClick, rowClass } = useCatalogSort({ sortable,
  commit: (list, name, target, after) => props.perform({ kind: list === 'group' ? 'reorder-group' : 'reorder-preset',
    name, target, after, group: props.snapshot.group, weapon: props.snapshot.weapon }),
});
watch([() => props.snapshot.game, () => props.snapshot.bodyId, () => props.snapshot.weapon, () => props.snapshot.group,
  () => props.snapshot.selectionMode, () => props.snapshot.suspended, () => props.busy, () => props.active], cancelDrag, { flush: 'sync' });

async function moveWithKey(event: KeyboardEvent, list: CatalogList, name: string) {
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
    <div class="catalog-list" @dragstart.prevent>
      <div v-for="item in groups" :key="item.name" class="sortable-row" :class="rowClass('group', item.name)"
        data-sort-list="group" :data-sort-name="item.name">
      <button class="catalog-row" :aria-pressed="snapshot.group === item.name" :disabled="disabled"
        :draggable="false" :data-sortable="sortable('group', item.name)" :aria-keyshortcuts="item.name && !item.global ? 'Alt+ArrowUp Alt+ArrowDown' : undefined"
        @pointerdown="beginDrag($event, 'group', item.name)"
        @keydown="moveWithKey($event, 'group', item.name)" @click="acceptClick($event) && chooseGroup(item.name)">
        <span class="row-name" :title="item.label">{{ item.label }}</span><span v-if="item.global" class="row-tag">{{ t('global') }}</span>
        <svg v-if="item.name && !item.global" class="drag-handle" viewBox="0 0 16 16" :aria-label="t('sort')" role="img"><path d="M5 3h1m4 0h1M5 8h1m4 0h1M5 13h1m4 0h1" /></svg>
      </button>
      </div>
    </div>
    <div class="pane-actions"><strong class="action-heading">{{ t('groupActions') }}</strong>
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
    <div class="pane-heading"><h2>{{ group?.label ?? t('main') }} · {{ t('presets') }}</h2><span class="count">{{ snapshot.presets.length }}</span></div>

    <div class="catalog-list" @dragstart.prevent>
      <div v-for="item in snapshot.presets" :key="item.name" class="sortable-row" :class="rowClass('preset', item.name)"
        data-sort-list="preset" :data-sort-name="item.name">
      <button class="catalog-row preset-row" :aria-pressed="snapshot.selectedPreset === item.name" :disabled="disabled"
        :draggable="false" :data-sortable="sortable('preset', item.name)" aria-keyshortcuts="Alt+ArrowUp Alt+ArrowDown"
        @pointerdown="beginDrag($event, 'preset', item.name)"
        @keydown="moveWithKey($event, 'preset', item.name)" @click="acceptClick($event) && choosePreset(item.name)">
        <span class="row-name" :title="item.name">{{ item.name }}</span>
        <ElTag v-if="item.default" class="avm-tag tag-default" size="small">{{ t('default') }}</ElTag>
        <span v-if="item.active" class="active-dot" :title="t('active')" :aria-label="t('active')"></span>
        <svg class="drag-handle" viewBox="0 0 16 16" :aria-label="t('sort')" role="img"><path d="M5 3h1m4 0h1M5 8h1m4 0h1M5 13h1m4 0h1" /></svg>
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

    </form>
    <Teleport to="#file-tools"><ImportPresetPane v-if="snapshot.game === 'Rise' && snapshot.canImport" :snapshot="snapshot" :busy="busy" :perform="perform" :load-imports="loadImports" :t="t" @imported="presetName = ''" />
<ElButton :disabled="disabled" @click="perform({ kind: 'find' })">{{ t('find') }}</ElButton></Teleport>
  </section>
</template>
