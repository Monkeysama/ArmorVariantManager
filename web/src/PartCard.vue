<script setup lang="ts">
import { computed, shallowRef } from 'vue';
import { ElButton, ElCheckbox, ElTag } from '@reff/ui';
import type { Action, Part, Material, Perform, Snapshot } from './types';
import type { Translate } from './i18n';

const props = defineProps<{ snapshot: Snapshot; busy: boolean; perform: Perform; t: Translate; part: Part; query: string }>();

const collapsed = shallowRef(false);
const disabled = computed(() => props.busy || !props.snapshot.bodyId || !props.part.available);
const materials = computed(
  () => props.part.materials.filter((item) => item.name.toLowerCase().includes(props.query.trim().toLowerCase())) ?? [],
);
const visibleCount = computed(() => props.part.materials.filter((item) => item.enabled && !item.hidden).length ?? 0);
const selectedCount = computed(
  () => Object.values(props.snapshot.pending[String(props.part.index)] ?? {}).filter(Boolean).length,
);
function checked(material: Material) {
  return props.snapshot.selectionMode ? !!props.snapshot.pending[String(props.part.index)]?.[material.name] : material.enabled;
}
function editable(material: Material) {
  return props.snapshot.selectionMode || (material.editable !== false && !material.hidden);
}
function toggle(material: Material, enabled: boolean) {
  void props.perform({
    kind: props.snapshot.selectionMode ? 'select-material' : 'material',
    part: props.part.index,
    name: material.name,
    enabled,
  });
}
function bulk(enabled: boolean) {
  const index = props.part.index;
  const actions: Action[] = materials.value
    .filter(editable)
    .filter((item) => checked(item) !== enabled)
    .map((item) => ({
      kind: props.snapshot.selectionMode ? 'select-material' : 'material',
      part: index,
      name: item.name,
      enabled,
    }));
  if (actions.length) void props.perform(actions);
}
function groupLabel(name: string) {
  return props.snapshot.groups.find((item) => item.name === name)?.label ?? name;
}
function partName(label: string) {
  return label.replace(/\s+\[[^\]]+\]$/, '');
}
function partId(label: string) {
  return /\s+\[([^\]]+)\]$/.exec(label)?.[1];
}
</script>
<template>
  <div class="material-detail">
    <button class="part-title" type="button" :aria-expanded="!collapsed" @click="collapsed = !collapsed">
      <span>{{ collapsed ? '▸' : '▾' }}　{{ partName(part.label) }}</span
      ><span class="id-tag">{{ partId(part.label) }}</span>
    </button>
    <div v-show="!collapsed">
      <div class="mesh-line">
        <ElCheckbox
          :model-value="part.enabled"
          :disabled="disabled || part.meshLocked || snapshot.selectionMode"
          @change="(value: boolean | string | number) => perform({ kind: 'mesh', part: part.index, enabled: !!value })"
          >{{ t('mesh') }}</ElCheckbox
        >
        <span v-if="part.meshLocked" class="count">{{ t('locked') }}</span>
        <span v-else class="count"
          >{{ snapshot.selectionMode ? t('selected') : t('visibleCount') }}
          {{ snapshot.selectionMode ? selectedCount : visibleCount }}/{{ part.materials.length }}</span
        >
      </div>

      <div class="bulk-actions">
        <ElButton text :disabled="disabled || !materials.length" @click="bulk(true)">{{
          snapshot.selectionMode ? t('all') : t('showAll')
        }}</ElButton>
        <ElButton text :disabled="disabled || !materials.length" @click="bulk(false)">{{
          snapshot.selectionMode ? t('clear') : t('hideAll')
        }}</ElButton>
      </div>
      <div class="material-list">
        <div
          v-for="material in materials"
          :key="material.name"
          class="material-row"
          :class="{ 'globally-hidden': material.hidden && !snapshot.selectionMode }"
        >
          <ElCheckbox
            :model-value="checked(material)"
            :disabled="disabled || !editable(material)"
            @change="(value: boolean | string | number) => toggle(material, !!value)"
            ><span class="material-name" :title="material.name">{{ material.name }}</span></ElCheckbox
          >
          <div v-if="material.hidden || material.owner || material.groups.length" class="material-meta">
            <span v-if="material.hidden" class="hidden-label">{{ t('hidden') }}</span>
            <ElTag
              v-if="material.owner"
              class="avm-tag tag-owner"
              size="small"
              :title="t('member') + ' · ' + groupLabel(material.owner)"
              >{{ groupLabel(material.owner) }}</ElTag
            >
            <ElTag
              v-for="name in material.groups"
              :key="name"
              class="avm-tag tag-global"
              size="small"
              :title="t('global') + ' · ' + groupLabel(name)"
              >{{ groupLabel(name) }}</ElTag
            >
          </div>
        </div>
        <p v-if="!part.available" class="empty-note">{{ t('unavailable') }}</p>
        <p v-else-if="!materials.length" class="empty-note">{{ query ? t('noMatches') : t('noMaterials') }}</p>
      </div>
      <div v-if="snapshot.selectionMode" class="selection-hint"><span class="active-dot"></span>{{ t('selecting') }}</div>
    </div>
  </div>
</template>
