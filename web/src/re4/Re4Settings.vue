<script setup lang="ts">
import { ElInputNumber, ElRadio, ElRadioGroup, ElSwitch } from '@reff/ui';
import type { Re4Translate } from './i18n';
import type { Re4Perform, Re4Snapshot } from './types';

// 全局设置，与 REF 面板顶部的几个开关是同一份（GlobalSettings.json）。
const props = defineProps<{ snapshot: Re4Snapshot; busy: boolean; perform: Re4Perform; t: Re4Translate }>();
function setTime(value: number | undefined | null) {
  if (typeof value === 'number' && Number.isFinite(value)) void props.perform({ kind: 'setting', id: 'ui_dissolve_time', value });
}
</script>

<template>
  <div class="re4-settings">
    <section class="re4-section">
      <div class="re4-row">
        <span class="re4-row-label">{{ t('language') }}</span>
        <ElRadioGroup :model-value="snapshot.language" :disabled="busy" @change="value => perform({ kind: 'setting', id: 'language', value: value === 'en' ? 'en' : 'zh' })">
          <ElRadio value="zh">中文</ElRadio>
          <ElRadio value="en">English</ElRadio>
        </ElRadioGroup>
      </div>
      <div class="re4-row">
        <span class="re4-row-label">{{ t('weaponHide') }}</span>
        <ElSwitch :model-value="snapshot.settings.weaponHideStorage" :disabled="busy"
          @change="value => perform({ kind: 'setting', id: 'weapon_hide_storage', value: value === true })" />
      </div>
      <div class="re4-row">
        <span class="re4-row-label">{{ t('uiDissolve') }}</span>
        <ElSwitch :model-value="snapshot.settings.uiDissolveEnabled" :disabled="busy"
          @change="value => perform({ kind: 'setting', id: 'ui_dissolve_enabled', value: value === true })" />
      </div>
      <div v-if="snapshot.settings.uiDissolveEnabled" class="re4-row">
        <span class="re4-row-label">{{ t('uiDissolveTime') }}</span>
        <ElInputNumber :model-value="snapshot.settings.uiDissolveTime" :min="0" :max="30" :step="0.1" :precision="1" :disabled="busy" @change="setTime" />
      </div>
      <p class="re4-note">{{ t('uiDissolveHint') }}</p>
    </section>
  </div>
</template>
