<script setup lang="ts">
import Re4Num from './Re4Num.vue';
import { computed, shallowRef } from 'vue';
import { ElSwitch } from '@reff/ui';
import type { Re4Translate } from './i18n';
import type { Re4Perform, Re4Snapshot } from './types';
import { baseLabel, conditionSentence, groupLabel, kindText, labelOf, optionLabel, stateLabel, targetSentence } from './util';
import { cycleOf, keyOf as hotkeyFor } from './hotkeys';

// 快速切换：一切从简。被条件状态接管的层锁定（只在这里锁，编辑页照常能改手动选择）。
const props = defineProps<{ snapshot: Re4Snapshot; busy: boolean; perform: Re4Perform; t: Re4Translate }>();
const nfOff = computed(() => props.snapshot.settings.newFeatures === false);   // 新版特性关闭:相关界面灰掉、不可改
const c = () => ({ character: props.snapshot.character });
const states = computed(() => props.snapshot.states ?? []);
const groupsOpen = shallowRef(true);
const owner = (index?: number) => stateLabel(states.value, index);
const pick = (layer: string, option: string) => props.perform({ kind: 'manual', ...c(), layer, option });
// 造型归属:当前整套造型不在状态组的归属里时不显示这一行
const rows = computed(() => (props.snapshot.groups ?? []).filter(g => g.shown !== false).map(g => ({
  layer: g.name, label: labelOf(g), active: g.active, effective: g.effective, locked: g.fromState, none: true,
  options: g.options.map(o => o.name), multi: g.multi === true,
  // 选项的显示名(双语);按钮发动作仍用名字
  labels: Object.fromEntries(g.options.map(o => [o.name, labelOf(o)])) as Record<string, string>,
  // 复选组各选项:手动开关 / 这一帧生效 / 被哪个条件状态接管
  opts: Object.fromEntries(g.options.map(o => [o.name, { on: o.on === true, eff: o.effective === true, locked: o.fromState }])),
})));
type QRow = (typeof rows.value)[number];
// 一个按钮按下 / 锁定 / 高亮:复选组按选项各自看,单选组按整组看
const optPressed = (r: QRow, name: string) => r.multi ? r.opts[name]?.on === true : r.active === name;
const optLocked = (r: QRow, name: string) => r.multi ? r.opts[name]?.locked : r.locked;
const optEff = (r: QRow, name: string) => r.multi ? !!r.opts[name]?.locked && r.opts[name]?.eff === true : !!r.locked && r.effective === name;
const nonePressed = (r: QRow) => r.multi ? !Object.values(r.opts).some(o => o.on) : r.active === '';
const toggleOpt = (r: QRow, name: string) => r.multi
  ? props.perform({ kind: 'option-on', ...c(), group: r.layer, option: name, on: !optPressed(r, name) })
  : pick(r.layer, name);
// 只有一个选项(不算「（无）」)的状态组用勾选框紧凑排在一起:勾上 = 选这个选项,取消 = 「（无）」
const multiRows = computed(() => rows.value.filter(r => r.options.length !== 1));
const singleRows = computed(() => rows.value.filter(r => r.options.length === 1));
// 被条件接管时显示生效的选项,否则显示手动选择
const singleOn = (r: QRow) => r.multi
  ? (r.opts[r.options[0]]?.locked ? r.opts[r.options[0]]?.eff === true : r.opts[r.options[0]]?.on === true)
  : (r.locked ? r.effective : r.active) === r.options[0];
