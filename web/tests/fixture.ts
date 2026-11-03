import type { ConditionAction, ConditionDefinition, ConditionField, ConditionRule, Conditions, ImportFile, Snapshot } from '../src/types';
import { settingsFor } from './settings-schema';
import { documentationFor } from './documentation-fixture';

const targetGroups: Conditions['targets'] = [
  { name: '', label: '主预设', global: false, presets: ['日常', '战斗'] },
  { name: '上身', label: '上身', global: false, presets: ['完整上装', '无外套', '内衬'] },
  { name: '腰部装饰', label: '腰部装饰', global: false, presets: ['腰饰开启', '腰饰关闭'] },
  { name: '全局隐藏', label: '全局隐藏', global: true, presets: ['隐藏徽章'] },
];
function fixed(id: string, label: string, key: string, values: (string | number)[], labels: string[] = values.map(String)): ConditionDefinition {
  return { id, label, enabled: false, priority: 1, fields: [], canAdd: false, canRemove: false,
    rules: values.map((value, index) => ({ index: index + 1, label: labels[index], [key]: value, targets: [] })) };
}
function threshold(id: string, label: string, min: number): ConditionDefinition {
  return { id, label, enabled: true, priority: 1, canAdd: true, canRemove: true,
    fields: [{ key: 'threshold', label: id === 'hp' ? 'HP（%）' : 'Monster HP (%)', kind: 'number', min, max: 100, default: 50 }],
    rules: [{ index: 1, label, threshold: 50, targets: [{ index: 1, group: '上身', preset: '无外套' }] }, { index: 2, label, threshold: 25, targets: [] }] };
}
function wildsConditions(): Conditions {
  const damageFields: ConditionField[] = [
    { key: 'mode', label: '动作模式', kind: 'select', default: 1, options: [{ value: 1, label: '普通' }, { value: 2, label: '循环' }, { value: 3, label: '链式' }] },
    { key: 'condition_delay', label: '条件延迟（秒）', kind: 'number', min: 0, default: 0 },
    { key: 'duration', label: '持续时间（秒）', kind: 'number', min: 0, default: 5, modes: [1, 2] },
    { key: 'loop_inactive_time', label: '循环间隔（秒）', kind: 'number', min: 0, default: 0, modes: [2] },
    { key: 'loop_count', label: '循环次数（0 为无限）', kind: 'number', min: 0, default: 0, modes: [2] },
    { key: 'chain_loop_count', label: '链式循环次数（0 为无限）', kind: 'number', min: 0, default: 1, modes: [3] },
  ];
  return { enabled: true, canEnable: false, parallel: false, selected: 'hp', canTestHp: true, canTestDamage: true, targets: structuredClone(targetGroups), definitions: [
    { ...threshold('hp', '血量', 1), stateLabel: '76.0%' },
    fixed('weapon', '武器拔刀状态', 'state', ['sheathed', 'drawn'], ['收刀', '拔刀']),
    { id: 'damage', label: '受击', enabled: true, priority: 3, fields: damageFields, canAdd: false, canRemove: false, stateLabel: '未触发',
      rules: [{ index: 1, label: '受击', mode: 1, condition_delay: 0, duration: 5, loop_inactive_time: 0, loop_count: 0, chain_loop_count: 1,
        targets: [{ index: 1, group: '上身', preset: '完整上装' }], chain_nodes: [{ index: 1, duration: 1, targets: [] }] }] },
    fixed('spirit', '太刀气刃等级', 'level', [1, 2, 3, 4], ['无刃', '白刃', '黄刃', '红刃']),
    fixed('dual_blades', '双刀状态', 'state', ['normal', 'kijin', 'enhancement'], ['普通', '鬼人化', '鬼人强化']),
    fixed('switch_axe', '斩斧状态', 'state', ['sword_normal', 'sword_awakened', 'axe_normal', 'axe_enhanced']),
    fixed('insect_glaive', '操虫棍状态', 'state', ['none', 'white', 'orange', 'red', 'triple']),
    fixed('charge_blade', '盾斧状态', 'state', ['sword', 'axe', 'sword_shield', 'sword_sword', 'sword_shield_sword', 'axe_axe', 'triple']),
    fixed('greatsword_type', '大剑招式类型', 'state', ['0', '1', '2', '3', '5', 'other']),
    fixed('greatsword_level', '大剑蓄力等级', 'level', [0, 1, 2, 3]),
    fixed('bow_level', '弓蓄力等级', 'level', [1, 2, 3, 4]),
    fixed('hammer_level', '大锤蓄力等级', 'level', [0, 1, 2, 3]),
  ].map((definition, index) => ({ ...definition, priority: index + 1 })) };
}
function riseConditions(): Conditions {
  return { enabled: true, canEnable: true, parallel: false, selected: 'weapon', targets: structuredClone(targetGroups), definitions: [
    fixed('weapon', 'Weapon state', 'state', ['sheathed', 'drawn'], ['Sheathed', 'Drawn']),
    fixed('scroll', 'Switch Skill Swap', 'state', ['red', 'blue'], ['Red scroll', 'Blue scroll']),
    threshold('monster_hp', 'Monster HP', 0),
    fixed('longsword', 'Spirit level', 'level', [0, 1, 2, 3]),
    fixed('dual_blades', 'Dual blades', 'state', [0, 1, 2]),
    fixed('switch_axe', 'Switch axe', 'state', [0, 1, 2]),
    fixed('charge_axe', 'Charge blade', 'state', [0, 1, 2, 3, 4, 5]),
    fixed('greatsword_level', 'Great sword charge', 'level', [0, 1, 2, 3]),
    fixed('hammer', 'Hammer charge', 'level', [0, 1, 2]),
    fixed('bow', 'Bow charge', 'level', [0, 1, 2, 3]),
  ].map((definition, index) => ({ ...definition, priority: index + 1 })) };
}

