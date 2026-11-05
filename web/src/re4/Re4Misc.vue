<script setup lang="ts">
import { shallowRef } from 'vue';
import { ElButton, ElInputNumber, ElSwitch } from '@reff/ui';
import type { Documentation } from '../types';
import type { Re4Translate } from './i18n';
import type { Re4Perform, Re4Snapshot } from './types';

// 杂项:旧配置迁移(只有检测到旧配置时按钮才能点)、设置、帮助(默认收起)。
const props = defineProps<{ snapshot: Re4Snapshot; busy: boolean; perform: Re4Perform; t: Re4Translate;
  documentation: Documentation | null; documentationLoading: boolean; documentationError: string }>();
defineEmits<{ 'retry-documentation': [] }>();
const helpOpen = shallowRef(false);
const old = () => props.snapshot.configVersion === 2;
const setting = (id: 'weapon_hide_storage' | 'ui_dissolve_enabled' | 'ui_dissolve_time' | 'portrait_distance' | 'portrait_height', value: boolean | number) =>
  props.perform({ kind: 'setting', id, value });
</script>

<template>
  <div class="re4-main">
    <section class="re4-panel re4-panel-body">
      <div class="re4-panel-title">{{ t('migrateTitle') }}</div>
      <p class="re4-lead">{{ t('migrateLead') }}</p>
      <div class="re4-row">
        <ElButton size="small" type="primary" :disabled="busy || !old() || !snapshot.character"
          @click="perform({ kind: 'migrate', character: snapshot.character })">{{ t('migrateButton') }}</ElButton>
        <span class="re4-muted re4-small">{{ old() ? t('detectedOld') : t('alreadyNew') }}</span>
      </div>
    </section>

    <section class="re4-panel re4-panel-body">
      <div class="re4-panel-title">{{ t('settings') }}</div>
      <div v-if="snapshot.configVersion === 3" class="re4-row">
        <ElSwitch :model-value="snapshot.armorMirror" :disabled="busy" size="small"
          @change="v => perform({ kind: 'armor-mirror', character: snapshot.character, enabled: v === true })" />
        <span>{{ t('armorMirror') }}</span><span class="re4-muted re4-small">{{ t('armorMirrorHint') }}</span>
      </div>
      <div class="re4-row">
        <ElSwitch :model-value="snapshot.settings.weaponHideStorage" :disabled="busy" size="small" @change="v => setting('weapon_hide_storage', v === true)" />
        <span>{{ t('weaponHide') }}</span>
      </div>
      <div class="re4-row">
        <ElSwitch :model-value="snapshot.settings.uiDissolveEnabled" :disabled="busy" size="small" @change="v => setting('ui_dissolve_enabled', v === true)" />
        <span>{{ t('uiDissolve') }}</span>
        <span class="re4-muted re4-small">{{ t('uiDissolveTime') }}</span>
        <ElInputNumber :model-value="snapshot.settings.uiDissolveTime" :min="0" :max="30" :step="0.1" size="small" :disabled="busy"
          @change="v => typeof v === 'number' && setting('ui_dissolve_time', v)" />
        <span class="re4-muted re4-small">{{ t('seconds') }}</span>
      </div>
      <div v-if="snapshot.preview" class="re4-row">
        <span>{{ t('previewDistance') }}</span>
        <ElInputNumber :model-value="snapshot.settings.previewDistance ?? 3" :min="1.2" :max="8" :step="0.1" size="small" :disabled="busy"
          @change="v => typeof v === 'number' && setting('portrait_distance', v)" />
        <span class="re4-muted re4-small">{{ t('meters') }}</span>
        <span>{{ t('previewHeight') }}</span>
        <ElInputNumber :model-value="snapshot.settings.previewHeight ?? 0" :min="-1" :max="1" :step="0.05" size="small" :disabled="busy"
          @change="v => typeof v === 'number' && setting('portrait_height', v)" />
        <span class="re4-muted re4-small">{{ t('meters') }}</span>
      </div>
    </section>

    <section class="re4-panel">
      <div class="re4-panel-head">
        <button class="re4-caret" :aria-expanded="helpOpen" @click="helpOpen = !helpOpen">{{ helpOpen ? '▾' : '▸' }}</button>
        <span class="re4-panel-title">{{ t('help') }}</span>
      </div>
      <div v-if="helpOpen" class="re4-panel-body re4-help">
        <p v-if="documentationLoading" class="re4-muted">{{ t('loadingHelp') }}</p>
        <p v-else-if="documentationError" class="re4-muted">{{ documentationError }} <ElButton size="small" @click="$emit('retry-documentation')">{{ t('retryHelp') }}</ElButton></p>
        <p v-else-if="!documentation?.sections.length" class="re4-muted">{{ t('noHelp') }}</p>
        <template v-else>
          <article v-for="section in documentation?.sections ?? []" :key="section.id">
            <h2>{{ section.title }}</h2>
            <div v-for="entry in section.entries" :key="entry.title">
              <h3>{{ entry.title }}</h3>
              <p v-for="(paragraph, index) in entry.paragraphs" :key="index">{{ paragraph }}</p>
            </div>
          </article>
        </template>
      </div>
    </section>
  </div>
</template>