// 模型高度:显示当前生效的值和来源;全局覆盖打开时无视各预设 / 选项,统一用这里的值(存在当前配置里)
const override = computed(() => props.snapshot.heightOverride ?? { enabled: false, cm: 0 });
const signed = (v: number) => (v > 0 ? '+' : '') + v;
const heightNow = computed(() => {
  const h = props.snapshot.height;
  return h === undefined || h === 0 ? props.t('heightNone') : signed(h) + ' cm';
});
const heightFrom = computed(() => {
  const s = props.snapshot.heightSource;
  if (!s) return props.t('heightNoSource');
  if (s.layer === 'override') return props.t('heightFromOverride');
  if (s.layer === 'base') return props.t('heightFromBase', baseLabel(props.snapshot, s.option ?? ''));
  return props.t('heightFromGroup', groupLabel(props.snapshot, s.layer), optionLabel(props.snapshot, s.layer, s.option ?? ''));
});
// 调色方案:点一下就选中(选中就生效,同调色页顶部的选择框);"" = 初始。不锁定 —— 调色是叠加的,条件引用的方案
// 盖在选中的上面。被引用、这一帧正在叠加生效的方案用绿框标出(同上面「被条件接管」的样式)
const schemes = computed(() => (props.snapshot.palettes?.list ?? []).map(x => x.name));
const selectedScheme = computed(() => props.snapshot.palettes?.selected ?? '');
const activeSchemes = computed(() => ({ referenced: new Set(props.snapshot.palettes?.active ?? []) }));
const pickScheme = (scheme: string) => props.perform({ kind: 'palette-scheme-select', ...c(), scheme });
const base = computed(() => {
  const b = props.snapshot.base!;
  return { layer: 'base', label: props.t('tabBase'), active: b.active, effective: b.effective, locked: b.fromState, none: false,
    options: b.presets.map(p => p.name),
    labels: Object.fromEntries(b.presets.map(p => [p.name, labelOf(p)])) as Record<string, string> };
});
// 整套造型绑的快捷键(Alt + 数字),显示在按钮上
// 快捷键(Alt + 数字):按钮上标单项键,行标题旁标整个结构的轮换键
const layerTarget = (layer: string) => layer === 'base' ? { kind: 'base' as const } : { kind: 'group' as const, group: layer };
const hotkeyOf = (layer: string, option: string) => hotkeyFor(props.snapshot, { ...layerTarget(layer), option })?.digit;
const cycleKey = (layer: string) => cycleOf(props.snapshot, layerTarget(layer))?.digit;
</script>

