<script setup lang="ts">
import { computed, shallowRef, watchEffect } from 'vue';
import { ElButton, ElConfigProvider, ElOption, ElSelect, REFF_ELEMENT_LOCALES } from '@reff/ui';
import { useAvmState } from '../avm';
import Re4Quick from './Re4Quick.vue';
import Re4Editor from './Re4Editor.vue';
import Re4Saves from './Re4Saves.vue';
import Re4Rules from './Re4Rules.vue';
import Re4Settings from './Re4Settings.vue';
import { useRe4Text } from './i18n';
import type { Re4Perform, Re4Snapshot } from './types';

// RE4 的 REFF 页面：按 RE4 的模型（整套造型 / 状态组 / 规则）设计，不套用 MH 的分组页面。
// 覆盖 REF 面板的全部功能：角色与条件状态、快速切换、编辑（预设 / 状态组 / 材质 / 备注与定位）、规则、存档与归属、设置、帮助。
const tab = shallowRef<'quick' | 'edit' | 'rules' | 'saves' | 'settings' | 'help'>('quick');
const avm = useAvmState();
watchEffect(() => { avm.helpOpen.value = tab.value === 'help'; });
const { busy, loading, error, connect, documentation, documentationLoading, documentationError, retryDocumentation } = avm;
const snapshot = computed(() => avm.snapshot.value?.game === 'RE4' ? avm.snapshot.value as Re4Snapshot : null);
const perform: Re4Perform = actions => avm.perform(actions);
const { t, english } = useRe4Text(snapshot);
const ready = computed(() => !!snapshot.value?.character && !!snapshot.value.base);
const character = computed(() => snapshot.value?.characters.find(item => item.id === snapshot.value?.character));
const hp = computed(() => snapshot.value?.status?.hp);
</script>

<template>
  <ElConfigProvider :locale="REFF_ELEMENT_LOCALES[english ? 'en-US' : 'zh-CN']">
    <main class="avm re4" data-theme="reff" :aria-busy="busy || loading">
      <header class="avm-header re4-header">
        <div class="identity"><h1>{{ t('title') }}</h1></div>
        <div v-if="snapshot && snapshot.characters.length > 0" class="re4-character">
          <span class="field-label">{{ t('character') }}</span>
          <ElSelect v-if="snapshot.characters.length > 1" :model-value="snapshot.character" :disabled="busy" size="small"
            :aria-label="t('character')" @change="id => perform({ kind: 'character', id: String(id) })">
            <ElOption v-for="item in snapshot.characters" :key="item.id" :value="item.id"
              :label="item.label + (item.configured ? '' : ' · ' + t('noConfig'))" />
          </ElSelect>
          <span v-else class="re4-character-name">{{ character?.label }}<template v-if="character && !character.configured"> · {{ t('noConfig') }}</template></span>
        </div>
        <div class="game-identity"><span>RE4</span><span class="version">{{ snapshot?.version }}</span></div>
      </header>
      <div class="avm-body">
        <div class="avm-content">
          <div v-if="error" class="error-banner" role="alert"><span>{{ error }}</span>
            <ElButton v-if="!snapshot" :disabled="loading" @click="connect">{{ t('retry') }}</ElButton>
            <button v-else class="dismiss-error" :aria-label="t('dismiss')" @click="error = ''">×</button>
          </div>
          <div v-if="!snapshot" class="connection-state"><span v-if="loading" class="connection-dot"></span>{{ loading ? t('loading') : t('wait') }}</div>
          <template v-else>
            <div v-if="ready" class="re4-status" role="status">
              <span v-if="character && character.targets.length > 1" class="re4-covers">{{ t('targets') }}: {{ character.targets.join(', ') }}</span>
              <span v-if="hp !== undefined" class="re4-hp">{{ t('hp') }} {{ hp.toFixed(1) }}%</span>
              <span v-for="flag in snapshot.status?.flags ?? []" :key="flag" class="avm-tag el-tag el-tag--small"><span class="el-tag__content">{{ flag }}</span></span>
            </div>
            <div v-if="snapshot.sharedWith" class="state-banner" role="status">{{ t('sharedWith') }} {{ snapshot.sharedWith }}<br>{{ t('sharedHint') }}</div>
            <div v-if="!ready && tab !== 'settings' && tab !== 'help'" class="state-banner" role="status">{{ t('noCharacter') }}</div>
            <Re4Quick v-if="ready" v-show="tab === 'quick'" :snapshot="snapshot" :busy="busy" :perform="perform" :t="t" />
            <Re4Editor v-if="ready && snapshot.editor" v-show="tab === 'edit'" :key="'edit-' + snapshot.character" :snapshot="snapshot" :busy="busy" :perform="perform" :t="t" />
            <Re4Rules v-if="ready" v-show="tab === 'rules'" :key="snapshot.character" :snapshot="snapshot" :busy="busy" :perform="perform" :t="t" />
            <Re4Saves v-if="ready && snapshot.ownership && snapshot.saves" v-show="tab === 'saves'" :key="'saves-' + snapshot.character" :snapshot="snapshot" :busy="busy" :perform="perform" :t="t" />
            <Re4Settings v-show="tab === 'settings'" :snapshot="snapshot" :busy="busy" :perform="perform" :t="t" />
            <section v-show="tab === 'help'" class="re4-help">
              <p v-if="documentationLoading" class="re4-muted">{{ t('loadingHelp') }}</p>
              <p v-else-if="documentationError" class="re4-muted">{{ documentationError }} <ElButton size="small" @click="retryDocumentation">{{ t('retryHelp') }}</ElButton></p>
              <p v-else-if="!documentation?.sections.length" class="re4-muted">{{ t('noHelp') }}</p>
              <template v-else>
                <article v-for="section in documentation.sections" :key="section.id">
                  <h2>{{ section.title }}</h2>
                  <div v-for="entry in section.entries" :key="entry.title" class="re4-help-entry">
                    <h3>{{ entry.title }}</h3>
                    <p v-for="(paragraph, index) in entry.paragraphs" :key="index">{{ paragraph }}</p>
                  </div>
                </article>
              </template>
            </section>
          </template>
        </div>
      </div>
      <footer class="avm-footer">
        <div class="status" role="status"><span v-if="busy" class="active-dot"></span>{{ busy ? t('saving') : '' }}</div>
        <nav class="footer-tabs" :aria-label="t('title')">
          <button v-for="item in (['quick', 'edit', 'rules', 'saves', 'settings', 'help'] as const)" :key="item" :aria-current="tab === item ? 'page' : undefined" @click="tab = item">{{ t(item) }}</button>
        </nav>
      </footer>
    </main>
  </ElConfigProvider>
