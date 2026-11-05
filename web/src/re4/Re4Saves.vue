<script setup lang="ts">
import { computed, shallowRef, watch } from 'vue';
import { ElButton, ElInput, ElOption, ElSelect } from '@reff/ui';
import type { Re4Translate } from './i18n';
import type { Re4Perform, Re4Snapshot } from './types';

// 配置归属与存档。会替换当前配置的操作（独立、初始化、读档、恢复）一律二次确认。
//   * 共用时只能「创建独立预设」；初始化只在独立时出现（共用时初始化会把来源角色一起清空）
//   * 「匹配同角色配置」只在配置没什么可丢时出现
//   * 命名存档跨角色列出：自己的可删；别人的只能读，读进来是复制，不动来源
const props = defineProps<{ snapshot: Re4Snapshot; busy: boolean; perform: Re4Perform; t: Re4Translate }>();
const ownership = computed(() => props.snapshot.ownership!);
const saves = computed(() => props.snapshot.saves!);
const name = shallowRef('');
const selected = shallowRef('');
const pending = shallowRef<'independent' | 'reset' | 'load' | 'backup' | 'onload' | null>(null);
const slot = computed(() => saves.value.slots.find(item => `${item.key}/${item.name}` === selected.value));
watch(() => saves.value.slots.map(item => `${item.key}/${item.name}`).join('|'), () => {
  if (!slot.value) selected.value = saves.value.slots[0] ? `${saves.value.slots[0].key}/${saves.value.slots[0].name}` : '';
}, { immediate: true });
watch([selected, () => props.snapshot.character], () => { pending.value = null; });
const character = computed(() => props.snapshot.character);

async function run() {
  const which = pending.value;
  if (!which) return;
  const c = character.value;
  const ok = which === 'independent' ? await props.perform({ kind: 'make-independent', character: c })
    : which === 'reset' ? await props.perform({ kind: 'reset-config', character: c })
    : which === 'load' ? !!slot.value && await props.perform({ kind: 'slot-load', character: c, key: slot.value.key, name: slot.value.name })
    : await props.perform({ kind: 'restore', character: c, which });
  if (ok) pending.value = null;
}
async function save() {
  if (await props.perform({ kind: 'slot-save', character: character.value, name: name.value.trim() })) name.value = '';
}
const confirmText = computed(() => pending.value === 'independent' ? props.t('confirmIndependent')
  : pending.value === 'reset' ? props.t('confirmReset') : props.t('confirmReplace'));
</script>

<template>
  <div class="re4-saves">
    <section class="re4-section">
      <h2 class="re4-section-title">{{ t('ownership') }}</h2>
      <template v-if="ownership.shared">
        <p class="re4-note">{{ t('sharedWith') }} {{ snapshot.sharedWith }}</p>
        <ElButton :disabled="busy" @click="pending = 'independent'">{{ t('makeIndependent') }}</ElButton>
      </template>
      <div v-else class="re4-row-control">
        <ElButton v-if="ownership.canReset" :disabled="busy" @click="pending = 'reset'">{{ t('resetConfig') }}</ElButton>
        <ElButton v-if="ownership.canMatchKin" :disabled="busy" @click="perform({ kind: 'match-kin', character })">{{ t('matchKin') }}</ElButton>
      </div>
      <p class="re4-note">{{ ownership.shared ? t('independentHint') : t('resetHint') }}</p>
    </section>

    <section class="re4-section">
      <h2 class="re4-section-title">{{ t('namedSaves') }}</h2>
      <div class="re4-inline">
        <ElInput v-model="name" :placeholder="t('saveName')" :disabled="busy" @keydown.enter="save" />
        <ElButton :disabled="busy" @click="save">{{ t('saveSlot') }}</ElButton>
      </div>
      <p v-if="saves.slots.length === 0" class="re4-muted">{{ t('noSaves') }}</p>
      <div v-else class="re4-row-control">
        <ElSelect v-model="selected" :disabled="busy" :aria-label="t('namedSaves')">
          <ElOption v-for="item in saves.slots" :key="`${item.key}/${item.name}`" :value="`${item.key}/${item.name}`" :label="item.label" />
        </ElSelect>
        <ElButton :disabled="busy || !slot" @click="pending = 'load'">{{ t('loadSlot') }}</ElButton>
        <ElButton v-if="slot?.own" :disabled="busy" @click="perform({ kind: 'slot-delete', character, name: slot.name })">{{ t('delete') }}</ElButton>
      </div>
      <p v-if="slot && !slot.own" class="re4-note">{{ t('foreignSave') }}</p>
    </section>

    <section class="re4-section">
      <h2 class="re4-section-title">{{ t('restorePoints') }}</h2>
      <div class="re4-row-control">
        <ElButton v-if="saves.hasBackup" :disabled="busy" @click="pending = 'backup'">{{ t('restoreBackup') }}</ElButton>
        <span v-else class="re4-muted">{{ t('noBackup') }}</span>
      </div>
      <div class="re4-row-control">
        <ElButton v-if="saves.hasOnload" :disabled="busy" @click="pending = 'onload'">{{ t('restoreOnload') }}</ElButton>
        <span v-else class="re4-muted">{{ t('noOnload') }}</span>
      </div>
    </section>

    <div v-if="pending" class="delete-confirm re4-confirm" role="alert">
      <p>{{ confirmText }}</p>
      <div class="button-pair"><ElButton :disabled="busy" @click="pending = null">{{ t('cancel') }}</ElButton><ElButton type="primary" :disabled="busy" @click="run">{{ t('confirm') }}</ElButton></div>
    </div>
  </div>
</template>

<style>
.re4-saves .re4-section { max-width: 44em; }
.re4-saves .re4-row-control { margin: 4px 0; }
.re4-confirm { margin: 8px 16px; }
</style>
