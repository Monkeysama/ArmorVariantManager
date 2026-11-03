<script setup lang="ts">
import { computed, shallowRef } from 'vue';
import { ElButton, ElCheckbox, ElInput, ElTag, ElTooltip } from '@reff/ui';
import SettingControl from './SettingControl.vue';
import type { Action, Material, Perform, Snapshot } from './types';
import type { Translate } from './i18n';

const props = defineProps<{ snapshot: Snapshot; busy: boolean; perform: Perform; t: Translate }>();
const selectedIndex = shallowRef<number | null>(null);
const query = shallowRef('');
const part = computed(() => props.snapshot.parts.find(item => item.index === selectedIndex.value) ?? props.snapshot.parts.find(item => item.available) ?? props.snapshot.parts[0]);
const disabled = computed(() => props.busy || !props.snapshot.bodyId || !part.value?.available);
const materials = computed(() => part.value?.materials.filter(item => item.name.toLowerCase().includes(query.value.trim().toLowerCase())) ?? []);
const visibleCount = computed(() => part.value?.materials.filter(item => item.enabled && !item.hidden).length ?? 0);
const selectedCount = computed(() => Object.values(props.snapshot.pending[String(part.value?.index)] ?? {}).filter(Boolean).length);
const height = computed(() => !props.snapshot.bodyId || props.snapshot.weapon ? undefined : props.snapshot.settings?.sections.find(section => section.id === 'ground_clipping'));
const heightUnavailableReason = computed(() => {
  const fields = height.value?.fields ?? [];
  const reason = fields[0]?.reason;
  return reason && fields.every(field => field.disabled && field.reason === reason) ? reason : undefined;
});
function checked(material: Material) {
  return props.snapshot.selectionMode ? !!props.snapshot.pending[String(part.value?.index)]?.[material.name] : material.enabled;
}
function editable(material: Material) {
  return props.snapshot.selectionMode || (material.editable !== false && !material.hidden);
}
function toggle(material: Material, enabled: boolean) {
  if (part.value) void props.perform({ kind: props.snapshot.selectionMode ? 'select-material' : 'material', part: part.value.index, name: material.name, enabled });
}
function bulk(enabled: boolean) {
  if (!part.value) return;
  const index = part.value.index;
  const actions: Action[] = materials.value.filter(editable).filter(item => checked(item) !== enabled).map(item => ({ kind: props.snapshot.selectionMode ? 'select-material' : 'material', part: index, name: item.name, enabled }));
  if (actions.length) void props.perform(actions);
}
function groupLabel(name: string) { return props.snapshot.groups.find(item => item.name === name)?.label ?? name; }
function partName(label: string) { return label.replace(/\s+\[[^\]]+\]$/, ''); }
function partId(label: string) { return /\s+\[([^\]]+)\]$/.exec(label)?.[1]; }
</script>

<template>
  <section class="pane materials-pane" :aria-label="t('parts')">
    <div class="pane-heading"><h2>{{ snapshot.weapon ? t('weapon') : t('armor') }} · {{ t('parts') }}</h2><span class="count">{{ snapshot.parts.length }}</span></div>
    <div v-if="snapshot.bodyId && part" class="materials-layout">
      <nav class="part-list" :aria-label="t('parts')">
        <button v-for="item in snapshot.parts" :key="item.index" class="part-row" :class="{ unavailable: !item.available }" :aria-label="item.label" :title="item.label" :aria-pressed="part.index === item.index" @click="selectedIndex = item.index"><span class="part-name">{{ partName(item.label) }}</span><span class="part-count">{{ item.materials.length }}</span></button>
      </nav>
      <div class="material-detail">
        <div v-if="partId(part.label)" class="part-equipment equipment-id" :title="part.label">{{ partId(part.label) }}</div>
        <div class="mesh-line">
          <ElCheckbox :model-value="part.enabled" :disabled="disabled || part.meshLocked || snapshot.selectionMode" @change="(value: boolean | string | number) => perform({ kind: 'mesh', part: part.index, enabled: !!value })">{{ t('mesh') }}</ElCheckbox>
          <span v-if="part.meshLocked" class="count">{{ t('locked') }}</span>
          <span v-else class="count">{{ snapshot.selectionMode ? t('selected') : t('visibleCount') }} {{ snapshot.selectionMode ? selectedCount : visibleCount }}/{{ part.materials.length }}</span>
        </div>
        <ElInput v-model="query" clearable :aria-label="t('search')" :placeholder="t('search')" :disabled="!part.available" />
        <div class="bulk-actions">
          <ElButton text :disabled="disabled || !materials.length" @click="bulk(true)">{{ snapshot.selectionMode ? t('all') : t('showAll') }}</ElButton>
          <ElButton text :disabled="disabled || !materials.length" @click="bulk(false)">{{ snapshot.selectionMode ? t('clear') : t('hideAll') }}</ElButton>
        </div>
        <div class="material-list">
          <div v-for="material in materials" :key="material.name" class="material-row" :class="{ 'globally-hidden': material.hidden && !snapshot.selectionMode }">
            <ElCheckbox :model-value="checked(material)" :disabled="disabled || !editable(material)" @change="(value: boolean | string | number) => toggle(material, !!value)"><span class="material-name" :title="material.name">{{ material.name }}</span></ElCheckbox>
            <div v-if="material.hidden || material.owner || material.groups.length" class="material-meta">
              <span v-if="material.hidden" class="hidden-label">{{ t('hidden') }}</span>
              <ElTag v-if="material.owner" class="avm-tag tag-owner" size="small" :title="t('member') + ' · ' + groupLabel(material.owner)">{{ groupLabel(material.owner) }}</ElTag>
              <ElTag v-for="name in material.groups" :key="name" class="avm-tag tag-global" size="small" :title="t('global') + ' · ' + groupLabel(name)">{{ groupLabel(name) }}</ElTag>
            </div>
          </div>
          <p v-if="!part.available" class="empty-note">{{ t('unavailable') }}</p>
          <p v-else-if="!materials.length" class="empty-note">{{ query ? t('noMatches') : t('noMaterials') }}</p>
        </div>
        <div v-if="snapshot.selectionMode" class="selection-hint"><span class="active-dot"></span>{{ t('selecting') }}</div>
      </div>
    </div>
    <p v-else class="empty-note">{{ t('noParts') }}</p>
    <section v-if="height" class="height-pane" :aria-label="height.label">
      <p v-if="heightUnavailableReason" class="setting-note height-unavailable" role="status">{{ heightUnavailableReason }}</p>
      <div v-else class="height-controls">
        <SettingControl v-for="field in height.fields" :key="snapshot.bodyId + ':' + snapshot.group + ':' + snapshot.selectedPreset + ':' + field.id"
          :field="field.type === 'boolean' ? { ...field, label: height.label } : field"
          :disabled="busy || !snapshot.bodyId || !!field.disabled"
          :save="value => perform({ kind: 'setting', id: field.id, ...(value !== undefined ? { value } : {}) })" :t="t" />
        <ElTooltip :trigger="['hover', 'focus']" placement="top-end" :teleported="false" :show-after="250" popper-class="height-tooltip">
          <template #content><p>{{ height.description || t('heightDraft') }}</p></template>
          <button class="height-help-button" type="button" :aria-label="t('heightHelp')"><svg viewBox="0 0 20 20" fill="none" aria-hidden="true"><circle cx="10" cy="10" r="7.25" /><path d="M10 9v5M10 6v.5" /></svg></button>
        </ElTooltip>
      </div>
    </section>
  </section>
</template>
