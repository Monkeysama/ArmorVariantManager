<script setup lang="ts">
import Re4Num from './Re4Num.vue';
import { computed, reactive, shallowRef, watch } from 'vue';
import { ElButton, ElColorPicker, ElDialog, ElInput, ElOption, ElSelect, ElSwitch } from '@reff/ui';
import type { Re4Key, Re4Translate } from './i18n';
import type { Re4DissolveEdge, Re4DissolvePreset, Re4EffectLabel, Re4EffectProvider, Re4Perform, Re4Snapshot } from './types';

// 溶解:手动切换时的过渡(全局)、溶解预设库(全局:形状 + 光边覆盖;条件状态 / 整套造型预设 / 状态组选项按名字引用)、
// 其他 mod 注册的效果提供者。和调色页一样:上面选要编辑的预设、新建 / 改名 / 删除,下面编辑它。
const props = defineProps<{ snapshot: Re4Snapshot; busy: boolean; perform: Re4Perform; t: Re4Translate }>();

const BUILTIN = 'avm.builtin';
const en = computed(() => props.snapshot.language === 'en');
const lib = computed(() => props.snapshot.settings.dissolvePresets);
const presets = computed<Re4DissolvePreset[]>(() => Array.isArray(lib.value?.list) ? lib.value!.list : []);
const shapes = computed(() => Array.isArray(lib.value?.shapes) ? lib.value!.shapes : []);
const providers = (): Re4EffectProvider[] => Array.isArray(props.snapshot.effectProviders) ? props.snapshot.effectProviders : [];
const others = () => providers().filter(p => p.id !== BUILTIN);

const pick = (label: Re4EffectLabel | undefined): string | undefined => {
  if (typeof label === 'string') return label;
  if (!label) return undefined;
  return en.value ? (label['en-US'] ?? label['zh-CN']) : (label['zh-CN'] ?? label['en-US']);
};
// 提供者没给显示名时的中文兜底:社区测试包里那个提供者的效果 ID
const KNOWN_ZH: Record<string, string> = { original: '原版紫焰', square: '方块紫焰', hex: '六边形紫焰', height_down: '上下高度扫描',
  violet_cosmos: '紫宙能量', rainbow_radiance: '虹彩辉光', stellar_nebula: '星云流光' };
const effectLabel = (p: Re4EffectProvider, id: string): string => {
  const own = p.labels && !Array.isArray(p.labels) ? pick(p.labels[id]) : undefined;
  return own ?? (en.value ? id : (KNOWN_ZH[id] ?? id));
};
const shapeLabel = (id: string) => id === 'random' ? props.t('effectRandom') : (pick(shapes.value.find(s => s.id === id)?.label) ?? id);

const setting = (id: 'ui_dissolve_enabled' | 'ui_dissolve_time', value: boolean | number) => props.perform({ kind: 'setting', id, value });
const selectOther = (provider: string, effect: unknown) => props.perform({ kind: 'effect-select', provider, effect: String(effect) });

// ---------------------------------------------------------------- 选要编辑的预设
const editing = shallowRef('');
const current = computed(() => presets.value.find(p => p.name === editing.value));
// 没选过 / 选的被删了:选默认那个,默认是随机或空就选第一个
watch(presets, list => {
  if (list.some(p => p.name === editing.value)) return;
  const d = lib.value?.default;
  editing.value = list.find(p => p.name === d)?.name ?? list[0]?.name ?? '';
}, { immediate: true });

