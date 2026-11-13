<script setup lang="ts">
import Re4Num from './Re4Num.vue';
import Re4HotkeyPick from './Re4HotkeyPick.vue';
import { cycleOf, keyOf as hotkeyFor } from './hotkeys';
import { computed, reactive, ref, shallowRef } from 'vue';
import { ElButton, ElInput, ElOption, ElSelect, ElSwitch } from '@reff/ui';
import type { Re4Translate } from './i18n';
import type { Re4Perform, Re4SksRefs, Re4Snapshot, Re4Values } from './types';
import { baseLabel, keyOf, labelOf, shortSlot, splitKey, stateLabel, usersOf } from './util';
import { usePointerReorder } from './reorder';

// 整套造型 / 状态组的编辑页（两个页签共用）。可折叠的栏默认收起。
//   整套造型：完整快照，材质只有开 / 关；新建时抓取当前外观。
//   状态组：选项列出当前模型的全部材质，每个设「- / 关 / 开」（没有范围限制）。几个组可以写同一个材质，
//   靠下的组覆盖靠上的（顺序就是叠加顺序，拖 ⠿ 调整）；只提示取值不同的重叠。
//   材质按部位分段，每段三列排列。
const props = defineProps<{ mode: 'base' | 'groups'; snapshot: Re4Snapshot; busy: boolean; perform: Re4Perform; t: Re4Translate }>();
const c = () => ({ character: props.snapshot.character });

const open = reactive(new Set<string>());          // 展开的组 / 选项
const nfOff = computed(() => props.snapshot.settings.newFeatures === false);   // 新版特性关闭:相关界面灰掉、不可改
const toggle = (set: Set<string>, key: string) => { if (set.has(key)) set.delete(key); else set.add(key); };
const sksClosed = reactive(new Set<string>());     // 折叠起来的「形态键（SKS）」栏(默认展开)
const sksAll = reactive(new Set<string>());        // 也列出其他 SKS 配置里键组的选项
const notes = shallowRef(false);
// 整套造型预设的改名框。必须是 ref:v-model 改的是对象里的 value,shallowRef 不会因此重绘(打字看不到变化)
const confirming = shallowRef('');
const newGroupName = shallowRef('');

// 当前模型的材质(镜像开着时不编辑护甲)
const slots = computed(() => (props.snapshot.slots ?? []).filter(s => !s.mirrored));
const allKeys = computed(() => slots.value.flatMap(s => s.materials.map(m => keyOf(s.id, m.name))));
const noteOf = computed(() => {
  const out: Record<string, string> = {};
  for (const s of props.snapshot.slots ?? []) for (const m of s.materials) if (m.note) out[keyOf(s.id, m.name)] = m.note;
  return out;
});
// 每个组在每个材质上可能写出的取值(按全部选项统计,换个选项就可能改写法)
const writes = computed(() => {
  const out: Record<string, Record<string, { on: boolean; off: boolean }>> = {};
  for (const g of props.snapshot.groups ?? []) {
    const w: Record<string, { on: boolean; off: boolean }> = {};
    for (const o of g.options) for (const [k, v] of Object.entries(o.values)) {
      if (typeof v !== 'boolean') continue;
      const e = (w[k] ??= { on: false, off: false });
      if (v) e.on = true; else e.off = true;
    }
    out[g.name] = w;
  }
  return out;
});
// 材质 -> 写它的组(按叠加顺序)
const owners = computed(() => {
  const out: Record<string, string[]> = {};
  for (const g of props.snapshot.groups ?? []) for (const k of Object.keys(writes.value[g.name] ?? {})) (out[k] ??= []).push(g.name);
  return out;
});
const othersOf = (key: string, self: string) => (owners.value[key] ?? []).filter(n => n !== self);
// 两组在 key 上会不会写出不同的值
function clash(a: string, b: string, key: string) {
  const x = writes.value[a]?.[key], y = writes.value[b]?.[key];
  return !!x && !!y && ((x.on && y.off) || (x.off && y.on));
}
const groupIndex = computed(() => new Map((props.snapshot.groups ?? []).map((g, i) => [g.name, i])));
// 组和组之间取值不同的重叠:below = 被下面的组覆盖,above = 覆盖上面的组
const overlaps = computed(() => {
  type Overlap = { name: string; label?: string; n: number };
  const out: Record<string, { below: Overlap[]; above: Overlap[] }> = {};
  const gs = props.snapshot.groups ?? [];
  for (const [i, g] of gs.entries()) {
    const below: Overlap[] = [], above: Overlap[] = [];
    for (const [j, h] of gs.entries()) {
      if (i === j) continue;
      const n = Object.keys(writes.value[g.name] ?? {}).filter(k => clash(g.name, h.name, k)).length;
      if (n) (j > i ? below : above).push({ name: h.name, label: h.label, n });
    }
    out[g.name] = { below, above };
  }
  return out;
});
// 这个选项在 key 上写的值,会被哪些更靠下的组写成相反的值
function overriders(card: Card, values: Re4Values, key: string) {
  const v = values[key];
  if (card.isBase || typeof v !== 'boolean') return [];
  const me = groupIndex.value.get(card.name) ?? -1;
  return othersOf(key, card.name).filter(n => (groupIndex.value.get(n) ?? -1) > me && (v ? writes.value[n]?.[key]?.off : writes.value[n]?.[key]?.on));
}

// 拖动排序(同条件状态页,pointer 事件,见 reorder.ts)
const { from: dragFrom, drop: dropAt, start: startDrag } = usePointerReorder('.re4-main > .re4-gcard', (from, to) => {
  const g = props.snapshot.groups?.[from];
  if (g && !props.busy) return props.perform({ kind: 'group-move', ...c(), group: g.name, offset: to - from });
});
const stateName = (i?: number) => stateLabel(props.snapshot.states ?? [], i);

