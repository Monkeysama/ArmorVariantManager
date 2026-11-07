<script setup lang="ts">
import { computed, onActivated, onBeforeUnmount, onDeactivated, onMounted, reactive, shallowRef, watch } from 'vue';
import { ElButton, ElColorPicker, ElDialog, ElInput, ElOption, ElSelect, ElSlider, ElSwitch, ElTooltip } from '@reff/ui';
import Re4Num from './Re4Num.vue';
import Re4HotkeyPick from './Re4HotkeyPick.vue';
import type { Re4Translate } from './i18n';
import type {
  Re4Comp, Re4Palette, Re4PaletteEntry, Re4PaletteGroup, Re4PaletteMaterial, Re4PaletteOption, Re4PaletteOverride,
  Re4LiveWrite, Re4PaletteValue, Re4PaletteWrite, Re4Perform, Re4Snapshot, Re4Text,
} from './types';

// 调色页。左边选材质（可多选，跨部位），右边按材质映射列出参数：通用含义、拆开的分量、「i」里的注释。
// 多选时只列所有选中材质都有的项，改一次全部生效；「整体调色」对选中材质的颜色项转色相 / 调饱和度和明度。
// 值存在角色配置里，跟着预设走；映射只决定怎么显示。
// 顶部选中哪一份就生效哪一份(存进配置):初始(mdf2 原值,只读)或某个调色方案(cfg.palettes[名],
// 垫在被整套造型 / 状态组 / 条件状态引用的方案下面)。调色页编辑的就是选中的那一份;
// 选着初始时一改,Lua 自动新建一个方案并选中,改动记在新方案里。
const props = defineProps<{ snapshot: Re4Snapshot; busy: boolean; perform: Re4Perform; liveWrite?: Re4LiveWrite; t: Re4Translate }>();
const c = () => ({ character: props.snapshot.character });
const pal = computed<Re4Palette | undefined>(() => props.snapshot.palette);
const en = computed(() => props.snapshot.language === 'en');
const text = (v?: Re4Text, fallback = '') => (en.value ? v?.en ?? v?.zh : v?.zh ?? v?.en) ?? fallback;
const COMP: Re4Comp[] = ['x', 'y', 'z', 'w'];
const CI: Record<Re4Comp, number> = { x: 0, y: 1, z: 2, w: 3 };

// ---------------------------------------------------------------- 选择
const selection = shallowRef<string[]>([]);
// 选中的那一份("" = 初始)。以快照为准:选中 / 新建 / 改名 / 删除都由 Lua 改
const scheme = shallowRef('');
watch(() => pal.value?.scheme, v => {
  if (typeof v !== 'string' || v === scheme.value) return;
  // 选着初始时一改,Lua 自动新建方案并选中:这是我们自己的改动,接着用新方案,拖动中的预览不取消
  if (scheme.value === '' && v) { if (base) batchScheme = v; scheme.value = v; return; }
  void cancelBatch(); local.clear(); scheme.value = v;
});
// 「仅显示选中部位」:开着时人物身上只留选中的材质(其余部位整个隐藏),跟着选择走;离开调色页自动关
const solo = shallowRef(props.snapshot.solo === true);
function view(open: boolean) { return props.perform({ kind: 'palette-view', ...c(), open, keys: open ? selection.value : [], solo: open && solo.value }); }
function setSolo(on: boolean) { solo.value = on; void view(true); }
// 页签由 KeepAlive 缓存:切走是 deactivated 而不是卸载。关掉后 Lua 不再在快照里带调色数据
const close = () => { solo.value = false; void cancelBatch(); void props.perform({ kind: 'palette-view', ...c(), open: false, keys: [] }); };
onMounted(() => { void view(true); });
onActivated(() => { void view(true); });
onDeactivated(close);
onBeforeUnmount(close);
watch(() => props.snapshot.character, () => { selection.value = []; });
// 快照里的选择是 Lua 那边记住的；网页刷新后从它恢复
watch(() => pal.value?.selected, keys => { if (keys && !selection.value.length && keys.length) selection.value = [...keys]; }, { immediate: true });
function select(keys: string[]) { selection.value = keys; void view(true); }
const toggle = (key: string) => select(selection.value.includes(key) ? selection.value.filter(k => k !== key) : [...selection.value, key]);
const only = (key: string) => select([key]);
// 按部位(身体 / 头部 / 头发……)整组操作;保留其它部位的选择,新加的接在后面(第一个选中的材质决定显示哪个的值)
const slotKeys = (g: { rows: Re4PaletteMaterial[] }) => g.rows.map(m => m.key);
const slotCount = (g: { rows: Re4PaletteMaterial[] }) => slotKeys(g).filter(k => selection.value.includes(k)).length;
function slotAll(g: { rows: Re4PaletteMaterial[] }) { select([...selection.value, ...slotKeys(g).filter(k => !selection.value.includes(k))]); }
function slotInvert(g: { rows: Re4PaletteMaterial[] }) {
  const keys = slotKeys(g);
  select([...selection.value.filter(k => !keys.includes(k)), ...keys.filter(k => !selection.value.includes(k))]);
}
function slotClear(g: { rows: Re4PaletteMaterial[] }) { const keys = slotKeys(g); select(selection.value.filter(k => !keys.includes(k))); }

const materials = computed(() => pal.value?.materials ?? []);
const bySlot = computed(() => {
  const out: { slot: string; label: string; rows: Re4PaletteMaterial[] }[] = [];
  for (const m of materials.value) {
    let g = out.find(x => x.slot === m.slot);
    if (!g) { g = { slot: m.slot, label: props.snapshot.slots?.find(s => s.id === m.slot)?.label ?? m.slot, rows: [] }; out.push(g); }
    g.rows.push(m);
  }
  return out;
});
const chosen = computed(() => selection.value.map(k => materials.value.find(m => m.key === k)).filter((m): m is Re4PaletteMaterial => !!m));

