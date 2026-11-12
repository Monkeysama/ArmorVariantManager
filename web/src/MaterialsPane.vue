<script setup lang="ts">
import { computed, shallowRef, watch } from 'vue';
import { ElInput, ElTooltip } from '@reff/ui';
import PartCard from './PartCard.vue';
import SettingControl from './SettingControl.vue';
import type { Perform, Snapshot } from './types';
import type { Translate } from './i18n';

const props = defineProps<{ snapshot: Snapshot; busy: boolean; perform: Perform; t: Translate }>();
const selectedIndex = shallowRef<number | null>(null);
const query = shallowRef('');
watch([() => props.snapshot.bodyId, () => props.snapshot.weapon], () => {
  selectedIndex.value = null;
  query.value = '';
});
const height = computed(() =>
  !props.snapshot.bodyId || props.snapshot.weapon
    ? undefined
    : props.snapshot.settings?.sections.find((section) => section.id === 'ground_clipping'),
);
const heightUnavailableReason = computed(() => {
  const fields = height.value?.fields ?? [];
  const reason = fields[0]?.reason;
  return reason && fields.every((field) => field.disabled && field.reason === reason) ? reason : undefined;
});
const shown = computed(() => {
  const filter = query.value.trim().toLowerCase();
  return props.snapshot.parts.filter(
    (part) =>
      (selectedIndex.value === null || part.index === selectedIndex.value) &&
      (!filter || part.materials.some((material) => material.name.toLowerCase().includes(filter))),
  );
});
</script>
<template>
  <section class="materials-pane">
    <ElInput v-model="query" clearable :aria-label="t('search')" :placeholder="t('search')" />
    <nav class="part-list" :aria-label="t('parts')">
      <button class="part-row" :aria-pressed="selectedIndex === null" @click="selectedIndex = null">{{ t('allParts') }}</button>
      <button
        class="part-row"
        v-for="p in snapshot.parts"
        :key="p.index"
        :aria-pressed="selectedIndex === p.index"
        @click="selectedIndex = p.index"
      >
        {{ p.label.split(' [')[0] }}
      </button>
    </nav>
    <div class="parts-scroll">
      <PartCard
        v-for="p in shown"
        :key="p.index"
        :part="p"
        :query="query"
        :snapshot="snapshot"
        :busy="busy"
        :perform="perform"
        :t="t"
      />
      <p v-if="!shown.length">{{ query ? t('noMatches') : t('noParts') }}</p>
    </div>
    <section v-if="height" class="height-pane" :aria-label="height.label">
      <p v-if="heightUnavailableReason" class="setting-note height-unavailable" role="status">{{ heightUnavailableReason }}</p>
      <div v-else class="height-controls">
        <SettingControl
          v-for="field in height.fields"
          :key="snapshot.bodyId + ':' + snapshot.group + ':' + snapshot.selectedPreset + ':' + field.id"
          :field="field.type === 'boolean' ? { ...field, label: height.label } : field"
          :disabled="busy || !snapshot.bodyId || !!field.disabled"
          :save="(value) => perform({ kind: 'setting', id: field.id, ...(value !== undefined ? { value } : {}) })"
          :t="t"
        />
        <ElTooltip
          :trigger="['hover', 'focus']"
          placement="top-end"
          :teleported="false"
          :show-after="250"
          popper-class="height-tooltip"
        >
          <template #content
            ><p>{{ height.description || t('heightDraft') }}</p></template
          >
          <button class="height-help-button" type="button" :aria-label="t('heightHelp')">
            <svg viewBox="0 0 20 20" fill="none" aria-hidden="true">
              <circle cx="10" cy="10" r="7.25" />
              <path d="M10 9v5M10 6v.5" />
            </svg>
          </button>
        </ElTooltip>
      </div>
    </section>
  </section>
</template>
