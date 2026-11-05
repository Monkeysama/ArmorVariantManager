<script setup lang="ts">
import { computed } from 'vue';

// RE4 页面统一的数值框：只有输入，没有上下步进按钮（步长没法定得合适）。
// 显示最多 3 位小数、去掉末尾的 0（0.58999997 → 0.59）；回车或离开时提交，
// 填不成数字就退回当前值；min / max 是硬范围，超出的按边界提交。
// allowEmpty：清空表示"不设"，提交 undefined（例如模型高度）。
const props = defineProps<{
  value?: number | null; min?: number; max?: number; placeholder?: string;
  disabled?: boolean; ariaLabel?: string; allowEmpty?: boolean;
}>();
const emit = defineEmits<{ change: [value: number | undefined] }>();

const fmt = (v?: number | null) => typeof v === 'number' && Number.isFinite(v) ? String(Number(v.toFixed(3))) : '';
const shown = computed(() => fmt(props.value));

function commit(e: Event) {
  const el = e.target as HTMLInputElement;
  const raw = el.value.trim().replace('，', '.').replace('。', '.');
  if (raw === '') {
    if (props.allowEmpty) { if (props.value !== undefined && props.value !== null) emit('change', undefined); }
    else el.value = shown.value;
    return;
  }
  let n = Number(raw);
  if (!Number.isFinite(n)) { el.value = shown.value; return; }
  if (props.min !== undefined) n = Math.max(props.min, n);
  if (props.max !== undefined) n = Math.min(props.max, n);
  n = Math.round(n * 1000) / 1000;
  el.value = fmt(n);
  if (n !== props.value) emit('change', n);
}
</script>

<template>
  <input class="re4-num" type="text" inputmode="decimal" autocomplete="off" spellcheck="false" :value="shown" :placeholder="placeholder"
    :disabled="disabled" :aria-label="ariaLabel" @change="commit" @keydown.enter="($event.target as HTMLInputElement).blur()">
</template>

<style>
.re4-num { width: 4.5em; border: 1px solid var(--avm-line); border-radius: 4px; background: transparent; color: inherit; padding: 1px 5px;
  font: inherit; font-size: 12.5px; font-variant-numeric: tabular-nums; text-align: right; }
.re4-num:focus { outline: none; border-color: var(--avm-accent); }
.re4-num:disabled { opacity: .6; }
.re4-num::placeholder { color: var(--avm-muted); text-align: left; }
</style>
