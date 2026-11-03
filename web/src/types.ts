export interface Material { name: string; enabled: boolean; hidden: boolean; groups: string[] }
export interface Part { index: number; label: string; available: boolean; enabled: boolean; meshLocked: boolean; materials: Material[] }
export interface Snapshot {
  game: 'Wilds' | 'Rise'; version: string; bodyId: string; weapon: boolean; suspended: boolean;
  groups: { name: string; label: string; global: boolean }[]; group: string;
  presets: { name: string; default: boolean; active: boolean }[]; selectedPreset: string;
  parts: Part[]; theme: 'custom' | 'reff'; language: string; selectionMode: boolean;
  pending: Record<string, Record<string, boolean>>;
}
export type Action =
  | { kind: 'mode'; weapon: boolean }
  | { kind: 'theme'; value: 'custom' | 'reff' }
  | { kind: 'group' | 'preset' | 'save' | 'delete-preset' | 'default' | 'delete-group'; name: string }
  | { kind: 'create-group'; name: string; global: boolean }
  | { kind: 'mesh'; part: number; enabled: boolean }
  | { kind: 'material' | 'select-material'; part: number; name: string; enabled: boolean }
  | { kind: 'selection'; enabled: boolean }
  | { kind: 'find' | 'restore' };
export type Perform = (actions: Action | Action[]) => Promise<boolean>;
