<script setup lang="ts">
import { computed, reactive, shallowRef } from 'vue';
import { ElButton, ElOption, ElSelect, ElSwitch } from '@reff/ui';
import type { Re4Key, Re4Translate } from './i18n';
import type { Re4Category, Re4ConditionDef, Re4ConditionInput, Re4Op, Re4Perform, Re4Snapshot, Re4State, Re4StateCondition } from './types';
import { conditionSentence, currentValueText, kindText, resultText, targetSentence } from './util';
import { usePointerReorder } from './reorder';

// 条件状态页。从上往下是优先级(拖 ⠿ 调整;拖动用 pointer 事件,见 reorder.ts)。
// 收起时一行;展开后左右两栏:左边触发条件,右边切换到(整套造型单独一行,下面是状态组)。
const props = defineProps<{ snapshot: Re4Snapshot; busy: boolean; perform: Re4Perform; t: Re4Translate }>();
const c = () => ({ character: props.snapshot.character });
const states = computed(() => props.snapshot.states ?? []);
const defs = computed(() => props.snapshot.conditions ?? []);
const defOf = (id: string) => defs.value.find(d => d.id === id);
const groups = computed(() => props.snapshot.groups ?? []);
const basePresets = computed(() => props.snapshot.base?.presets.map(p => p.name) ?? []);
const open = reactive(new Set<number>());
const confirming = shallowRef(0);
const CATS: Re4Category[] = ['hp', 'combat', 'move', 'damage', 'other'];
const CAT_KEY: Record<Re4Category, Re4Key> = { hp: 'catHp', combat: 'catCombat', move: 'catMove', damage: 'catDamage', other: 'catOther' };
const byCategory = computed(() => CATS.map(cat => ({ cat, defs: defs.value.filter(d => d.category === cat) })).filter(x => x.defs.length));
const LEGEND = ['active', 'partial', 'outranked', 'idle', 'off'] as const;
const LEGEND_KEY = { active: 'kindActive', partial: 'kindPartial', outranked: 'kindOutranked', idle: 'kindIdle', off: 'kindOff' } as const;

const toggle = (i: number) => { if (open.has(i)) open.delete(i); else open.add(i); };
const field = (i: number, f: 'enabled' | 'exclusive', value: boolean) => props.perform({ kind: 'state-field', ...c(), index: i, field: f, value });
const numField = (i: number, f: 'hold' | 'fade_in' | 'fade_out', raw: string) => {
  const v = Number(raw);
  if (!Number.isFinite(v)) return;
  return props.perform({ kind: 'state-field', ...c(), index: i, field: f, value: v });
};
async function newState() {
  let n = states.value.length + 1;
  const base = props.t('newState');
  while (states.value.some(s => s.name === `${base} ${n}`)) n++;
  if (await props.perform({ kind: 'state-new', ...c(), name: `${base} ${n}` })) open.add(states.value.length);
}
function defaultCondition(def?: Re4ConditionDef): Re4ConditionInput {
  if (!def) return { type: 'is_battle', value: true };
  if (def.kind === 'number') return { type: def.id, op: '<=', value: 50 };
  if (def.kind === 'enum') return { type: def.id, op: '==', value: def.options?.[0]?.value ?? 0 };
  return { type: def.id, value: true };
}
const inputOf = (c0: Re4StateCondition): Re4ConditionInput => ({ type: c0.type, op: c0.op, value: c0.value });
function setCondition(i: number, ci: number, cond: Re4ConditionInput) {
  return props.perform({ kind: 'condition-set', ...c(), index: i, condition_index: ci, condition: cond });
}
function changeType(i: number, ci: number, type: string) { return setCondition(i, ci, defaultCondition(defOf(type))); }
function changeOp(i: number, ci: number, cond: Re4StateCondition, op: string) { return setCondition(i, ci, { ...inputOf(cond), op: op as Re4Op }); }
function changeValue(i: number, ci: number, cond: Re4StateCondition, raw: string) {
  const def = defOf(cond.type);
  let value: number | string | boolean = raw;
  if (!def || def.kind === 'bool') value = raw === 'true';
  else if (def.kind === 'number' || typeof def.options?.[0]?.value === 'number') { value = Number(raw); if (!Number.isFinite(value)) return; }
  return setCondition(i, ci, { ...inputOf(cond), value });
}
const setLogic = (i: number, logic: string) => props.perform({ kind: 'state-field', ...c(), index: i, field: 'logic', value: logic === 'OR' ? 'OR' : 'AND' });
function setHp(i: number, st: Re4State, patch: Partial<{ upper: number; lower: number; invert: boolean }> | null) {
  if (patch === null) return props.perform({ kind: 'state-hp', ...c(), index: i });
  const cur = st.hp ?? { upper: 100, lower: 0, invert: false };
  return props.perform({ kind: 'state-hp', ...c(), index: i, hp: { ...cur, ...patch } });
}
const optionsOf = (group: string) => groups.value.find(g => g.name === group)?.options.map(o => o.name) ?? [];
function addTarget(i: number, st: Re4State) {
  const used = new Set(st.targets.map(x => x.group));
  const g = groups.value.find(x => !used.has(x.name) && x.options.length);
  if (g) return props.perform({ kind: 'state-target', ...c(), index: i, group: g.name, option: g.options[0].name });
}