// Browser-only fixture. It is not an entry in the production build.
const initial: Snapshot = {
  game: 'Wilds', version: '4.3.4', bodyId: 'ch03_001_0000', weapon: false, suspended: false, backupPending: false, canImport: false,
  groups: [{ name: '', label: '主预设', global: false }, { name: '上身', label: '上身', global: false }, { name: '腰部装饰', label: '腰部装饰', global: false }, { name: '全局隐藏', label: '全局隐藏', global: true }],
  group: '上身', presets: [{ name: '完整上装', default: true, active: false }, { name: '无外套', default: false, active: true }, { name: '内衬', default: false, active: false }], selectedPreset: '无外套',
  parts: ['头部', '身体', '手臂', '腰部', '腿部', '附加部件'].map((label, index) => ({ index, label, available: index !== 5, enabled: true, meshLocked: index === 0,
    materials: index === 5 ? [] : ['body_leather', 'body_lining', 'cape_outer', 'metal_trim', 'guild_emblem'].map((name, material) => ({ name: index === 1 ? name : `${['head', 'body', 'arm', 'waist', 'leg'][index]}_${name}`, enabled: material !== 2, hidden: material === 4, groups: material === 4 ? ['全局隐藏'] : material < 2 ? ['上身'] : [] })),
  })), theme: 'custom', language: 'zh-CN', selectionMode: false, pending: {}, conditions: wildsConditions(), settings: settingsFor('Wilds'),
};
let state = structuredClone(initial);
let failNext = false;
let failNextDocumentation = false;
let slowNextDocumentation = false;
let failNextImports = false;
let slowNextImports = false;
let emptyImports = false;
let emptyTables = false;
let active = 0;
let peak = 0;
let polls = 0;
const calls: Record<string, unknown>[] = [];
const documents: { game: Snapshot['game']; language: string }[] = [];
const imports: { bodyId: string; weapon: boolean }[] = [];
const importFiles: ImportFile[] = [
  { path: 'ArmorVariantManager/pl001_0000.json', name: 'pl001_0000.json' },
  { path: 'ArmorVariantManager/pl001_0000.json.backup', name: 'pl001_0000.json [backup]' },
  { path: 'ArmorVariantManager/wp00_0000.json', name: 'wp00_0000.json' },
];
let status: HTMLOutputElement | undefined;
function renderStatus() { if (status) status.textContent = JSON.stringify({ polls, peak, calls, documents, imports }); }
const wait = (delay = 120) => new Promise(resolve => setTimeout(resolve, delay));
function applyCondition(request: ConditionAction) {
  const conditions = state.conditions!;
  if (request.op === 'parallel') { conditions.parallel = !!request.value; return; }
  if (request.op === 'enabled') { conditions.enabled = !!request.value; return; }
  if (request.op === 'select') { conditions.selected = String(request.value); return; }
  if (request.op === 'test_hp' || request.op === 'test_damage') return;
  const definition = conditions.definitions.find(item => item.id === request.condition)!;
  if (request.op === 'setting') {
    if (request.field === 'enabled') definition.enabled = !!request.value; else definition.priority = Number(request.value);
    return;
  }
  if (request.op === 'rule_add') {
    const rule: ConditionRule = { index: definition.rules.length + 1, label: definition.label, targets: [] };
    definition.fields.forEach(field => { rule[field.key] = field.default; }); definition.rules.push(rule); return;
  }
  if (request.op === 'rule_delete') { definition.rules.splice(request.rule! - 1, 1); definition.rules.forEach((rule, index) => { rule.index = index + 1; }); return; }
  const rule = definition.rules[request.rule! - 1];
  if (request.op === 'rule_set') { rule[request.field!] = request.value as string | number; return; }
  if (request.op === 'chain_add') { rule.chain_nodes!.push({ index: rule.chain_nodes!.length + 1, duration: 1, targets: [] }); return; }
  if (request.op === 'chain_delete') { rule.chain_nodes!.splice(request.node! - 1, 1); rule.chain_nodes!.forEach((node, index) => { node.index = index + 1; }); return; }
  const node = request.node ? rule.chain_nodes![request.node - 1] : undefined;
  if (request.op === 'chain_set') { node!.duration = Number(request.value); return; }
  const targets = (node ?? rule).targets;
  if (request.op === 'target_add') { targets.push({ index: targets.length + 1, group: '', preset: state.game === 'Rise' ? '日常' : '' }); return; }
  if (request.op === 'target_delete') { targets.splice(request.target! - 1, 1); targets.forEach((target, index) => { target.index = index + 1; }); return; }
  const target = targets[request.target! - 1];
  if (request.field === 'group') { target.group = String(request.value); target.preset = ''; }
  else target.preset = String(request.value);
}
(window as Window & { reffNativeCall?: (method: string, params: Record<string, unknown>) => Promise<unknown> }).reffNativeCall = async (method, params) => {
  if (method === 'ui.status') return { ready: true, epoch: 1 };
  if (!['monkeysama.avm.snapshot', 'monkeysama.avm.action', 'monkeysama.avm.documentation', 'monkeysama.avm.imports'].includes(method)) throw new Error(`Fixture: unknown method ${method}`);
  active += 1; peak = Math.max(active, peak);
  try {
    if (method === 'monkeysama.avm.documentation') {
      documents.push({ game: state.game, language: state.language }); renderStatus();
      const value = documentationFor(state.game, state.language);
      const delay = slowNextDocumentation ? 1400 : 120; slowNextDocumentation = false;
      await wait(delay);
      if (failNextDocumentation) { failNextDocumentation = false; throw new Error('测试：帮助读取失败'); }
      return value;
    }
    if (method === 'monkeysama.avm.imports') {
      imports.push({ bodyId: state.bodyId, weapon: state.weapon }); renderStatus();
      const value = { bodyId: state.bodyId, files: emptyImports ? {} : importFiles.filter(file => state.weapon || !file.name.startsWith('wp')) };
      const delay = slowNextImports ? 1400 : 120; slowNextImports = false;
      await wait(delay);
      if (failNextImports) { failNextImports = false; throw new Error('测试：无法读取配置目录'); }
      return structuredClone(value);
    }
    await wait();
    if (method === 'monkeysama.avm.snapshot') {
      polls += 1;
      if (emptyTables) return { ...structuredClone(state), bodyId: '', groups: null, presets: {}, parts: null, pending: null, conditions: null };
      return { ...structuredClone(state), conditions: state.bodyId ? structuredClone(state.conditions) : null };
    }
    calls.push(params);
    if (failNext) { failNext = false; throw new Error('测试：保存失败，名称已保留'); }
    const kind = params.kind as string;
    if (!['theme', 'mode', 'setting'].includes(kind) && params.bodyId !== state.bodyId) throw new Error('装备已变化，请重试');
    if (kind === 'condition') applyCondition(params as unknown as ConditionAction);
    else if (kind === 'theme') state.theme = params.value as Snapshot['theme'];
    else if (kind === 'setting') {
      const field = state.settings!.sections.flatMap(section => section.fields).find(field => field.id === params.id);
      if (!field || field.disabled) throw new Error(field?.reason ?? '设置不存在');
      const section = state.settings!.sections.find(section => section.fields.includes(field))!;
      if (section.scope === 'equipment' && (!state.bodyId || state.weapon || params.bodyId !== state.bodyId)) throw new Error('当前装备不支持该设置');
      if (field.id === 'portrait_camera.reset') {
        const defaults = { distance: 2.8, horizontal: 0, vertical: 0, light_intensity: 1, refresh_fps: 30 };
        for (const [key, value] of Object.entries(defaults)) section.fields.find(item => item.id === 'portrait_camera.' + key)!.value = value;
      } else field.value = params.value as typeof field.value;
      if (field.id === 'language') state.language = field.value === 'en' ? 'en-US' : 'zh-CN';
    } else if (kind === 'reorder-group' || kind === 'reorder-preset') {
      const items = kind === 'reorder-group' ? state.groups.filter(item => item.name !== '') : state.presets;
      const index = items.findIndex(item => item.name === params.name), target = index + Number(params.offset);
      if (index < 0 || target < 0 || target >= items.length) throw new Error('无法移动该项');
      [items[index], items[target]] = [items[target], items[index]];
      if (kind === 'reorder-group') state.groups = [state.groups.find(item => item.name === '')!, ...(items as Snapshot['groups'])];
    }
    else if (kind === 'mode') { state.weapon = !!params.weapon; state.bodyId = state.weapon ? 'wp00_000_0000' : initial.bodyId; }
    else if (kind === 'group') { state.group = String(params.name); state.selectedPreset = ''; }
    else if (kind === 'preset' || kind === 'save') {
      const name = String(params.name);
      if (!state.presets.some(item => item.name === name)) state.presets.push({ name, active: false, default: false });
      state.selectedPreset = name; state.presets.forEach(item => { item.active = item.name === name; });
    } else if (kind === 'default') state.presets.forEach(item => { item.default = item.name === params.name; });
    else if (kind === 'delete-preset') { state.presets = state.presets.filter(item => item.name !== params.name); state.selectedPreset = ''; }
    else if (kind === 'delete-group') { state.groups = state.groups.filter(item => item.name !== params.name); state.group = ''; }
    else if (kind === 'create-group') { state.groups.push({ name: String(params.name), label: String(params.name), global: !!params.global }); state.group = String(params.name); state.selectionMode = false; }
    else if (kind === 'selection') state.selectionMode = !!params.enabled;
    else if (kind === 'select-material') { const part = String(params.part); state.pending[part] ??= {}; state.pending[part][String(params.name)] = !!params.enabled; }
    else if (kind === 'mesh') { const part = state.parts.find(item => item.index === params.part); if (part) part.enabled = !!params.enabled; }
    else if (kind === 'material') { const material = state.parts.find(item => item.index === params.part)?.materials.find(item => item.name === params.name); if (material) material.enabled = !!params.enabled; }
    else if (kind === 'restore') { state.backupPending = false; state.parts.forEach(part => { part.enabled = true; part.materials.forEach(material => { material.enabled = true; }); }); }
    else if (kind === 'dismiss-backup') state.backupPending = false;
    else if (kind === 'import-preset') {
      if (!state.canImport || !importFiles.some(file => file.path === params.path)) throw new Error('无法导入该文件');
      state.group = ''; state.groups = [{ name: '', label: 'Main presets', global: false }];
      state.presets = [{ name: 'Imported preset', default: true, active: true }]; state.selectedPreset = 'Imported preset';
      state.backupPending = false;
    }
    return structuredClone(state);
  } finally { active -= 1; renderStatus(); }
};
window.addEventListener('message', event => {
  if (event.data?.type === 'reff:request') window.postMessage({ type: 'reff:response', id: event.data.id, ok: true, result: {} }, '*');
});