// 新建 / 改名共用一个对话框(同调色页)
const dialog = reactive({ open: false, mode: 'new' as 'new' | 'rename', name: '', from: 'none' as 'none' | 'current' });
const nameTaken = computed(() => presets.value.some(p => p.name === dialog.name.trim()) && !(dialog.mode === 'rename' && dialog.name.trim() === editing.value));
const dialogOk = computed(() => !!dialog.name.trim() && dialog.name.trim().length <= 48 && dialog.name.trim() !== 'random' && !nameTaken.value);
function openNew() { Object.assign(dialog, { open: true, mode: 'new', name: '', from: editing.value ? 'current' : 'none' }); }
function openRename() { Object.assign(dialog, { open: true, mode: 'rename', name: editing.value, from: 'none' }); }
async function submitDialog() {
  if (!dialogOk.value) return;
  const name = dialog.name.trim();
  const ok = dialog.mode === 'rename'
    ? await props.perform({ kind: 'dissolve-preset-rename', preset: editing.value, name })
    : await props.perform({ kind: 'dissolve-preset-new', name, from: dialog.from === 'current' && editing.value ? editing.value : undefined });
  if (ok) { dialog.open = false; editing.value = name; }
}
const confirmDelete = shallowRef(false);
async function doDelete() {
  confirmDelete.value = false;
  await props.perform({ kind: 'dissolve-preset-delete', preset: editing.value });
}

// ---------------------------------------------------------------- 编辑选中的预设
const setShape = (shape: unknown) => props.perform({ kind: 'dissolve-preset-shape', preset: editing.value, shape: String(shape) });
const edge = (key: string, change: { on?: boolean; value?: number | number[] }) =>
  props.perform({ kind: 'dissolve-edge', preset: editing.value, key, ...change });
const EDGE_TEXT: Record<string, [Re4Key, Re4Key]> = {
  color: ['edgeColor', 'edgeColorHint'], width: ['edgeWidth', 'edgeWidthHint'], intensity: ['edgeIntensity', 'edgeIntensityHint'],
  border: ['edgeBorder', 'edgeBorderHint'], noise_weight: ['edgeNoiseWeight', 'edgeNoiseWeightHint'],
  cell_size: ['edgeCellSize', 'edgeCellSizeHint'], flow: ['edgeFlow', 'edgeFlowHint'],
};
const label = (e: Re4DissolveEdge) => EDGE_TEXT[e.key] ? props.t(EDGE_TEXT[e.key][0]) : e.key;
const hint = (e: Re4DissolveEdge) => EDGE_TEXT[e.key] ? props.t(EDGE_TEXT[e.key][1]) : '';

// 颜色:线性 0~1 ↔ 取色器的 #rrggbb(同调色页,不做伽马换算)。
// 和调色页同一个习惯:拖动(active-change)就生效,点取色器外面关掉也保留;停手 250ms 再提交,确定(change)立即提交
const to255 = (v: number) => Math.max(0, Math.min(255, Math.round(v * 255)));
const hex = (v: unknown) => Array.isArray(v) && v.length >= 3 ? '#' + v.slice(0, 3).map(x => to255(Number(x)).toString(16).padStart(2, '0')).join('') : '#ffffff';
const shownColor = reactive(new Map<string, string>());
const timers = new Map<string, ReturnType<typeof setTimeout>>();
function parseColor(value: string | null): number[] | null {
  const m = /^#?([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})/i.exec(value ?? '') ?? /rgba?\((\d+),\s*(\d+),\s*(\d+)/i.exec(value ?? '');
  if (!m) return null;
  const isHex = m[0].startsWith('#') || /^[0-9a-f]{6}/i.test(m[0]);
  return [m[1], m[2], m[3]].map(x => Math.round((isHex ? parseInt(x, 16) : Number(x)) / 255 * 1000) / 1000);
}
const colorKey = (key: string) => editing.value + '|' + key;
const colorOf = (key: string) => shownColor.get(colorKey(key)) ?? hex(current.value?.edge.find(e => e.key === key)?.value);
async function commitColor(ck: string, preset: string, key: string, rgb: number[]) {
  timers.delete(ck);
  await props.perform({ kind: 'dissolve-edge', preset, key, value: rgb });
  if (!timers.has(ck)) shownColor.delete(ck);
}
function setColor(key: string, value: string | null, live = false) {
  const rgb = parseColor(value);
  if (!rgb) return;
  // 刚打开或快照刚刷新时取色器也会发一次 active-change,和当前显示相同就不是在拖
  if (live && hex(rgb).toLowerCase() === colorOf(key).toLowerCase()) return;
  const ck = colorKey(key), preset = editing.value;
  shownColor.set(ck, hex(rgb));
  const old = timers.get(ck);
  if (old) clearTimeout(old);
  if (live) timers.set(ck, setTimeout(() => void commitColor(ck, preset, key, rgb), 250));
  else void commitColor(ck, preset, key, rgb);
}
</script>