interface Card {
  id: string; isBase: boolean; name: string; label?: string; active: string; effective?: string; fromState?: number; bases?: string[];
  multi?: boolean; actives?: string[];
  options: { name: string; label?: string; values: Re4Values; match?: { status: string; skipped: string[] }; height?: number; palette?: string; dissolve?: string; sks?: Re4SksRefs;
    on?: boolean; effective?: boolean; fromState?: number }[];
}
const cards = computed<Card[]>(() => {
  if (props.mode === 'base') {
    const b = props.snapshot.base!;
    return [{ id: 'base', isBase: true, name: props.t('tabBase'), active: b.active, effective: b.effective, fromState: b.fromState,
      options: b.presets }];
  }
  return (props.snapshot.groups ?? []).map(g => ({ id: 'g:' + g.name, isBase: false, name: g.name, label: g.label, active: g.active,
    effective: g.effective, fromState: g.fromState, options: g.options, bases: Array.isArray(g.bases) ? g.bases : [],
    multi: g.multi === true, actives: Array.isArray(g.actives) ? g.actives : [] }));
});

// 整套造型只数当前模型上的材质;状态组数选项写了的材质
const counts = (card: Card, values: Re4Values) => {
  let on = 0, off = 0;
  const keys = card.isBase ? allKeys.value : Object.keys(values);
  for (const k of keys) { if (values[k] === true) on++; else if (values[k] === false) off++; }
  return { on, off };
};
const setCount = (card: Card) => Object.keys(writes.value[card.name] ?? {}).length;
// 选项展开后的材质:按部位分段;状态组写了、但当前模型上没有的材质另列一段(可以改成「-」清掉)
function sections(card: Card, values: Re4Values) {
  const out = slots.value.filter(s => s.materials.length)
    .map(s => ({ id: s.id, label: shortSlot(s.label), keys: s.materials.map(m => keyOf(s.id, m.name)) }));
  if (!card.isBase) {
    const known = new Set(allKeys.value);
    const extra = Object.keys(values).filter(k => !known.has(k)).sort();
    if (extra.length) out.push({ id: '', label: props.t('notOnModel'), keys: extra });
  }
  return out;
}
const users = (card: Card, option?: string) => usersOf(props.snapshot, card.isBase ? null : card.name, option);

function act(kind: string, card: Card, extra: Record<string, unknown>) {
  const target = card.isBase ? {} : { group: card.name };
  return props.perform({ kind, ...c(), ...target, ...extra } as never);
}
const pick = (card: Card, option: string) => props.perform({ kind: 'manual', ...c(), layer: card.isBase ? 'base' : card.name, option });
// 复选组:选项各自开关;「（无）」= 全部关掉。行的高亮:复选组按各选项自己的开关 / 接管看
const setOn = (card: Card, option: string, on: boolean) => props.perform({ kind: 'option-on', ...c(), group: card.name, option, on });
const noneOn = (card: Card) => card.multi ? !(card.actives ?? []).length : card.active === '';
const optManual = (card: Card, opt: Card['options'][number]) => card.multi ? opt.on === true : card.active === opt.name;
const optEff = (card: Card, opt: Card['options'][number]) =>
  card.multi ? !!opt.fromState && opt.effective === true : !!card.fromState && card.effective === opt.name;
const setMulti = (card: Card, on: boolean) => card.multi !== on && props.perform({ kind: 'group-multi', ...c(), group: card.name, on });
const prefix = (card: Card) => card.isBase ? 'base' : 'option';

function setMaterial(card: Card, option: string, key: string, value: 'none' | 'off' | 'on') {
  const [slot, material] = splitKey(key);
  if (card.isBase) return props.perform({ kind: 'base-material', ...c(), preset: option, slot, material, value: value === 'on' });
  return props.perform({ kind: 'option-material', ...c(), group: card.name, option, slot, material, value });
}
// 一个部位(一段)的材质批量设置:全部 — / 关 / 开、反选
function bulk(card: Card, option: string, keys: string[], op: 'none' | 'off' | 'on' | 'invert') {
  const items = keys.map(k => { const [slot, material] = splitKey(k); return { slot, material }; });
  return props.perform({ kind: 'material-bulk', ...c(), layer: card.isBase ? 'base' : card.name, option, items, op });
}
const valueOf = (values: Re4Values, key: string) => values[key] === true ? 'on' : values[key] === false ? 'off' : 'none';

