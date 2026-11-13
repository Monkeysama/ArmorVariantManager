// 快捷键(Alt + 数字)的网页侧工具。绑定由 Lua 发来(snapshot.hotkeys,见 ModelV3 的 hotkeys):
//   轮换 = 整个结构(整套造型 / 某个状态组 / 调色)按一下切到下一项;单项 = 切到某一项。
//   所有设定共用 Alt+0~9;一个键一个设定;结构有轮换键时,它下面的项只能开关「参与轮换」,不能单独绑键。
import type { Re4Hotkey, Re4HotkeyTarget, Re4Snapshot } from './types';
import type { Re4Translate } from './i18n';
import { baseLabel, groupLabel, optionLabel } from './util';

export const DIGITS = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0];

const structureOf = (t: { kind: string; group?: string }) => t.kind === 'group' ? 'group:' + t.group : t.kind;
export const isCycle = (t: Re4HotkeyTarget) => t.option === undefined && t.scheme === undefined;
const itemOf = (t: Re4HotkeyTarget) => t.kind === 'palette' ? t.scheme : t.option;
export const sameTarget = (a: Re4HotkeyTarget, b: Re4HotkeyTarget) =>
  structureOf(a) === structureOf(b) && isCycle(a) === isCycle(b) && itemOf(a) === itemOf(b);

export const hotkeysOf = (s: Re4Snapshot) => s.hotkeys ?? [];
/** 这个设定绑的键 */
export const keyOf = (s: Re4Snapshot, t: Re4HotkeyTarget) => hotkeysOf(s).find(h => sameTarget(h, t));
/** 这个结构的轮换键 */
export const cycleOf = (s: Re4Snapshot, t: { kind: string; group?: string }) =>
  hotkeysOf(s).find(h => h.cycle && structureOf(h) === structureOf(t));

/** 一条绑定的文字说明,例如「状态组「面部」· 轮换」「调色 · 初始」 */
// 整套造型 / 状态组 / 选项用显示名(双语,见 util.ts 的 labelOf)
export function describe(s: Re4Snapshot, h: Re4HotkeyTarget, t: Re4Translate) {
  const where = h.kind === 'base' ? t('tabBase') : h.kind === 'group' ? t('hotkeyGroup', groupLabel(s, h.group ?? '')) : t('hotkeyPalette');
  if (isCycle(h)) return where + ' · ' + t('hotkeyCycle');
  const item = itemOf(h) ?? '';
  if (item === '') return where + ' · ' + (h.kind === 'palette' ? t('paletteAlways') : t('none'));
  return where + ' · ' + (h.kind === 'base' ? baseLabel(s, item) : h.kind === 'group' ? optionLabel(s, h.group ?? '', item) : item);
}

/** 下拉框里每个数字的说明:空着就是「Alt+1」,被别的设定占着就写出是谁(选了会从那里移过来) */
export function digitLabel(s: Re4Snapshot, d: number, self: Re4HotkeyTarget, t: Re4Translate) {
  const owner = hotkeysOf(s).find(h => h.digit === d);
  return owner && !sameTarget(owner, self) ? t('hotkeyUsedBy', 'Alt+' + d, describe(s, owner, t)) : 'Alt+' + d;
}

export type HotkeyRow = Re4Hotkey;
