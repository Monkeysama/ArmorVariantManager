import type { Snapshot } from '../src/types';

// Browser-only fixture. It is not an entry in the production build.
const initial: Snapshot = {
  game: 'Wilds', version: '4.3.4', bodyId: 'ch03_001_0000', weapon: false, suspended: false,
  groups: [{ name: '', label: '主预设', global: false }, { name: '上身', label: '上身', global: false }, { name: '腰部装饰', label: '腰部装饰', global: false }, { name: '全局隐藏', label: '全局隐藏', global: true }],
  group: '上身', presets: [{ name: '完整上装', default: true, active: false }, { name: '无外套', default: false, active: true }, { name: '内衬', default: false, active: false }], selectedPreset: '无外套',
  parts: ['头部', '身体', '手臂', '腰部', '腿部', '附加部件'].map((label, index) => ({ index, label, available: index !== 5, enabled: true, meshLocked: index === 0,
    materials: index === 5 ? [] : ['body_leather', 'body_lining', 'cape_outer', 'metal_trim', 'guild_emblem'].map((name, material) => ({ name: index === 1 ? name : `${['head', 'body', 'arm', 'waist', 'leg'][index]}_${name}`, enabled: material !== 2, hidden: material === 4, groups: material === 4 ? ['全局隐藏'] : material < 2 ? ['上身'] : [] })),
  })), theme: 'custom', language: 'zh-CN', selectionMode: false, pending: {},
};
let state = structuredClone(initial);
let failNext = false;
let emptyTables = false;
let active = 0;
let peak = 0;
let polls = 0;
const calls: Record<string, unknown>[] = [];
let status: HTMLOutputElement | undefined;
function renderStatus() { if (status) status.textContent = JSON.stringify({ polls, peak, calls }); }
const wait = () => new Promise(resolve => setTimeout(resolve, 120));
(window as Window & { reffNativeCall?: (method: string, params: Record<string, unknown>) => Promise<unknown> }).reffNativeCall = async (method, params) => {
  if (method === 'ui.status') return { ready: true, epoch: 1 };
  if (method !== 'monkeysama.avm.snapshot' && method !== 'monkeysama.avm.action') throw new Error(`Fixture: unknown method ${method}`);
  active += 1; peak = Math.max(active, peak);
  try {
    await wait();
    if (method === 'monkeysama.avm.snapshot') {
      polls += 1;
      if (emptyTables) return { ...structuredClone(state), bodyId: '', groups: null, presets: {}, parts: null, pending: null };
      return structuredClone(state);
    }
    calls.push(params);
    if (failNext) { failNext = false; throw new Error('测试：保存失败，名称已保留'); }
    const kind = params.kind as string;
    if (!['theme', 'mode'].includes(kind) && params.bodyId !== state.bodyId) throw new Error('装备已变化，请重试');
    if (kind === 'theme') state.theme = params.value as Snapshot['theme'];
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
    else if (kind === 'restore') state.parts.forEach(part => { part.enabled = true; part.materials.forEach(material => { material.enabled = true; }); });
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
  add('No character', () => { state.bodyId = ''; });
  add('Restore character', () => { state.bodyId = initial.bodyId; });
  add('Empty Lua tables', () => { emptyTables = !emptyTables; });
  add('English / Rise', () => { state.language = 'en-US'; state.game = 'Rise'; });
  add('REFF amber', () => window.postMessage({ type: 'reff:preferences', preferences: { language: 'zh-CN', appearance: { preset: 'amber', accent: '#f1ba68', background: '#201c17', surface: '#2b251d', backgroundOpacity: .94, cornerRadius: 6, surfaceBlur: 8, textScale: 1 } } }, '*'));
  add('REFF violet / 140%', () => window.postMessage({ type: 'reff:preferences', preferences: { language: 'zh-CN', appearance: { preset: 'violet', accent: '#c8a0ef', background: '#1b1823', surface: '#272031', backgroundOpacity: .94, cornerRadius: 6, surfaceBlur: 8, textScale: 1.4 } } }, '*'));
  status = document.createElement('output'); status.style.cssText = 'flex-basis:100%;max-height:60px;overflow:auto'; toolbar.append(status); renderStatus();
}
void import('../src/main');