// 整套造型预设 / 状态组选项的行内改名;失败(重名 / 非法)就把输入框恢复成原名。展开状态按名字记,改名后跟着搬。
// 框里是显示名:英文界面且有英文名时改的是英文名,名字(引用键)不变,展开状态也不用搬(Lua OpsV3.rename_base / rename_option)
async function renameOption(card: Card, opt: Card['options'][number], input: HTMLInputElement) {
  const old = opt.name, shown = labelOf(opt);
  const name = input.value.trim();
  if (!name || name === shown) { input.value = shown; return; }
  const ok = card.isBase
    ? await props.perform({ kind: 'base-rename', ...c(), preset: old, name })
    : await props.perform({ kind: 'option-rename', ...c(), group: card.name, option: old, name });
  if (!ok) { input.value = shown; return; }
  if (opt.label !== undefined) return;
  const from = card.id + '|' + old;
  if (open.delete(from)) open.add(card.id + '|' + name);
}
// 模型高度(厘米,同 Lua 的 ModelV3.HEIGHT_MIN / MAX)。value = undefined(数值框清空 / 点清除)→ 清除
const HEIGHT_MIN = -20, HEIGHT_MAX = 50;
const cmText = (v: number) => (v > 0 ? '+' : '') + v;
function setHeight(card: Card, option: string, value: number | undefined) {
  const cm = value === undefined ? undefined : Math.round(value * 10) / 10;
  return card.isBase ? props.perform({ kind: 'base-height', ...c(), preset: option, cm })
    : props.perform({ kind: 'option-height', ...c(), group: card.name, option, cm });
}
// 调色方案:选中这个预设 / 选项时叠加的方案。"" = 不调色;指向已删除的方案时下拉框里另列一项「方案不存在」
const schemeNames = computed(() => (props.snapshot.palettes?.list ?? []).map(x => x.name));
const schemeMissing = (name?: string) => !!name && !schemeNames.value.includes(name);
const setPalette = (card: Card, option: string, scheme: string) =>
  props.perform({ kind: 'palette-ref', ...c(), layer: card.isBase ? 'base' : card.name, option, scheme });
// 溶解预设(全局库):切到这个预设 / 选项时的溶解用它;"" = 默认预设
const dissolveNames = computed(() => (props.snapshot.settings.dissolvePresets?.list ?? []).map(x => x.name));
const dissolveMissing = (name?: string) => !!name && !dissolveNames.value.includes(name);
const setDissolve = (card: Card, option: string, preset: string) =>
  props.perform({ kind: 'dissolve-ref', ...c(), layer: card.isBase ? 'base' : card.name, option, preset });
// 造型归属的下拉:所有整套造型预设
const baseNames = computed(() => (props.snapshot.base?.presets ?? []).map(p => p.name));
// ShapeKeySystem 键组:SKS 驱动这个角色时才能编辑。默认只列当前生效的 SKS 配置里的键组,
// 外加这一项已经设置了的键组(不在当前配置里的标「*」);all = 也列出这个角色其他 SKS 配置里的键组
type SksRow = { name: string; options: string[]; inCurrent: boolean };
const sksEditable = computed(() => !!props.snapshot.sks?.actor);
const sksKnown = computed<SksRow[]>(() => {
  const g = props.snapshot.sks?.groups;
  return (Array.isArray(g) ? g : []).map(x => ({ name: x.name, options: Array.isArray(x.options) ? x.options : [], inCurrent: x.inCurrent }));
});
function sksRows(opt: { sks?: Re4SksRefs }, all = false): SksRow[] {
  const set = opt.sks ?? {};
  const rows = sksKnown.value.filter(r => all || r.inCurrent || r.name in set);
  for (const name of Object.keys(set)) {
    if (!rows.some(r => r.name === name)) rows.push({ name, options: [], inCurrent: false });
  }
  return rows;
}
// 默认被隐去的键组数(其他配置里有、当前配置没有、这一项也没设置)
const sksHidden = (opt: { sks?: Re4SksRefs }) => sksRows(opt, true).length - sksRows(opt).length;
const sksSetCount = (opt: { sks?: Re4SksRefs }) => Object.keys(opt.sks ?? {}).length;
const sksValue = (opt: { sks?: Re4SksRefs }, group: string): string | 0 => opt.sks?.[group] ?? '';
const sksOptionMissing = (row: SksRow, v: string | 0) => typeof v === 'string' && v !== '' && !row.options.includes(v);
const sksError = (opt: { sks?: Re4SksRefs }, group: string) =>
  sksValue(opt, group) !== '' ? props.snapshot.sks?.errors?.[group] : undefined;
const sksText = (refs?: Re4SksRefs) => Object.entries(refs ?? {}).map(([g, v]) => g + '＝' + (v === 0 ? props.t('sksNoneOption') : v)).join('、');
const setSks = (card: Card, option: string, group: string, value: unknown) =>
  props.perform({ kind: 'sks-ref', ...c(), layer: card.isBase ? 'base' : card.name, option, group, value: value === 0 ? 0 : String(value ?? '') });
// 快捷键(Alt + 数字,见 hotkeys.ts):卡片标题上是整个结构的轮换键,每一项上是单项键或「参与轮换」开关
const cycleTarget = (card: Card) => card.isBase ? { kind: 'base' as const } : { kind: 'group' as const, group: card.name };
const itemTarget = (card: Card, option: string) =>
  card.isBase ? { kind: 'base' as const, option } : { kind: 'group' as const, group: card.name, option };
