<script setup lang="ts">
import { computed } from 'vue';
import { ElRadio, ElRadioGroup } from '@reff/ui';
import SettingControl from './SettingControl.vue';
import type { PanelTheme, Perform, Snapshot } from './types';
import type { Translate } from './i18n';

const props = defineProps<{ snapshot: Snapshot; busy: boolean; perform: Perform; t: Translate }>();
const sections = computed(() => (props.snapshot.settings?.sections ?? []).filter(section => section.id !== 'ground_clipping').map(section => {
  const fields = section.fields;
  const reason = fields[0]?.reason;
  return { ...section, sharedReason: reason && fields.every(field => field.disabled && field.reason === reason) ? reason : undefined };
}));
</script>

<template>
  <section class="information settings-page" :aria-label="t('settings')">
    <h2>{{ t('settings') }}</h2>
    <section class="settings-section theme-settings" :aria-label="t('theme')">
      <h3>{{ t('theme') }}</h3>
      <ElRadioGroup :model-value="snapshot.theme" :disabled="busy" @change="(value: string | number | boolean | undefined) => perform({ kind: 'theme', value: value as PanelTheme })">
        <ElRadio value="white">{{ t('classicWhite') }}</ElRadio>
        <ElRadio value="black">{{ t('classicBlack') }}</ElRadio>
        <ElRadio value="glass">{{ t('glass') }}</ElRadio>
        <ElRadio value="custom">{{ t('custom') }}</ElRadio><ElRadio value="reff">{{ t('follow') }}</ElRadio>
      </ElRadioGroup>
      <p class="setting-note">{{ t('themeHelp') }} {{ t('scope') }}</p>
    </section>
    <section v-for="section in sections" :key="section.id" class="settings-section" :aria-label="section.label" :aria-describedby="section.sharedReason ? 'settings-' + section.id + '-reason' : undefined">
      <h3>{{ section.label }}</h3>
      <p v-if="section.description" class="settings-section-description">{{ section.description }}</p>
      <p v-if="section.sharedReason" :id="'settings-' + section.id + '-reason'" class="settings-section-description setting-reason">{{ section.sharedReason }}</p>
      <div class="settings-fields">
        <SettingControl v-for="field in section.fields" :key="field.id + (field.id === 'reff_scale_with_panel' ? ':' + snapshot.theme : section.scope === 'equipment' ? ':' + snapshot.bodyId : '')" :field="section.sharedReason ? { ...field, reason: undefined } : field" :disabled="busy || !!field.disabled || (section.scope === 'equipment' && !snapshot.bodyId)" :save="value => perform({ kind: 'setting', id: field.id, ...(value !== undefined ? { value } : {}) })" :t="t" />
      </div>
    </section>
  </section>
</template>
