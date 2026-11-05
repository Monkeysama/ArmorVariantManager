<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, shallowRef, useTemplateRef } from 'vue';
import { registerNativePreviewSlot, type NativePreviewSlot, type ReffClient } from '@reff-sdk/index';
import type { Translate } from './i18n';
import type { Preview } from './types';

// controls:在预览区里用鼠标调相机,只有 RE4 页面打开:滚轮缩放 / 右键旋转 / 中键或 Shift+右键平移 / 双击复位,
// 左键空着。REFF 1.0.2 不把中键转发给网页(插件与宿主都只认左右键),所以同时保留 Shift+右键;转发中键的 REFF 上两者都能用。
// 相机参数随预览请求发给 Lua(camera 字段),Wilds 不传就不会收到。controlsHint 是提示文字(由页面给,不进共用文案)。
const props = defineProps<{ client: ReffClient; preview: Preview; t: Translate; controls?: boolean; controlsHint?: string }>();
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
let dirty = false;

const camera = { yaw: 0, pitch: 0, zoom: 1, pan_x: 0, pan_y: 0 };
const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));
let drag: { mode: 'pan' | 'rotate'; x: number; y: number } | null = null;
const dragging = shallowRef<'pan' | 'rotate' | null>(null);
// 相机一变就发,不等 200ms 心跳;请求进行中时记一笔,结束后补发
function sendCamera() { if (pending) dirty = true; else void heartbeat(); }
function onPointerDown(e: PointerEvent) {
  if (!props.controls || (e.button !== 1 && e.button !== 2)) return;
  e.preventDefault();   // 中键按下时浏览器默认进入自动滚动
  drag = { mode: e.button === 1 || e.shiftKey ? 'pan' : 'rotate', x: e.clientX, y: e.clientY };
  dragging.value = drag.mode;
  window.addEventListener('pointermove', onPointerMove);
  window.addEventListener('pointerup', endDrag);
  window.addEventListener('pointercancel', endDrag);
}
function onPointerMove(e: PointerEvent) {
  if (!drag) return;
  const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
  drag.x = e.clientX; drag.y = e.clientY;
  if (!dx && !dy) return;
  if (drag.mode === 'rotate') {
    camera.yaw -= dx * 0.01;
    camera.pitch = clamp(camera.pitch + dy * 0.008, -1.2, 1.2);
  } else {
    // 竖向可见高度 = 1.95 m / zoom,按槽位高度换算,拖多少像素画面就跟着移多少
    const metersPerPixel = 1.95 / camera.zoom / Math.max(1, viewport.value?.clientHeight ?? 1);
    camera.pan_x = clamp(camera.pan_x - dx * metersPerPixel, -2, 2);
    camera.pan_y = clamp(camera.pan_y + dy * metersPerPixel, -2, 2);
  }
  sendCamera();
}
function endDrag() {
  drag = null; dragging.value = null;
  window.removeEventListener('pointermove', onPointerMove);
  window.removeEventListener('pointerup', endDrag);
  window.removeEventListener('pointercancel', endDrag);
}
function onWheel(e: WheelEvent) {
  if (!props.controls || !e.deltaY) return;
  camera.zoom = clamp(camera.zoom * (e.deltaY < 0 ? 1.12 : 1 / 1.12), 0.5, 8);
  sendCamera();
}
function resetCamera() {
  if (!props.controls) return;
  Object.assign(camera, { yaw: 0, pitch: 0, zoom: 1, pan_x: 0, pan_y: 0 });
  sendCamera();
}

// 网页只租用相机并报告正式槽位；纹理和 GPU 同步不经过 RPC。
async function heartbeat() {
  if (pending || disposed) return;
  pending = true;
  try {
    const bounds = viewport.value?.getBoundingClientRect();
    const value = await props.client.call<Preview>('monkeysama.avm.preview', {
      visible: !document.hidden && !!bounds && bounds.width > 0 && bounds.height > 0,
      width: bounds?.width, height: bounds?.height,
      ...(props.controls ? { camera: { ...camera } } : {}),
    });
    if (!disposed) { current.value = value; error.value = ''; }
  } catch (reason) {
    if (!disposed) error.value = reason instanceof Error ? reason.message : String(reason);
  } finally {
    pending = false;
    if (dirty && !disposed) { dirty = false; void heartbeat(); }
  }
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
  endDrag();
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
      :class="{ 'portrait-pending': state.status !== 'preview_live' || error || state.error, 'portrait-controls': controls,
        [`portrait-${dragging}`]: !!dragging }"
      :aria-label="t('preview')" :title="controls ? controlsHint : undefined"
      @pointerdown="onPointerDown" @mousedown.middle.prevent @auxclick.prevent @wheel.prevent="onWheel" @dblclick="resetCamera"
      @contextmenu.prevent></div></div>
    <p class="portrait-status" :class="{ 'portrait-error': error || state.error }" role="status">{{ message }}</p>
    <p v-if="controls && controlsHint" class="portrait-hint">{{ controlsHint }}</p>
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
.portrait-controls { cursor: grab; touch-action: none; user-select: none; }
.portrait-pan { cursor: move; }
.portrait-rotate { cursor: grabbing; }
.portrait-hint { margin: 0; padding: 0 16px 10px; font-size: 12px; color: var(--avm-muted); background: var(--avm-bg); }
@media (max-width: 760px) {
  .portrait-pane { flex-basis: 330px; border-right: 0; border-bottom: 1px solid var(--avm-line); }
}
@media (max-width: 500px) {
  .portrait-heading, .portrait-status { padding-inline: 10px; }
}
</style>