const itemKey = (card: Card, option: string) => hotkeyFor(props.snapshot, itemTarget(card, option))?.digit;
// 结构绑了轮换键:每一行外面直接给「参与轮换」开关(不用展开);没绑时单项选键在展开的工具栏里
// 卡片按名字做键，改名后展开状态要跟着搬到新名字上，否则改完就收起了
async function renameGroup(card: Card, input: HTMLInputElement) {
  const shown = labelOf(card);
  const name = input.value.trim();
  if (!name || name === shown) { input.value = shown; return; }
  const ok = await props.perform({ kind: 'group-rename', ...c(), group: card.name, name });
  if (!ok) { input.value = shown; return; }
  if (card.label !== undefined) return;   // 改的是英文名,卡片的键不变
  const from = card.id, to = 'g:' + name;
  for (const k of [...open]) {
    if (k === from) { open.delete(k); open.add(to); } else if (k.startsWith(from + '|')) { open.delete(k); open.add(to + k.slice(from.length)); }
  }
}
async function remove(card: Card, option?: string) {
  confirming.value = '';
  if (option === undefined) await props.perform({ kind: 'group-delete', ...c(), group: card.name });
  else if (card.isBase) await props.perform({ kind: 'base-delete', ...c(), preset: option });
  else await props.perform({ kind: 'option-delete', ...c(), group: card.name, option });
}
async function newOption(card: Card) {
  if (await act('option-new', card, {})) open.add(card.id);
}
async function newGroup() {
  const name = newGroupName.value.trim();
  if (!name) return;
  if (await props.perform({ kind: 'group-new', ...c(), name })) { newGroupName.value = ''; open.add('g:' + name); }
}
const setNote = (key: string, text: string) => { const [slot, material] = splitKey(key); return props.perform({ kind: 'note', ...c(), slot, material, text }); };
const locate = (key: string) => { const [slot, material] = splitKey(key); return props.perform({ kind: 'locate', ...c(), slot, material }); };
// 材质名的提示:全名 + 备注 + 也写了它的其他组
function nameTitle(card: Card, key: string) {
  const parts = [splitKey(key)[1]];
  if (noteOf.value[key]) parts.push(noteOf.value[key]);
  const others = card.isBase ? [] : othersOf(key, card.name);
  if (others.length) parts.push(props.t('alsoIn', others.join('、')));
  return parts.join('\n');
}
</script>