// ---------------------------------------------------------------- 可编辑的项（所有选中材质都能用的）
interface Row { group: string; groupLabel: string; groupNote?: string; tier: 'basic' | 'more' | 'other'; entry: Re4PaletteEntry; options?: Re4PaletteOption[] }
function profilesOf(m: Re4PaletteMaterial) { return [m.main, ...m.addons].filter((x): x is string => !!x); }
// 跨映射比较用的签名:同一个参数、同样的拆法就算同一项(比如 lilToon 的「主色」和通用兜底里的 BaseColor)
const sig = (e: Re4PaletteEntry) => [e.param, e.kind, e.component ?? '', e.kind === 'color' ? e.channels ?? 'rgb' : ''].join('|');
const genericEntry = (param: string): Re4PaletteEntry => ({ param, kind: 'color', channels: 'rgb', label: { zh: param, en: param } });
const sigsOf = computed(() => {
  const out = new Map<string, Set<string>>();
  for (const m of materials.value) {
    const set = new Set<string>();
    for (const id of profilesOf(m)) for (const g of pal.value?.profiles[id]?.groups ?? []) for (const e of g.params) if (!m.missing.includes(e.param)) set.add(sig(e));
    for (const p of m.generic ?? []) set.add(sig(genericEntry(p)));
    out.set(m.key, set);
  }
  return out;
});
const usable = (m: Re4PaletteMaterial, e: Re4PaletteEntry) => sigsOf.value.get(m.key)?.has(sig(e)) ?? false;
interface Group { key: string; section: string; label: string; note?: string; tier: 'basic' | 'more' | 'other'; rows: Row[]; extraFrom: number }
const groups = computed(() => {
  const first = chosen.value[0];
  const out: Group[] = [];
  if (!first || !pal.value) return out;
  const add = (profileId: string | null, g: Re4PaletteGroup, enums: Record<string, Re4PaletteOption[]>) => {
    const basic: Row[] = [], extra: Row[] = [];
    for (const e of g.params) {
      if (!chosen.value.every(m => usable(m, e))) continue;
      const row: Row = { group: g.id, groupLabel: text(g.label, g.id), groupNote: text(g.note) || undefined, tier: e.tier ?? g.tier, entry: e,
        options: e.options ?? (e.enum ? enums[e.enum] : undefined) };
      // 基本组里的进阶项放在组的末尾(组内有一条「进阶」小标题);进阶组里不再细分
      (g.tier === 'basic' && row.tier === 'more' ? extra : basic).push(row);
    }
    if (basic.length + extra.length) out.push({ key: (profileId ?? 'generic') + ':' + g.id, section: g.section ?? 'other',
      label: text(g.label, g.id), note: text(g.note) || undefined, tier: g.tier, rows: [...basic, ...extra], extraFrom: extra.length ? basic.length : -1 });
  };
  for (const id of profilesOf(first)) {
    const p = pal.value.profiles[id];
    for (const g of p?.groups ?? []) add(id, g, p.enums ?? {});
  }
  if (!first.main && first.generic?.length) {
    add(null, { id: 'colors', tier: 'basic', section: 'color', label: { zh: '颜色', en: 'Colours' }, params: first.generic.map(genericEntry) }, {});
  }
  return out;
});
// 类别名:取第一个声明了它的映射里的名字;通用兜底的颜色归在「颜色层」
const sectionLabel = (id: string) => {
  for (const p of Object.values(pal.value?.profiles ?? {})) {
    const sec = p.sections.find(x => x.id === id);
    if (sec) return text(sec.label, id);
  }
  return id === 'color' ? props.t('paletteSectionColor') : props.t('paletteSectionOther');
};
// 版面:基本 / 进阶 / 其他 三块,每块里按类别(映射里的顺序)排组。其他 = 含义按参数名推断、可能不准的项
const areas = computed(() => (['basic', 'more', 'other'] as const).map(tier => {
  const sections: { id: string; label: string; groups: Group[] }[] = [];
  for (const g of groups.value.filter(x => x.tier === tier)) {
    let sec = sections.find(x => x.id === g.section);
    if (!sec) { sec = { id: g.section, label: sectionLabel(g.section), groups: [] }; sections.push(sec); }
    sec.groups.push(g);
  }
  return { tier, sections };
}).filter(a => a.sections.length));
// 组的展开状态(默认全部收起);换选材质时保留,同一个组还是展开的
const openGroups = reactive(new Set<string>());
const toggleGroup = (key: string) => { if (openGroups.has(key)) openGroups.delete(key); else openGroups.add(key); };
const groupModified = (g: Group) => g.rows.some(r => modified(r.entry));

// ---------------------------------------------------------------- 默认贴图导致的失效
// 贴图槽绑了游戏内置的 null 贴图时,和它相乘 / 被它遮罩的参数改了看不出变化(Lua 按离线材质库判断)。
// 一项的全部分量在每个选中的材质上都失效才灰掉;一组全灰时在组标题右边写明
const entryComps = (e: Re4PaletteEntry) => e.kind === 'color' ? (e.channels === 'rgba' ? 'xyzw' : 'xyz') : e.kind === 'vec' ? 'xyzw' : (e.component ?? 'x');
function deadOn(m: Re4PaletteMaterial, e: Re4PaletteEntry) {
  const d = m.ineffective?.[e.param];
  return !!d && [...entryComps(e)].every(ch => d.comps.includes(ch));
}
const dead = (e: Re4PaletteEntry) => chosen.value.length > 0 && chosen.value.every(m => deadOn(m, e));
const shortTex = (p: string) => p.split('/').pop() ?? p;
function deadWhy(e: Re4PaletteEntry) {
  const d = chosen.value[0]?.ineffective?.[e.param];
  return d ? props.t('paletteDeadWhy', d.why.map(w => `${w.texture} = ${shortTex(w.null)}`).join('；')) : '';
}
const deadCount = (g: Group) => g.rows.filter(r => dead(r.entry)).length;
const groupDead = (g: Group) => g.rows.length > 0 && deadCount(g) === g.rows.length;

