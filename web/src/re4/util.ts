import type { Re4Translate } from './i18n';
import type { Re4ConditionDef, Re4Result, Re4Snapshot, Re4State, Re4StateCondition, Re4StateKind } from './types';

export const splitKey = (key: string): [string, string] => {
  const i = key.indexOf('/');
  return i < 0 ? [key, ''] : [key.slice(0, i), key.slice(i + 1)];
};
export const keyOf = (slot: string, material: string) => `${slot}/${material}`;
// 部位名只留中文 / 英文名，去掉后面括号里的内部 id（如「身体 (body / 00)」→「身体」）
export const shortSlot = (label: string) => label.replace(/\s*[(（][^()（）]*[)）]\s*$/, '') || label;

const KIND_KEY: Record<Re4StateKind, 'kindActive' | 'kindPartial' | 'kindOutranked' | 'kindIdle' | 'kindOff' | 'kindPaused'> = {
  active: 'kindActive', partial: 'kindPartial', outranked: 'kindOutranked', idle: 'kindIdle', off: 'kindOff', paused: 'kindPaused',
};

// 状态的文字说明（颜色之外的那一份，给悬停提示和读屏用）
export function kindText(state: Re4State, states: Re4State[], t: Re4Translate) {
  let text = t(KIND_KEY[state.kind]);
  if (state.kind === 'outranked' && state.by && states[state.by - 1]) text += '，' + t('coveredBy', states[state.by - 1].name);
  if (state.holding && (state.kind === 'active' || state.kind === 'partial')) text += '，' + t('holding');
  return text;
}

export function resultText(result: Re4Result | undefined, states: Re4State[], t: Re4Translate) {
  if (!result) return '';
  if (result.kind === 'broken') return t('broken');
  if (result.kind === 'win') return t('win');
  return t('coveredBy', states[(result.by ?? 0) - 1]?.name ?? '?');
}

const OP_TEXT: Record<string, string> = { '<=': '≤', '<': '<', '>=': '≥', '>': '>', '==': '=', '~=': '≠' };
export const opText = (op?: string) => OP_TEXT[op ?? '<='] ?? op ?? '';

export function conditionText(c: Re4StateCondition, t: Re4Translate) {
  if (!c.known) return t('unknownCondition') + ' ' + c.type;
  if (typeof c.value === 'boolean') return c.value ? c.label : `${c.label} = ${t('no')}`;
  if (c.valueLabel !== undefined) return `${c.label} ${c.op === '~=' ? '≠' : '='} ${c.valueLabel}`;
  const pct = c.label.endsWith('%');
  return `${c.label.replace(/\s*%$/, '')} ${opText(c.op)} ${c.value}${pct ? '%' : ''}`;
}

export function conditionSentence(state: Re4State, t: Re4Translate) {
  if (state.hp) return t('sentenceHp', state.hp.upper, state.hp.lower);
  if (state.conditions.length === 0) return t('sentenceNoCond');
  const joined = state.conditions.map(c => conditionText(c, t)).join(state.logic === 'OR' ? `，${t('or')}` : `，${t('and')}`);
  return t('sentenceWhen', joined) + (state.hold > 0 ? t('sentenceHold', state.hold) : '');
}

export function targetSentence(state: Re4State, t: Re4Translate) {
  const parts: string[] = [];
  // 箭头只留给"条件 → 切换目标"这一层，目标里的"组：选项"用冒号
  if (state.base) parts.push(t('targetPair', t('baseTarget'), state.base));
  for (const target of state.targets) parts.push(t('targetPair', target.group, target.option));
  return parts.join(t('targetSep')) || t('noTargets');
}

// 当前值的显示（条件行右侧的"现在：…"）
export function currentValueText(def: Re4ConditionDef | undefined, t: Re4Translate) {
  if (!def || def.value === undefined) return '';
  if (def.kind === 'bool') return def.value ? t('yes') : t('no');
  if (def.kind === 'enum') return def.options?.find(o => o.value === def.value)?.label ?? String(def.value);
  return def.label.endsWith('%') ? `${Math.round(Number(def.value) * 10) / 10}%` : String(def.value);
}

// 某个状态组 / 选项被哪些条件状态用着
export function usersOf(snapshot: Re4Snapshot, group: string | null, option?: string) {
  return (snapshot.states ?? []).filter(s => group === null
    ? (option === undefined ? !!s.base : s.base === option)
    : s.targets.some(tg => tg.group === group && (option === undefined || tg.option === option)));
}