<template>
  <div class="re4-main">
    <label class="re4-row" :title="t('notesHint')">
      <ElSwitch v-model="notes" size="small" /><span>{{ t('notesMode') }}</span>
    </label>
    <section v-for="(card, ci) in cards" :key="card.id" class="re4-panel"
      :class="{ 're4-gcard': !card.isBase, dragging: !card.isBase && dragFrom === ci,
        'drop-before': !card.isBase && dropAt?.index === ci && !dropAt.after, 'drop-after': !card.isBase && dropAt?.index === ci && dropAt.after }">
      <div class="re4-panel-head re4-ghead">
        <template v-if="!card.isBase">
          <span class="re4-grip" :title="t('groupOrder')" @pointerdown="e => startDrag(e, ci)">⠿</span>
          <span class="re4-prio"><span>{{ ci + 1 }}</span></span>
        </template>
        <!-- 整套造型只有这一栏,不折叠 -->
        <button v-if="!card.isBase" class="re4-caret" :aria-expanded="open.has(card.id)" @click="toggle(open, card.id)">{{ open.has(card.id) ? '▾' : '▸' }}</button>
        <!-- 同条件状态：展开时名字就是输入框，回车或离开即改名 -->
        <input v-if="!card.isBase && open.has(card.id)" class="re4-sname-input" :value="labelOf(card)" :aria-label="t('groupName')" :disabled="busy"
          @change="e => renameGroup(card, e.target as HTMLInputElement)">
        <span v-else class="re4-panel-title" :title="card.isBase ? undefined : t('optionsCount', card.options.length) + ' · ' + t('materialsCount', setCount(card))">{{ labelOf(card) }}</span>
        <!-- 信息区可收缩，操作按钮固定在右侧同一行 -->
        <span class="re4-gmeta">
          <!-- 状态组的选项数、材质数不占标题栏(窄屏时挤掉名字),放在名字的悬停提示里 -->
          <span v-if="card.isBase" class="re4-muted re4-small">{{ t('baseCount', card.options.length) }}</span>
          <span v-if="card.fromState" class="re4-tag ok">{{ t('takenOverBy', stateName(card.fromState)) }}</span>
          <template v-if="!card.isBase">
            <span v-for="o in overlaps[card.name]?.below ?? []" :key="'b' + o.name" class="re4-tag bad" :title="t('overlapHint')">{{ t('overriddenBy', labelOf(o), o.n) }}</span>
            <span v-for="o in overlaps[card.name]?.above ?? []" :key="'a' + o.name" class="re4-tag" :title="t('overlapHint')">{{ t('overrides', labelOf(o), o.n) }}</span>
          </template>
        </span>
        <span class="re4-gacts">
          <!-- 选择方式:单选 / 复选(复选组各选项分别开关) -->
          <span v-if="!card.isBase" class="re4-height" :title="t('groupModeHint')">{{ t('groupMode') }}
            <span class="re4-seg re4-gmode" role="group" :aria-label="t('groupMode')">
              <button :aria-pressed="!card.multi" :disabled="busy" @click="setMulti(card, false)">{{ t('groupSingle') }}</button>
              <button :aria-pressed="card.multi === true" :disabled="busy" @click="setMulti(card, true)">{{ t('groupMulti') }}</button>
            </span></span>
          <!-- 造型归属:快速切换页只在当前整套造型属于这些造型时显示这个状态组;空 = 全部 -->
          <label v-if="!card.isBase" class="re4-height re4-gbases" :title="t('groupBasesHint')">{{ t('groupBases') }}
            <ElSelect :model-value="card.bases" multiple collapse-tags collapse-tags-tooltip size="small" style="width:10em" :disabled="busy"
              :placeholder="t('groupBasesAll')" :aria-label="t('groupBases')"
              @change="v => perform({ kind: 'group-bases', ...c(), group: card.name, bases: (v as string[]) ?? [] })">
              <ElOption v-for="n in baseNames" :key="n" :value="n" :label="baseLabel(snapshot, n)" />
            </ElSelect></label>
          <Re4HotkeyPick v-if="!card.multi" :snapshot="snapshot" :busy="busy" :perform="perform" :t="t" :target="cycleTarget(card)" :label="t('hotkeyCycleRef')" />
          <ElButton v-if="card.isBase" size="small" :disabled="busy" @click="perform({ kind: 'base-new', ...c() }).then(ok => ok && open.add(card.id))">{{ t('newBase') }}</ElButton>
          <ElButton v-else size="small" type="danger" plain :disabled="busy" @click="confirming = card.id">{{ t('delete') }}</ElButton>
        </span>
      </div>
      <div v-if="confirming === card.id" class="re4-confirm">
        <span>{{ t('delete') }}「{{ labelOf(card) }}」？<template v-if="users(card).length">{{ t('deleteWarnUsed', users(card).map(labelOf).join('」「')) }}</template>{{ t('backupFirst') }}</span>
        <ElButton size="small" type="danger" @click="remove(card)">{{ t('confirmDelete') }}</ElButton><ElButton size="small" @click="confirming = ''">{{ t('cancel') }}</ElButton>
      </div>

      <template v-if="card.isBase || open.has(card.id)">
        <div class="re4-olist">
          <div v-if="!card.isBase" class="re4-orow" :class="{ manual: noneOn(card) }">
            <span class="re4-caret"></span>
            <label class="re4-oname"><input :type="card.multi ? 'checkbox' : 'radio'" :name="card.id" :checked="noneOn(card)" :disabled="busy || (card.multi && noneOn(card))"
              @change="pick(card, '')">{{ t('none') }}</label>
            <span class="re4-oinfo"><span v-if="itemKey(card, '') !== undefined" class="re4-tag" :title="t('hotkeyHint')">Alt+{{ itemKey(card, '') }}</span></span>
            <span class="re4-oact"><Re4HotkeyPick :snapshot="snapshot" :busy="busy" :perform="perform" :t="t" :target="itemTarget(card, '')" /></span>
          </div>
          <template v-for="opt in card.options" :key="opt.name">
            <div class="re4-orow" :class="{ manual: optManual(card, opt), eff: optEff(card, opt) }">
              <button class="re4-caret" :aria-expanded="open.has(card.id + '|' + opt.name)" @click="toggle(open, card.id + '|' + opt.name)">{{ open.has(card.id + '|' + opt.name) ? '▾' : '▸' }}</button>
              <!-- 整套造型的预设 / 状态组的选项:名字就是输入框,点上就能改,回车或离开即改名,Esc 放弃 -->
              <span class="re4-oname">
                <input v-if="card.multi" type="checkbox" :checked="opt.on === true" :disabled="busy" :aria-label="labelOf(opt)"
                  @change="e => setOn(card, opt.name, (e.target as HTMLInputElement).checked)">
                <input v-else type="radio" :name="card.id" :checked="card.active === opt.name" :disabled="busy" :aria-label="labelOf(opt)" @change="pick(card, opt.name)">
                <input class="re4-oname-input" :value="labelOf(opt)" :aria-label="t('rename')" :disabled="busy"
                  @change="e => renameOption(card, opt, e.target as HTMLInputElement)"
                  @keydown.enter="e => (e.target as HTMLInputElement).blur()"
                  @keydown.esc="e => { const el = e.target as HTMLInputElement; el.value = labelOf(opt); el.blur(); }">
              </span>
              <span class="re4-oinfo">
                <button class="re4-sum" @click="toggle(open, card.id + '|' + opt.name)">
                  <span class="on">{{ t('countOn', counts(card, opt.values).on) }}</span><span>{{ t('countOff', counts(card, opt.values).off) }}</span>
                </button>
                <span v-if="opt.match?.status === 'mismatch'" class="re4-res broken">{{ t('mismatch') }}</span>
                <span v-else-if="opt.match?.status === 'partial'" class="re4-res broken">{{ t('partialSlots', opt.match.skipped.join('、')) }}</span>
                <span v-if="users(card, opt.name).length" class="re4-used">{{ t('usedBy', users(card, opt.name).map(labelOf).join('」「')) }}</span>
                <span v-if="opt.height !== undefined" class="re4-tag" :title="t('heightHint')">{{ t('heightTag', cmText(opt.height)) }}</span>
                <span v-if="itemKey(card, opt.name) !== undefined" class="re4-tag" :title="t('hotkeyHint')">Alt+{{ itemKey(card, opt.name) }}</span>
                <span v-if="opt.palette" class="re4-tag" :class="{ 're4-res broken': schemeMissing(opt.palette) }"
                  :title="schemeMissing(opt.palette) ? t('paletteRefBroken') : t('paletteRef')">🎨 {{ opt.palette }}</span>
                <span v-if="opt.dissolve" class="re4-tag" :class="{ 're4-res broken': dissolveMissing(opt.dissolve) }"
                  :title="dissolveMissing(opt.dissolve) ? t('dissolveRefBroken') : t('dissolveRef')">✦ {{ opt.dissolve }}</span>
                <span v-if="opt.sks && Object.keys(opt.sks).length" class="re4-tag" :title="t('sksHint')">{{ t('sksTag', sksText(opt.sks)) }}</span>
              </span>
              <span class="re4-oact">
                <!-- 快捷键放在选项行上(同「（无）」):单项键;所在结构绑了轮换键时是「参与轮换」开关 -->
                <Re4HotkeyPick :snapshot="snapshot" :busy="busy" :perform="perform" :t="t" :target="itemTarget(card, opt.name)" />
                <ElButton size="small" type="danger" plain :disabled="busy" @click="confirming = card.id + '|' + opt.name">{{ t('delete') }}</ElButton>
              </span>
            </div>
            <div v-if="confirming === card.id + '|' + opt.name" class="re4-confirm">
              <span>{{ t('delete') }}「{{ labelOf(opt) }}」？<template v-if="users(card, opt.name).length">{{ t('deleteWarnUsed', users(card, opt.name).map(labelOf).join('」「')) }}</template>{{ t('backupFirst') }}</span>
              <ElButton size="small" type="danger" @click="remove(card, opt.name)">{{ t('confirmDelete') }}</ElButton><ElButton size="small" @click="confirming = ''">{{ t('cancel') }}</ElButton>
            </div>
            <div v-if="open.has(card.id + '|' + opt.name)" class="re4-mlist-wrap">
              <div class="re4-row re4-mtools">
                <ElButton size="small" :disabled="busy" @click="act(prefix(card) + '-move', card, card.isBase ? { preset: opt.name, offset: -1 } : { option: opt.name, offset: -1 })">{{ t('moveUp') }}</ElButton>
                <ElButton size="small" :disabled="busy" @click="act(prefix(card) + '-move', card, card.isBase ? { preset: opt.name, offset: 1 } : { option: opt.name, offset: 1 })">{{ t('moveDown') }}</ElButton>
                <ElButton size="small" :disabled="busy" @click="act(prefix(card) + '-duplicate', card, card.isBase ? { preset: opt.name } : { option: opt.name })">{{ t('duplicate') }}</ElButton>
                <template v-if="card.isBase">
                  <ElButton v-if="confirming !== 'rc|' + opt.name" size="small" :disabled="busy" @click="confirming = 'rc|' + opt.name">{{ t('recapture') }}</ElButton>
                  <template v-else>
                    <ElButton size="small" type="danger" @click="confirming = ''; perform({ kind: 'base-recapture', ...c(), preset: opt.name })">{{ t('confirmRecapture') }}</ElButton>
                    <ElButton size="small" @click="confirming = ''">{{ t('cancel') }}</ElButton>
                  </template>
                </template>
                <!-- 模型高度、调色方案、溶解预设、形态键:新版特性,关闭时灰掉 -->
                <span class="re4-nf-group" :class="{ 're4-nf-lock': nfOff }" :inert="nfOff">
                <!-- 模型高度:留空 = 这一层不管高度(交给别的层);填了就按叠加顺序覆盖 -->
                <label class="re4-height" :title="t('heightHint')">{{ t('heightLabel') }}
                  <Re4Num :value="opt.height" :min="HEIGHT_MIN" :max="HEIGHT_MAX" :placeholder="t('heightUnset')" allow-empty
                    :disabled="busy" @change="v => setHeight(card, opt.name, v)" />cm</label>
                <button v-if="opt.height !== undefined" class="re4-link" :disabled="busy" @click="setHeight(card, opt.name, undefined)">{{ t('heightClear') }}</button>
                <!-- 调色方案:选中这个预设 / 选项时叠加(在调色页新建和编辑方案) -->
                <label class="re4-height" :title="card.isBase ? undefined : t('paletteRefOptionHint')">{{ t('paletteRef') }}
                  <ElSelect :model-value="opt.palette ?? ''" :empty-values="[null, undefined]" size="small" style="width:11em" :disabled="busy" :aria-label="t('paletteRef')"
                    @change="v => setPalette(card, opt.name, String(v))">
                    <ElOption value="" :label="t('paletteRefNone')" />
                    <ElOption v-for="n in schemeNames" :key="n" :value="n" :label="n" />
                    <ElOption v-if="schemeMissing(opt.palette)" :value="opt.palette!" :label="t('paletteRefBroken') + '：' + opt.palette" disabled />
                  </ElSelect></label>
                <!-- 溶解预设:切到这个预设 / 选项时的溶解用它(在溶解页新建和编辑预设) -->
                <label class="re4-height">{{ t('dissolveRef') }}
                  <ElSelect :model-value="opt.dissolve ?? ''" :empty-values="[null, undefined]" size="small" style="width:11em" :disabled="busy" :aria-label="t('dissolveRef')"
                    @change="v => setDissolve(card, opt.name, String(v))">
                    <ElOption value="" :label="t('dissolveRefNone')" />
                    <ElOption v-for="n in dissolveNames" :key="n" :value="n" :label="n" />
                    <ElOption v-if="dissolveMissing(opt.dissolve)" :value="opt.dissolve!" :label="t('dissolveRefBroken') + '：' + opt.dissolve" disabled />
                  </ElSelect></label>
                </span>
              </div>
              <!-- ShapeKeySystem 键组:切到这个预设 / 选项时 SKS 的键组改用所选选项(数值在 SKS 里调)。折叠栏,默认展开 -->
              <div v-if="sksEditable && sksRows(opt, true).length" class="re4-sksbox" :class="{ 're4-nf-lock': nfOff }" :inert="nfOff">
                <div class="re4-sks-head">
                  <button class="re4-caret" :aria-expanded="!sksClosed.has(card.id + '|' + opt.name)"
                    @click="toggle(sksClosed, card.id + '|' + opt.name)">{{ sksClosed.has(card.id + '|' + opt.name) ? '▸' : '▾' }}</button>
                  <span :title="t('sksHint')">{{ t('sksRef') }}</span>
                  <span v-if="sksSetCount(opt)" class="re4-muted re4-small">{{ t('sksSetCount', sksSetCount(opt)) }}</span>
                  <button v-if="!sksClosed.has(card.id + '|' + opt.name) && (sksHidden(opt) || sksAll.has(card.id + '|' + opt.name))" class="re4-link"
                    @click="toggle(sksAll, card.id + '|' + opt.name)">{{ sksAll.has(card.id + '|' + opt.name) ? t('sksShowCurrent') : t('sksShowAll', sksHidden(opt)) }}</button>
                </div>
                <div v-if="!sksClosed.has(card.id + '|' + opt.name)" class="re4-sks">
                  <span v-if="!sksRows(opt, sksAll.has(card.id + '|' + opt.name)).length" class="re4-muted re4-small">{{ t('sksNoCurrent') }}</span>
                  <label v-for="row in sksRows(opt, sksAll.has(card.id + '|' + opt.name))" :key="row.name" class="re4-height" :class="{ 're4-bad-text': !!sksError(opt, row.name) }"
                    :title="sksError(opt, row.name) ? t('sksError', sksError(opt, row.name)!) : (!row.inCurrent ? t('sksNotInCurrent') : '')">
                    {{ row.name }}<span v-if="!row.inCurrent" class="re4-muted">*</span>
                    <ElSelect :model-value="sksValue(opt, row.name)" :empty-values="[null, undefined]" size="small" style="width:8em" :disabled="busy" :aria-label="row.name"
                      @change="v => setSks(card, opt.name, row.name, v)">
                      <ElOption value="" :label="t('sksUnset')" />
                      <ElOption :value="0" :label="t('sksNoneOption')" />
                      <ElOption v-for="o in row.options" :key="o" :value="o" :label="o" />
                      <ElOption v-if="sksOptionMissing(row, sksValue(opt, row.name))" :value="sksValue(opt, row.name)" :label="t('sksMissingOption') + '：' + sksValue(opt, row.name)" disabled />
                    </ElSelect></label>
                </div>
              </div>
              <span v-if="!sections(card, opt.values).length" class="re4-muted re4-small">{{ t('noMaterials') }}</span>
              <template v-for="sec in sections(card, opt.values)" :key="sec.id">
                <div class="re4-mslot" :class="{ missing: !sec.id }"><span>{{ sec.label }}</span>
                  <span class="re4-mbulk">
                    <button v-if="!card.isBase" class="re4-link" :disabled="busy" @click="bulk(card, opt.name, sec.keys, 'none')">{{ t('bulkNone') }}</button>
                    <button class="re4-link" :disabled="busy" @click="bulk(card, opt.name, sec.keys, 'off')">{{ t('bulkOff') }}</button>
                    <button class="re4-link" :disabled="busy" @click="bulk(card, opt.name, sec.keys, 'on')">{{ t('bulkOn') }}</button>
                    <button class="re4-link" :disabled="busy" :title="card.isBase ? undefined : t('bulkInvertHint')" @click="bulk(card, opt.name, sec.keys, 'invert')">{{ t('bulkInvert') }}</button>
                  </span></div>
                <div class="re4-mlist" :class="{ notes }">
                  <div v-for="key in sec.keys" :key="key" class="re4-mrow">
                    <span class="re4-tri" role="group" :aria-label="key">
                      <button v-if="!card.isBase" :aria-pressed="valueOf(opt.values, key) === 'none'" :disabled="busy" class="t-none" :title="t('ignore')" @click="setMaterial(card, opt.name, key, 'none')">-</button>
                      <button :aria-pressed="valueOf(opt.values, key) === 'off'" :disabled="busy" class="t-off" @click="setMaterial(card, opt.name, key, 'off')">{{ t('off') }}</button>
                      <button :aria-pressed="valueOf(opt.values, key) === 'on'" :disabled="busy" class="t-on" @click="setMaterial(card, opt.name, key, 'on')">{{ t('on') }}</button>
                    </span>
                    <span class="re4-mono re4-mname" :class="valueOf(opt.values, key)" :title="nameTitle(card, key)">{{ sec.id ? splitKey(key)[1] : key }}</span>
                    <template v-if="notes">
                      <input class="re4-alias" :value="noteOf[key] ?? ''" :placeholder="t('notePlaceholder')" :aria-label="key"
                        @change="e => setNote(key, (e.target as HTMLInputElement).value)">
                      <ElButton size="small" :disabled="busy" @click="locate(key)">{{ t('locate') }}</ElButton>
                    </template>
                    <span v-else-if="noteOf[key]" class="re4-muted re4-small re4-mnote" :title="noteOf[key]">{{ noteOf[key] }}</span>
                    <span v-if="overriders(card, opt.values, key).length" class="re4-small re4-bad-text re4-mwarn"
                      :title="t('mayBeOverridden', overriders(card, opt.values, key).join('、')) + '\n' + t('overlapHint')">⚠</span>
                  </div>
                </div>
              </template>
            </div>
          </template>
        </div>
        <div v-if="!card.isBase" class="re4-panel-body" style="border-top:1px solid var(--avm-line)">
          <div><ElButton size="small" :disabled="busy" @click="newOption(card)">{{ t('newOption') }}</ElButton></div>
        </div>
      </template>
    </section>

    <div v-if="mode === 'groups'" class="re4-row">
      <ElInput v-model="newGroupName" size="small" style="width:12em" :placeholder="t('groupName')" @keyup.enter="newGroup" />
      <ElButton size="small" :disabled="busy || !newGroupName.trim()" @click="newGroup">{{ t('newGroup') }}</ElButton>
    </div>
  </div>
