<script setup lang="ts">
import { computed, nextTick, shallowRef, watch } from 'vue';
import { ElButton } from '@reff/ui';
import type { Documentation } from './types';
import type { Translate } from './i18n';

const props = defineProps<{ documentation: Documentation | null; loading: boolean; error: string; t: Translate }>();
defineEmits<{ retry: [] }>();
const selected = shallowRef('configure');
const content = shallowRef<HTMLElement | null>(null);
const section = computed(() => props.documentation?.sections.find(item => item.id === selected.value));
watch(() => props.documentation, value => {
  if (value && !value.sections.some(item => item.id === selected.value)) selected.value = value.sections[0]?.id ?? '';
});
watch([section, () => props.documentation], async () => { await nextTick(); if (content.value) content.value.scrollTop = 0; });

function moveTab(event: KeyboardEvent) {
  const sections = props.documentation?.sections ?? [];
  if (!sections.length || !['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
  event.preventDefault();
  const current = sections.findIndex(item => item.id === selected.value);
  const index = event.key === 'Home' ? 0 : event.key === 'End' ? sections.length - 1 : (current + (event.key === 'ArrowRight' ? 1 : -1) + sections.length) % sections.length;
  selected.value = sections[index].id;
  void nextTick(() => document.getElementById(`help-tab-${selected.value}`)?.focus());
}
</script>

<template>
  <section class="information help-page" :aria-label="t('help')" :aria-busy="loading">
    <div v-if="loading" class="help-state" role="status">{{ t('loadingHelp') }}</div>
    <div v-else-if="error" class="help-state help-error" role="alert"><p>{{ error }}</p><ElButton @click="$emit('retry')">{{ t('retryHelp') }}</ElButton></div>
    <template v-else-if="documentation">
      <div class="help-tabs" role="tablist" :aria-label="t('help')" @keydown="moveTab">
        <button v-for="item in documentation.sections" :id="`help-tab-${item.id}`" :key="item.id" role="tab" :aria-selected="selected === item.id" :aria-controls="`help-panel-${item.id}`" :tabindex="selected === item.id ? 0 : -1" @click="selected = item.id">{{ item.title }}</button>
      </div>
      <article v-if="section" :id="`help-panel-${section.id}`" ref="content" class="help-content" role="tabpanel" :aria-labelledby="`help-tab-${section.id}`" tabindex="0">
        <h2>{{ section.title }}</h2>
        <section v-for="(entry, index) in section.entries" :key="index" class="help-entry">
          <h3 v-if="entry.title">{{ entry.title }}</h3>
          <p v-for="(paragraph, paragraphIndex) in entry.paragraphs" :key="paragraphIndex">{{ paragraph }}</p>
        </section>
      </article>
      <p v-else class="empty-note">{{ t('noHelp') }}</p>
    </template>
  </section>
</template>