// ---------------------------------------------------------------- 取值
const valueOf = (key: string, param: string): Re4PaletteValue | undefined => pal.value?.values[key]?.[param];
function num(key: string, e: Re4PaletteEntry): number | undefined {
  const v = valueOf(key, e.param);
  if (typeof v === 'number') return v;
  if (Array.isArray(v) && e.component) return v[CI[e.component]];
  return undefined;
}
function rgb(key: string, param: string): [number, number, number] | undefined {
  const v = valueOf(key, param);
  return Array.isArray(v) ? [v[0], v[1], v[2]] : undefined;
}
const near = (a?: number, b?: number) => a !== undefined && b !== undefined && Math.abs(a - b) < 1e-4;
const firstKey = computed(() => chosen.value[0]?.key ?? '');
function mixed(e: Re4PaletteEntry) {
  const keys = chosen.value.map(m => m.key);
  if (e.kind === 'color' || e.kind === 'vec') {
    const a = valueOf(keys[0], e.param);
    return keys.some(k => { const b = valueOf(k, e.param); return !Array.isArray(a) || !Array.isArray(b) || a.some((x, i) => !near(x, b[i])); });
  }
  const a = num(keys[0], e);
  return keys.some(k => !near(num(k, e), a));
}
function overrideOf(key: string, param: string): Re4PaletteOverride | undefined {
  const o = pal.value?.overrides[key];
  return o ? o[param] : undefined;
}
// 这一项在选中的材质上改过没有（颜色看 xyz，分量看自己那一个）
function modified(e: Re4PaletteEntry) {
  return chosen.value.some(m => {
    const o = overrideOf(m.key, e.param);
    if (o === undefined) return false;
    if (typeof o === 'number') return true;
    const comps = e.kind === 'color' ? (e.channels === 'rgba' ? COMP : ['x', 'y', 'z'] as Re4Comp[]) : e.kind === 'vec' ? COMP : e.component ? [e.component] : [];
    return comps.some(k => o[k] !== undefined);
  });
}
const anyOverride = computed(() => chosen.value.some(m => m.overridden > 0));
// ---------------------------------------------------------------- 导出 mdf2 材质预设(只选了一个材质时)
// 导出:先填预设名(RE Mesh Editor 用它当文件名,只允许英文;同 Lua 的 Mdf2.valid_name)
const exporting = shallowRef(false);
const presetName = shallowRef('');
const nameOk = computed(() => /^[A-Za-z0-9_-][A-Za-z0-9 _-]{0,63}$/.test(presetName.value) && !/\s$/.test(presetName.value));
function startExport() { exporting.value = true; presetName.value = presetName.value || (chosen.value[0]?.material ?? '').replace(/[^A-Za-z0-9 _-]/g, '_'); }
async function doExport() {
  const m = chosen.value[0];
  if (!m || !nameOk.value) return;
  if (await props.perform({ kind: 'palette-export', ...c(), slot: m.slot, material: m.material, name: presetName.value })) exporting.value = false;
}
watch(selection, () => { exporting.value = false; });
// 替换 mdf:把这个材质所在 mdf2 涉及的调色值写进原文件并当场换上,随后清空这些调色配置。危险操作,单独弹窗确认
const replaceState = computed(() => chosen.value[0]?.replace);
const replaceTip = computed(() => replaceState.value === 'packed' ? props.t('paletteReplacePacked')
  : replaceState.value === 'plugin' ? props.t('paletteReplacePlugin') : '');
const confirmReplace = shallowRef(false);
async function doReplace() {
  confirmReplace.value = false;
  const m = chosen.value[0];
  if (m) await props.perform({ kind: 'palette-replace', ...c(), slot: m.slot });
}

// ---------------------------------------------------------------- 写入
const targets = () => chosen.value.map(m => ({ slot: m.slot, material: m.material }));
// 写入队列:拖动取色器 / 滑条时实时写,但同一时间只有一个请求在途;在途期间只记下最新的一次,
// 上一个完成后立刻补发,所以松手时最后的值一定会送到。页面正忙(别的操作在途)时稍后重试。
let inflight = false;
// live 的写入只改内存、不存盘;最后一次(松手 / 确定)不带 live,由 Lua 存盘
let pending: { writes: Re4PaletteWrite[]; live: boolean; scheme: string } | null = null;
function pump() {
  if (inflight || !pending) return;
  const job = pending;
  pending = null;
  inflight = true;
  const action = { kind: 'palette-set' as const, ...c(), writes: job.writes, live: job.live || undefined, scheme: job.scheme };
  // 拖动中走轻量写入(只等确认、不拿快照);选着初始时第一次写会新建方案,要拿快照才知道新方案,仍走 perform
  const send = job.live && job.scheme && props.liveWrite ? props.liveWrite(action) : props.perform(action);
  void send.then(ok => {
    if (!ok && !pending) { pending = job; window.setTimeout(pump, 60); }
  }).finally(() => { inflight = false; pump(); });
}
function write(list: Omit<Re4PaletteWrite, 'slot' | 'material'>[], live = false) {
  const writes: Re4PaletteWrite[] = [];
  for (const t of targets()) for (const w of list) writes.push({ ...t, ...w });
  if (!writes.length) return;
  pending = { writes, live, scheme: scheme.value };
  pump();
}
// 拖动中的本地显示值(滑条位置 / 取色器颜色)。快照比拖动慢,直接用快照的值滑块会被拽回去;
// 松手后清掉,回到快照里的实际值
const local = reactive(new Map<string, number | string>());
const localKey = (e: Re4PaletteEntry) => e.param + '|' + (e.component ?? '');
watch(selection, () => { local.clear(); void cancelBatch(); });
function reset(e: Re4PaletteEntry) {
  const comps: (Re4Comp | undefined)[] = e.kind === 'color' ? (e.channels === 'rgba' ? COMP : ['x', 'y', 'z']) : e.kind === 'vec' ? [undefined] : [e.component];
  void (async () => {
    for (const component of comps) await props.perform({ kind: 'palette-reset', ...c(), targets: targets(), param: e.param, component, scheme: scheme.value });
  })();
}
const resetAll = () => props.perform({ kind: 'palette-reset', ...c(), targets: targets(), scheme: scheme.value });
const setNumber = (e: Re4PaletteEntry, v: number | undefined | null) => {
  if (typeof v !== 'number' || !Number.isFinite(v)) return;
  return write([e.component ? { param: e.param, component: e.component, value: v } : { param: e.param, value: v }]);
};
const setVec = (e: Re4PaletteEntry, i: number, v: number | undefined | null) => {
  if (typeof v === 'number' && Number.isFinite(v)) return write([{ param: e.param, component: COMP[i], value: v }]);
};

