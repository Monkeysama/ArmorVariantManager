import { inject, type InjectionKey, type ShallowRef } from 'vue';
import type { useAvm } from './useAvm';

// Root 建立唯一的 REFF 连接；MH 与 RE4 页面从这里取状态，按快照里的 game 决定渲染哪一套。
export type AvmState = ReturnType<typeof useAvm> & { helpOpen: ShallowRef<boolean> };
export const avmKey: InjectionKey<AvmState> = Symbol('avm');

export function useAvmState(): AvmState {
  const state = inject(avmKey);
  if (!state) throw new Error('AVM state is not provided');
  return state;
}
