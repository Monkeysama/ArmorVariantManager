<script setup lang="ts">
import { computed, shallowRef, watch, watchEffect } from 'vue';
import { ElButton, ElConfigProvider, ElOption, ElSelect, REFF_ELEMENT_LOCALES } from '@reff/ui';
import { useAvmState } from '../avm';
import Re4Side from './Re4Side.vue';
import Re4Quick from './Re4Quick.vue';
import Re4Layers from './Re4Layers.vue';
import Re4States from './Re4States.vue';
import Re4Presets from './Re4Presets.vue';
import Re4Misc from './Re4Misc.vue';
import { useRe4Text, type Re4Key } from './i18n';
import type { Re4Notice, Re4Perform, Re4Snapshot } from './types';

// RE4 的 REFF 页面（v3）：按 RE4 的模型设计，不套用 MH 的分组页面。
// 左侧常驻游戏状态（和编辑页的最终材质）；右侧六个页签。v2 配置只能先迁移。
type Tab = 'quick' | 'base' | 'groups' | 'states' | 'presets' | 'misc';
const TABS: Tab[] = ['quick', 'base', 'groups', 'states', 'presets', 'misc'];
const TAB_LABEL: Record<Tab, Re4Key> = { quick: 'tabQuick', base: 'tabBase', groups: 'tabGroups', states: 'tabStates', presets: 'tabPresets', misc: 'tabMisc' };
const tab = shallowRef<Tab>('quick');
const avm = useAvmState();
watchEffect(() => { avm.helpOpen.value = tab.value === 'misc'; });
const { busy, loading, error, connect, documentation, documentationLoading, documentationError, retryDocumentation } = avm;
const snapshot = computed(() => avm.snapshot.value?.game === 'RE4' ? avm.snapshot.value as Re4Snapshot : null);
const perform: Re4Perform = actions => avm.perform(actions);
const { t, english } = useRe4Text(snapshot);
const hasCharacter = computed(() => !!snapshot.value?.character);
const v3 = computed(() => snapshot.value?.configVersion === 3);
const character = computed(() => snapshot.value?.characters.find(item => item.id === snapshot.value?.character));
// 有更合适的预设时在「预设」页签上点个小圆点（只提醒，从不自动切换）
const presetDot = computed(() => {
  const p = snapshot.value?.presets;
  return !!p && p.current !== 'full' && p.better.length > 0 && !p.dismissed;
});
const showLook = computed(() => tab.value === 'base' || tab.value === 'groups' || tab.value === 'states');
// 一次性提示（迁移结果）：快照只带一次，留到用户关掉
const notice = shallowRef<Re4Notice | null>(null);
watch(() => snapshot.value?.notice, value => { if (value) notice.value = value; });
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
          <span v-else class="re4-character-name">{{ character?.label }}</span>
          <span v-if="character && character.targets.length" class="re4-muted re4-small">{{ t('onField') }}：{{ character.targets.join('、') }}</span>
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
          <div v-else class="re4-layout">
            <Re4Side v-if="hasCharacter && v3" :snapshot="snapshot" :t="t" :show-look="showLook" />
            <div class="re4-main">
              <div v-if="notice" class="re4-banner ok" role="status">
                <span>{{ t('migrated') }}<template v-if="notice.overlaps"> {{ t('migratedOverlaps', notice.overlaps) }}</template><template v-if="notice.presets"> {{ t('migratedPresets', notice.presets) }}</template></span>
                <button class="dismiss-error" :aria-label="t('dismiss')" @click="notice = null">×</button>
              </div>
              <div v-if="!hasCharacter && tab !== 'misc'" class="state-banner" role="status">{{ t('noCharacter') }}</div>
              <div v-else-if="!v3 && tab !== 'misc'" class="re4-banner" role="status">
                <span>{{ t('needMigration') }}</span><ElButton size="small" type="primary" @click="tab = 'misc'">{{ t('goMigrate') }}</ElButton>
              </div>
              <template v-else>
                <Re4Quick v-if="tab === 'quick'" :snapshot="snapshot" :busy="busy" :perform="perform" :t="t" />
                <Re4Layers v-else-if="tab === 'base'" :key="'base-' + snapshot.character" mode="base" :snapshot="snapshot" :busy="busy" :perform="perform" :t="t" />
                <Re4Layers v-else-if="tab === 'groups'" :key="'groups-' + snapshot.character" mode="groups" :snapshot="snapshot" :busy="busy" :perform="perform" :t="t" />
                <Re4States v-else-if="tab === 'states'" :key="'states-' + snapshot.character" :snapshot="snapshot" :busy="busy" :perform="perform" :t="t" />
                <Re4Presets v-else-if="tab === 'presets'" :key="'presets-' + snapshot.character" :snapshot="snapshot" :busy="busy" :perform="perform" :t="t" />
                <Re4Misc v-else :snapshot="snapshot" :busy="busy" :perform="perform" :t="t" :documentation="documentation"
                  :documentation-loading="documentationLoading" :documentation-error="documentationError" @retry-documentation="retryDocumentation" />
              </template>
            </div>
          </div>
        </div>
      </div>
      <footer class="avm-footer">
        <div class="status" role="status"><span v-if="busy" class="active-dot"></span>{{ busy ? t('saving') : '' }}</div>
        <nav class="footer-tabs" :aria-label="t('title')">
          <button v-for="item in TABS" :key="item" :aria-current="tab === item ? 'page' : undefined" @click="tab = item">
            {{ t(TAB_LABEL[item]) }}<span v-if="item === 'presets' && presetDot" class="re4-dot" aria-hidden="true"></span>
          </button>
        </nav>
      </footer>
    </main>
  </ElConfigProvider>
