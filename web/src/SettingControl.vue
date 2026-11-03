<script setup lang="ts">
import { computed, shallowRef, watch } from 'vue';
import { ElButton, ElCheckbox } from '@reff/ui';
import ConditionNumber from './ConditionNumber.vue';
import ConditionSelect from './ConditionSelect.vue';
import type { SettingField, SettingValue } from './types';
import type { Translate } from './i18n';

const props = defineProps<{ field: SettingField; disabled: boolean; save: (value?: SettingValue) => Promise<boolean>; t: Translate }>();
const draft = shallowRef(!!props.field.value);
const dirty = shallowRef(false);
const id = computed(() => `setting-${props.field.id.replace(/\./g, '-')}`);
watch(() => props.field.value, value => { if (!dirty.value) draft.value = !!value; });
async function toggle(value: boolean | string | number = draft.value) {
  draft.value = !!value; dirty.value = true;
  if (await props.save(draft.value)) { dirty.value = false; draft.value = !!props.field.value; }
}
</script>

<template>
  <div class="setting-control" :data-setting="field.id">
    <ElButton v-if="field.type === 'action'" :disabled="disabled" @click="save()">{{ field.label }}</ElButton>
    <div v-else-if="field.type === 'boolean'" class="setting-toggle-line">
      <ElCheckbox :id="id" :model-value="draft" :disabled="disabled" :aria-describedby="field.description || field.reason ? id + '-note' : undefined" @change="toggle">{{ field.label }}</ElCheckbox>
      <ElButton v-if="dirty" :disabled="disabled" @click="toggle()">{{ t('applyValue') }}</ElButton>
    </div>
    <ConditionNumber v-else-if="field.type === 'number'" :id="id" :value="field.value as number" :label="field.label" :min="field.min" :max="field.max" :step="field.step" :disabled="disabled" :save="save" :t="t" />
    <ConditionSelect v-else :value="field.value as string | number" :label="field.label" :options="field.options ?? []" :disabled="disabled" :save="save" :t="t" />
    <p v-if="field.description || field.reason" :id="id + '-note'" class="setting-note">{{ field.description }}<span v-if="field.reason" class="setting-reason">{{ field.reason }}</span></p>
  </div>
</template>