</template>

<style>
.re4-header { align-items: center; }
.re4-character { display: flex; align-items: center; gap: 8px; min-width: 0; margin-left: 12px; }
.re4-character .field-label { margin: 0; }
.re4-character .el-select { width: 12em; }
.re4-character-name { color: var(--avm-ink); overflow-wrap: anywhere; }
.re4-status { display: flex; flex-wrap: wrap; align-items: center; gap: 6px 10px; padding: 8px 16px 4px; color: var(--avm-muted); }
.re4-hp { color: var(--avm-ink); font-variant-numeric: tabular-nums; }
.re4-muted { color: var(--avm-muted); }
.re4-section { padding: 8px 16px; }
.re4-section + .re4-section { border-top: 1px solid var(--avm-line); }
.re4-section-title { display: flex; align-items: baseline; gap: 8px; margin: 0 0 6px; font-size: inherit; font-weight: 400; color: var(--avm-muted); }
.re4-section-title small { font-size: var(--reff-font-size-xs, 12px); }
.re4-row { display: grid; grid-template-columns: minmax(7em, 14em) minmax(0, 1fr); align-items: center; gap: 6px 12px; min-height: var(--avm-control-height); padding: 3px 0; }
.re4-row-label { overflow-wrap: anywhere; }
.re4-row-control { display: flex; flex-wrap: wrap; align-items: center; gap: 6px 10px; min-width: 0; }
.re4-row-control .el-select { width: min(16em, 100%); }
.re4-note { color: var(--avm-muted); font-size: var(--reff-font-size-xs, 12px); margin: 4px 0 0; overflow-wrap: anywhere; }
.re4-help { padding: 8px 16px 16px; max-width: 60em; }
.re4-help h2 { font-size: inherit; color: var(--avm-accent); margin: 12px 0 4px; }
.re4-help h3 { font-size: inherit; font-weight: 600; margin: 8px 0 2px; }
.re4-help p { margin: 0 0 4px; color: var(--avm-ink); }
@media (max-width: 640px) { .re4-row { grid-template-columns: minmax(0, 1fr); } .re4-character { margin-left: 0; } }
</style>