<template>
  <div class="re4-main">
    <section class="re4-panel re4-panel-body">
      <div class="re4-panel-title">{{ t('dissolveTransition') }}</div>
      <div class="re4-row">
        <ElSwitch :model-value="snapshot.settings.uiDissolveEnabled" :disabled="busy" size="small" @change="v => setting('ui_dissolve_enabled', v === true)" />
        <span>{{ t('uiDissolve') }}</span>
        <span class="re4-muted re4-small">{{ t('uiDissolveTime') }}</span>
        <Re4Num :value="snapshot.settings.uiDissolveTime" :min="0" :max="30" :disabled="busy" :aria-label="t('uiDissolveTime')"
          @change="v => v !== undefined && setting('ui_dissolve_time', v)" />
        <span class="re4-muted re4-small">{{ t('seconds') }}</span>
      </div>
    </section>

    <section v-if="lib" class="re4-panel re4-panel-body re4-dis-presets">
      <div class="re4-panel-title">{{ t('dissolvePresets') }}</div>
      <p class="re4-lead">{{ t('dissolvePresetsLead') }}</p>
      <div class="re4-row">
        <span>{{ t('dissolveDefault') }}</span>
        <ElSelect :model-value="lib.default" :empty-values="[null, undefined]" :disabled="busy" size="small" style="width: 14em"
          :aria-label="t('dissolveDefault')" @change="v => perform({ kind: 'dissolve-default', preset: String(v) })">
          <ElOption value="random" :label="t('dissolveDefaultRandom')" />
          <ElOption v-for="p in presets" :key="p.name" :value="p.name" :label="p.name" />
        </ElSelect>
        <span class="re4-muted re4-small">{{ t('dissolveDefaultHint') }}</span>
      </div>
      <div class="re4-row">
        <span>{{ t('dissolvePresetEdit') }}</span>
        <ElSelect v-if="presets.length" :model-value="editing" size="small" style="width: 14em" :aria-label="t('dissolvePresetEdit')"
          @change="v => editing = String(v)">
          <ElOption v-for="p in presets" :key="p.name" :value="p.name" :label="p.name">
            <span>{{ p.name }}</span>
            <span v-if="lib.default === p.name" class="re4-tag on re4-dis-opttag">{{ t('dissolveDefaultTag') }}</span>
          </ElOption>
        </ElSelect>
        <span v-else class="re4-muted re4-small">{{ t('dissolveNone') }}</span>
        <ElButton size="small" :disabled="busy" @click="openNew">{{ t('dissolvePresetNew') }}</ElButton>
        <template v-if="current">
          <ElButton size="small" :disabled="busy" @click="openRename">{{ t('rename') }}</ElButton>
          <ElButton size="small" type="danger" plain :disabled="busy" @click="confirmDelete = true">{{ t('delete') }}</ElButton>
        </template>
      </div>
      <ElDialog v-model="dialog.open" :title="dialog.mode === 'rename' ? t('dissolvePresetRename') : t('dissolvePresetNew')" width="420px" append-to-body>
        <div class="re4-pal-dialog">
          <ElInput v-model="dialog.name" size="small" :placeholder="t('dissolvePresetName')" maxlength="48" @keyup.enter="submitDialog" />
          <span v-if="nameTaken" class="re4-small re4-bad-text">{{ t('dissolvePresetTaken') }}</span>
          <template v-if="dialog.mode === 'new'">
            <label class="re4-small"><input v-model="dialog.from" type="radio" value="none"> {{ t('dissolveFromNone') }}</label>
            <label v-if="editing" class="re4-small"><input v-model="dialog.from" type="radio" value="current"> {{ t('dissolveFromCurrent', editing) }}</label>
          </template>
        </div>
        <template #footer>
          <ElButton size="small" @click="dialog.open = false">{{ t('cancel') }}</ElButton>
          <ElButton size="small" type="primary" :disabled="busy || !dialogOk" @click="submitDialog">{{ t('confirm') }}</ElButton>
        </template>
      </ElDialog>
      <ElDialog v-model="confirmDelete" :title="t('dissolvePresetDelete')" width="420px" append-to-body>
        <p class="re4-small">{{ t('dissolvePresetDeleteBody', editing) }}</p>
        <template #footer>
          <ElButton size="small" @click="confirmDelete = false">{{ t('cancel') }}</ElButton>
          <ElButton size="small" type="danger" :disabled="busy" @click="doDelete">{{ t('delete') }}</ElButton>
        </template>
      </ElDialog>
    </section>

    <template v-if="current">
      <section class="re4-panel re4-panel-body">
        <div class="re4-panel-title">{{ t('dissolveShape') }}</div>
        <p class="re4-lead">{{ t('dissolveShapeLead') }}</p>
        <div class="re4-row">
          <span>{{ t('dissolveShape') }}</span>
          <ElSelect :model-value="current.shape" :disabled="busy" size="small" style="width: 12em" :aria-label="t('dissolveShape')" @change="setShape">
            <ElOption value="random" :label="t('effectRandom')" />
            <ElOption v-for="s in shapes" :key="s.id" :value="s.id" :label="shapeLabel(s.id)" />
          </ElSelect>
        </div>
      </section>

      <section class="re4-panel re4-panel-body">
        <div class="re4-panel-title">{{ t('dissolveEdge') }}</div>
        <p class="re4-lead">{{ t('dissolveEdgeLead') }}</p>
        <div v-for="e in current.edge" :key="e.key" class="re4-row">
          <ElSwitch :model-value="e.on" :disabled="busy" size="small" :aria-label="label(e)" @change="v => edge(e.key, { on: v === true })" />
          <span :class="{ 're4-muted': !e.on }">{{ label(e) }}</span>
          <ElColorPicker v-if="e.kind === 'color'" :model-value="colorOf(e.key)" :disabled="!e.on"
            @active-change="v => setColor(e.key, v, true)" @change="v => setColor(e.key, v)" />
          <Re4Num v-else :value="typeof e.value === 'number' ? e.value : undefined" :min="e.min" :max="e.max" :disabled="busy || !e.on"
            :aria-label="label(e)" @change="v => v !== undefined && edge(e.key, { value: v })" />
          <span class="re4-muted re4-small">{{ hint(e) }}</span>
        </div>
      </section>
    </template>

    <section v-if="others().length" class="re4-panel re4-panel-body">
      <div class="re4-panel-title">{{ t('dissolveOthers') }}</div>
      <p class="re4-lead">{{ t('dissolveOthersLead') }}</p>
      <div v-for="p in others()" :key="p.id" class="re4-row">
        <span>{{ pick(p.name) ?? p.id }}</span>
        <ElSelect :model-value="p.mode" :disabled="busy" size="small" style="width: 12em" :aria-label="pick(p.name) ?? p.id"
          @change="v => selectOther(p.id, v)">
          <ElOption value="random" :label="t('effectRandom')" />
          <ElOption v-for="id in p.effects" :key="id" :value="id" :label="effectLabel(p, id)" />
        </ElSelect>
        <span class="re4-muted re4-small">{{ t('dissolveEffectHint') }}</span>
      </div>
    </section>
  </div>
</template>

<style scoped>
.re4-dis-presets .re4-row { flex-wrap: wrap; gap: 6px; align-items: center; }
.re4-dis-presets .el-button + .el-button { margin-left: 0; }
.re4-dis-opttag { margin-left: 6px; }
</style>