<template>
  <div class="re4-main">
    <section class="re4-panel re4-panel-body">
      <div class="re4-qrow" :class="{ locked: base.locked }">
        <span class="re4-qname">{{ base.label }}<span v-if="cycleKey('base') !== undefined" class="re4-qkey" :title="t('hotkeyCycleHint')">Alt+{{ cycleKey('base') }} {{ t('hotkeyCycle') }}</span></span>
        <span class="re4-seg" role="group" :aria-label="base.label">
          <button v-for="name in base.options" :key="name" :disabled="busy || !!base.locked"
            :aria-pressed="base.active === name" :class="{ eff: base.locked && base.effective === name }"
            :title="base.locked ? t('lockedBy', owner(base.locked)) : ''" @click="pick('base', name)">{{ base.labels[name] }}<span v-if="hotkeyOf('base', name) !== undefined" class="re4-qkey">Alt+{{ hotkeyOf('base', name) }}</span></button>
        </span>
      </div>
    </section>

    <section class="re4-panel">
      <div class="re4-panel-head">
        <button class="re4-caret" :aria-expanded="groupsOpen" @click="groupsOpen = !groupsOpen">{{ groupsOpen ? '▾' : '▸' }}</button>
        <span class="re4-panel-title">{{ t('tabGroups') }}</span>
      </div>
      <div v-if="groupsOpen" class="re4-panel-body">
        <span v-if="!rows.length" class="re4-muted re4-small">{{ t('noGroups') }}</span>
        <div v-for="row in multiRows" :key="row.layer" class="re4-qrow" :class="{ locked: row.locked }">
          <span class="re4-qname">{{ row.label }}<span v-if="cycleKey(row.layer) !== undefined" class="re4-qkey" :title="t('hotkeyCycleHint')">Alt+{{ cycleKey(row.layer) }} {{ t('hotkeyCycle') }}</span></span>
          <!-- 复选组:左边「（无）」用分段按钮的框(点一下关掉全部),右边各选项用勾选框紧凑排列 -->
          <span v-if="row.multi" class="re4-qmulti" role="group" :aria-label="row.label">
            <span class="re4-seg"><button :disabled="busy" :aria-pressed="nonePressed(row)" @click="!nonePressed(row) && pick(row.layer, '')">{{ t('none') }}<span v-if="hotkeyOf(row.layer, '') !== undefined" class="re4-qkey">Alt+{{ hotkeyOf(row.layer, '') }}</span></button></span>
            <label v-for="name in row.options" :key="name + '|' + optPressed(row, name) + '|' + optEff(row, name)" class="re4-schip"
              :class="{ locked: !!optLocked(row, name), eff: optEff(row, name) }" :title="optLocked(row, name) ? t('lockedBy', owner(optLocked(row, name))) : ''">
              <input type="checkbox" :checked="optLocked(row, name) ? optEff(row, name) : optPressed(row, name)" :disabled="busy || !!optLocked(row, name)"
                @change="toggleOpt(row, name)">
              <span class="re4-sname">{{ row.labels[name] }}</span>
              <span v-if="hotkeyOf(row.layer, name) !== undefined" class="re4-qkey">Alt+{{ hotkeyOf(row.layer, name) }}</span>
            </label>
          </span>
          <span v-else class="re4-seg" role="group" :aria-label="row.label">
            <button :disabled="busy || (!row.multi && !!row.locked)" :aria-pressed="nonePressed(row)" :title="!row.multi && row.locked ? t('lockedBy', owner(row.locked)) : ''"
              @click="pick(row.layer, '')">{{ t('none') }}<span v-if="hotkeyOf(row.layer, '') !== undefined" class="re4-qkey">Alt+{{ hotkeyOf(row.layer, '') }}</span></button>
            <button v-for="name in row.options" :key="name" :disabled="busy || !!optLocked(row, name)"
              :aria-pressed="optPressed(row, name)" :class="{ eff: optEff(row, name) }"
              :title="optLocked(row, name) ? t('lockedBy', owner(optLocked(row, name))) : ''" @click="toggleOpt(row, name)">{{ row.labels[name] }}<span v-if="hotkeyOf(row.layer, name) !== undefined" class="re4-qkey">Alt+{{ hotkeyOf(row.layer, name) }}</span></button>
          </span>
        </div>
        <div v-if="singleRows.length" class="re4-sflow re4-qsingles">
          <label v-for="row in singleRows" :key="row.layer + '|' + row.active + '|' + row.effective" class="re4-schip"
            :class="{ locked: optLocked(row, row.options[0]), eff: optLocked(row, row.options[0]) && singleOn(row) }"
            :title="optLocked(row, row.options[0]) ? t('lockedBy', owner(optLocked(row, row.options[0]))) : (row.labels[row.options[0]] !== row.label ? row.labels[row.options[0]] : '')">
            <input type="checkbox" :checked="singleOn(row)" :disabled="busy || !!optLocked(row, row.options[0])"
              @change="e => pick(row.layer, (e.target as HTMLInputElement).checked ? row.options[0] : '')">
            <span class="re4-sname">{{ row.label }}</span>
            <span v-if="row.labels[row.options[0]] !== row.label" class="re4-muted re4-small">{{ row.labels[row.options[0]] }}</span>
            <span v-if="cycleKey(row.layer) !== undefined" class="re4-qkey" :title="t('hotkeyCycleHint')">Alt+{{ cycleKey(row.layer) }}</span>
            <span v-else-if="hotkeyOf(row.layer, row.options[0]) !== undefined" class="re4-qkey">Alt+{{ hotkeyOf(row.layer, row.options[0]) }}</span>
          </label>
        </div>
      </div>
    </section>

    <section class="re4-panel">
      <div class="re4-panel-head">
        <ElSwitch :model-value="snapshot.auto" :disabled="busy" size="small" :title="t('conditionSwitchHint')"
          @change="v => perform({ kind: 'auto', ...c(), enabled: v === true })" />
        <span class="re4-panel-title">{{ t('conditionSwitch') }}</span>
      </div>
      <div class="re4-panel-body re4-sflow">
        <span v-if="!states.length" class="re4-muted re4-small">{{ t('noStates') }}</span>
        <label v-for="(st, i) in states" :key="i" class="re4-schip" :class="'k-' + st.kind"
          :title="conditionSentence(st, t) + ' → ' + targetSentence(st, t, snapshot)">
          <input type="checkbox" :checked="st.enabled" :disabled="busy"
            @change="e => perform({ kind: 'state-field', ...c(), index: i + 1, field: 'enabled', value: (e.target as HTMLInputElement).checked })">
          <span class="re4-sdot" :title="kindText(st, states, t)"></span>
          <span class="re4-sname">{{ labelOf(st) }}</span>
        </label>
      </div>
    </section>

    <section class="re4-panel re4-panel-body" :class="{ 're4-nf-lock': nfOff }" :inert="nfOff">
      <div class="re4-qrow">
        <span class="re4-qname">{{ t('paletteScheme') }}</span>
        <span class="re4-seg" role="group" :aria-label="t('paletteScheme')">
          <button :disabled="busy" :aria-pressed="selectedScheme === ''" @click="selectedScheme !== '' && pickScheme('')">{{ t('paletteAlways') }}</button>
          <button v-for="name in schemes" :key="name" :disabled="busy" :aria-pressed="selectedScheme === name"
            :class="{ eff: selectedScheme !== name && activeSchemes.referenced.has(name) }"
            :title="selectedScheme !== name && activeSchemes.referenced.has(name) ? t('paletteSchemeRefOn') : ''"
            @click="selectedScheme !== name && pickScheme(name)">{{ name }}</button>
        </span>
      </div>
    </section>

    <section class="re4-panel re4-panel-body" :class="{ 're4-nf-lock': nfOff }" :inert="nfOff">
      <div class="re4-qrow">
        <span class="re4-qname">{{ t('heightQuick') }}</span>
        <span class="re4-hnow" :class="{ off: snapshot.settings.heightEnabled === false }">
          <b>{{ heightNow }}</b><span class="re4-muted re4-small">{{ heightFrom }}</span>
          <span v-if="snapshot.settings.heightEnabled === false" class="re4-small re4-bad-text">{{ t('heightOff') }}</span>
        </span>
      </div>
      <div class="re4-qrow">
        <span class="re4-qname">{{ t('heightOverride') }}</span>
        <span class="re4-hctl" :class="{ dim: !override.enabled }">
          <ElSwitch :model-value="override.enabled" :disabled="busy" size="small" :aria-label="t('heightOverride')"
            @change="v => perform({ kind: 'height-override', ...c(), enabled: v === true })" />
          <Re4Num :value="override.cm" :min="-20" :max="50" :disabled="busy" :aria-label="t('heightOverride')"
            @change="v => v !== undefined && perform({ kind: 'height-override', ...c(), cm: v })" />cm
          <span class="re4-muted re4-small">{{ t('heightOverrideHint') }}</span>
        </span>
      </div>
    </section>
  </div>
