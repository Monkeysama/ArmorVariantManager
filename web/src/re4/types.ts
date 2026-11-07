// RE4 的 REFF 数据契约，与 Games/RE4/Reff.lua 的 snapshot / action 一一对应。
// v3 模型：整套造型 + 平铺的状态组（显式作用域）+ 按优先级排列的条件状态 + 预设库。
// v2 配置只给角色、设置和"迁移旧配置"入口（configVersion = 2）。

export type Re4Op = '<=' | '<' | '>=' | '>' | '==' | '~=';
export type Re4Category = 'hp' | 'combat' | 'move' | 'damage' | 'other';
export interface Re4ConditionOption { value: number | string; label: string }
export interface Re4ConditionDef {
  id: string; kind: 'bool' | 'number' | 'enum'; label: string; category: Re4Category;
  ops?: Re4Op[]; options?: Re4ConditionOption[]; value?: number | boolean;
  // 被合成条件取代的旧布尔:下拉框里不列(已经在用它的条件照常显示)
  legacy?: boolean;
}
export interface Re4Character { id: string; label: string; configured: boolean; targets: string[] }
export interface Re4Settings {
  weaponHideStorage: boolean; uiDissolveEnabled: boolean; uiDissolveTime: number;
  previewDistance?: number; previewHeight?: number; blockGameMouse?: boolean; heightEnabled?: boolean;
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
  // 命中时叠加的调色方案；paletteResult：win = 生效 / lose = 被独占状态挡住 / broken = 方案不存在
  palette?: string; paletteResult?: Re4Result;
}

// 材质值：键是 "slot/材质"。整套造型是整份（每个材质都有值）；状态组稀疏，没写 = 不管
export type Re4Values = Record<string, boolean>;
export interface Re4Match { status: 'ok' | 'partial' | 'mismatch'; skipped: string[] }
// height:这个预设 / 选项设的模型高度（厘米）；没有 = 这一层不管高度
// palette:选中这个预设 / 选项时叠加的调色方案（可能指向已删除的方案）
export interface Re4BasePreset { name: string; values: Re4Values; match: Re4Match; height?: number; palette?: string }
export interface Re4Base { active: string; effective?: string; fromState?: number; presets: Re4BasePreset[] }
export interface Re4Option { name: string; values: Re4Values; height?: number; palette?: string }
export interface Re4Group { name: string; active: string; effective?: string; fromState?: number; options: Re4Option[] }

export interface Re4Material { name: string; note?: string }
export interface Re4Slot { id: string; label: string; mirrored: boolean; materials: Re4Material[] }
export interface Re4Look { slot: string; material: string; on: boolean }

export type Re4Fit = 'full' | 'partial' | 'none';
export interface Re4PresetEntry { id: string; name: string; source: 'user' | 'mod'; match: Re4Fit }
export interface Re4Presets {
  current?: Re4Fit; source?: { id: string; name: string; own: boolean }; dismissed: boolean;
  list: Re4PresetEntry[]; better: { id: string; name: string }[]; autosaves: { name: string; time: number }[];
}
// palette-exported:exact = 取自 mod 的 mdf2;否则 reason 写明为什么读不到、只用了运行时数据
export type Re4Notice = { kind: 'migrated'; presets: number } | { kind: 'palette-exported'; path: string; exact?: boolean; reason?: string }
  | { kind: 'mdf-replaced'; path: string };

// 调色盘（Lua 的 Palette.lua / tools/re4/material_profiles）
export type Re4Text = { zh?: string; en?: string };
export type Re4Comp = 'x' | 'y' | 'z' | 'w';
export interface Re4PaletteOption { value: number; label: Re4Text }
export interface Re4PaletteEntry {
  param: string; kind: 'color' | 'float' | 'enum' | 'bool' | 'vec'; component?: Re4Comp; channels?: 'rgb' | 'rgba';
  min?: number; max?: number; step?: number; hard_min?: number; hard_max?: number;
  enum?: string; options?: Re4PaletteOption[]; labels?: { zh?: string[]; en?: string[] };
  tier?: 'basic' | 'more' | 'other'; label?: Re4Text; note?: Re4Text;
}
export interface Re4PaletteGroup { id: string; tier: 'basic' | 'more' | 'other'; section?: string; label?: Re4Text; note?: Re4Text; params: Re4PaletteEntry[] }
export interface Re4PaletteSection { id: string; label?: Re4Text }
export interface Re4PaletteProfile { id: string; label: Re4Text; addon: boolean; enums: Record<string, Re4PaletteOption[]>; groups: Re4PaletteGroup[]; sections: Re4PaletteSection[] }
export interface Re4PaletteMaterial {
  key: string; slot: string; material: string; note?: string; main?: string; addons: string[];
  missing: string[]; generic?: string[]; overridden: number;
  // 贴图槽绑了默认(null)贴图而改了不生效的参数:comps = 失效的分量,why = 哪个槽绑了哪张 null 贴图
  ineffective?: Record<string, { comps: string; why: { texture: string; null: string }[] }>;
  // 「替换 mdf」能不能用:ok / packed(不是松散文件)/ plugin(原生插件太旧);没有 = 读不到 mdf2 路径
  replace?: 'ok' | 'packed' | 'plugin';
}
// 当前值：float 是数字，float4 是 [x, y, z, w]；覆盖值：float 是数字，float4 只有改过的分量
export type Re4PaletteValue = number | [number, number, number, number];
export type Re4PaletteOverride = number | Partial<Record<Re4Comp, number>>;
export interface Re4Palette {
  materials: Re4PaletteMaterial[]; profiles: Record<string, Re4PaletteProfile>;
  values: Record<string, Record<string, Re4PaletteValue>>;
  overrides: Record<string, Record<string, Re4PaletteOverride> | false>;
  selected: string[]; errors: string[]; error?: string;
  replacing?: boolean;   // 替换 mdf 正在等新 mdf2 加载
  scheme: string;        // 选中的方案（选中就生效，调色页也编辑它）："" = 初始（mdf2 原值，只读）；overrides / overridden 都按它
}
// 调色方案（子预设）：used = 被引用几次，materials = 改了几个材质
export interface Re4PaletteScheme { name: string; used: number; materials: number }
// active：这一帧生效的方案（从下到上叠加：选中的 → 被引用的；常驻垫在最下面，不在列表里）
// selected：选中的方案（"" = 初始），和调色页打开时 palette.scheme 相同
export interface Re4PaletteSchemes { list: Re4PaletteScheme[]; active: string[]; selected: string }
export interface Re4PaletteWrite { slot: string; material: string; param: string; component?: Re4Comp; value: number }

