// RE4 的 REFF 数据契约，与 Games/RE4/Reff.lua 的 snapshot / action 一一对应。
// v3 模型：整套造型 + 平铺的状态组（显式作用域）+ 按优先级排列的条件状态 + 预设库。
// v2 配置只给角色、设置和"迁移旧配置"入口（configVersion = 2）。

export type Re4Op = '<=' | '<' | '>=' | '>' | '==' | '~=';
export type Re4Category = 'hp' | 'combat' | 'move' | 'damage' | 'other';
export interface Re4ConditionOption { value: number | string; label: string }
export interface Re4ConditionDef {
  id: string; kind: 'bool' | 'number' | 'enum'; label: string; category: Re4Category;
  ops?: Re4Op[]; options?: Re4ConditionOption[]; value?: number | boolean;
}
export interface Re4Character { id: string; label: string; configured: boolean; targets: string[] }
export interface Re4Settings {
  weaponHideStorage: boolean; uiDissolveEnabled: boolean; uiDissolveTime: number;
  previewDistance?: number; previewHeight?: number;
}
// 全身预览(和荒野同一个原生插件);只在装了预览插件和新版 REFF 时可用
export interface Re4Preview { available: boolean; enabled: boolean; status: string; error?: string }

// 认领结果：win = 这一处由它决定；lose = 被第 by 个条件状态覆盖；broken = 引用的组 / 选项不存在
export interface Re4Result { kind: 'win' | 'lose' | 'broken'; by?: number }
export type Re4StateKind = 'active' | 'partial' | 'outranked' | 'idle' | 'off' | 'paused';
export interface Re4StateCondition {
  type: string; op?: Re4Op; value: number | string | boolean; label: string; known: boolean; valueLabel?: string; met?: boolean;
}
export interface Re4StateTarget { group: string; option: string; result?: Re4Result }
export interface Re4State {
  name: string; enabled: boolean; exclusive: boolean; logic: 'AND' | 'OR'; hold: number; fadeIn: number; fadeOut: number;
  hp?: { upper: number; lower: number; invert: boolean };
  base?: string; baseResult?: Re4Result; targets: Re4StateTarget[]; conditions: Re4StateCondition[];
  kind: Re4StateKind; by?: number; holding: boolean;
}

// 材质值：键是 "slot/材质"。整套造型是整份（每个材质都有值）；状态组稀疏，没写 = 不管
export type Re4Values = Record<string, boolean>;
export interface Re4Match { status: 'ok' | 'partial' | 'mismatch'; skipped: string[] }
export interface Re4BasePreset { name: string; values: Re4Values; match: Re4Match }
export interface Re4Base { active: string; effective?: string; fromState?: number; presets: Re4BasePreset[] }
export interface Re4Option { name: string; values: Re4Values }
export interface Re4Group { name: string; scope: string[]; active: string; effective?: string; fromState?: number; options: Re4Option[] }

export interface Re4Material { name: string; note?: string }
export interface Re4Slot { id: string; label: string; mirrored: boolean; materials: Re4Material[] }
export interface Re4Look { slot: string; material: string; on: boolean }

export type Re4Fit = 'full' | 'partial' | 'none';
export interface Re4PresetEntry { id: string; name: string; source: 'user' | 'mod'; match: Re4Fit }
export interface Re4Presets {
  current?: Re4Fit; source?: { id: string; name: string; own: boolean }; dismissed: boolean;
  list: Re4PresetEntry[]; better: { id: string; name: string }[]; autosaves: { name: string; time: number }[];
}
export interface Re4Notice { kind: 'migrated'; overlaps: number; presets: number }

export interface Re4Snapshot {
  game: 'RE4'; version: string; language: 'zh' | 'en';
  settings: Re4Settings; characters: Re4Character[]; character: string;
  configVersion?: 2 | 3; notice?: Re4Notice; preview?: Re4Preview;
  // 以下只在 v3 配置时出现
  status?: { hp?: number; flags: string[] };
  conditions?: Re4ConditionDef[];
  auto?: boolean; armorMirror?: boolean;
  slots?: Re4Slot[]; look?: Re4Look[];
  base?: Re4Base; groups?: Re4Group[]; states?: Re4State[];
  locating?: { slot: string; material: string };
  presets?: Re4Presets;
  backups?: { hasBackup: boolean; hasOnload: boolean };
}