// 颜色：材质里是线性的 0~1(可以超过 1)，取色器只显示 0~1；按显示值改
const to255 = (v: number) => Math.round(Math.max(0, Math.min(1, v)) * 255);
const hex = (c3?: [number, number, number]) => c3 ? '#' + c3.map(v => to255(v).toString(16).padStart(2, '0')).join('') : '';
// live = 取色面板里拖动中(active-change):实时写并记住本地颜色;确定(change)时写最终值并清掉本地
function setColor(e: Re4PaletteEntry, value: string | null, live = false) {
  // 换材质时新值还没到,取色器的值会先变成空、再变成新颜色,Element Plus 会把这一下也当成 active-change 发出来。
  // 和当前显示的一样就不是用户在拖,不写;否则会把新材质取整后的颜色写成覆盖
  if (live && (value ?? '').toLowerCase() === colorShown(e).toLowerCase()) return;
  const m = /^#?([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})/i.exec(value ?? '') ?? /rgba?\((\d+),\s*(\d+),\s*(\d+)/i.exec(value ?? '');
  if (!m) return;
  const hexInput = m[0].startsWith('#') || /^[0-9a-f]{6}/i.test(m[0]);
  const [r, g, b] = [m[1], m[2], m[3]].map(x => (hexInput ? parseInt(x, 16) : Number(x)) / 255);
  if (live) local.set(localKey(e), '#' + [r, g, b].map(v => to255(v).toString(16).padStart(2, '0')).join(''));
  else local.delete(localKey(e));
  write([{ param: e.param, component: 'x', value: r }, { param: e.param, component: 'y', value: g }, { param: e.param, component: 'z', value: b }], live);
}
// 悬停时显示实际数值(线性 0~1,可以超过 1;色块只能显示到 1)
const colorTitle = (e: Re4PaletteEntry) => rgb(firstKey.value, e.param)?.map(v => String(Number(v.toFixed(3)))).join(' / ') ?? '';
const colorShown = (e: Re4PaletteEntry) => (local.get(localKey(e)) as string | undefined) ?? hex(rgb(firstKey.value, e.param));
// 滑条:拖动中(input)实时写,松手(change)写最终值
function slide(e: Re4PaletteEntry, v: number | number[], live: boolean) {
  const n = Array.isArray(v) ? v[0] : v;
  if (live) local.set(localKey(e), n); else local.delete(localKey(e));
  if (Number.isFinite(n)) write([e.component ? { param: e.param, component: e.component, value: n } : { param: e.param, value: n }], live);
}
const sliderShown = (e: Re4PaletteEntry) => (local.get(localKey(e)) as number | undefined) ?? clampSlider(e, num(firstKey.value, e));

// ---------------------------------------------------------------- 整体调色
const batch = reactive({ hue: 0, sat: 100, val: 100 });
function hsv([r, g, b]: [number, number, number]) {
  const max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min;
  let h = 0;
  if (d > 0) h = max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
  return [h * 60 < 0 ? h * 60 + 360 : h * 60, max > 0 ? d / max : 0, max];
}
function fromHsv(h: number, s: number, v: number): [number, number, number] {
  const f = (n: number) => { const k = (n + h / 60) % 6; return v - v * s * Math.max(0, Math.min(k, 4 - k, 1)); };
  return [f(5), f(3), f(1)];
}
// 整体调色作用于「基本」里的颜色项(颜色层、阴影、边缘光、自发光……),进阶里的不动
const colorRows = computed(() => groups.value.filter(g => g.tier === 'basic').flatMap(g => g.rows).filter(r => r.tier === 'basic' && r.entry.kind === 'color'));
// 实时预览:滑条一离开初始位置就记下当时的颜色(base),之后每次都从 base 算,写入走 live(只改内存、不存盘)。
// 「应用」写最终值并存盘;「取消」/ 换材质 / 切走页签 把颜色还原成 base。
// 原本没改过的颜色,还原时取消覆盖而不是写回原值,免得平白多出「已改」。
interface BatchBase { slot: string; material: string; key: string; param: string; rgb: [number, number, number]; had: boolean }
let base: BatchBase[] | null = null;
let batchScheme = '';   // 开始预览时选中的那一份;换方案会先取消预览
const touched = new Set<string>();
const batchNeutral = () => batch.hue === 0 && batch.sat === 100 && batch.val === 100;
const previewing = shallowRef(false);
const baseId = (b: BatchBase) => b.key + '|' + b.param;
function hadOverride(key: string, param: string) {
  const o = overrideOf(key, param);
  return o !== undefined && (typeof o === 'number' || (['x', 'y', 'z'] as Re4Comp[]).some(k => o[k] !== undefined));
}
function captureBase() {
  base = [];
  for (const m of chosen.value) for (const r of colorRows.value) {
    const cur = rgb(m.key, r.entry.param);
    if (cur) base.push({ slot: m.slot, material: m.material, key: m.key, param: r.entry.param, rgb: [...cur], had: hadOverride(m.key, r.entry.param) });
  }
  touched.clear();
  batchScheme = scheme.value;
  previewing.value = true;
}
const batchOut = (b: BatchBase) => {
  const [h, s, v] = hsv(b.rgb);
  return fromHsv((h + batch.hue + 360) % 360, Math.max(0, Math.min(1, s * batch.sat / 100)), v * batch.val / 100);
};
const rgbWrites = (b: BatchBase, c3: [number, number, number]): Re4PaletteWrite[] =>
  COMP.slice(0, 3).map((k, i) => ({ slot: b.slot, material: b.material, param: b.param, component: k, value: c3[i] }));