</template>

<style>
.re4-panel-head.re4-ghead { flex-wrap: nowrap; }
.re4-ghead > :not(.re4-gmeta) { flex: none; }
.re4-gmeta { flex: 1 1 0; min-width: 0; display: flex; flex-wrap: wrap; align-items: center; gap: 4px 8px; }
.re4-gacts { display: flex; gap: 6px; }
.re4-gacts .el-button + .el-button { margin-left: 0; }
.re4-olist { display: grid; }
.re4-orow { display: grid; grid-template-columns: 1.4em minmax(0, 10em) minmax(0, 1fr) auto; gap: 4px 10px; align-items: center; min-height: 34px; padding: 3px 12px; }
.re4-olist > * + .re4-orow { border-top: 1px solid var(--avm-line); }
.re4-orow.manual { background: var(--re4-soft); }
.re4-orow.eff .re4-oname { color: var(--re4-ok); }
@media (max-width: 640px) { .re4-orow { grid-template-columns: 1.4em minmax(0, 1fr); } .re4-orow .re4-oinfo, .re4-orow .re4-oact { grid-column: 2; } }
.re4-oname { display: inline-flex; align-items: center; gap: 7px; cursor: pointer; font-weight: 500; overflow-wrap: anywhere; min-width: 0; }
.re4-oname input[type=radio] { margin: 0; }
.re4-oname-input { font: inherit; font-weight: 500; border: 1px solid transparent; border-radius: 4px; padding: 1px 5px; margin-left: -6px;
  background: transparent; color: inherit; width: 100%; min-width: 3em; cursor: text; }