export type Re4ConditionInput = { type: string; op?: Re4Op; value: number | string | boolean };
type C = { character: string };
export type Re4Action =
  | { kind: 'character'; id: string }
  | { kind: 'setting'; id: 'weapon_hide_storage' | 'ui_dissolve_enabled' | 'ui_dissolve_time' | 'portrait_enabled' | 'portrait_distance' | 'portrait_height'; value: boolean | number }
  | C & { kind: 'migrate' }
  | C & { kind: 'manual'; layer: string; option: string }
  | C & { kind: 'auto'; enabled: boolean }
  | C & { kind: 'armor-mirror'; enabled: boolean }
  | C & { kind: 'note'; slot: string; material: string; text: string }
  | C & { kind: 'locate'; slot: string; material: string }
  | C & { kind: 'base-new' }
  | C & { kind: 'base-duplicate' | 'base-delete' | 'base-recapture'; preset: string }
  | C & { kind: 'base-rename'; preset: string; name: string }
  | C & { kind: 'base-move'; preset: string; offset: number }
  | C & { kind: 'base-material'; preset: string; slot: string; material: string; value: boolean }
  | C & { kind: 'group-new'; name: string }
  | C & { kind: 'group-rename'; group: string; name: string }
  | C & { kind: 'group-move'; group: string; offset: number }
  | C & { kind: 'group-delete'; group: string }
  | C & { kind: 'scope-add' | 'scope-remove'; group: string; slot: string; material: string }
  | C & { kind: 'option-new'; group: string; name?: string }
  | C & { kind: 'option-duplicate' | 'option-delete'; group: string; option: string }
  | C & { kind: 'option-rename'; group: string; option: string; name: string }
  | C & { kind: 'option-move'; group: string; option: string; offset: number }
  | C & { kind: 'option-material'; group: string; option: string; slot: string; material: string; value: 'none' | 'off' | 'on' }
  | C & { kind: 'state-new'; name: string }
  | C & { kind: 'state-delete'; index: number }
  | C & { kind: 'state-move'; from: number; to: number }
  | C & { kind: 'state-rename'; index: number; name: string }
  | C & { kind: 'state-field'; index: number; field: 'enabled' | 'exclusive'; value: boolean }
  | C & { kind: 'state-field'; index: number; field: 'logic'; value: 'AND' | 'OR' }
  | C & { kind: 'state-field'; index: number; field: 'hold' | 'fade_in' | 'fade_out'; value: number }
  | C & { kind: 'state-hp'; index: number; hp?: { upper: number; lower: number; invert: boolean } }
  | C & { kind: 'state-base'; index: number; preset?: string }
  | C & { kind: 'state-target'; index: number; group: string; option: string }
  | C & { kind: 'state-target-group'; index: number; target: number; group: string }
  | C & { kind: 'state-target-remove'; index: number; target: number }
  | C & { kind: 'condition-add'; index: number; condition: Re4ConditionInput }
  | C & { kind: 'condition-set'; index: number; condition_index: number; condition: Re4ConditionInput }
  | C & { kind: 'condition-delete'; index: number; condition_index: number }
  | C & { kind: 'preset-apply' | 'preset-delete'; id: string }
  | C & { kind: 'preset-rename'; id: string; name: string }
  | C & { kind: 'preset-save'; name: string }
  | C & { kind: 'preset-update' | 'preset-dismiss' }
  | C & { kind: 'autosave-restore'; index: number }
  | C & { kind: 'autosave-promote'; index: number; name: string }
  | C & { kind: 'restore'; which: 'backup' | 'onload' };

// 子组件只拿到这个：一次一个或一串操作，结果是否成功
export type Re4Perform = (actions: Re4Action | Re4Action[]) => Promise<boolean>;
