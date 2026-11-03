<script setup lang="ts">
import { computed, shallowRef, watch } from 'vue';
import { ElButton, ElInput } from '@reff/ui';
import type { Translate } from './i18n';

const props = defineProps<{ value: number; label: string; id: string; min?: number; max?: number; disabled: boolean; save: (value: number) => Promise<boolean>; t: Translate }>();
const draft = shallowRef(String(props.value));
const dirty = shallowRef(false);
const focused = shallowRef(false);
const input = shallowRef<{ blur: () => void }>();
const invalid = computed(() => !draft.value.trim() || !Number.isFinite(Number(draft.value))
  || (props.min !== undefined && Number(draft.value) < props.min) || (props.max !== undefined && Number(draft.value) > props.max));
watch(() => props.value, value => { if (!dirty.value && !focused.value) draft.value = String(value); });
watch(() => props.disabled, disabled => { if (disabled) { input.value?.blur(); focused.value = false; } });
async function commit() {
  if (!dirty.value || invalid.value || props.disabled) return;
  if (await props.save(Number(draft.value))) { dirty.value = false; draft.value = String(props.value); }
}
</script>

<template>
  <div class="condition-number">
    <label :for="id" class="field-label">{{ label }}</label>
    <div class="number-input-line">
      <ElInput ref="input" :id="id" v-model="draft" inputmode="decimal" :disabled="disabled" :aria-invalid="dirty && invalid" :aria-describedby="dirty && invalid ? id + '-error' : undefined"
        @input="dirty = true" @focus="focused = true" @blur="focused = false; commit()" @keyup.enter="commit" />
      <ElButton v-if="dirty" :disabled="disabled || invalid" @click="commit">{{ t('applyValue') }}</ElButton>
    </div>
    <span v-if="dirty && invalid" :id="id + '-error'" class="field-error">{{ t('validNumber') }}{{ min !== undefined ? ' ≥ ' + min : '' }}{{ max !== undefined ? ' ≤ ' + max : '' }}</span>
  </div>
</template>
