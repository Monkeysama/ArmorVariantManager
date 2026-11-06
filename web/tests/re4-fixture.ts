// RE4 浏览器夹具（fixture.html?re4）。只在开发服务中使用，不进生产构建。
// 用一份内存里的 v3 配置模拟 Games/RE4/Reff.lua：每次快照都从这份数据重新生成，结算规则同 ModelV3。
//   &re4-v2    先给一份旧配置（configVersion = 2），点「迁移旧配置」后变成 v3
//   &re4-empty 没有角色
//   &re4-null  空表按 REFramework 的习惯序列化成 null
import type { Re4Action, Re4ConditionDef, Re4Hotkey, Re4Palette, Re4PaletteMaterial, Re4PaletteOverride, Re4PaletteProfile, Re4PaletteValue, Re4Result, Re4Snapshot, Re4State, Re4StateKind } from '../src/re4/types';

type Win = Window & { reffNativeCall?: (method: string, params: Record<string, unknown>) => Promise<unknown>; re4Calls?: unknown[] };
type Values = Record<string, boolean>;
interface Cond { type: string; op?: string; value: number | string | boolean }
interface State {
  name: string; enabled: boolean; exclusive: boolean; logic: 'AND' | 'OR'; hold: number; fade_in: number; fade_out: number;
  hp?: { upper: number; lower: number; invert: boolean }; base?: string; targets: { group: string; option: string }[]; conditions: Cond[];
  palette?: string;
}
interface Group { name: string; scope: string[]; options: Record<string, Values>; order: string[]; active: string }
interface Config {
  base: { presets: Record<string, Values>; order: string[]; active: string };
  groups: Group[]; auto: boolean; states: State[]; notes: Record<string, string>; armorMirror: boolean; source?: string;
}
interface Preset { id: string; name: string; source: 'user' | 'mod'; match: 'full' | 'partial' | 'none'; config?: Config }

const catalog: Record<string, string[]> = {
  body: ['Skin', 'Jacket', 'Jacket_Torn', 'Shirt'], head: ['Face', 'Blood_Light', 'Blood_Heavy'], hair: ['Hair', 'Clip'],
};
const labels: Record<string, string> = { body: '身体', head: '头部', hair: '头发' };
const allKeys = Object.entries(catalog).flatMap(([slot, mats]) => mats.map(m => `${slot}/${m}`));

// 调色盘夹具:身体和头部的材质按一份简化的 lilToon 映射识别,头发走通用兜底
const paletteProfile: Re4PaletteProfile = {
  id: 'fx_toon', label: { zh: 'lilToon（夹具）', en: 'lilToon (fixture)' }, addon: false,
  sections: [{ id: 'color', label: { zh: '颜色层' } }, { id: 'light', label: { zh: '明暗' } }, { id: 'system', label: { zh: '系统' } }],
  enums: { blend: [{ value: 0, label: { zh: '正常' } }, { value: 1, label: { zh: '相加' } }, { value: 2, label: { zh: '滤色' } }, { value: 3, label: { zh: '相乘' } }] },
  groups: [
    { id: 'main', tier: 'basic', section: 'color', label: { zh: '主色' }, params: [{ param: 'BaseColor', kind: 'color', channels: 'rgb', label: { zh: '主色' }, note: { zh: '原生的基础色乘数' } }] },
    { id: 'main2nd', tier: 'basic', section: 'color', label: { zh: '第二层' }, params: [{ param: 'LIL_Main2ndColor', kind: 'color', channels: 'rgb', label: { zh: '颜色' } },
      { param: 'LIL_Main2ndColor', component: 'w', kind: 'float', min: 0, max: 1, label: { zh: '强度' }, note: { zh: '0 = 关闭这一层' } }] },
    { id: 'shadow', tier: 'basic', section: 'light', label: { zh: '阴影' }, note: { zh: '卡通阴影' }, params: [
      { param: 'LIL_ShadowColor', kind: 'color', channels: 'rgb', label: { zh: '一影颜色' } },
      { param: 'LIL_ShadowParam', component: 'x', kind: 'float', min: 0, max: 1, label: { zh: '一影边界' }, note: { zh: '越大阴影越多' } },
      { param: 'LIL_ShadowParam', component: 'y', kind: 'float', min: 0, max: 1, label: { zh: '一影模糊' } },
      { param: 'LIL_ShadowParam2', component: 'z', kind: 'float', min: 0, max: 1, tier: 'more', label: { zh: '阴影混入主色' } }] },
    { id: 'rim', tier: 'more', section: 'system', label: { zh: '边缘光' }, params: [
      { param: 'LIL_RimColor', kind: 'color', channels: 'rgb', label: { zh: '颜色' } },
      { param: 'LIL_RimParam2', component: 'x', kind: 'enum', enum: 'blend', label: { zh: '混合模式' } },
      { param: 'LIL_Switch', component: 'x', kind: 'bool', label: { zh: '总开关' } },
      { param: 'LIL_MatCapST', kind: 'vec', labels: { zh: ['缩放 U', '缩放 V', '偏移 U', '偏移 V'] }, label: { zh: 'UV 缩放 / 偏移' } }] },
    { id: 'shadow_other', tier: 'other', section: 'light', label: { zh: '阴影' }, params: [
      { param: 'LIL_ShadowParam2', component: 'x', kind: 'float', min: 0, max: 1, tier: 'other', label: { zh: '阴影接收（LIL_ShadowParam2）' } },
      { param: 'LIL_ShadowParam2', component: 'y', kind: 'float', min: 0, max: 1, tier: 'other', label: { zh: 'SSS_Channel' } }] },
  ],
};
const paletteBase = (slot: string): Record<string, Re4PaletteValue> => slot === 'hair'
  ? { BaseColor: [0.4, 0.3, 0.2, 1], SpecularColor: [1, 1, 1, 1] }
  : { BaseColor: [1, 1, 1, 1], LIL_ShadowColor: [0.7, 0.6, 0.65, 1], LIL_ShadowParam: [0.5, 0.05, 0.4, 0.05], LIL_ShadowParam2: [1, 0, 0.5, 1],
      LIL_RimColor: [1, 1, 1, 0.5], LIL_RimParam2: [0, 0.5, 1, 1], LIL_Switch: [1, 0, 0.5, 0], LIL_MatCapST: [1, 1, 0, 0], LIL_Main2ndColor: [1, 0.8, 0.9, 0] };
