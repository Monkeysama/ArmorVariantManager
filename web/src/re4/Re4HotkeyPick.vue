<script setup lang="ts">
import { computed } from 'vue';
import { ElOption, ElSelect } from '@reff/ui';
import type { Re4Translate } from './i18n';
import type { Re4HotkeyTarget, Re4Perform, Re4Snapshot } from './types';
import { DIGITS, cycleOf, digitLabel, isCycle, keyOf } from './hotkeys';

// 一处快捷键设置(Alt + 数字)。target 没有 option / scheme = 整个结构的轮换键,否则是单项。
// 单项所在的结构已经绑了轮换键时,这里换成「参与轮换」开关(单项不能再单独绑键)。
const props = defineProps<{ snapshot: Re4Snapshot; busy: boolean; perform: Re4Perform; t: Re4Translate; target: Re4HotkeyTarget; label?: string }>();
// 快捷键属于新版特性:关闭时灰掉、不可改
const nfOff = computed(() => props.snapshot.settings.newFeatures === false);
const c = () => ({ character: props.snapshot.character });
const own = computed(() => keyOf(props.snapshot, props.target));
const cycle = computed(() => isCycle(props.target) ? undefined : cycleOf(props.snapshot, props.target));
const item = computed(() => (props.target.kind === 'palette' ? props.target.scheme : props.target.option) ?? '');
const included = computed(() => !cycle.value?.skip.includes(item.value));
const structure = computed(() => ({ kind: props.target.kind, group: props.target.group }));

function pick(v: string | number) {
  if (v === '' || v === undefined || v === null) {
    if (own.value) void props.perform({ kind: 'hotkey-clear', ...c(), digit: own.value.digit });
    return;
  }
  void props.perform({ kind: 'hotkey-set', ...c(), digit: Number(v), target: props.target });
}
const toggle = (on: boolean) => props.perform({ kind: 'hotkey-skip', ...c(), structure: structure.value, item: item.value, included: on });
</script>

<template>
  <label v-if="cycle" class="re4-hk re4-hk-incl" :class="{ 're4-nf-lock': nfOff }" :inert="nfOff" :title="t('hotkeyIncludeHint', 'Alt+' + cycle.digit)">
    <input type="checkbox" :checked="included" :disabled="busy" @change="e => toggle((e.target as HTMLInputElement).checked)">
    {{ t('hotkeyInclude') }}
  </label>
  <label v-else class="re4-hk" :class="{ 're4-nf-lock': nfOff }" :inert="nfOff" :title="isCycle(target) ? t('hotkeyCycleHint') : t('hotkeyHint')">{{ label ?? t('hotkeyRef') }}
    <ElSelect :model-value="own?.digit ?? ''" :empty-values="[null, undefined]" size="small" style="width:13em" :disabled="busy"
      :aria-label="label ?? t('hotkeyRef')" @change="pick">
      <ElOption value="" :label="t('hotkeyNone')" />
      <ElOption v-for="d in DIGITS" :key="d" :value="d" :label="digitLabel(snapshot, d, target, t)" />
    </ElSelect>
  </label>
</template>

<style>
.re4-hk { display: inline-flex; align-items: center; gap: 4px; font-size: 12.5px; color: var(--avm-muted); }
.re4-hk-incl { cursor: pointer; }
</style>