function enqueue(writes: Re4PaletteWrite[], live: boolean) {
  if (!writes.length) return;
  pending = { writes, live, scheme: batchScheme };
  pump();
}
const idle = () => new Promise<void>(res => { const tick = () => (inflight || pending ? window.setTimeout(tick, 30) : res()); tick(); });
// 页面正忙时 perform 会返回 false,稍后重试几次
async function must(action: Parameters<typeof props.perform>[0]) {
  for (let i = 0; i < 20; i++) { if (await props.perform(action)) return true; await new Promise(r => window.setTimeout(r, 60)); }
  return false;
}
watch(() => [batch.hue, batch.sat, batch.val], () => {
  if (!base) { if (batchNeutral() || !chosen.value.length) return; captureBase(); }
  const writes: Re4PaletteWrite[] = [];
  for (const b of base!) {
    const out = batchOut(b);
    // 没变化的颜色(比如白色转色相)不写;之前写过的要写回 base
    if (out.every((x, i) => near(x, b.rgb[i]))) { if (touched.has(baseId(b))) writes.push(...rgbWrites(b, b.rgb)); continue; }
    touched.add(baseId(b));
    writes.push(...rgbWrites(b, out));
  }
  enqueue(writes, true);
});
function endBatch() {
  base = null; touched.clear(); previewing.value = false;
  Object.assign(batch, { hue: 0, sat: 100, val: 100 });
}
// 把 list 里的颜色还原:原本改过的写回 base,原本没改过的取消覆盖
async function restore(list: BatchBase[]) {
  const writes = list.filter(b => b.had).flatMap(b => rgbWrites(b, b.rgb));
  if (writes.length) await must({ kind: 'palette-set', ...c(), writes, scheme: batchScheme });
  for (const b of list.filter(b => !b.had))
    await must({ kind: 'palette-reset', ...c(), targets: [{ slot: b.slot, material: b.material }], param: b.param, scheme: batchScheme });
}
async function applyBatch() {
  if (!base) return;
  const writes: Re4PaletteWrite[] = [], back: BatchBase[] = [];
  for (const b of base) {
    if (!touched.has(baseId(b))) continue;
    const out = batchOut(b);
    if (out.every((x, i) => near(x, b.rgb[i]))) back.push(b); else writes.push(...rgbWrites(b, out));
  }
  endBatch();
  // 不带 live 的最后一次:Lua 存盘。排在拖动中的写入之后
  enqueue(writes, false);
  await idle();
  if (back.length) await restore(back);
}
async function cancelBatch() {
  if (!base) return;
  const list = base.filter(b => touched.has(baseId(b)));
  endBatch();
  pending = null;
  await idle();
  if (list.length) await restore(list);
}

// ---------------------------------------------------------------- 调色方案
const schemes = computed(() => props.snapshot.palettes?.list ?? []);
const activeSchemes = computed(() => props.snapshot.palettes?.active ?? []);
const current = computed(() => schemes.value.find(x => x.name === scheme.value));
// 选中就生效(存进配置),调色页也编辑选中的那一份;"" = 初始
async function pickScheme(name: string) {
  if (name === scheme.value) return;
  await cancelBatch();
  local.clear();
  if (await props.perform({ kind: 'palette-scheme-select', ...c(), scheme: name })) scheme.value = name;
}
// 新建 / 改名共用一个对话框。from:'none' 空白(= 初始)/ 'current' 复制选中的方案
const dialog = reactive({ open: false, mode: 'new' as 'new' | 'rename', name: '', from: 'none' as 'none' | 'current' });
const nameTaken = computed(() => schemes.value.some(x => x.name === dialog.name.trim()) && !(dialog.mode === 'rename' && dialog.name.trim() === scheme.value));
const dialogOk = computed(() => !!dialog.name.trim() && dialog.name.trim().length <= 64 && !nameTaken.value);
function openNew() { Object.assign(dialog, { open: true, mode: 'new', name: '', from: scheme.value ? 'current' : 'none' }); }
function openRename() { Object.assign(dialog, { open: true, mode: 'rename', name: scheme.value, from: 'none' }); }
async function submitDialog() {
  if (!dialogOk.value) return;
  const name = dialog.name.trim();
  await cancelBatch();
  const ok = dialog.mode === 'rename'
    ? await props.perform({ kind: 'palette-scheme-rename', ...c(), scheme: scheme.value, name })
    : await props.perform({ kind: 'palette-scheme-new', ...c(), name,
      from: dialog.from === 'current' && scheme.value ? scheme.value : undefined });
  if (ok) dialog.open = false;
}
const confirmDelete = shallowRef(false);
async function doDelete() {
  confirmDelete.value = false;
  await cancelBatch();
  await props.perform({ kind: 'palette-scheme-delete', ...c(), scheme: scheme.value });
}

const labels = (e: Re4PaletteEntry) => (en.value ? e.labels?.en : e.labels?.zh) ?? COMP.map(k => k.toUpperCase());
const sliderMin = (e: Re4PaletteEntry) => e.min ?? 0;
const sliderMax = (e: Re4PaletteEntry) => e.max ?? 1;
const step = (e: Re4PaletteEntry) => e.step ?? (sliderMax(e) - sliderMin(e) > 20 ? 0.1 : 0.01);
// 数值框不受滑条范围限制；只有映射写了硬范围时才限制
const clampSlider = (e: Re4PaletteEntry, v?: number) => Math.max(sliderMin(e), Math.min(sliderMax(e), v ?? sliderMin(e)));
</script>