</template>

<style>
.re4-qkey { margin-left: 6px; font-size: 11px; opacity: 0.6; }
.re4-qrow { display: grid; grid-template-columns: minmax(5em, 8em) minmax(0, 1fr); gap: 6px 12px; align-items: center; padding: 3px 0; }
.re4-qrow + .re4-qrow { border-top: 1px solid var(--avm-line); padding-top: 6px; }
@media (max-width: 520px) { .re4-qrow { grid-template-columns: minmax(0, 1fr); } }
.re4-qname { font-weight: 500; overflow-wrap: anywhere; }
.re4-qrow.locked .re4-qname { color: var(--avm-muted); }
.re4-seg { display: flex; flex-wrap: wrap; gap: 4px; }
.re4-seg button { border: 1px solid var(--avm-line); background: transparent; border-radius: 6px; padding: 1px 10px; color: var(--avm-muted); cursor: pointer; position: relative; min-height: 26px; }
.re4-seg button:hover:not(:disabled) { border-color: var(--avm-accent); }
.re4-seg button[aria-pressed=true] { background: var(--el-color-primary-light-9, var(--re4-soft)); border-color: var(--avm-accent); color: var(--avm-accent); font-weight: 500; }
.re4-seg button:disabled { cursor: not-allowed; }
.re4-seg button:disabled:not(.eff) { opacity: .4; }
.re4-seg button.eff { box-shadow: 0 0 0 2px var(--re4-ok); color: var(--avm-ink); opacity: 1; }
.re4-hnow { display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 10px; }
.re4-hnow b { font-weight: 600; font-variant-numeric: tabular-nums; }
.re4-hnow.off b { color: var(--avm-muted); text-decoration: line-through; }
.re4-hctl { display: flex; flex-wrap: wrap; align-items: center; gap: 4px 8px; }
.re4-hctl input { width: 4.5em; border: 1px solid var(--avm-line); border-radius: 4px; background: transparent; color: inherit; padding: 0 4px; }
.re4-hctl.dim input { opacity: .55; }
.re4-sflow { display: flex; flex-wrap: wrap; gap: 6px; }
.re4-schip { display: inline-flex; align-items: center; gap: 6px; padding: 2px 10px 2px 6px; border: 1px solid var(--avm-line); border-radius: 14px; cursor: pointer; user-select: none; }
.re4-schip input { margin: 0; }
.re4-schip .re4-sname { font-weight: 500; }
.re4-qsingles { padding-top: 6px; }
.re4-qmulti { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; }
.re4-qrow + .re4-qsingles { border-top: 1px solid var(--avm-line); }
.re4-schip.locked { cursor: not-allowed; color: var(--avm-muted); }
.re4-schip.eff { box-shadow: 0 0 0 2px var(--re4-ok); }
</style>