// 拖动(下标从 0 开始;state-move 从 1 开始)
const { from: dragFrom, drop: dropAt, start: startDrag } = usePointerReorder('.re4-main > .re4-state',
  (from, to) => props.busy ? undefined : props.perform({ kind: 'state-move', ...c(), from: from + 1, to: to + 1 }));
</script>

<template>
  <div class="re4-main">
    <section class="re4-panel re4-panel-head">
      <ElSwitch :model-value="snapshot.auto" :disabled="busy" size="small" @change="v => perform({ kind: 'auto', ...c(), enabled: v === true })" />
      <span class="re4-panel-title" :title="t('conditionSwitchHint')">{{ t('conditionSwitch') }}</span>
      <div class="re4-legend"><span v-for="k in LEGEND" :key="k" :class="'k-' + k"><span class="re4-sdot"></span>{{ t(LEGEND_KEY[k]) }}</span></div>
      <span class="re4-spacer"></span>
      <ElButton size="small" @click="states.forEach((_, i) => open.add(i + 1))">{{ t('expandAll') }}</ElButton>
      <ElButton size="small" @click="open.clear()">{{ t('collapseAll') }}</ElButton>
      <ElButton size="small" type="primary" :disabled="busy" @click="newState">{{ t('newState') }}</ElButton>
    </section>
    <span v-if="!states.length" class="re4-muted re4-small">{{ t('noStates') }}</span>

    <article v-for="(st, k) in states" :key="k" class="re4-panel re4-state" :class="['k-' + st.kind, { open: open.has(k + 1),
      'drop-before': dropAt?.index === k && !dropAt.after, 'drop-after': dropAt?.index === k && dropAt.after, dragging: dragFrom === k }]">
      <div class="re4-state-head" :class="{ one: !open.has(k + 1) }">
        <span class="re4-grip" :title="t('orderHint')" @pointerdown="e => startDrag(e, k)">⠿</span>
        <span v-if="open.has(k + 1)" class="re4-prio"><span>{{ k + 1 }}</span></span>
        <button class="re4-caret" :aria-expanded="open.has(k + 1)" @click="toggle(k + 1)">{{ open.has(k + 1) ? '▾' : '▸' }}</button>
        <span class="re4-sdot" :title="kindText(st, states, t)"></span>
        <template v-if="!open.has(k + 1)">
          <span class="re4-sname">{{ st.name }}</span>
          <span v-if="st.exclusive" class="re4-excl">{{ t('exclusive') }}</span>
          <span class="re4-ssum">{{ conditionSentence(st, t) }}　→　{{ targetSentence(st, t) }}</span>
        </template>
        <template v-else>
          <input class="re4-sname re4-sname-input" :value="st.name" :aria-label="t('stateName')"
            @change="e => perform({ kind: 'state-rename', ...c(), index: k + 1, name: (e.target as HTMLInputElement).value.trim() })">
          <button class="re4-xbtn" :aria-pressed="st.exclusive" :disabled="busy" :title="t('exclusiveHint')" @click="field(k + 1, 'exclusive', !st.exclusive)">{{ t('exclusive') }}</button>
          <span class="re4-fade">
            <label>{{ t('fadeIn') }}<input type="number" min="0" step="0.1" :value="st.fadeIn" @change="e => numField(k + 1, 'fade_in', (e.target as HTMLInputElement).value)"></label>
            <label>{{ t('fadeOut') }}<input type="number" min="0" step="0.1" :value="st.fadeOut" @change="e => numField(k + 1, 'fade_out', (e.target as HTMLInputElement).value)"></label>{{ t('seconds') }}
          </span>
          <span class="re4-spacer"></span>
        </template>
        <ElSwitch :model-value="st.enabled" :disabled="busy" size="small" :aria-label="t('enabled')" @change="v => field(k + 1, 'enabled', v === true)" />
        <span v-if="open.has(k + 1)" class="re4-small">{{ t('enabled') }}</span>
        <ElButton v-if="open.has(k + 1)" size="small" type="danger" plain :disabled="busy" @click="confirming = k + 1">{{ t('delete') }}</ElButton>
      </div>
      <div v-if="confirming === k + 1" class="re4-confirm">
        <span>{{ t('delete') }}「{{ st.name }}」？</span>
        <ElButton size="small" type="danger" @click="confirming = 0; perform({ kind: 'state-delete', ...c(), index: k + 1 })">{{ t('confirmDelete') }}</ElButton>
        <ElButton size="small" @click="confirming = 0">{{ t('cancel') }}</ElButton>
      </div>

      <div v-if="open.has(k + 1)" class="re4-state-body">
        <div class="re4-scol">
          <div class="re4-scol-title">{{ t('trigger') }}</div>
          <label class="re4-row re4-small" :title="t('hpHint')"><input type="checkbox" :checked="!!st.hp" :disabled="busy" @change="e => setHp(k + 1, st, (e.target as HTMLInputElement).checked ? {} : null)">{{ t('hpDrive') }}</label>
          <template v-if="st.hp">
            <div class="re4-fade">
              <label>{{ t('hpUpper') }}<input type="number" min="0" max="100" :value="st.hp.upper" @change="e => setHp(k + 1, st, { upper: Number((e.target as HTMLInputElement).value) })"></label>
              <label>{{ t('hpLower') }}<input type="number" min="0" max="100" :value="st.hp.lower" @change="e => setHp(k + 1, st, { lower: Number((e.target as HTMLInputElement).value) })"></label>
              <label><input type="checkbox" :checked="st.hp.invert" @change="e => setHp(k + 1, st, { invert: (e.target as HTMLInputElement).checked })">{{ t('hpInvert') }}</label>
            </div>
          </template>
          <template v-else>
            <span v-if="!st.conditions.length" class="re4-muted re4-small">{{ t('noConditions') }}</span>
            <div v-for="(cond, ci) in st.conditions" :key="ci" class="re4-cond" :class="{ met: cond.met }">
              <span class="re4-conn">
                <template v-if="ci === 0">{{ t('when') }}</template>
                <ElSelect v-else :model-value="st.logic" :disabled="busy" size="small" @change="v => setLogic(k + 1, String(v))">
                  <ElOption value="AND" :label="t('and')" /><ElOption value="OR" :label="t('or')" />
                </ElSelect>
              </span>
              <span class="re4-cexpr">
                <ElSelect class="re4-sel-type" :model-value="cond.type" :disabled="busy" size="small" filterable @change="v => changeType(k + 1, ci + 1, String(v))">
                  <ElOption v-if="!cond.known" :value="cond.type" :label="t('unknownCondition') + ' ' + cond.type" />
                  <template v-for="group in byCategory" :key="group.cat">
                    <ElOption class="re4-opt-head" :value="'__cat_' + group.cat" :label="t(CAT_KEY[group.cat])" disabled />
                    <ElOption v-for="d in group.defs" :key="d.id" :value="d.id" :label="d.label" />
                  </template>
                </ElSelect>
                <template v-if="defOf(cond.type)?.kind === 'number'">
                  <ElSelect class="re4-sel-op" :model-value="cond.op" :disabled="busy" size="small" @change="v => changeOp(k + 1, ci + 1, cond, String(v))">
                    <ElOption v-for="op in defOf(cond.type)?.ops ?? []" :key="op" :value="op" :label="op" />
                  </ElSelect>
                  <input type="number" :value="cond.value" :disabled="busy" @change="e => changeValue(k + 1, ci + 1, cond, (e.target as HTMLInputElement).value)">
                </template>
                <template v-else-if="defOf(cond.type)?.kind === 'enum'">
                  <ElSelect class="re4-sel-op" :model-value="cond.op" :disabled="busy" size="small" @change="v => changeOp(k + 1, ci + 1, cond, String(v))">
                    <ElOption value="==" label="=" /><ElOption value="~=" label="≠" />
                  </ElSelect>
                  <ElSelect class="re4-sel-val" :model-value="String(cond.value)" :disabled="busy" size="small" @change="v => changeValue(k + 1, ci + 1, cond, String(v))">
                    <ElOption v-for="o in defOf(cond.type)?.options ?? []" :key="String(o.value)" :value="String(o.value)" :label="o.label" />
                  </ElSelect>
                </template>
                <ElSelect v-else class="re4-sel-op" :model-value="String(cond.value)" :disabled="busy" size="small" @change="v => changeValue(k + 1, ci + 1, cond, String(v))">
                  <ElOption value="true" :label="t('yes')" /><ElOption value="false" :label="t('no')" />
                </ElSelect>
                <span class="re4-now">{{ currentValueText(defOf(cond.type), t) ? t('now', currentValueText(defOf(cond.type), t)) : '' }}</span>
              </span>
              <button class="re4-x" :disabled="busy" :aria-label="t('delete')" @click="perform({ kind: 'condition-delete', ...c(), index: k + 1, condition_index: ci + 1 })">×</button>
            </div>
            <div><ElButton size="small" :disabled="busy" @click="perform({ kind: 'condition-add', ...c(), index: k + 1, condition: defaultCondition(defOf('is_battle')) })">{{ t('addCondition') }}</ElButton></div>
            <div class="re4-fade">{{ t('holdLabel') }}<input type="number" min="0" step="0.5" :value="st.hold" @change="e => numField(k + 1, 'hold', (e.target as HTMLInputElement).value)">{{ t('seconds') }}</div>
          </template>
        </div>
        <div class="re4-scol">
          <div class="re4-scol-title">{{ t('switchTo') }}</div>
          <div class="re4-target">
            <span class="re4-muted re4-small">{{ t('baseTarget') }}</span>
            <ElSelect class="re4-sel-target" :model-value="st.base ?? ''" :empty-values="[null, undefined]" :disabled="busy" size="small" @change="v => perform({ kind: 'state-base', ...c(), index: k + 1, preset: String(v ?? '') || undefined })">
              <ElOption value="" :label="t('noSwitch')" />
              <ElOption v-if="st.base && !basePresets.includes(st.base)" :value="st.base" :label="st.base + ' · ' + t('moved')" />
              <ElOption v-for="name in basePresets" :key="name" :value="name" :label="name" />
            </ElSelect>
            <span class="re4-res" :class="st.baseResult?.kind">{{ resultText(st.baseResult, states, t) }}</span>
          </div>
          <div v-for="(tg, ti) in st.targets" :key="tg.group" class="re4-target">
            <ElSelect class="re4-sel-target" :model-value="tg.group" :disabled="busy" size="small" @change="v => perform({ kind: 'state-target-group', ...c(), index: k + 1, target: ti + 1, group: String(v) })">
              <ElOption v-if="!groups.some(g => g.name === tg.group)" :value="tg.group" :label="tg.group + ' · ' + t('moved')" />
              <ElOption v-for="g in groups" :key="g.name" :value="g.name" :label="g.name" />
            </ElSelect>
            <span class="re4-muted">→</span>
            <ElSelect class="re4-sel-target" :model-value="tg.option" :disabled="busy" size="small" @change="v => perform({ kind: 'state-target', ...c(), index: k + 1, group: tg.group, option: String(v) })">
              <ElOption v-if="!optionsOf(tg.group).includes(tg.option)" :value="tg.option" :label="tg.option + ' · ' + t('moved')" />
              <ElOption v-for="o in optionsOf(tg.group)" :key="o" :value="o" :label="o" />
            </ElSelect>
            <span class="re4-res" :class="tg.result?.kind">{{ resultText(tg.result, states, t) }}</span>
            <button class="re4-x" :disabled="busy" :aria-label="t('delete')" @click="perform({ kind: 'state-target-remove', ...c(), index: k + 1, target: ti + 1 })">×</button>
          </div>
          <div><ElButton size="small" :disabled="busy || st.targets.length >= groups.length" @click="addTarget(k + 1, st)">{{ t('addGroupTarget') }}</ElButton></div>
        </div>
      </div>
    </article>
  </div>
