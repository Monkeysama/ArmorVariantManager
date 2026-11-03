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
const sortGroups = shallowRef(false);
const sortPresets = shallowRef(false);
const disabled = computed(() => props.busy || !props.snapshot.bodyId);
const customGroups = computed(() => props.snapshot.groups.filter(item => item.name !== ''));
const group = computed(() => props.snapshot.groups.find(item => item.name === props.snapshot.group));
const selected = computed(() => props.snapshot.presets.find(item => item.name === props.snapshot.selectedPreset));
const selectionCount = computed(() => Object.values(props.snapshot.pending).reduce((total, part) => total + Object.values(part).filter(Boolean).length, 0));
watch([() => props.snapshot.bodyId, () => props.snapshot.group], () => { confirmation.value = null; });
watch([() => props.snapshot.game, () => props.snapshot.bodyId, () => props.snapshot.weapon, () => props.snapshot.selectionMode], () => {
  groupName.value = ''; global.value = false;
});

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
    <div class="pane-heading"><h2>{{ t('groups') }}</h2><span class="count">{{ snapshot.groups.length }}</span><button class="sort-toggle" :aria-pressed="sortGroups" :disabled="disabled || customGroups.length < 2" @click="sortGroups = !sortGroups">{{ t(sortGroups ? 'finishSort' : 'sort') }}</button></div>
    <div class="catalog-list">
      <div v-for="item in snapshot.groups" :key="item.name" class="sortable-row">
      <button class="catalog-row" :aria-pressed="snapshot.group === item.name" :disabled="disabled" @click="chooseGroup(item.name)">
        <span class="row-name" :title="item.label">{{ item.label }}</span><span v-if="item.global" class="row-tag">{{ t('global') }}</span><span class="row-arrow" aria-hidden="true">›</span>
      </button>
      <div v-if="sortGroups && item.name !== ''" class="sort-actions">
        <button v-for="offset in ([-1, 1] as const)" :key="offset" class="move-button" :aria-label="t(offset === -1 ? 'moveUp' : 'moveDown') + ' · ' + item.label" :title="t(offset === -1 ? 'moveUp' : 'moveDown')" :disabled="disabled || (offset === -1 ? customGroups[0]?.name === item.name : customGroups[customGroups.length - 1]?.name === item.name)" @click="perform({ kind: 'reorder-group', name: item.name, offset })"><svg viewBox="0 0 16 16" fill="none" aria-hidden="true"><path :d="offset === -1 ? 'M4 10 8 6l4 4' : 'm4 6 4 4 4-4'" /></svg></button>
      </div>
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
    <div class="pane-heading"><h2>{{ t('presets') }}</h2><span class="count">{{ snapshot.presets.length }}</span><button class="sort-toggle" :aria-pressed="sortPresets" :disabled="disabled || snapshot.presets.length < 2" @click="sortPresets = !sortPresets">{{ t(sortPresets ? 'finishSort' : 'sort') }}</button></div>
    <div class="group-caption">{{ group?.label ?? t('main') }}</div>
    <div class="catalog-list">
      <div v-for="(item, index) in snapshot.presets" :key="item.name" class="sortable-row">
      <button class="catalog-row preset-row" :aria-pressed="snapshot.selectedPreset === item.name" :disabled="disabled" @click="choosePreset(item.name)">
        <span class="row-name" :title="item.name">{{ item.name }}</span><span v-if="item.default" class="default-star" :title="t('default')" :aria-label="t('default')">★</span><span v-if="item.active" class="active-dot" :title="t('active')" :aria-label="t('active')"></span>
      </button>
      <div v-if="sortPresets" class="sort-actions">
        <button v-for="offset in ([-1, 1] as const)" :key="offset" class="move-button" :aria-label="t(offset === -1 ? 'moveUp' : 'moveDown') + ' · ' + item.name" :title="t(offset === -1 ? 'moveUp' : 'moveDown')" :disabled="disabled || (offset === -1 ? index === 0 : index === snapshot.presets.length - 1)" @click="perform({ kind: 'reorder-preset', name: item.name, offset })"><svg viewBox="0 0 16 16" fill="none" aria-hidden="true"><path :d="offset === -1 ? 'M4 10 8 6l4 4' : 'm4 6 4 4 4-4'" /></svg></button>
      </div>
      </div>
      <p v-if="!snapshot.presets.length" class="empty-note">{{ t('none') }}</p>
    </div>
    <form class="pane-actions" @submit.prevent="save">
      <label for="preset-name" class="field-label">{{ t('presetName') }}</label>
      <ElInput id="preset-name" v-model="presetName" :disabled="disabled" />
      <ElButton type="primary" native-type="submit" :disabled="disabled || !presetName.trim()">{{ t('save') }}</ElButton>
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