<template>
  <div class="re4-main re4-pal">
    <div v-if="pal?.error" class="re4-banner" role="alert">{{ pal.error }}</div>
    <div v-if="pal?.errors?.length" class="re4-banner" role="status">{{ t('paletteBadFiles', pal.errors.join('、')) }}</div>
    <div v-if="!pal" class="re4-muted re4-small">{{ t('loading') }}</div>
    <section v-if="pal" class="re4-panel re4-pal-schemes" :aria-label="t('paletteScheme')">
      <!-- 整个调色的轮换快捷键单独一行,在方案选择上面 -->
      <div class="re4-panel-body re4-row re4-pal-cycle">
        <Re4HotkeyPick :snapshot="snapshot" :busy="busy" :perform="perform" :t="t" :target="{ kind: 'palette' }" :label="t('hotkeyCycleRef')" />
        <span class="re4-spacer"></span>
        <ElTooltip :content="t('paletteSoloHint')" placement="bottom">
          <label class="re4-pal-solo"><ElSwitch :model-value="solo" size="small" :disabled="busy" @change="v => setSolo(v === true)" /><span>{{ t('paletteSolo') }}</span></label>
        </ElTooltip>
      </div>
      <div class="re4-panel-body re4-row">
        <ElSelect :model-value="scheme" :empty-values="[null, undefined]" size="small" style="width:16em" :aria-label="t('paletteScheme')" @change="v => pickScheme(String(v))">
          <ElOption value="" :label="t('paletteAlways')" />
          <ElOption v-for="s in schemes" :key="s.name" :value="s.name" :label="s.name">
            <span>{{ s.name }}</span>
            <span v-if="activeSchemes.includes(s.name)" class="re4-tag on re4-pal-opttag">{{ t('paletteSchemeOn') }}</span>
          </ElOption>
        </ElSelect>
        <ElButton size="small" :disabled="busy" @click="openNew">{{ t('paletteSchemeNew') }}</ElButton>
        <template v-if="scheme">
          <ElButton size="small" :disabled="busy" @click="openRename">{{ t('rename') }}</ElButton>
          <ElButton size="small" type="danger" plain :disabled="busy" @click="confirmDelete = true">{{ t('delete') }}</ElButton>
        </template>
        <span class="re4-spacer"></span>
        <!-- 快捷键:选中的这一份(初始 / 方案)的单项键;调色绑了轮换键时是「参与轮换」开关 -->
        <Re4HotkeyPick :snapshot="snapshot" :busy="busy" :perform="perform" :t="t" :target="{ kind: 'palette', scheme }" />
      </div>
      <ElDialog v-model="dialog.open" :title="dialog.mode === 'rename' ? t('paletteSchemeRename') : t('paletteSchemeNew')" width="420px" append-to-body>
        <div class="re4-pal-dialog">
          <ElInput v-model="dialog.name" size="small" :placeholder="t('paletteSchemeName')" maxlength="64" @keyup.enter="submitDialog" />
          <span v-if="nameTaken" class="re4-small re4-bad-text">{{ t('paletteSchemeTaken') }}</span>
          <template v-if="dialog.mode === 'new'">
            <label class="re4-small"><input v-model="dialog.from" type="radio" value="none"> {{ t('paletteFromNone') }}</label>
            <label v-if="scheme" class="re4-small"><input v-model="dialog.from" type="radio" value="current"> {{ t('paletteFromCurrent', scheme) }}</label>
          </template>
        </div>
        <template #footer>
          <ElButton size="small" @click="dialog.open = false">{{ t('cancel') }}</ElButton>
          <ElButton size="small" type="primary" :disabled="busy || !dialogOk" @click="submitDialog">{{ t('confirm') }}</ElButton>
        </template>
      </ElDialog>
      <ElDialog v-model="confirmDelete" :title="t('paletteSchemeDelete')" width="420px" append-to-body>
        <p class="re4-small">{{ t('paletteSchemeDeleteBody', scheme, current?.used ?? 0) }}</p>
        <template #footer>
          <ElButton size="small" @click="confirmDelete = false">{{ t('cancel') }}</ElButton>
          <ElButton size="small" type="danger" :disabled="busy" @click="doDelete">{{ t('delete') }}</ElButton>
        </template>
      </ElDialog>
    </section>
    <div v-if="pal" class="re4-pal-layout">
      <section class="re4-panel re4-pal-list" :aria-label="t('paletteMaterials')">
        <div class="re4-panel-head">
          <span class="re4-panel-title">{{ t('paletteMaterials') }}</span>
          <span class="re4-spacer"></span>
          <button class="re4-link" :disabled="!selection.length" @click="select([])">{{ t('paletteClear') }}</button>
        </div>
        <div class="re4-panel-body">
          <div v-for="g in bySlot" :key="g.slot" class="re4-pal-slot">
            <div class="re4-pal-slothead">
              <span class="re4-muted re4-small">{{ g.label }}</span>
              <span class="re4-spacer"></span>
              <button class="re4-link re4-small" :disabled="slotCount(g) === g.rows.length" @click="slotAll(g)">{{ t('paletteSlotAll') }}</button>
              <button class="re4-link re4-small" @click="slotInvert(g)">{{ t('paletteSlotInvert') }}</button>
              <button class="re4-link re4-small" :disabled="!slotCount(g)" @click="slotClear(g)">{{ t('paletteSlotClear') }}</button>
            </div>
            <div v-for="m in g.rows" :key="m.key" class="re4-pal-mat" :class="{ on: selection.includes(m.key) }">
              <input type="checkbox" :checked="selection.includes(m.key)" :aria-label="m.material" @change="toggle(m.key)">
              <button class="re4-pal-name" :title="t('paletteOnly')" @click="only(m.key)">
                <span class="re4-mono">{{ m.material }}</span><span v-if="m.note" class="re4-muted re4-small">{{ m.note }}</span>
              </button>
              <span v-if="m.overridden" class="re4-tag partial">{{ t('paletteChanged', m.overridden) }}</span>
            </div>
          </div>
        </div>
      </section>

      <section class="re4-panel re4-pal-edit">
        <div class="re4-panel-head">
          <span class="re4-panel-title">{{ chosen.length ? t('paletteSelected', chosen.length) : t('paletteNothing') }}</span>
          <span class="re4-spacer"></span>
          <template v-if="chosen.length === 1">
            <ElButton size="small" :disabled="busy" @click="startExport">{{ t('paletteExport') }}</ElButton>
            <!-- 灰掉时只在悬停时说明原因(禁用的按钮收不到悬停,包一层 span) -->
            <ElTooltip v-if="scheme" :content="replaceTip" :disabled="!replaceTip" placement="bottom">
              <span><ElButton size="small" type="danger" plain :disabled="busy || replaceState !== 'ok' || pal?.replacing"
                @click="confirmReplace = true">{{ t('paletteReplace') }}</ElButton></span>
            </ElTooltip>
          </template>
          <ElButton size="small" :disabled="busy" @click="perform({ kind: 'palette-reload', ...c() })">{{ t('paletteReload') }}</ElButton>
          <ElButton v-if="anyOverride" size="small" type="danger" plain :disabled="busy" @click="resetAll">{{ t('paletteResetAll') }}</ElButton>
        </div>
        <div v-if="exporting && chosen.length === 1" class="re4-panel-body re4-row">
          <ElInput v-model="presetName" size="small" style="width:16em" :placeholder="t('palettePresetName')" @keyup.enter="doExport" />
          <ElButton size="small" type="primary" :disabled="busy || !nameOk" @click="doExport">{{ t('paletteExportConfirm') }}</ElButton>
          <ElButton size="small" @click="exporting = false">{{ t('cancel') }}</ElButton>
          <span class="re4-small" :class="nameOk || !presetName ? 're4-muted' : 're4-bad-text'">{{ t('palettePresetNameHint') }}</span>
        </div>
        <ElDialog v-model="confirmReplace" :title="t('paletteReplace')" width="420px" append-to-body>
          <span>{{ t('paletteReplaceConfirm') }}</span>
          <template #footer>
            <ElButton size="small" @click="confirmReplace = false">{{ t('cancel') }}</ElButton>
            <ElButton size="small" type="danger" @click="doReplace">{{ t('confirm') }}</ElButton>
          </template>
        </ElDialog>
        <div v-if="!chosen.length" class="re4-panel-body re4-muted re4-small">{{ t('paletteHint') }}</div>
        <template v-else>
          <div v-if="chosen.length > 1" class="re4-panel-body re4-muted re4-small">{{ t('paletteCommon') }}</div>
          <div v-if="colorRows.length" class="re4-panel-body re4-pal-batch">
            <span class="re4-pal-glabel">{{ t('paletteBatch') }}</span>
            <label>{{ t('paletteHue') }}<ElSlider v-model="batch.hue" :min="-180" :max="180" :step="1" size="small" /></label>
            <label>{{ t('paletteSat') }}<ElSlider v-model="batch.sat" :min="0" :max="200" :step="1" size="small" /></label>
            <label>{{ t('paletteVal') }}<ElSlider v-model="batch.val" :min="0" :max="200" :step="1" size="small" /></label>
            <span class="re4-pal-batchbtns">
              <ElButton size="small" type="primary" :disabled="!previewing" @click="applyBatch">{{ t('paletteApply') }}</ElButton>
              <ElButton size="small" :disabled="!previewing" @click="cancelBatch">{{ t('paletteBatchCancel') }}</ElButton>
            </span>
            <span v-if="previewing" class="re4-muted re4-small">{{ t('paletteBatchLive') }}</span>
          </div>
          <div v-for="area in areas" :key="area.tier" class="re4-pal-area">
            <div class="re4-pal-areahead">{{ area.tier === 'basic' ? t('paletteBasic') : area.tier === 'more' ? t('paletteAdvanced') : t('paletteOther') }}
              <span v-if="area.tier === 'other'" class="re4-pal-areahint">{{ t('paletteOtherHint') }}</span></div>
            <div v-for="sec in area.sections" :key="sec.id" class="re4-pal-section">
              <div class="re4-pal-sechead">{{ sec.label }}</div>
              <div v-for="g in sec.groups" :key="g.key" class="re4-pal-group" :class="{ open: openGroups.has(g.key), dead: groupDead(g) }">
                <button class="re4-pal-ghead" :aria-expanded="openGroups.has(g.key)" @click="toggleGroup(g.key)">
                  <span class="re4-caret">{{ openGroups.has(g.key) ? '▾' : '▸' }}</span>
                  <span v-if="groupModified(g)" class="re4-pal-dot" :title="t('paletteModified')"></span>
                  <span class="re4-pal-gname">{{ g.label }}</span>
                  <span class="re4-muted re4-small">{{ g.rows.length }}</span>
                  <span v-if="groupDead(g)" class="re4-pal-deadnote">{{ t('paletteDeadGroup') }}</span>
                  <span v-else-if="deadCount(g)" class="re4-pal-deadnote">{{ t('paletteDeadSome', deadCount(g)) }}</span>
                </button>
                <ElTooltip v-if="g.note" :content="g.note" placement="top"><span class="re4-pal-i re4-pal-gi" tabindex="0">i</span></ElTooltip>
                <div v-if="openGroups.has(g.key)" class="re4-pal-gbody">
                <template v-for="(r, ri) in g.rows" :key="r.entry.param + (r.entry.component ?? '') + r.entry.kind">
                <div v-if="ri === g.extraFrom" class="re4-pal-sub">{{ t('paletteAdvanced') }}</div>
                <div class="re4-pal-row" :class="{ dead: dead(r.entry) }">
                  <span class="re4-pal-label">
                    <span v-if="modified(r.entry)" class="re4-pal-dot" :title="t('paletteModified')"></span>{{ text(r.entry.label, r.entry.param) }}
                    <ElTooltip v-if="r.entry.note" :content="text(r.entry.note)" placement="top"><span class="re4-pal-i" tabindex="0">i</span></ElTooltip>
                    <ElTooltip v-if="dead(r.entry)" :content="deadWhy(r.entry)" placement="top"><span class="re4-pal-deadtag" tabindex="0">{{ t('paletteDeadTag') }}</span></ElTooltip>
                  </span>
                  <span class="re4-pal-ctl">
                    <span v-if="r.entry.kind === 'color'" class="re4-pal-color" :title="colorTitle(r.entry)">
                      <ElColorPicker :model-value="colorShown(r.entry)" @active-change="v => setColor(r.entry, v, true)" @change="v => setColor(r.entry, v)" />
                    </span>
                    <template v-else-if="r.entry.kind === 'float'">
                      <ElSlider class="re4-pal-slider" :model-value="sliderShown(r.entry)" :min="sliderMin(r.entry)" :max="sliderMax(r.entry)"
                        :step="step(r.entry)" size="small" @input="v => slide(r.entry, v, true)" @change="v => slide(r.entry, v, false)" />
                      <Re4Num :value="num(firstKey, r.entry)" :min="r.entry.hard_min" :max="r.entry.hard_max" :aria-label="text(r.entry.label, r.entry.param)"
                        @change="v => setNumber(r.entry, v)" />
                    </template>
                    <ElSelect v-else-if="r.entry.kind === 'enum'" :model-value="num(firstKey, r.entry)" size="small" @change="v => setNumber(r.entry, Number(v))">
                      <ElOption v-for="o in r.options ?? []" :key="o.value" :value="o.value" :label="text(o.label, String(o.value))" />
                    </ElSelect>
                    <ElSwitch v-else-if="r.entry.kind === 'bool'" :model-value="(num(firstKey, r.entry) ?? 0) >= 0.5" size="small"
                      @change="v => setNumber(r.entry, v === true ? 1 : 0)" />
                    <span v-else class="re4-pal-vec">
                      <label v-for="(name, i) in labels(r.entry)" :key="i">{{ name }}
                        <Re4Num :value="(valueOf(firstKey, r.entry.param) as number[] | undefined)?.[i]" :aria-label="name" @change="v => setVec(r.entry, i, v)" />
                      </label>
                    </span>
                    <span v-if="chosen.length > 1 && mixed(r.entry)" class="re4-small re4-muted">{{ t('paletteMixed') }}</span>
                    <button v-if="modified(r.entry)" class="re4-link" :disabled="busy" @click="reset(r.entry)">{{ t('paletteRestore') }}</button>
                  </span>
                </div>
                </template>
                </div>
              </div>
            </div>
          </div>
          <div v-if="!groups.length" class="re4-panel-body re4-muted re4-small">{{ t('paletteNoEntries') }}</div>
        </template>
      </section>
    </div>
  </div>