const full = (off: string[] = []): Values => Object.fromEntries(allKeys.map(k => [k, !off.includes(k)]));
const clone = <T>(v: T): T => structuredClone(v);

const live: Record<string, number | boolean | string> = {
  hp_ratio: 76, hp_vital: 0, hp_decreased: false, is_battle: true, is_wheel: false, is_crouch: false, has_armor_mesh: false,
};
const defs: Re4ConditionDef[] = [
  { id: 'hp_ratio', kind: 'number', label: 'HP%', category: 'hp', ops: ['<=', '<', '>=', '>', '=='] },
  { id: 'hp_vital', kind: 'enum', label: '血量等级', category: 'hp', ops: ['==', '~='], options: [{ value: 0, label: '正常' }, { value: 2, label: '危险' }] },
  { id: 'hp_decreased', kind: 'bool', label: '血量减少', category: 'hp' },
  { id: 'is_battle', kind: 'bool', label: '战斗中', category: 'combat' },
  { id: 'is_wheel', kind: 'bool', label: '站定瞄准/举刀', category: 'combat' },
  { id: 'is_crouch', kind: 'bool', label: '蹲下', category: 'move' },
  { id: 'has_armor_mesh', kind: 'bool', label: '护甲槛位已加载', category: 'other' },
];

function initial(): Config {
  return {
    base: { presets: { '原版': full(['body/Jacket_Torn', 'head/Blood_Light', 'head/Blood_Heavy']), '只穿衬衫': full(['body/Jacket', 'body/Jacket_Torn', 'head/Blood_Light', 'head/Blood_Heavy']) },
      order: ['原版', '只穿衬衫'], active: '原版' },
    groups: [
      { name: '面部', scope: ['head/Blood_Light', 'head/Blood_Heavy'], active: '', order: ['干净', '受伤', '血迹重'],
        options: { '干净': { 'head/Blood_Light': false, 'head/Blood_Heavy': false }, '受伤': { 'head/Blood_Light': true }, '血迹重': { 'head/Blood_Light': true, 'head/Blood_Heavy': true } } },
      { name: '外套', scope: ['body/Jacket', 'body/Jacket_Torn'], active: '穿着', order: ['穿着', '破损', '脱下'],
        options: { '穿着': { 'body/Jacket': true, 'body/Jacket_Torn': false }, '破损': { 'body/Jacket': false, 'body/Jacket_Torn': true }, '脱下': { 'body/Jacket': false, 'body/Jacket_Torn': false } } },
    ],
    auto: true,
    states: [
      { name: '濒死', enabled: true, exclusive: true, logic: 'AND', hold: 0, fade_in: .5, fade_out: 1.5, conditions: [{ type: 'hp_ratio', op: '<=', value: 25 }],
        targets: [{ group: '面部', option: '血迹重' }, { group: '外套', option: '破损' }] },
      { name: '刚挨打', enabled: true, exclusive: false, logic: 'AND', hold: 3, fade_in: .2, fade_out: 1, conditions: [{ type: 'hp_decreased', value: true }],
        targets: [{ group: '面部', option: '受伤' }] },
      { name: '交火', enabled: true, exclusive: false, logic: 'OR', hold: 2, fade_in: 0, fade_out: 0,
        conditions: [{ type: 'is_battle', value: true }, { type: 'is_wheel', value: true }], targets: [{ group: '外套', option: '穿着' }] },
      { name: '蹲下休息', enabled: true, exclusive: false, logic: 'AND', hold: 0, fade_in: .5, fade_out: .5, base: '只穿衬衫',
        conditions: [{ type: 'is_crouch', value: true }], targets: [] },
    ],
    notes: { 'body/Jacket': '皮夹克' }, armorMirror: true,
  };
}

function nullify(value: unknown): unknown {
  if (Array.isArray(value)) return value.length ? value.map(nullify) : null;
  if (value && typeof value === 'object') {
    const entries = Object.entries(value);
    return entries.length ? Object.fromEntries(entries.map(([k, v]) => [k, nullify(v)])) : null;
  }
  return value;
}

