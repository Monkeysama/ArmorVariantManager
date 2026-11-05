// RE4 的 REFF 数据契约，与 Games/RE4/Reff.lua 的 snapshot / action 一一对应。
// RE4 的模型是「整套造型 + 状态组 + 每个状态一条规则」，不复用 MH 的分组 / 预设类型。

export type Re4Op = '<=' | '<' | '>=' | '>' | '==' | '~=';
export interface Re4ConditionOption { value: number | string; label: string }
export interface Re4ConditionDef {
  id: string; kind: 'bool' | 'number' | 'enum'; label: string;
  ops?: Re4Op[]; options?: Re4ConditionOption[]; value?: number | boolean;
}
export interface Re4Condition {
  type: string; op?: Re4Op; value: number | string | boolean; label: string; known: boolean; valueLabel?: string;
}
export interface Re4Rule {
  index: number; preset: string; priority?: number; logic: 'AND' | 'OR'; hold: number;
  conditions: Re4Condition[]; hits: boolean; effective: boolean; orphan: boolean;
  dissolve: { enabled: boolean; hideTime: number; showTime: number };
  hpDrive: { enabled: boolean; upper: number; lower: number; invert: boolean };
}
// 预设里存的材质值：槛位 -> 材质名 -> 开/关。整套造型是整份快照；状态组稀疏，没写的材质 = 不管。
export type Re4PresetValues = Record<string, Record<string, boolean>>;
// 整套造型的逐槛位闸门：全部对不上 = mismatch（整份跳过），部分对不上 = partial。
export interface Re4Match { status: 'ok' | 'partial' | 'mismatch'; skipped: string[] }
export interface Re4Layer {
  name: string; base: boolean; presets: string[]; active: string; effective?: string;
  fromRule: boolean; auto: boolean; advanced: boolean; rules: Re4Rule[];
  values: Record<string, Re4PresetValues>; match?: Record<string, Re4Match>;
}
export interface Re4Material { name: string; enabled: boolean; note?: string }
export interface Re4Slot { id: string; label: string; mirrored: boolean; materials: Re4Material[] }
export interface Re4Conflict { key: string; parts: { axis: string; on: boolean; off: boolean }[] }
export interface Re4Editor {
  armorMirror: boolean; slots: Re4Slot[]; conflicts: Re4Conflict[]; locating?: { slot: string; material: string };
}
export interface Re4Ownership { shared: boolean; canReset: boolean; canMatchKin: boolean }
export interface Re4SaveSlot { key: string; name: string; own: boolean; label: string }
export interface Re4Saves { slots: Re4SaveSlot[]; hasBackup: boolean; hasOnload: boolean }
export interface Re4Character { id: string; label: string; configured: boolean; targets: string[] }
export interface Re4Settings { weaponHideStorage: boolean; uiDissolveEnabled: boolean; uiDissolveTime: number }
export interface Re4Snapshot {
  game: 'RE4'; version: string; language: 'zh' | 'en';
  settings: Re4Settings; characters: Re4Character[]; character: string; sharedWith?: string;
  status?: { hp?: number; flags: string[] };
  conditions?: Re4ConditionDef[]; base?: Re4Layer; axes?: Re4Layer[];
  editor?: Re4Editor; ownership?: Re4Ownership; saves?: Re4Saves;
}

// 层：axis 省略 = 整套造型；带 character，角色在两次刷新之间变了 Lua 端会拒绝。
type LayerTarget = { character: string; axis?: string };
type PresetTarget = LayerTarget & { preset: string };
export type Re4Action =
  | { kind: 'character'; id: string }
  | { kind: 'setting'; id: 'language'; value: 'zh' | 'en' }
  | { kind: 'setting'; id: 'weapon_hide_storage' | 'ui_dissolve_enabled'; value: boolean }
  | { kind: 'setting'; id: 'ui_dissolve_time'; value: number }
  | (PresetTarget & { kind: 'active' })
  | (LayerTarget & { kind: 'auto'; enabled: boolean })
  | (LayerTarget & { kind: 'rule-delete'; rule: number })
  | (PresetTarget & { kind: 'condition-add'; condition: { type: string; op?: Re4Op; value: number | string | boolean }; logic: 'AND' | 'OR' })
  | (PresetTarget & { kind: 'condition-delete'; index: number })
  | (PresetTarget & { kind: 'hold'; value: number })
  | (PresetTarget & { kind: 'dissolve' | 'hp-drive' | 'hp-invert'; enabled: boolean })
  | (PresetTarget & { kind: 'dissolve-time'; field: 'dissolve_hide_time' | 'dissolve_show_time'; value: number })
  | (PresetTarget & { kind: 'hp-bound'; field: 'dissolve_hp_upper' | 'dissolve_hp_lower'; value: number })
  // 编辑：整套造型的材质是 true/false，状态组是 none（不管）/ off / on
  | (LayerTarget & { kind: 'preset-new' })
  | (PresetTarget & { kind: 'preset-duplicate' | 'preset-delete' | 'preset-recapture' })
  | (PresetTarget & { kind: 'preset-rename'; name: string })
  | (PresetTarget & { kind: 'preset-move'; offset: -1 | 1 })
  | (PresetTarget & { kind: 'material'; slot: string; material: string; value: boolean | 'none' | 'off' | 'on' })
  | (PresetTarget & { kind: 'slot-bulk'; slot: string; op: 'all_on' | 'all_off' | 'invert' | 'claim' | 'release' })
  | { kind: 'axis-new'; character: string; name: string }
  | { kind: 'axis-rename'; character: string; axis: string; name: string }
  | { kind: 'axis-delete'; character: string; axis: string }
  | { kind: 'armor-mirror'; character: string; enabled: boolean }
  | { kind: 'note'; character: string; slot: string; material: string; text: string }
  | { kind: 'locate'; character: string; slot: string; material: string }
  // 归属与存档
  | { kind: 'make-independent' | 'reset-config' | 'match-kin'; character: string }
  | { kind: 'slot-save'; character: string; name: string }
  | { kind: 'slot-load'; character: string; key: string; name: string }
  | { kind: 'slot-delete'; character: string; name: string }
  | { kind: 'restore'; character: string; which: 'backup' | 'onload' };
export type Re4Perform = (actions: Re4Action | Re4Action[]) => Promise<boolean>;
