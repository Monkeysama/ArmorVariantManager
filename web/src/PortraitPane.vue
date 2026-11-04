<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, shallowRef, useTemplateRef } from 'vue';
import { registerNativePreviewSlot, type NativePreviewSlot, type ReffClient } from '@reff-sdk/index';
import type { Translate } from './i18n';
import type { Preview } from './types';

const props = defineProps<{ client: ReffClient; preview: Preview; t: Translate }>();
const viewport = useTemplateRef<HTMLElement>('viewport');
const current = shallowRef<Preview>();
const error = shallowRef('');
const state = computed(() => current.value ?? props.preview);
const message = computed(() => {
  if (error.value) return error.value;
  if (!state.value.available) return props.t('previewUnavailable');
  if (state.value.error) return state.value.error;
  if (state.value.status === 'preview_output_unsupported') return props.t('previewSdr');
  if (state.value.status === 'preview_compositor_waiting') return props.t('previewWaitingForHost');
  return props.t(state.value.status === 'preview_live' ? 'previewLive' : 'previewWaiting');
});
let slot: NativePreviewSlot | undefined;
let timer: number | undefined;
let disposed = false;
let pending = false;

// 网页只租用相机并报告正式槽位；纹理和 GPU 同步不经过 RPC。
async function heartbeat() {
  if (pending || disposed) return;
  pending = true;
  try {
    const bounds = viewport.value?.getBoundingClientRect();
    const value = await props.client.call<Preview>('monkeysama.avm.preview', {
      visible: !document.hidden && !!bounds && bounds.width > 0 && bounds.height > 0,
      width: bounds?.width, height: bounds?.height,
    });
    if (!disposed) { current.value = value; error.value = ''; }
  } catch (reason) {
    if (!disposed) error.value = reason instanceof Error ? reason.message : String(reason);
  } finally { pending = false; }
}
onMounted(async () => {
  if (!props.preview.available || !viewport.value) return;
  try {
    const registered = await registerNativePreviewSlot(props.client, viewport.value, 'portrait');
    if (disposed) { registered.dispose(); return; }
    slot = registered;
    void heartbeat();
    timer = window.setInterval(heartbeat, 200);
    document.addEventListener('visibilitychange', heartbeat);
  } catch (reason) {
    if (!disposed) error.value = reason instanceof Error ? reason.message : String(reason);
  }
});
onBeforeUnmount(() => {
  disposed = true;
  window.clearInterval(timer);
  document.removeEventListener('visibilitychange', heartbeat);
  slot?.dispose();
  void props.client.call('monkeysama.avm.preview', { visible: false }).catch(() => {});
});
</script>

<template>
  <aside class="portrait-pane" :aria-label="t('preview')">
    <h2 class="portrait-heading">{{ t('preview') }}</h2>
    <div class="portrait-stage"><div ref="viewport" class="portrait-viewport"
      :class="{ 'portrait-pending': state.status !== 'preview_live' || error || state.error }"
      :aria-label="t('preview')"></div></div>
    <p class="portrait-status" :class="{ 'portrait-error': error || state.error }" role="status">{{ message }}</p>
  </aside>
</template>

<style scoped>
.portrait-pane { flex: 0 0 clamp(190px, 23%, 330px); display: flex; flex-direction: column; min-height: 0; border-right: 1px solid var(--avm-line); }
.portrait-heading { margin: 0; padding: 10px 16px; font-size: inherit; font-weight: 400; color: var(--avm-muted); background: var(--avm-bg); }
.portrait-stage { flex: 1; min-height: 0; display: flex; }
/* 原生层填实底；网页保持透明，整列高度交给相机与等比合成。 */
.portrait-viewport { flex: 1; min-width: 0; min-height: 0; }
.portrait-pending { background: #111819; }
/* 下缘重叠覆盖整数裁剪留下的亚像素缝，画布尺寸与文字位置不变。 */
.portrait-status { margin: 0; padding: 10px 16px; box-shadow: 0 -2px 0 #111819; font-size: inherit; color: var(--avm-muted); background: var(--avm-bg); overflow-wrap: anywhere; }
.portrait-error { color: var(--el-color-danger, #f29898); }
@media (max-width: 760px) {
  .portrait-pane { flex-basis: 330px; border-right: 0; border-bottom: 1px solid var(--avm-line); }
}
@media (max-width: 500px) {
  .portrait-heading, .portrait-status { padding-inline: 10px; }
}
</style>