</template>

<style>
/* 状态颜色：绿 = 生效，红 = 被覆盖（有问题），灰 = 未命中。颜色之外还有形状，照顾色弱 */
.re4 { --re4-ok: var(--el-color-success, #2c7a4b); --re4-bad: var(--el-color-danger, #c0353d); --re4-soft: var(--el-fill-color-light, rgba(127, 127, 127, .08));
  --re4-ok-soft: var(--el-color-success-light-9, rgba(44, 122, 75, .12)); --re4-bad-soft: var(--el-color-danger-light-9, rgba(192, 53, 61, .12)); }
.re4-header { align-items: center; }
.re4-character { display: flex; flex-wrap: wrap; align-items: center; gap: 4px 8px; min-width: 0; margin-left: 12px; }
.re4-character .field-label { margin: 0; }
.re4-character .el-select { width: 10em; }
.re4-character-name { color: var(--avm-ink); }
.re4-muted { color: var(--avm-muted); }
.re4-small { font-size: var(--reff-font-size-xs, 12px); }
.re4-layout { display: grid; grid-template-columns: minmax(0, 15em) minmax(0, 1fr); gap: 12px; padding: 10px 12px 16px; align-items: start; }
@media (max-width: 720px) { .re4-layout { grid-template-columns: minmax(0, 1fr); } }
.re4-main { display: grid; gap: 10px; min-width: 0; align-content: start; }
.re4-panel { border: 1px solid var(--avm-line); border-radius: 8px; background: var(--el-bg-color, transparent); min-width: 0; }
.re4-panel-head { display: flex; flex-wrap: wrap; align-items: center; gap: 6px 10px; padding: 7px 12px; }
.re4-panel-head + * { border-top: 1px solid var(--avm-line); }
.re4-panel-body { padding: 8px 12px; display: grid; gap: 6px; }
.re4-panel-title { font-weight: 600; }
.re4-eyebrow { font-size: 11px; letter-spacing: .1em; color: var(--avm-muted); text-transform: uppercase; margin: 0 0 6px; }
.re4-lead { color: var(--avm-muted); margin: 0; max-width: 70ch; }
.re4-banner { display: flex; flex-wrap: wrap; align-items: center; gap: 6px 12px; padding: 8px 12px; border-radius: 8px; background: var(--re4-soft); }
.re4-banner.ok { background: var(--re4-ok-soft); }
.re4-banner.info { background: var(--el-color-primary-light-9, var(--re4-soft)); }
.re4-spacer { flex: 1; }
.re4-row { display: flex; flex-wrap: wrap; align-items: center; gap: 6px 10px; }
.re4-caret { border: 0; background: none; color: var(--avm-muted); padding: 0; width: 1.4em; font-size: 12px; cursor: pointer; flex: none; }
.re4-link { border: 0; background: none; color: var(--avm-accent); padding: 0; cursor: pointer; font-size: var(--reff-font-size-xs, 12px); }
.re4-dot { display: inline-block; width: 7px; height: 7px; border-radius: 50%; background: var(--avm-accent); margin-left: 5px; vertical-align: 2px; }
.re4-tag { font-size: 12px; padding: 0 7px; border-radius: 9px; white-space: nowrap; background: var(--re4-soft); color: var(--avm-muted); }
.re4-tag.ok { background: var(--re4-ok-soft); color: var(--re4-ok); }
.re4-tag.partial { background: var(--el-color-primary-light-9, var(--re4-soft)); color: var(--avm-accent); }
/* 状态圆点：实心 = 生效，半实心 = 部分生效，红色斜线 = 被覆盖，空心 = 未命中，虚线 = 停用 */
.re4-sdot { width: 11px; height: 11px; border-radius: 50%; border: 1.5px solid var(--avm-muted); display: inline-block; flex: none; }
.k-active .re4-sdot { background: var(--re4-ok); border-color: var(--re4-ok); }
.k-partial .re4-sdot { background: linear-gradient(90deg, var(--re4-ok) 50%, transparent 50%); border-color: var(--re4-ok); }
.k-outranked .re4-sdot { border-color: var(--re4-bad); background: linear-gradient(135deg, transparent 40%, var(--re4-bad) 40%, var(--re4-bad) 60%, transparent 60%); }
.k-off .re4-sdot, .k-paused .re4-sdot { border-style: dashed; }
.k-active .re4-sname, .k-partial .re4-sname { color: var(--re4-ok); }
.k-outranked .re4-sname { color: var(--re4-bad); }
.k-off .re4-sname, .k-paused .re4-sname { color: var(--avm-muted); }
.re4-legend { display: flex; flex-wrap: wrap; gap: 2px 12px; font-size: 12px; color: var(--avm-muted); }
.re4-legend > span { display: inline-flex; align-items: center; gap: 4px; }
.re4-res { font-size: 12px; color: var(--avm-muted); }
.re4-res.win { color: var(--re4-ok); }
.re4-res.lose, .re4-res.broken { color: var(--re4-bad); }
.re4-mono { font-family: var(--reff-font-mono, ui-monospace, Consolas, monospace); font-size: 12px; }
.re4-confirm { display: flex; flex-wrap: wrap; align-items: center; gap: 6px 10px; padding: 6px 12px; background: var(--re4-bad-soft); color: var(--re4-bad); font-size: 13px; }
.re4-help h2 { font-size: inherit; color: var(--avm-accent); margin: 10px 0 4px; }
.re4-help h3 { font-size: inherit; font-weight: 600; margin: 6px 0 2px; }
.re4-help p { margin: 0 0 4px; }
</style>