</template>

<style>
.re4-state { overflow: hidden; }
.re4-state.dragging { opacity: .45; }
.re4-state.drop-before { box-shadow: 0 -3px 0 var(--avm-accent); }
.re4-state.drop-after { box-shadow: 0 3px 0 var(--avm-accent); }
.re4-state-head { display: flex; flex-wrap: wrap; align-items: center; gap: 6px 10px; padding: 7px 12px; }
.re4-state-head.one { flex-wrap: nowrap; }
.re4-state.open .re4-state-head { border-bottom: 1px solid var(--avm-line); }
.re4-grip { cursor: grab; color: var(--avm-muted); user-select: none; touch-action: none; padding: 2px 3px; }
body.re4-reordering, body.re4-reordering * { cursor: grabbing !important; user-select: none !important; }
.re4-prio { display: inline-flex; flex-direction: column; align-items: center; line-height: 1; }
.re4-prio span { font-size: 11px; color: var(--avm-muted); font-variant-numeric: tabular-nums; }
.re4-state-head .re4-sname { font-weight: 600; white-space: nowrap; }
.re4-sname-input { font-weight: 600; border: 1px solid transparent; border-radius: 4px; padding: 1px 6px; background: transparent; width: 9em; max-width: 100%; color: inherit; }
.re4-sname-input:hover, .re4-sname-input:focus { border-color: var(--avm-line); }
.k-active .re4-sname-input, .k-partial .re4-sname-input { color: var(--re4-ok); }
.k-outranked .re4-sname-input { color: var(--re4-bad); }
.re4-ssum { flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: var(--avm-muted); font-size: 12.5px; }
.re4-excl { font-size: 11px; padding: 0 6px; border-radius: 8px; border: 1px solid var(--avm-accent); color: var(--avm-accent); white-space: nowrap; }
.re4-xbtn { border: 1px solid var(--avm-line); background: transparent; color: var(--avm-muted); border-radius: 12px; padding: 0 10px; font-size: 12.5px; line-height: 1.7; cursor: pointer; }
.re4-xbtn[aria-pressed=true] { background: var(--avm-accent); border-color: var(--avm-accent); color: var(--el-bg-color, #fff); }
.re4-fade { display: inline-flex; flex-wrap: wrap; align-items: center; gap: 4px 8px; font-size: 12.5px; color: var(--avm-muted); }
.re4-fade label { display: inline-flex; align-items: center; gap: 4px; }
.re4-fade input[type=number] { width: 4em; border: 1px solid var(--avm-line); border-radius: 4px; background: transparent; color: inherit; padding: 0 4px; }
.re4-state-body { display: grid; grid-template-columns: minmax(0, 1.15fr) minmax(0, 1fr); }
@media (max-width: 760px) { .re4-state-body { grid-template-columns: minmax(0, 1fr); } }
.re4-scol { padding: 8px 12px; display: grid; gap: 6px; align-content: start; min-width: 0; }
.re4-scol + .re4-scol { border-left: 1px solid var(--avm-line); }
@media (max-width: 760px) { .re4-scol + .re4-scol { border-left: 0; border-top: 1px solid var(--avm-line); } }
.re4-scol-title { font-weight: 500; font-size: 13px; }
.re4-cond { display: grid; grid-template-columns: 3.4em minmax(0, 1fr) auto; gap: 6px; align-items: center; }
.re4-conn { font-size: 13px; color: var(--avm-muted); text-align: right; }
.re4-conn .el-select { width: 100%; }
.re4-conn .el-select__selected-item { color: var(--avm-accent); }
.re4-cexpr { display: flex; flex-wrap: wrap; align-items: center; gap: 4px 6px; padding: 3px 8px; border-radius: 6px; border: 1px solid var(--avm-line); min-width: 0; }
.re4-cond.met .re4-cexpr { border-color: var(--re4-ok); background: var(--re4-ok-soft); }
.re4-cexpr > input { border: 1px solid var(--avm-line); border-radius: 4px; background: var(--el-bg-color, transparent); color: inherit; padding: 0 4px; max-width: 100%; }
.re4-sel-type { width: 11em; }
.re4-sel-op { width: 5em; }
.re4-sel-val { width: 8em; }
.re4-sel-target { width: 9.5em; }
.re4-opt-head.is-disabled { font-size: 12px; font-weight: 600; cursor: default; }
.re4-cexpr > input[type=number] { width: 4.5em; }
.re4-now { font-size: 12px; color: var(--avm-muted); margin-left: auto; }
.re4-cond.met .re4-now { color: var(--re4-ok); }
.re4-x { border: 0; background: none; color: var(--avm-muted); padding: 0 4px; font-size: 16px; line-height: 1; cursor: pointer; }
.re4-x:hover:not(:disabled) { color: var(--re4-bad); }
.re4-target { display: flex; flex-wrap: wrap; align-items: center; gap: 6px 8px; }
</style>
