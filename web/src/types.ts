import type { Re4Action, Re4Snapshot } from './re4/types';

export interface Material { name: string; enabled: boolean; hidden: boolean; groups: string[]; owner?: string; editable?: boolean }
export interface Part { index: number; label: string; available: boolean; enabled: boolean; meshLocked: boolean; materials: Material[] }
export interface ConditionTarget { index: number; group: string; preset: string }
export interface ConditionNode { index: number; duration: number; targets: ConditionTarget[] }
export interface ConditionRule {
  index: number; label: string; targets: ConditionTarget[]; chain_nodes?: ConditionNode[];
  [key: string]: number | string | ConditionTarget[] | ConditionNode[] | undefined;
}
export interface ConditionField {
  key: string; label: string; kind: 'number' | 'select'; default: number | string;
  min?: number; max?: number; step?: number; sliderMax?: number; modes?: number[]; options?: { value: number | string; label: string }[];
}
export interface ConditionDefinition {
  id: string; label: string; enabled: boolean; priority: number; fields: ConditionField[];
  canAdd: boolean; canRemove: boolean; rules: ConditionRule[]; stateLabel?: string; warning?: string;
}
export interface Conditions {
  enabled: boolean; canEnable: boolean; parallel: boolean; selected: string;
  definitions: ConditionDefinition[]; targets: { name: string; label: string; global: boolean; presets: string[] }[];
  canTestHp?: boolean; canTestDamage?: boolean;
}
export type SettingValue = boolean | number | string;
export interface SettingField {
  id: string; label: string; description?: string; type: 'boolean' | 'number' | 'select' | 'action'; value?: SettingValue;
  min?: number; max?: number; step?: number; options?: { value: string | number; label: string }[];
  disabled?: boolean; reason?: string;
}
export interface SettingsSection {
  id: string; label: string; description?: string; scope: 'global' | 'equipment'; fields: SettingField[];
}
export interface Settings { sections: SettingsSection[] }
export interface DocumentationEntry { title: string; paragraphs: string[] }
export interface DocumentationSection { id: string; title: string; entries: DocumentationEntry[] }
export interface Documentation { sections: DocumentationSection[] }
export interface ImportFile { path: string; name: string }
export interface Imports { bodyId: string; files: ImportFile[] }
export interface Preview { available: boolean; enabled: boolean; status: string; error?: string }
export interface Snapshot {
  game: 'Wilds' | 'Rise'; version: string; bodyId: string; weapon: boolean; suspended: boolean;
  backupPending: boolean; canImport: boolean;
  groups: { name: string; label: string; global: boolean }[]; group: string;
  presets: { name: string; default: boolean; active: boolean }[]; selectedPreset: string;
  parts: Part[]; theme: 'custom' | 'reff'; language: string; selectionMode: boolean;
  pending: Record<string, Record<string, boolean>>;
  conditions: Conditions | null;
  settings?: Settings;
  preview?: Preview;
}
export interface ConditionAction {
  kind: 'condition';
  op: 'parallel' | 'select' | 'enabled' | 'setting' | 'rule_add' | 'rule_delete' | 'rule_set'
    | 'target_add' | 'target_delete' | 'target_set' | 'chain_add' | 'chain_delete' | 'chain_set' | 'test_hp' | 'test_damage';
  condition?: string; rule?: number; node?: number; target?: number; field?: string; value?: boolean | number | string;
}
export type Action =
  | ConditionAction
  | { kind: 'mode'; weapon: boolean }
  | { kind: 'theme'; value: 'custom' | 'reff' }
  | { kind: 'setting'; id: string; value?: SettingValue }
  | { kind: 'reorder-preset' | 'reorder-group'; name: string; offset: -1 | 1 }
  | { kind: 'reorder-preset' | 'reorder-group'; name: string; target: string; after: boolean; group: string; weapon: boolean }
  | { kind: 'group' | 'preset' | 'save' | 'delete-preset' | 'default' | 'delete-group'; name: string }
  | { kind: 'create-group'; name: string; global: boolean }
  | { kind: 'mesh'; part: number; enabled: boolean }
  | { kind: 'material' | 'select-material'; part: number; name: string; enabled: boolean }
  | { kind: 'selection'; enabled: boolean }
  | { kind: 'import-preset'; path: string }
  | { kind: 'find' | 'restore' | 'dismiss-backup' };
export type Perform = (actions: Action | Action[]) => Promise<boolean>;
// RE4 走自己的数据契约（src/re4/types.ts），共用同一条 REFF 通道。
export type AnySnapshot = Snapshot | Re4Snapshot;
export type AnyAction = Action | Re4Action;