</template>

<style>
.re4-pal-layout { display: grid; grid-template-columns: minmax(0, 18em) minmax(0, 1fr); gap: 10px; align-items: start; }
@media (max-width: 760px) { .re4-pal-layout { grid-template-columns: minmax(0, 1fr); } }
.re4-pal-list .re4-panel-body { gap: 8px; }
.re4-pal-slot { display: grid; gap: 1px; }
.re4-pal-slothead { display: flex; align-items: center; gap: 8px; }
.re4-pal-mat { display: flex; align-items: center; gap: 6px; min-width: 0; padding: 1px 4px; border-radius: 4px; }
.re4-pal-mat.on { background: var(--re4-soft); }
.re4-pal-mat input { margin: 0; flex: none; }
.re4-pal-name { border: 0; background: none; color: inherit; padding: 0; cursor: pointer; display: inline-flex; gap: 6px; align-items: baseline; min-width: 0; flex: 1; text-align: left; overflow-wrap: anywhere; }
.re4-pal-mat .re4-tag { border: 0; cursor: pointer; flex: none; }
.re4-pal-area { display: grid; gap: 8px; padding: 8px 12px 10px; border-top: 1px solid var(--avm-line); }
.re4-pal-areahead { font-size: 11px; letter-spacing: .1em; color: var(--avm-muted); }
.re4-pal-areahint { letter-spacing: 0; margin-left: 8px; }
.re4-pal-section { display: grid; gap: 4px; }
.re4-pal-sechead { font-weight: 600; font-size: 13px; }
.re4-pal-group { display: grid; grid-template-columns: minmax(0, 1fr) auto; align-items: center; border: 1px solid var(--avm-line); border-radius: 6px; }
.re4-pal-group.open { background: var(--el-bg-color, transparent); }
.re4-pal-ghead { display: flex; align-items: center; gap: 6px; border: 0; background: none; color: inherit; padding: 4px 8px; cursor: pointer; text-align: left; min-width: 0; }
.re4-pal-ghead .re4-caret { width: 1em; }
.re4-pal-gname { font-weight: 500; }
.re4-pal-gi { margin-right: 8px; }
.re4-pal-gbody { grid-column: 1 / -1; display: grid; gap: 2px; padding: 4px 10px 8px 26px; border-top: 1px dashed var(--avm-line); }
@media (max-width: 560px) { .re4-pal-gbody { padding-left: 10px; } }
.re4-pal-sub { font-size: 11px; letter-spacing: .08em; color: var(--avm-muted); margin-top: 4px; padding-top: 4px; border-top: 1px dashed var(--avm-line); }
.re4-pal-glabel { font-weight: 600; display: flex; align-items: center; gap: 6px; margin-bottom: 2px; }
.re4-pal-row { display: grid; grid-template-columns: minmax(7em, 12em) minmax(0, 1fr); gap: 4px 12px; align-items: center; min-height: 30px; }
@media (max-width: 560px) { .re4-pal-row { grid-template-columns: minmax(0, 1fr); } }
.re4-pal-label { display: inline-flex; align-items: center; gap: 5px; min-width: 0; overflow-wrap: anywhere; }
.re4-pal-ctl { display: flex; flex-wrap: wrap; align-items: center; gap: 4px 10px; min-width: 0; }
.re4-pal-color { display: inline-flex; width: min(14em, 100%); }
.re4-pal-color .el-color-picker { width: 100%; height: 24px; }
.re4-pal-color .el-color-picker__trigger { width: 100%; height: 24px; padding: 2px; border-radius: 5px; }
.re4-pal-color .el-color-picker__color { border-radius: 3px; border: 0; }
.re4-pal-color .el-color-picker__color-inner { border-radius: 3px; }
.re4-pal-color .el-color-picker__icon { display: none; }
.re4-pal-ctl .el-select { width: 9em; }
.re4-pal-slider { flex: 1 1 10em; min-width: 8em; max-width: 20em; }
.re4-pal-vec { display: flex; flex-wrap: wrap; gap: 4px 10px; }
.re4-pal-vec label { display: inline-flex; align-items: center; gap: 4px; font-size: 12px; color: var(--avm-muted); }
.re4-pal-i { display: inline-grid; place-items: center; width: 15px; height: 15px; border-radius: 50%; border: 1px solid var(--avm-muted); color: var(--avm-muted);
  font: italic 600 10px/1 Georgia, serif; cursor: help; flex: none; }
