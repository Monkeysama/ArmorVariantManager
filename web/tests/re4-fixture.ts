// RE4 浏览器夹具（fixture.html?re4）。只在开发服务中使用，不进生产构建。
// 用一份内存里的「配置」模拟 Games/RE4/Reff.lua：每次快照都从这份数据重新生成，
// 所以编辑、规则、存档在页面上的效果是连贯的。不提供游戏人物、真实条件或模型画面。
import type { Re4Action, Re4ConditionDef, Re4Layer, Re4PresetValues, Re4Rule, Re4SaveSlot, Re4Snapshot } from '../src/re4/types';

type Win = Window & { reffNativeCall?: (method: string, params: Record<string, unknown>) => Promise<unknown>; re4Calls?: unknown[] };
interface Layer { presets: Record<string, Re4PresetValues>; order: string[]; active: string; auto: boolean; rules: Re4Rule[] }
interface Config { base: Layer; axes: Record<string, Layer>; notes: Record<string, Record<string, string>>; armorMirror: boolean }

const defs: Re4ConditionDef[] = [
  { id: 'hp_ratio', kind: 'number', label: '血量 %', ops: ['<=', '<', '>=', '>', '=='], value: 76 },
  { id: 'hp_vital', kind: 'enum', label: '血量等级', ops: ['==', '~='], options: [{ value: 0, label: '正常' }, { value: 1, label: '警告' }, { value: 2, label: '危险' }], value: 0 },
  { id: 'is_battle', kind: 'bool', label: '战斗中', value: true },
  { id: 'is_aiming', kind: 'bool', label: '瞄准中', value: false },
  { id: 'hp_decreased', kind: 'bool', label: '血量减少', value: false },
];
const catalog: Record<string, string[]> = {
  body: ['Body_Skin', 'Jacket_Main', 'Jacket_Metal', 'Skirt_Main', 'Stocking'],
  head: ['Face', 'Eyelash'],
  hair: ['Hair_Main', 'Ponytail', 'Hair_Clip'],
  armor: ['Body_Skin', 'Jacket_Main'],
};
const labels: Record<string, string> = { body: '身体 (00)', head: '头部 (10)', hair: '头发 (20)', armor: '护甲' };
const shown: Record<string, Record<string, boolean>> = { body: { Stocking: false }, head: {}, hair: {}, armor: {} };
const full = (off: string[] = []): Re4PresetValues => Object.fromEntries(['body', 'head', 'hair'].map(slot =>
  [slot, Object.fromEntries(catalog[slot].map(m => [m, !off.includes(m)]))]));
const rule = (preset: string, extra: Partial<Re4Rule> = {}): Re4Rule => ({ index: 0, preset, priority: 0, logic: 'AND', hold: 0, conditions: [],
  hits: false, effective: false, orphan: false, dissolve: { enabled: false, hideTime: .5, showTime: .5 }, hpDrive: { enabled: false, upper: 100, lower: 0, invert: false }, ...extra });
const layer = (presets: Record<string, Re4PresetValues>, active: string, rules: Re4Rule[] = []): Layer =>
  ({ presets, order: Object.keys(presets), active, auto: true, rules });
const clone = <T>(value: T): T => structuredClone(value);

function initial(): Config {
  return {
    base: layer({ 'Default | 默认': full(['Stocking']), '战斗服': full(['Skirt_Main']), '旧模型预设': { body: { Old_Body: true } } }, 'Default | 默认'),
    axes: {
      '隐藏头发': layer({ '隐藏': { hair: { Ponytail: false } } }, ''),
      '外套': layer({ '完整': {}, '敞开': { body: { Jacket_Metal: false } }, '无外套': { body: { Jacket_Main: false, Jacket_Metal: false } } }, '敞开'),
      '面部表情': layer({ '低血量': { head: { Face: true } }, '受伤': { head: { Eyelash: false } }, '正常': {} }, '正常', [
        rule('低血量', { conditions: [{ type: 'hp_ratio', op: '<=', value: 30, label: '血量 %', known: true }] }),
        rule('受伤', { hold: 2, logic: 'OR', dissolve: { enabled: true, hideTime: .8, showTime: 1.2 },
          conditions: [{ type: 'hp_decreased', value: true, label: '血量减少', known: true }, { type: 'is_battle', value: true, label: '战斗中', known: true }] }),
        rule('已删除的状态', { conditions: [{ type: 'is_aiming', value: true, label: '瞄准中', known: true }] }),
      ]),
    },
    notes: { body: { Jacket_Metal: '外套金属扣' } },
    armorMirror: false,
  };
}

