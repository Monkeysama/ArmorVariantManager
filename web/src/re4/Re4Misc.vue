<script setup lang="ts">
import Re4Num from './Re4Num.vue';
import { shallowRef } from 'vue';
import { ElButton, ElSwitch } from '@reff/ui';
import type { Documentation } from '../types';
import type { Re4Translate } from './i18n';
import type { Re4Perform, Re4Snapshot } from './types';
import { describe } from './hotkeys';

// 杂项:旧配置迁移(只有检测到旧配置时按钮才能点)、设置、帮助(默认收起)。溶解相关的设置在「溶解」页。
const props = defineProps<{ snapshot: Re4Snapshot; busy: boolean; perform: Re4Perform; t: Re4Translate;
  documentation: Documentation | null; documentationLoading: boolean; documentationError: string }>();
defineEmits<{ 'retry-documentation': [] }>();
const helpOpen = shallowRef(false);
const old = () => props.snapshot.configVersion === 2;
// 快捷键总览:十个键各自绑的是什么(只在 v3 配置时有)
const hotkeys = () => props.snapshot.hotkeys ?? [];
const skipText = (skip: string[], kind: string) => skip.map(n => n === '' ? (kind === 'palette' ? props.t('paletteAlways') : props.t('none')) : n).join('、');
const setting = (id:'weapon_hide_storage' | 'portrait_distance' | 'portrait_height' | 'block_game_mouse' | 'height_enabled', value: boolean | number) =>
  props.perform({ kind: 'setting', id, value });
</script>

<template>
  <div class="re4-main">
    <section v-if="snapshot.configVersion === 3" class="re4-panel re4-panel-body">
      <div class="re4-panel-title">{{ t('hotkeyTitle') }}</div>
      <p class="re4-lead">{{ t('hotkeyListHint') }}</p>
      <span v-if="!hotkeys().length" class="re4-muted re4-small">{{ t('hotkeyEmpty') }}</span>
      <div v-for="h in hotkeys()" :key="h.digit" class="re4-row re4-hkrow">
        <span class="re4-tag">Alt+{{ h.digit }}</span>
        <span>{{ describe(h, t) }}</span>
        <span v-if="h.cycle && h.skip.length" class="re4-muted re4-small">{{ t('hotkeySkipped', skipText(h.skip, h.kind)) }}</span>
        <span class="re4-spacer"></span>
        <button class="re4-link" :disabled="busy" @click="perform({ kind: 'hotkey-clear', character: snapshot.character, digit: h.digit })">{{ t('heightClear') }}</button>
      </div>
    </section>

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
        <ElSwitch :model-value="snapshot.settings.blockGameMouse !== false" :disabled="busy" size="small" @change="v => setting('block_game_mouse', v === true)" />
        <span>{{ t('blockGameMouse') }}</span><span class="re4-muted re4-small">{{ t('blockGameMouseHint') }}</span>
      </div>
      <div class="re4-row">
        <ElSwitch :model-value="snapshot.settings.heightEnabled !== false" :disabled="busy" size="small" @change="v => setting('height_enabled', v === true)" />
        <span>{{ t('heightEnabled') }}</span><span class="re4-muted re4-small">{{ t('heightEnabledHint') }}</span>
      </div>
      <div class="re4-row">
        <ElSwitch :model-value="snapshot.settings.weaponHideStorage" :disabled="busy" size="small" @change="v => setting('weapon_hide_storage', v === true)" />
        <span>{{ t('weaponHide') }}</span>
      </div>
      <div v-if="snapshot.preview" class="re4-row">
        <span>{{ t('previewDistance') }}</span>
        <Re4Num :value="snapshot.settings.previewDistance ?? 3" :min="1.2" :max="8" :disabled="busy" :aria-label="t('previewDistance')"
          @change="v => v !== undefined && setting('portrait_distance', v)" />
        <span class="re4-muted re4-small">{{ t('meters') }}</span>
        <span>{{ t('previewHeight') }}</span>
        <Re4Num :value="snapshot.settings.previewHeight ?? 0" :min="-1" :max="1" :disabled="busy" :aria-label="t('previewHeight')"
          @change="v => v !== undefined && setting('portrait_height', v)" />
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