.re4-pal-i:hover, .re4-pal-i:focus { border-color: var(--avm-accent); color: var(--avm-accent); outline: none; }
.re4-pal-row.dead .re4-pal-ctl { opacity: .4; }
.re4-pal-row.dead .re4-pal-label { color: var(--avm-muted); }
.re4-pal-group.dead .re4-pal-gname { color: var(--avm-muted); }
.re4-pal-deadnote { margin-left: auto; font-size: 12px; color: var(--avm-muted); }
.re4-pal-deadtag { font-size: 11px; padding: 0 5px; border: 1px solid var(--avm-line); border-radius: 8px; color: var(--avm-muted); cursor: help; flex: none; }
.re4-pal-dot { width: 7px; height: 7px; border-radius: 50%; background: var(--avm-accent); flex: none; }
.re4-pal-batch { display: grid; grid-template-columns: repeat(auto-fill, minmax(12em, 1fr)); gap: 4px 16px; align-items: center; background: var(--re4-soft); }
.re4-pal-batch .re4-pal-glabel { grid-column: 1 / -1; margin: 0; }
.re4-pal-batchbtns { display: flex; gap: 6px; }
.re4-pal-schemes { margin-bottom: 8px; }
.re4-pal-cycle { padding-bottom: 0; }
.re4-pal-solo { display: inline-flex; align-items: center; gap: 6px; cursor: pointer; }
.re4-pal-schemes .re4-row { flex-wrap: wrap; gap: 6px; align-items: center; }
.re4-pal-schemes .el-button + .el-button { margin-left: 0; }
.re4-pal-opttag { margin-left: 8px; }
.re4-pal-dialog { display: grid; gap: 8px; }
.re4-pal-batchbtns .el-button + .el-button { margin-left: 0; }
.re4-pal-batch label { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 8px; align-items: center; font-size: 12.5px; color: var(--avm-muted); }
</style>