export function installRe4Fixture() {
  const params = new URLSearchParams(location.search);
  let config = initial();
  let version: 2 | 3 = params.has('re4-v2') ? 2 : 3;
  const settings = { weaponHideStorage: false, uiDissolveEnabled: true, uiDissolveTime: 1, blockGameMouse: true, heightEnabled: true };
  // 模型高度(夹具简化:不跟改名 / 删除走)。键:'base|预设' / 'g:组|选项'
  const heights: Record<string, number> = {};
  const heightOverride = { enabled: false, cm: 0 };
  // 快捷键(Alt + 数字),规则同 Lua 的 OpsV3.set_hotkey(夹具简化:不跟改名 / 删除走)
  const hotkeys: Record<number, Re4Hotkey> = {};
  const hkStructure = (t: { kind: string; group?: string }) => t.kind === 'group' ? 'group:' + t.group : t.kind;
  const hkCycle = (t: { option?: string; scheme?: string }) => t.option === undefined && t.scheme === undefined;
  const hkSame = (a: Re4Hotkey, b: Re4Hotkey) => hkStructure(a) === hkStructure(b) && hkCycle(a) === hkCycle(b)
    && (a.kind === 'palette' ? a.scheme : a.option) === (b.kind === 'palette' ? b.scheme : b.option);
  let paletteOpen = false, paletteSel: string[] = [];
  // 调色方案(夹具简化:不跟整套造型 / 选项改名走)。'' = 初始(只读,在它上面改会自动新建方案);引用键同 heights
  type Ov = Record<string, Record<string, Re4PaletteOverride>>;
  const schemeOv: Record<string, Ov> = { '': {} };
  let schemeOrder: string[] = [], editing = '';   // editing = 选中的方案(选中就生效)
  const palRefs: Record<string, string> = {};
  const ovOf = (name?: string) => schemeOv[name ?? ''] ?? fail();
  function paletteSnapshot(): Re4Palette {
    const paletteOv = ovOf(editing);
    const materials: Re4PaletteMaterial[] = [], values: Re4Palette['values'] = {}, overrides: Re4Palette['overrides'] = {};
    for (const [slot, mats] of Object.entries(catalog)) for (const material of mats) {
      const key = `${slot}/${material}`, ov = paletteOv[key];
      materials.push({ key, slot, material, note: config.notes[key], main: slot === 'hair' ? undefined : 'fx_toon', addons: [],
        missing: [], generic: slot === 'hair' ? ['BaseColor', 'SpecularColor'] : undefined, overridden: ov ? Object.keys(ov).length : 0,
        replace: slot === 'hair' ? 'packed' : 'ok',
        // 默认贴图失效:边缘光整组(LIL_MaskMap 为黑)、第二层只有颜色(强度仍有效)
        ineffective: slot === 'hair' ? undefined : {
          LIL_RimColor: { comps: 'xyzw', why: [{ texture: 'LIL_MaskMap', null: 'systems/rendering/nullblack' }] },
          LIL_RimParam2: { comps: 'xyzw', why: [{ texture: 'LIL_MaskMap', null: 'systems/rendering/nullblack' }] },
          LIL_Switch: { comps: 'x', why: [{ texture: 'LIL_MaskMap', null: 'systems/rendering/nullblack' }] },
          LIL_MatCapST: { comps: 'xyzw', why: [{ texture: 'LIL_MatCapMap', null: 'systems/rendering/nullblack' }] },
          LIL_Main2ndColor: { comps: 'xyz', why: [{ texture: 'LIL_Main2nd', null: 'systems/rendering/nullblack' }] },
        } });
      overrides[key] = ov ?? false;
      if (!paletteSel.includes(key)) continue;
      const v: Record<string, Re4PaletteValue> = JSON.parse(JSON.stringify(paletteBase(slot)));
      for (const [param, o] of Object.entries(ov ?? {})) {
        if (typeof o === 'number') v[param] = o;
        else { const arr = v[param] as number[]; (['x', 'y', 'z', 'w'] as const).forEach((k, i) => { if (o[k] !== undefined) arr[i] = o[k]!; }); }
      }
      values[key] = v;
    }
    return { materials, profiles: { fx_toon: paletteProfile }, values, overrides, selected: [...paletteSel], errors: [], scheme: editing };
  }
  let character = 'Leon';
  let backup: Config | undefined;
  let notice: Re4Snapshot['notice'];
  let locating: { slot: string; material: string } | undefined;
  let dismissed = false;
  let previewEnabled = false;
  let nextId = 4;
  const presets: Preset[] = [
    { id: 'p0001', name: '日常', source: 'user', match: 'full', config: initial() },
    { id: 'p0002', name: '备用（改材质后）', source: 'user', match: 'partial', config: initial() },
    { id: 'p0003', name: '作者推荐配色', source: 'mod', match: 'none', config: initial() },
  ];
  const autosaves: { name: string; time: number; config: Config }[] = [];
  const calls: unknown[] = [];
  const fail = (message = '操作无效或目标已不存在，请刷新后重试'): never => { throw new Error(message); };
  const wait = () => new Promise(resolve => window.setTimeout(resolve, 60));
  const groupOf = (name: string) => config.groups.find(g => g.name === name);

  function met(c: Cond) {
    const v = live[c.type];
    if (v === undefined) return false;
    if (typeof c.value === 'boolean') return v === c.value;
    const a = Number(v), b = Number(c.value);
    switch (c.op ?? '<=') { case '<=': return a <= b; case '<': return a < b; case '>=': return a >= b; case '>': return a > b; case '~=': return a !== b; default: return a === b; }
  }
  function resolve() {
    const claims: Record<string, { i: number; option: string }> = {};
    const status: { kind: Re4StateKind; by?: number }[] = [];
    const results: { base?: Re4Result; targets: (Re4Result | undefined)[]; palette?: Re4Result }[] = [];
    let stop = 0;
    config.states.forEach((st, k) => {
      const i = k + 1;
      const list = [...(st.base ? [{ key: 'base', option: st.base, valid: !!config.base.presets[st.base], isBase: true }] : []),
        ...st.targets.map(t => ({ key: 'g:' + t.group, option: t.option, valid: !!groupOf(t.group)?.options[t.option], isBase: false }))];
      const res: (Re4Result | undefined)[] = list.map(x => x.valid ? undefined : { kind: 'broken' });
      const hit = st.conditions.length > 0 && (st.logic === 'OR' ? st.conditions.some(met) : st.conditions.every(met));
      if (!st.enabled) status[k] = { kind: 'off' };
      else if (!config.auto) status[k] = { kind: 'paused' };
      else if (st.hp || !hit) status[k] = { kind: 'idle' };
      else if (stop) { list.forEach((_, j) => { res[j] ??= { kind: 'lose', by: stop }; }); status[k] = { kind: 'outranked', by: stop }; }
      else {
        let won = 0, valid = 0, by: number | undefined;
        list.forEach((x, j) => {
          if (res[j]) return;
          valid++;
          if (!claims[x.key]) { claims[x.key] = { i, option: x.option }; won++; res[j] = { kind: 'win' }; }
          else { res[j] = { kind: 'lose', by: claims[x.key].i }; by ??= claims[x.key].i; }
        });
        status[k] = { kind: valid === 0 ? 'idle' : won === 0 ? 'outranked' : won < valid ? 'partial' : 'active', by: won === 0 ? by : undefined };
        if (st.exclusive) stop = i;
      }
      const out: { base?: Re4Result; targets: (Re4Result | undefined)[]; palette?: Re4Result } = { targets: [] };
      list.forEach((x, j) => { if (x.isBase) out.base = res[j]; else out.targets.push(res[j]); });
      // 调色方案不独占:命中且没被独占状态挡住就生效(夹具不算血量状态)
      if (st.palette) out.palette = !schemeOv[st.palette] ? { kind: 'broken' }
        : stop && stop < i ? { kind: 'lose', by: stop } : st.enabled && config.auto && hit && !st.hp ? { kind: 'win' } : undefined;
      if (out.palette?.kind === 'win' && status[k].kind === 'idle') status[k] = { kind: 'active' };
      results[k] = out;
    });
    return { claims, status, results };
  }

  function snapshot(): Re4Snapshot {
    const base: Re4Snapshot = { game: 'RE4', version: '4.3.4', language: 'zh', settings: { ...settings },
      characters: params.has('re4-empty') ? [] : [{ id: 'Leon', label: '里昂', configured: true, targets: ['玩家', '过场傀儡'] }, { id: 'Ada', label: '艾达', configured: false, targets: ['过场傀儡'] }],
      character: params.has('re4-empty') ? '' : character, notice,
      preview: params.has('preview') ? { available: true, enabled: previewEnabled, status: 'preview_live' }
        : { available: false, enabled: previewEnabled, status: 'preview_native_missing' } };
    notice = undefined;
    if (params.has('re4-empty')) return base;
    base.configVersion = version;
    if (version === 2) return base;
    const r = resolve();
    const pick = (key: string, manual: string) => r.claims[key]?.option ?? (manual || undefined);
    const effBase = pick('base', config.base.active);
    const look: Values = { ...(effBase ? config.base.presets[effBase] : full()) };
    let height = effBase !== undefined ? heights['base|' + effBase] : undefined;
    let heightSource: Re4Snapshot['heightSource'] = height !== undefined ? { layer: 'base', option: effBase } : undefined;
    for (const g of config.groups) {
      const o = pick('g:' + g.name, g.active);
      if (o && g.options[o]) Object.assign(look, g.options[o]);
      if (o && heights[`g:${g.name}|${o}`] !== undefined) { height = heights[`g:${g.name}|${o}`]; heightSource = { layer: g.name, option: o }; }
    }
    if (heightOverride.enabled) { height = heightOverride.cm; heightSource = { layer: 'override' }; }
    // 生效的调色方案:整套造型 → 状态组 → 条件状态(优先级低的先)
    const activePal: string[] = [];
    const addPal = (n?: string) => { if (n && schemeOv[n]) activePal.push(n); };
    addPal(editing);
    if (effBase) addPal(palRefs['base|' + effBase]);
    for (const g of config.groups) { const o = pick('g:' + g.name, g.active); if (o) addPal(palRefs[`g:${g.name}|${o}`]); }
    for (let k = config.states.length - 1; k >= 0; k--) if (r.results[k].palette?.kind === 'win') addPal(config.states[k].palette);
    const used = (n: string) => Object.values(palRefs).filter(v => v === n).length + config.states.filter(st => st.palette === n).length;
    const states: Re4State[] = config.states.map((st, k) => ({
      palette: st.palette, paletteResult: r.results[k].palette,
      name: st.name, enabled: st.enabled, exclusive: st.exclusive, logic: st.logic, hold: st.hold, fadeIn: st.fade_in, fadeOut: st.fade_out,
      hp: st.hp, base: st.base, baseResult: r.results[k].base, kind: r.status[k].kind, by: r.status[k].by, holding: false,
      targets: st.targets.map((t, j) => ({ ...t, result: r.results[k].targets[j] })),
      conditions: st.conditions.map(c => {
        const def = defs.find(d => d.id === c.type);
        return { ...c, op: c.op as never, label: def?.label ?? c.type, known: !!def, met: met(c),
          valueLabel: def?.kind === 'enum' ? def.options?.find(o => o.value === c.value)?.label : undefined };
      }),
    }));
    const source = presets.find(p => p.id === config.source);
    return { ...base,
      status: { hp: Number(live.hp_ratio), flags: defs.filter(d => d.kind === 'bool' && live[d.id] === true).map(d => d.label) },
      conditions: defs.map(d => ({ ...d, value: live[d.id] as number | boolean })), auto: config.auto, armorMirror: config.armorMirror,
      slots: Object.entries(catalog).map(([id, mats]) => ({ id, label: labels[id], mirrored: false, materials: mats.map(name => ({ name, note: config.notes[`${id}/${name}`] })) })),
      look: allKeys.map(k => { const [slot, material] = k.split('/'); return { slot, material, on: look[k] !== false }; }),
      base: { active: config.base.active, effective: effBase, fromState: r.claims.base?.i,
        presets: config.base.order.map(name => ({ name, values: config.base.presets[name], match: { status: 'ok', skipped: [] }, height: heights['base|' + name], palette: palRefs['base|' + name] })) },
      groups: config.groups.map(g => ({ name: g.name, scope: g.scope, active: g.active, effective: pick('g:' + g.name, g.active),
        fromState: r.claims['g:' + g.name]?.i, options: g.order.map(name => ({ name, values: g.options[name], height: heights[`g:${g.name}|${name}`], palette: palRefs[`g:${g.name}|${name}`] })) })),
      states, locating, height, heightSource, heightOverride: { ...heightOverride },
      palette: paletteOpen ? paletteSnapshot() : undefined,
      hotkeys: Object.values(hotkeys).sort((x, y) => x.digit - y.digit).map(h => ({ ...h, skip: [...h.skip] })),
      palettes: { list: schemeOrder.map(name => ({ name, used: used(name), materials: Object.keys(schemeOv[name]).length })), active: activePal, selected: editing },
      presets: { current: config.source === 'p0002' ? 'partial' : 'full', dismissed,
        source: source ? { id: source.id, name: source.name, own: source.source === 'user' } : undefined,
        list: presets.map(p => ({ id: p.id, name: p.name, source: p.source, match: p.match })),
        better: config.source === 'p0002' ? [{ id: 'p0001', name: '日常' }] : [],
        autosaves: autosaves.map(a => ({ name: a.name, time: a.time })) },
      backups: { hasBackup: !!backup, hasOnload: true },
    };
  }

  function rename<T>(map: Record<string, T>, order: string[], from: string, to: string) {
    if (!to || map[to] || !map[from]) fail('名称为空或已存在');
    map[to] = map[from]; delete map[from]; order[order.indexOf(from)] = to;
  }
  const move = (order: string[], name: string, offset: number) => {
    const from = order.indexOf(name), to = from + offset;
    if (from < 0 || to < 0 || to >= order.length) fail('无法移动该项');
    order.splice(to, 0, order.splice(from, 1)[0]);
  };
  const stateAt = (i: number) => config.states[i - 1] ?? fail();

  function act(a: Re4Action) {
    if (a.kind === 'character') { character = a.id; return; }
    if (a.kind === 'setting') {
      if (a.id === 'weapon_hide_storage') settings.weaponHideStorage = a.value === true;
      else if (a.id === 'block_game_mouse') settings.blockGameMouse = a.value === true;
      else if (a.id === 'height_enabled') settings.heightEnabled = a.value === true;
      else if (a.id === 'ui_dissolve_enabled') settings.uiDissolveEnabled = a.value === true;
      else if (a.id === 'portrait_enabled') previewEnabled = a.value === true;
      else if (a.id === 'portrait_distance' || a.id === 'portrait_height') return;
      else settings.uiDissolveTime = Math.round(Number(a.value) * 10) / 10;
      return;
    }
    if (a.character !== character) fail('当前角色已变化，请确认后重试');
    if (a.kind === 'migrate') { if (version === 3) fail(); version = 3; backup = clone(config); notice = { kind: 'migrated', presets: 2 }; return; }
    if (version !== 3) fail('这份配置还是旧版，请先在「杂项」里迁移旧配置');
    switch (a.kind) {
      case 'manual':
        if (a.layer === 'base') { if (a.option && !config.base.presets[a.option]) fail(); config.base.active = a.option; }
        else { const g = groupOf(a.layer) ?? fail(); if (a.option && !g.options[a.option]) fail(); g.active = a.option; }
        break;
      case 'auto': config.auto = a.enabled; break;
      case 'armor-mirror': config.armorMirror = a.enabled; break;
      case 'note': if (a.text) config.notes[`${a.slot}/${a.material}`] = a.text; else delete config.notes[`${a.slot}/${a.material}`]; break;
      case 'locate': locating = { slot: a.slot, material: a.material }; window.setTimeout(() => { locating = undefined; }, 3000); break;
      case 'base-new': { let n = 1; while (config.base.presets[String(n)]) n++; config.base.presets[String(n)] = full(); config.base.order.push(String(n)); config.base.active = String(n); break; }
      case 'base-duplicate': { const src = config.base.presets[a.preset] ?? fail(); const name = `${a.preset}_1`; config.base.presets[name] = clone(src); config.base.order.push(name); config.base.active = name; break; }
      case 'base-rename': rename(config.base.presets, config.base.order, a.preset, a.name); if (config.base.active === a.preset) config.base.active = a.name;
        config.states.forEach(s => { if (s.base === a.preset) s.base = a.name; }); break;
      case 'base-move': move(config.base.order, a.preset, a.offset); break;
      case 'base-delete': if (!config.base.presets[a.preset]) fail(); backup = clone(config); delete config.base.presets[a.preset];
        config.base.order.splice(config.base.order.indexOf(a.preset), 1); if (config.base.active === a.preset) config.base.active = ''; break;
      case 'base-recapture': if (!config.base.presets[a.preset]) fail(); backup = clone(config); config.base.presets[a.preset] = full(); break;
      case 'base-material': (config.base.presets[a.preset] ?? fail())[`${a.slot}/${a.material}`] = a.value; break;
      case 'hotkey-set': {
        if (a.digit < 0 || a.digit > 9) fail();
        const b: Re4Hotkey = { ...a.target, digit: a.digit, cycle: hkCycle(a.target), skip: [] };
        if (hotkeys[a.digit] && hkSame(hotkeys[a.digit], b)) fail();
        for (const [k, x] of Object.entries(hotkeys)) {
          if (hkStructure(x) !== hkStructure(b)) continue;
          if (hkSame(x, b)) { if (b.cycle) b.skip = x.skip; delete hotkeys[Number(k)]; }
          else if (b.cycle) delete hotkeys[Number(k)];
          else if (x.cycle) fail('这个结构已经绑了轮换键');
        }
        hotkeys[a.digit] = b; break; }
      case 'hotkey-clear': if (!hotkeys[a.digit]) fail(); delete hotkeys[a.digit]; break;
      case 'hotkey-skip': {
        const b = Object.values(hotkeys).find(x => x.cycle && hkStructure(x) === hkStructure(a.structure)) ?? fail();
        const at = b.skip.indexOf(a.item);
        if (a.included) { if (at < 0) fail(); b.skip.splice(at, 1); } else { if (at >= 0) fail(); b.skip.push(a.item); }
        break; }
      case 'base-height': if (!config.base.presets[a.preset]) fail();
        if (a.cm === undefined) delete heights['base|' + a.preset]; else heights['base|' + a.preset] = a.cm; break;
      case 'palette-view': paletteOpen = a.open; paletteSel = [...a.keys]; break;
      case 'palette-set': { if (!a.scheme && !editing) { let n = 1; while (schemeOv['方案 ' + n]) n++; editing = '方案 ' + n; schemeOv[editing] = {}; schemeOrder.push(editing); }
        const paletteOv = ovOf(a.scheme || editing); for (const w of a.writes) {
        const key = `${w.slot}/${w.material}`, ov = (paletteOv[key] ??= {});
        if (w.component) { const cur = ov[w.param]; const o = typeof cur === 'object' ? cur : {}; o[w.component] = w.value; ov[w.param] = o; }
        else ov[w.param] = w.value;
      } break; }
      case 'palette-reset': { const paletteOv = ovOf(a.scheme || editing); for (const t of a.targets) {
        const key = `${t.slot}/${t.material}`, ov = paletteOv[key];
        if (!ov) continue;
        if (!a.param) { delete paletteOv[key]; continue; }
        const cur = ov[a.param];
        if (a.component && typeof cur === 'object') { delete cur[a.component]; if (!Object.keys(cur).length) delete ov[a.param]; }
        else delete ov[a.param];
        if (!Object.keys(ov).length) delete paletteOv[key];
      } break; }
      case 'palette-scheme-new': if (!a.name || schemeOv[a.name] || (a.from && !schemeOv[a.from])) fail();
        schemeOv[a.name] = a.from === undefined ? {} : JSON.parse(JSON.stringify(schemeOv[a.from])); schemeOrder.push(a.name); editing = a.name; break;
      case 'palette-scheme-select': if (a.scheme && !schemeOv[a.scheme]) fail(); if (a.scheme === editing) fail(); editing = a.scheme; break;
      case 'palette-scheme-rename': if (!a.scheme || !schemeOv[a.scheme] || !a.name || schemeOv[a.name]) fail();
        schemeOv[a.name] = schemeOv[a.scheme]; delete schemeOv[a.scheme]; schemeOrder = schemeOrder.map(n => n === a.scheme ? a.name : n);
        for (const k of Object.keys(palRefs)) if (palRefs[k] === a.scheme) palRefs[k] = a.name;
        config.states.forEach(st => { if (st.palette === a.scheme) st.palette = a.name; });
        if (editing === a.scheme) editing = a.name; break;
      case 'palette-scheme-delete': if (!a.scheme || !schemeOv[a.scheme]) fail();
        delete schemeOv[a.scheme]; schemeOrder = schemeOrder.filter(n => n !== a.scheme); if (editing === a.scheme) editing = ''; break;
      case 'palette-ref': { const key = a.layer === 'base' ? 'base|' + a.option : `g:${a.layer}|${a.option}`;
        if (a.scheme && !schemeOv[a.scheme]) fail();
        if ((palRefs[key] ?? '') === a.scheme) fail();
        if (a.scheme) palRefs[key] = a.scheme; else delete palRefs[key]; break; }
      case 'state-palette': { const s = stateAt(a.index); if (a.scheme && !schemeOv[a.scheme]) fail(); s.palette = a.scheme || undefined; break; }
      case 'palette-reload': break;
      // 替换 mdf:夹具里只给出完成提示(真实流程要等新 mdf2 加载、再清空涉及的调色配置)
      case 'palette-replace': notice = { kind: 'mdf-replaced', path: `natives/STM/_Chainsaw/Character/ch/${a.slot}.mdf2.32` }; break;
      // 同 Lua:预设名只允许英文;头发的材质假装读不到 mdf2(打包在 pak 里),走运行时数据
      case 'palette-export':
        if (!/^[A-Za-z0-9_-][A-Za-z0-9 _-]{0,63}$/.test(a.name) || /\s$/.test(a.name)) throw new Error('预设名只能用英文字母、数字、空格、- 和 _(1~64 个字符)');
        notice = a.slot === 'hair'
          ? { kind: 'palette-exported', path: `reframework/data/ArmorVariantManager/mdf2_presets/RE4/${a.name}.json`, exact: false, reason: `natives/STM/_Chainsaw/Character/ch/hair.mdf2.32: not found` }
          : { kind: 'palette-exported', path: `reframework/data/ArmorVariantManager/mdf2_presets/RE4/${a.name}.json`, exact: true };
        break;
      case 'height-override': if (a.enabled !== undefined) heightOverride.enabled = a.enabled; if (a.cm !== undefined) heightOverride.cm = a.cm; break;
      case 'option-height': { const g = groupOf(a.group) ?? fail(); if (!g.options[a.option]) fail();
        if (a.cm === undefined) delete heights[`g:${a.group}|${a.option}`]; else heights[`g:${a.group}|${a.option}`] = a.cm; break; }
      case 'group-new': if (!a.name || groupOf(a.name)) fail(); config.groups.push({ name: a.name, scope: [], options: {}, order: [], active: '' }); break;
      case 'group-rename': { const g = groupOf(a.group) ?? fail(); if (!a.name || groupOf(a.name)) fail(); config.states.forEach(s => s.targets.forEach(t => { if (t.group === a.group) t.group = a.name; })); g.name = a.name; break; }
      case 'group-move': { const i = config.groups.findIndex(g => g.name === a.group), j = i + a.offset; if (i < 0 || j < 0 || j >= config.groups.length) fail(); config.groups.splice(j, 0, config.groups.splice(i, 1)[0]); break; }
      case 'group-delete': { const i = config.groups.findIndex(g => g.name === a.group); if (i < 0) fail(); backup = clone(config); config.groups.splice(i, 1); break; }
      case 'scope-add': { const g = groupOf(a.group) ?? fail(); const key = `${a.slot}/${a.material}`;
        if (g.scope.includes(key)) fail(); g.scope.push(key); break; }
      case 'scope-remove': { const g = groupOf(a.group) ?? fail(); const key = `${a.slot}/${a.material}`; if (!g.scope.includes(key)) fail();
        g.scope = g.scope.filter(k => k !== key); Object.values(g.options).forEach(o => { delete o[key]; }); break; }
      case 'option-new': { const g = groupOf(a.group) ?? fail(); let n = 1; while (g.options[String(n)]) n++; const name = a.name ?? String(n);
        g.options[name] = {}; g.order.push(name); g.active = name; break; }
      case 'option-duplicate': { const g = groupOf(a.group) ?? fail(); const src = g.options[a.option] ?? fail(); const name = `${a.option}_1`;
        g.options[name] = clone(src); g.order.splice(g.order.indexOf(a.option) + 1, 0, name); g.active = name; break; }
      case 'option-rename': { const g = groupOf(a.group) ?? fail(); rename(g.options, g.order, a.option, a.name); if (g.active === a.option) g.active = a.name;
        config.states.forEach(s => s.targets.forEach(t => { if (t.group === a.group && t.option === a.option) t.option = a.name; })); break; }
      case 'option-move': { const g = groupOf(a.group) ?? fail(); move(g.order, a.option, a.offset); break; }
      case 'option-delete': { const g = groupOf(a.group) ?? fail(); if (!g.options[a.option]) fail(); backup = clone(config);
        delete g.options[a.option]; g.order.splice(g.order.indexOf(a.option), 1); if (g.active === a.option) g.active = ''; break; }
      case 'option-material': { const g = groupOf(a.group) ?? fail(); const o = g.options[a.option] ?? fail(); const key = `${a.slot}/${a.material}`;
        if (!g.scope.includes(key)) fail(); if (a.value === 'none') delete o[key]; else o[key] = a.value === 'on'; break; }
      case 'state-new': config.states.push({ name: a.name, enabled: true, exclusive: false, logic: 'AND', hold: 0, fade_in: 0, fade_out: 0, targets: [], conditions: [] }); break;
      case 'state-delete': stateAt(a.index); config.states.splice(a.index - 1, 1); break;
      case 'state-move': { stateAt(a.from); if (a.to < 1 || a.to > config.states.length) fail(); config.states.splice(a.to - 1, 0, config.states.splice(a.from - 1, 1)[0]); break; }
      case 'state-rename': if (!a.name) fail(); stateAt(a.index).name = a.name; break;
      case 'state-field': { const s = stateAt(a.index);
        if (a.field === 'enabled' || a.field === 'exclusive') s[a.field] = a.value as boolean;
        else if (a.field === 'logic') s.logic = a.value as 'AND' | 'OR';
        else s[a.field] = Math.max(0, Math.round(Number(a.value) * 10) / 10);
        break; }
      case 'state-hp': stateAt(a.index).hp = a.hp; break;
      case 'state-base': { const s = stateAt(a.index); if (a.preset && !config.base.presets[a.preset]) fail(); s.base = a.preset; break; }
      case 'state-target': { const s = stateAt(a.index); if (!groupOf(a.group)?.options[a.option]) fail();
        const t = s.targets.find(x => x.group === a.group); if (t) t.option = a.option; else s.targets.push({ group: a.group, option: a.option }); break; }
      case 'state-target-group': { const s = stateAt(a.index); const g = groupOf(a.group) ?? fail(); const t = s.targets[a.target - 1] ?? fail();
        t.group = g.name; t.option = g.order[0] ?? ''; break; }
      case 'state-target-remove': { const s = stateAt(a.index); if (!s.targets[a.target - 1]) fail(); s.targets.splice(a.target - 1, 1); break; }
      case 'condition-add': stateAt(a.index).conditions.push({ ...a.condition }); break;
      case 'condition-set': { const s = stateAt(a.index); if (!s.conditions[a.condition_index - 1]) fail(); s.conditions[a.condition_index - 1] = { ...a.condition }; break; }
      case 'condition-delete': { const s = stateAt(a.index); if (!s.conditions[a.condition_index - 1]) fail(); s.conditions.splice(a.condition_index - 1, 1); break; }
      case 'preset-apply': { const p = presets.find(x => x.id === a.id) ?? fail(); if (p.match === 'none') fail();
        autosaves.unshift({ name: `套用「${p.name}」前`, time: Date.now() / 1000, config: clone(config) }); autosaves.splice(5);
        config = clone(p.config ?? initial()); config.source = p.id; dismissed = false; break; }
      case 'preset-save': { if (!a.name) fail(); const id = `p${String(nextId++).padStart(4, '0')}`;
        presets.push({ id, name: a.name, source: 'user', match: 'full', config: clone(config) }); config.source = id; break; }
      case 'preset-update': { const p = presets.find(x => x.id === config.source && x.source === 'user') ?? fail(); p.config = clone(config); break; }
      case 'preset-rename': { const p = presets.find(x => x.id === a.id && x.source === 'user') ?? fail(); p.name = a.name; break; }
      case 'preset-delete': { const i = presets.findIndex(x => x.id === a.id && x.source === 'user'); if (i < 0) fail(); presets.splice(i, 1); break; }
      case 'preset-dismiss': dismissed = true; break;
      case 'autosave-restore': { const s = autosaves[a.index - 1] ?? fail(); autosaves.splice(a.index - 1, 1);
        autosaves.unshift({ name: '恢复自动保存前', time: Date.now() / 1000, config: clone(config) }); config = clone(s.config); break; }
      case 'autosave-promote': { const s = autosaves[a.index - 1] ?? fail(); autosaves.splice(a.index - 1, 1);
        presets.push({ id: `p${String(nextId++).padStart(4, '0')}`, name: a.name, source: 'user', match: 'full', config: clone(s.config) }); break; }
      case 'restore': if (a.which === 'backup') { if (!backup) fail(); config = clone(backup!); } break;
    }
  }

  (window as Win).reffNativeCall = async (method, args) => {
    if (method === 'ui.status') return { ready: true, epoch: 1 };
    if (method === 'ui.layout.set') return { padding: 0, override: 0, defaultPadding: 24 };
    // 原生预览槽:只回应能力与登记,不画画面(?re4&preview 用于测试预览框布局与鼠标操作)
    if (method === 'ui.preview.capabilities') return { version: 1, layoutProtocol: 2, maxSlots: 4, composition: 'underlay-alpha', color: 'sdr-unorm8' };
    if (method === 'ui.preview.register') return { pageId: 'avm-re4-preview-fixture' };
    if (method === 'ui.preview.remove') return {};
    await wait();
    const out = (value: Re4Snapshot) => params.has('re4-null') ? nullify(value) : value;
    if (method === 'monkeysama.avm.snapshot') return out(snapshot());
    if (method === 'monkeysama.avm.preview') return snapshot().preview;
    if (method === 'monkeysama.avm.documentation') return { sections: [{ id: 'usage', title: '日常使用', entries: [{ title: '整套造型与状态组', paragraphs: ['整套造型是完整的一套外观。'] }] }] };
    if (method === 'monkeysama.avm.action') { calls.push(args); act(args as unknown as Re4Action); return out(snapshot()); }
    throw new Error(`RE4 fixture: unknown method ${method}`);
  };
  (window as Win).re4Calls = calls;
  // 演示用：控制台里改条件值（例如 re4Live.hp_ratio = 20）
  (window as Win & { re4Live?: typeof live }).re4Live = live;
}