// 快捷键（Alt + 数字）：kind 是哪个结构；没有 option / scheme = 轮换整个结构，否则是单项
// （option / scheme 为 "" = 状态组的「（无）」/ 调色的「初始」）。skip：轮换时跳过的项
export interface Re4HotkeyTarget { kind: 'base' | 'group' | 'palette'; group?: string; option?: string; scheme?: string }
export interface Re4Hotkey extends Re4HotkeyTarget { digit: number; cycle: boolean; skip: string[] }

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
  height?: number;   // 这一帧生效的模型高度（厘米）；没有 = 不抬高
  heightSource?: { layer: string; option?: string };   // layer: 'override' / 'base' / 状态组名
  heightOverride?: { enabled: boolean; cm: number };   // 快速切换页的全局覆盖（存在当前配置里）
  palette?: Re4Palette;   // 只在调色页打开时出现
  palettes?: Re4PaletteSchemes;
  hotkeys?: Re4Hotkey[];
  locating?: { slot: string; material: string };
  // 调色页的「仅显示选中部位」开着(只对当前角色)
  solo?: boolean;
  presets?: Re4Presets;
  backups?: { hasBackup: boolean; hasOnload: boolean };
}

export type Re4ConditionInput = { type: string; op?: Re4Op; value: number | string | boolean };
type C = { character: string };
export type Re4Action =
  | { kind: 'character'; id: string }
  | { kind: 'setting'; id: 'weapon_hide_storage' | 'ui_dissolve_enabled' | 'ui_dissolve_time' | 'portrait_enabled' | 'portrait_distance' | 'portrait_height' | 'block_game_mouse' | 'height_enabled'; value: boolean | number }
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
  | C & { kind: 'base-height'; preset: string; cm?: number }
  | C & { kind: 'hotkey-set'; digit: number; target: Re4HotkeyTarget }
  | C & { kind: 'hotkey-clear'; digit: number }
  | C & { kind: 'hotkey-skip'; structure: { kind: Re4HotkeyTarget['kind']; group?: string }; item: string; included: boolean }
  | C & { kind: 'option-height'; group: string; option: string; cm?: number }
  | C & { kind: 'height-override'; enabled?: boolean; cm?: number }
  | C & { kind: 'palette-view'; open: boolean; keys: string[]; scheme?: string; solo?: boolean }
  | C & { kind: 'palette-set'; writes: Re4PaletteWrite[]; live?: boolean; scheme?: string }
  | C & { kind: 'palette-reset'; targets: { slot: string; material: string }[]; param?: string; component?: Re4Comp; scheme?: string }
  | C & { kind: 'palette-scheme-new'; name: string; from?: string }
  | C & { kind: 'palette-scheme-select'; scheme: string }
  | C & { kind: 'palette-scheme-rename'; scheme: string; name: string }
  | C & { kind: 'palette-scheme-delete'; scheme: string }
  | C & { kind: 'palette-ref'; layer: string; option: string; scheme: string }
  | C & { kind: 'state-palette'; index: number; scheme: string }
  | C & { kind: 'palette-reload' }
  | C & { kind: 'palette-export'; slot: string; material: string; name: string }
  | C & { kind: 'palette-replace'; slot: string }
  | C & { kind: 'group-new'; name: string }
  | C & { kind: 'group-rename'; group: string; name: string }
  | C & { kind: 'group-move'; group: string; offset: number }
  | C & { kind: 'group-delete'; group: string }
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
  | C & { kind: 'preset-blank'; capture: boolean }
  | C & { kind: 'preset-update' | 'preset-dismiss' }
  | C & { kind: 'autosave-restore'; index: number }
  | C & { kind: 'autosave-promote'; index: number; name: string }
  | C & { kind: 'restore'; which: 'backup' | 'onload' };

// 子组件只拿到这个：一次一个或一串操作，结果是否成功
export type Re4Perform = (actions: Re4Action | Re4Action[]) => Promise<boolean>;
// 调色拖动中的实时写入:直接发给 Lua,只等一个小确认,不拿快照、不占通用操作的通道
export type Re4LiveWrite = (action: Re4Action) => Promise<boolean>;