.re4-oname-input:hover, .re4-oname-input:focus { border-color: var(--avm-line); }
.re4-oinfo { display: flex; flex-wrap: wrap; align-items: center; gap: 2px 10px; min-width: 0; font-size: 12.5px; color: var(--avm-muted); }
.re4-sum { border: 0; background: none; padding: 0; color: inherit; display: inline-flex; gap: 8px; cursor: pointer; font-size: inherit; }
.re4-sum .on { color: var(--re4-ok); }
.re4-used { color: var(--avm-accent); }
.re4-used b { font-weight: 500; }
.re4-oact { display: flex; gap: 4px; flex-wrap: wrap; justify-content: flex-end; align-items: center; }
.re4-oact .re4-hk-incl { margin-right: 6px; }
.re4-oact .el-button + .el-button, .re4-mtools .el-button + .el-button { margin-left: 0; }
.re4-height { display: inline-flex; align-items: center; gap: 4px; margin-left: 8px; font-size: 12.5px; color: var(--avm-muted); }
.re4-nf-group { display: contents; }
.re4-nf-group.re4-nf-lock { display: inline-flex; flex-wrap: wrap; align-items: center; gap: 6px; }
.re4-gmode button { min-height: 22px; padding: 0 8px; font-size: 12px; }
.re4-sksbox { display: grid; gap: 4px; }
.re4-sks-head { display: flex; align-items: center; gap: 8px; font-size: 12.5px; color: var(--avm-muted); }
.re4-sks { display: flex; flex-wrap: wrap; align-items: center; gap: 4px 0; padding-left: 1.4em; }
.re4-sks .re4-height { margin-left: 0; margin-right: 12px; }
.re4-mlist-wrap { padding: 6px 12px 8px 3.2em; background: var(--re4-soft); border-top: 1px dashed var(--avm-line); display: grid; gap: 6px; }
@media (max-width: 640px) { .re4-mlist-wrap { padding-left: 12px; } }
/* 材质三列排列(窄屏退到两列 / 一列);备注模式一行要放输入框和定位按钮,按宽度自动排 */
.re4-mslot { font-size: 12px; font-weight: 600; color: var(--avm-muted); padding-top: 2px; display: flex; flex-wrap: wrap; align-items: baseline; gap: 2px 12px; }
.re4-mbulk { display: inline-flex; flex-wrap: wrap; gap: 2px 10px; font-weight: 400; }
.re4-mslot.missing { color: var(--re4-bad); }
.re4-mlist { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 2px 16px; }
@media (max-width: 900px) { .re4-mlist { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
@media (max-width: 560px) { .re4-mlist { grid-template-columns: minmax(0, 1fr); } }
.re4-mlist.notes { grid-template-columns: repeat(auto-fill, minmax(24em, 1fr)); }
.re4-mrow { display: flex; align-items: center; gap: 8px; min-height: 26px; min-width: 0; }
.re4-mlist:not(.notes) .re4-mname { flex: 0 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.re4-mnote { flex: 1 1 0; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.re4-mwarn { flex: none; cursor: help; }
.re4-tri { display: inline-flex; border: 1px solid var(--avm-line); border-radius: 5px; overflow: hidden; flex: none; }
.re4-tri button { border: 0; background: transparent; width: 2.2em; height: 22px; padding: 0; font-size: 12px; color: var(--avm-muted); cursor: pointer; }
.re4-tri button + button { border-left: 1px solid var(--avm-line); }
.re4-tri button.t-none[aria-pressed=true] { background: var(--avm-line); color: var(--avm-ink); }
.re4-tri button.t-off[aria-pressed=true] { background: var(--avm-muted); color: var(--el-bg-color, #fff); }
.re4-tri button.t-on[aria-pressed=true] { background: var(--re4-ok); color: var(--el-bg-color, #fff); }
.re4-mname { overflow-wrap: anywhere; }
.re4-mname.none { color: var(--avm-muted); }
.re4-mname.off { color: var(--avm-muted); text-decoration: line-through; }
.re4-alias { width: 8em; border: 1px solid var(--avm-line); border-radius: 4px; background: transparent; color: inherit; padding: 0 5px; }
.re4-tag.bad { background: var(--re4-bad-soft); color: var(--re4-bad); }
.re4-bad-text { color: var(--re4-bad); }
.re4-panel.dragging { opacity: .45; }
.re4-panel.drop-before { box-shadow: 0 -3px 0 var(--avm-accent); }
.re4-panel.drop-after { box-shadow: 0 3px 0 var(--avm-accent); }
</style>