export function installRe4Fixture() {
  const params = new URLSearchParams(location.search);
  let config = initial();
  let language: 'zh' | 'en' = 'zh';
  const settings = { weaponHideStorage: false, uiDissolveEnabled: true, uiDissolveTime: 1 };
  let character = 'Leon';
  let shared = params.has('re4-shared');
  let backup: Config | undefined;
  let locating: { slot: string; material: string } | undefined;
  let saves: (Re4SaveSlot & { data: Config })[] = [{ key: 'Ada', name: '1104-2210', own: false, label: 'Ada / 1104-2210', data: initial() }];
  const calls: unknown[] = [];
  const wait = (delay = 80) => new Promise(resolve => setTimeout(resolve, delay));
  function fail(message = '操作无效或目标已不存在,请刷新后重试'): never { throw new Error(message); }

  function row(name: string, l: Layer, base: boolean): Re4Layer {
    const effective = l.auto && l.rules.some(r => r.preset === '受伤') ? '受伤' : (l.active || undefined);
    const rules = [...l.rules].sort((a, b) => (l.order.indexOf(a.preset) + 1 || 999) - (l.order.indexOf(b.preset) + 1 || 999)).map(r => {
      const p = l.order.indexOf(r.preset);
      return { ...clone(r), index: l.rules.indexOf(r) + 1, priority: p < 0 ? undefined : p + 1, orphan: p < 0,
        hits: r.preset === '受伤' && l.auto, effective: r.preset === '受伤' && l.auto };
    });
    return { name, base, presets: [...l.order], active: l.active, effective, fromRule: effective !== undefined && effective !== l.active,
      auto: l.auto, advanced: !base && l.rules.length > 0, rules, values: clone(l.presets),
      ...(base ? { match: Object.fromEntries(l.order.map(n => [n, n === '旧模型预设' ? { status: 'mismatch' as const, skipped: ['身体 (00)'] }
        : n === '战斗服' ? { status: 'partial' as const, skipped: ['头部 (10)'] } : { status: 'ok' as const, skipped: [] }])) } : {}) };
  }
  function snapshot(): Re4Snapshot {
    const base: Re4Snapshot = { game: 'RE4', version: '4.3.4', language, settings: { ...settings },
      characters: [{ id: 'Leon', label: '里昂', configured: true, targets: ['ch0_a0z0', 'ch0a0z0_puppet'] }, { id: 'Ada', label: '艾达', configured: false, targets: ['Figure00_010'] }],
      character };
    if (params.has('re4-empty')) return { ...base, characters: [], character: '' };
    const slots = ['body', 'head', 'hair', 'armor'].map(id => ({ id, label: labels[id], mirrored: id === 'armor' && config.armorMirror,
      materials: catalog[id].map(name => ({ name, enabled: shown[id][name] !== false, ...(config.notes[id]?.[name] ? { note: config.notes[id][name] } : {}) })) }));
    const value: Re4Snapshot = { ...base, status: { hp: 76, flags: ['战斗中'] }, conditions: defs,
      ...(shared ? { sharedWith: 'ch6_i0z0' } : {}),
      base: row('整套造型', config.base, true), axes: Object.entries(config.axes).map(([name, l]) => row(name, l, false)),
      editor: { armorMirror: config.armorMirror, slots, conflicts: config.axes['外套'] && config.axes['隐藏头发']?.presets['隐藏']?.body?.Jacket_Main !== undefined
        ? [{ key: 'body/Jacket_Main', parts: [{ axis: '外套', on: false, off: true }, { axis: '隐藏头发', on: true, off: false }] }] : [],
        ...(locating ? { locating } : {}) },
      ownership: { shared, canReset: !shared, canMatchKin: !shared && Object.keys(config.axes).length === 0 && config.base.order.length <= 1 },
      saves: { slots: saves.map(({ data: _, ...slot }) => slot), hasBackup: backup !== undefined, hasOnload: true } };
    if (params.has('re4-null')) return { ...value, axes: null, characters: null } as unknown as Re4Snapshot;
    return clone(value);
  }

  function layerOf(axis?: string) { return axis === undefined ? config.base : config.axes[axis]; }
  function nextName(l: Layer, base: string) { let n = 1; while (l.presets[`${base}${n}`]) n++; return `${base}${n}`; }
  function act(a: Re4Action) {
    if (a.kind === 'character') { if (a.id === 'Ada') fail('夹具：Ada 尚未配置'); character = a.id; return; }
    if (a.kind === 'setting') {
      if (a.id === 'language') language = a.value;
      else if (a.id === 'weapon_hide_storage') settings.weaponHideStorage = a.value;
      else if (a.id === 'ui_dissolve_enabled') settings.uiDissolveEnabled = a.value;
      else settings.uiDissolveTime = Math.round(Math.min(30, Math.max(0, Number(a.value))) * 10) / 10;
      return;
    }
    if (a.character !== character) fail('当前角色已变化,请确认后重试');
    switch (a.kind) {
      case 'axis-new': if (!a.name || config.axes[a.name]) fail(); config.axes[a.name] = layer({ '1': {} }, '1'); return;
      case 'axis-rename': if (!a.name || config.axes[a.name] || !config.axes[a.axis]) fail(); config.axes[a.name] = config.axes[a.axis]; delete config.axes[a.axis]; return;
      case 'axis-delete': if (!config.axes[a.axis]) fail(); delete config.axes[a.axis]; return;
      case 'armor-mirror': config.armorMirror = a.enabled; return;
      case 'note': (config.notes[a.slot] ??= {})[a.material] = a.text; if (!a.text) delete config.notes[a.slot][a.material]; return;
      case 'locate': locating = { slot: a.slot, material: a.material }; setTimeout(() => { locating = undefined; }, 3000); return;
      case 'make-independent': if (!shared) fail(); shared = false; return;
      case 'reset-config': if (shared) fail(); backup = clone(config); config = { base: layer({ default: full() }, 'default'), axes: {}, notes: {}, armorMirror: config.armorMirror }; return;
      case 'match-kin': return fail('没有找到可共用的同角色配置');
      case 'slot-save': {
        const name = a.name || '1104-2300';
        saves = [{ key: 'Leon', name, own: true, label: name, data: clone(config) }, ...saves.filter(s => !(s.own && s.name === name))]; return;
      }
      case 'slot-load': { const s = saves.find(item => item.key === a.key && item.name === a.name) ?? fail(); config = clone(s.data); return; }
      case 'slot-delete': { const before = saves.length; saves = saves.filter(s => !(s.own && s.name === a.name)); if (saves.length === before) fail(); return; }
      case 'restore': if (a.which === 'backup') { if (!backup) fail(); config = clone(backup); } return;
    }
    const l = layerOf(a.axis) ?? fail();
    const isBase = a.axis === undefined;
    const ruleOf = (preset: string) => l.rules.find(r => r.preset === preset && l.order.includes(r.preset));
    switch (a.kind) {
      case 'active': if (a.preset && !l.presets[a.preset]) fail(); l.active = a.preset; break;
      case 'auto': l.auto = a.enabled; break;
      case 'rule-delete': l.rules.splice(a.rule - 1, 1); break;
      case 'condition-add': {
        const def = defs.find(item => item.id === a.condition.type)!;
        const condition = { ...a.condition, label: def.label, known: true, valueLabel: def.options?.find(o => o.value === a.condition.value)?.label };
        const r = ruleOf(a.preset);
        if (r) { r.conditions.push(condition); r.logic = a.logic; } else l.rules.push(rule(a.preset, { conditions: [condition], logic: a.logic }));
        break;
      }
      case 'condition-delete': { const r = ruleOf(a.preset) ?? fail(); r.conditions.splice(a.index - 1, 1); if (!r.conditions.length && !r.hpDrive.enabled) l.rules.splice(l.rules.indexOf(r), 1); break; }
      case 'hold': (ruleOf(a.preset) ?? fail()).hold = Math.max(0, a.value); break;
      case 'dissolve': (ruleOf(a.preset) ?? fail()).dissolve.enabled = a.enabled; break;
      case 'dissolve-time': (ruleOf(a.preset) ?? fail()).dissolve[a.field === 'dissolve_hide_time' ? 'hideTime' : 'showTime'] = a.value; break;
      case 'hp-drive': {
        const r = ruleOf(a.preset);
        if (a.enabled) { if (r) r.hpDrive.enabled = true; else l.rules.push(rule(a.preset, { hpDrive: { enabled: true, upper: 100, lower: 0, invert: false } })); }
        else if (r) { r.hpDrive.enabled = false; if (!r.conditions.length) l.rules.splice(l.rules.indexOf(r), 1); }
        break;
      }
      case 'hp-bound': (ruleOf(a.preset) ?? fail()).hpDrive[a.field === 'dissolve_hp_upper' ? 'upper' : 'lower'] = a.value; break;
      case 'hp-invert': (ruleOf(a.preset) ?? fail()).hpDrive.invert = a.enabled; break;
      case 'preset-new': { const name = nextName(l, ''); l.presets[name] = isBase ? full() : {}; l.order.push(name); l.active = name; break; }
      case 'preset-duplicate': {
        if (!l.presets[a.preset]) fail();
        let i = 1; while (l.presets[`${a.preset}_${i}`]) i++;
        const name = `${a.preset}_${i}`;
        l.presets[name] = clone(l.presets[a.preset]); l.order.splice(l.order.indexOf(a.preset) + 1, 0, name); l.active = name; break;
      }
      case 'preset-rename':
        if (!a.name || l.presets[a.name] || !l.presets[a.preset]) fail('名称为空或已存在');
        l.presets[a.name] = l.presets[a.preset]; delete l.presets[a.preset]; l.order[l.order.indexOf(a.preset)] = a.name;
        if (l.active === a.preset) l.active = a.name; l.rules.forEach(r => { if (r.preset === a.preset) r.preset = a.name; }); break;
      case 'preset-move': {
        const from = l.order.indexOf(a.preset), to = from + a.offset;
        if (from < 0 || to < 0 || to >= l.order.length) fail('无法移动该项'); l.order.splice(to, 0, l.order.splice(from, 1)[0]); break;
      }
      case 'preset-delete':
        if (!l.presets[a.preset]) fail(); backup = clone(config);
        delete l.presets[a.preset]; l.order.splice(l.order.indexOf(a.preset), 1); if (l.active === a.preset) l.active = ''; break;
      case 'preset-recapture': if (!isBase || !l.presets[a.preset]) fail(); backup = clone(config); l.presets[a.preset] = full(Object.keys(shown.body).filter(m => !shown.body[m])); break;
      case 'material': {
        const values = l.presets[a.preset] ?? fail();
        const slot = values[a.slot] ??= {};
        if (isBase) { if (typeof a.value !== 'boolean') fail(); slot[a.material] = a.value; }
        else if (a.value === 'none') delete slot[a.material];
        else if (a.value === 'off' || a.value === 'on') slot[a.material] = a.value === 'on';
        else fail();
        break;
      }
      case 'slot-bulk': {
        const values = l.presets[a.preset] ?? fail();
        const slot = values[a.slot] ??= {};
        const names = catalog[a.slot] ?? fail();
        if (isBase && ['all_on', 'all_off', 'invert'].includes(a.op)) names.forEach(m => { slot[m] = a.op === 'invert' ? !(slot[m] !== false) : a.op === 'all_on'; });
        else if (!isBase && a.op === 'claim') names.forEach(m => { slot[m] = shown[a.slot][m] !== false; });
        else if (!isBase && a.op === 'release') values[a.slot] = {};
        else fail();
        break;
      }
    }
  }
  (window as Win).reffNativeCall = async (method, args) => {
    if (method === 'ui.status') return { ready: true, epoch: 1 };
    if (method === 'ui.layout.set') return { padding: 0, override: 0, defaultPadding: 24 };
    await wait();
    if (method === 'monkeysama.avm.snapshot') return snapshot();
    if (method === 'monkeysama.avm.documentation') return { sections: [{ id: 'usage', title: '日常使用', entries: [{ title: '角色', paragraphs: ['配置按角色保存。'] }] }] };
    if (method === 'monkeysama.avm.action') { calls.push(args); act(args as unknown as Re4Action); return snapshot(); }
    throw new Error(`RE4 fixture: unknown method ${method}`);
  };
  (window as Win).re4Calls = calls;
}