if (new URLSearchParams(location.search).has('controls')) {
  const toolbar = document.querySelector<HTMLDivElement>('#fixture-controls')!;
  toolbar.style.cssText = 'padding:8px;display:flex;gap:8px;flex-wrap:wrap;background:#ddd;color:#111;font:12px sans-serif';
  const add = (name: string, action: () => void) => { const button = document.createElement('button'); button.textContent = name; button.onclick = action; toolbar.append(button); };
  add('Fail next action', () => { failNext = true; });
  add('Backup pending', () => { state.backupPending = true; });
  add('Other equipment', () => { state.bodyId = 'ch03_002_0000'; });
  add('Fail next help', () => { failNextDocumentation = true; });
  add('Slow next help', () => { slowNextDocumentation = true; });
  add('Fail next imports', () => { failNextImports = true; });
  add('Slow next imports', () => { slowNextImports = true; });
  add('Empty import list', () => { emptyImports = !emptyImports; });
  add('No character', () => { state.bodyId = ''; });
  add('Restore character', () => { state.bodyId = initial.bodyId; });
  add('Empty Lua tables', () => { emptyTables = !emptyTables; });
  add('English / Rise', () => { state.language = 'en-US'; state.game = 'Rise'; state.canImport = true; state.conditions = riseConditions(); state.settings = settingsFor('Rise'); });
  add('Chinese / Wilds', () => { state.language = 'zh-CN'; state.game = 'Wilds'; state.canImport = false; state.conditions = wildsConditions(); state.settings = settingsFor('Wilds'); });
  add('English only', () => { state.language = 'en-US'; });
  add('Chinese only', () => { state.language = 'zh-CN'; });
  add('Rise only', () => { state.game = 'Rise'; state.canImport = true; state.conditions = riseConditions(); state.settings = settingsFor('Rise'); });
  add('Preview unavailable', () => { state.settings!.sections.find(section => section.id === 'preview')?.fields.forEach(field => { field.disabled = true; field.reason = '预览模块未加载'; }); });
  add('Condition warning', () => { state.conditions!.definitions[0].warning = '生命值模块尚未初始化'; });
  add('REFF amber', () => window.postMessage({ type: 'reff:preferences', preferences: { language: 'zh-CN', appearance: { preset: 'amber', accent: '#f1ba68', background: '#201c17', surface: '#2b251d', backgroundOpacity: .94, cornerRadius: 6, surfaceBlur: 8, textScale: 1 } } }, '*'));
  add('REFF violet / 140%', () => window.postMessage({ type: 'reff:preferences', preferences: { language: 'zh-CN', appearance: { preset: 'violet', accent: '#c8a0ef', background: '#1b1823', surface: '#272031', backgroundOpacity: .94, cornerRadius: 6, surfaceBlur: 8, textScale: 1.4 } } }, '*'));
  status = document.createElement('output'); status.style.cssText = 'flex-basis:100%;max-height:60px;overflow:auto'; toolbar.append(status); renderStatus();
}
void import('../src/main');
