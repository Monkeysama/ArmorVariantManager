import { onScopeDispose, shallowRef } from 'vue';

export type CatalogList = 'group' | 'preset';
type Row = { list: CatalogList; name: string };
type Target = Row & { after: boolean };
type Gesture = Row & { pointerId: number; x: number; y: number; startX: number; startY: number;
  element: HTMLElement; listElement: HTMLElement; listeners: AbortController };

// 排序只使用页面内指针捕获，避免 HTML5 拖放进入 WebView2 宿主的原生拖拽循环。
export function useCatalogSort(options: {
  sortable: (list: CatalogList, name: string) => boolean;
  commit: (list: CatalogList, name: string, target: string, after: boolean) => Promise<unknown>;
}) {
  const dragging = shallowRef<Row | null>(null);
  const target = shallowRef<Target | null>(null);
  let gesture: Gesture | null = null;
  let scrollFrame = 0;
  let suppressClick = false;

  function cancel() {
    const previous = gesture;
    suppressClick ||= !!dragging.value;
    gesture = null; dragging.value = null; target.value = null;
    cancelAnimationFrame(scrollFrame); scrollFrame = 0;
    previous?.listeners.abort();
    if (previous?.element.hasPointerCapture(previous.pointerId)) previous.element.releasePointerCapture(previous.pointerId);
  }

  function preview() {
    const current = gesture;
    target.value = null;
    if (!current || !dragging.value) return;
    if (!current.element.getClientRects().length || !options.sortable(current.list, current.name)) { cancel(); return; }
    const row = document.elementFromPoint(current.x, current.y)?.closest<HTMLElement>('.sortable-row');
    if (!row || !current.listElement.contains(row) || row.dataset.sortList !== current.list) return;
    const name = row.dataset.sortName;
    if (name === undefined || name === current.name || !options.sortable(current.list, name)) return;
    const rect = row.getBoundingClientRect();
    target.value = { list: current.list, name, after: current.y >= rect.top + rect.height / 2 };
  }

  // 仅在列表边缘滚动；松手或取消时清除逐帧任务。
  function scroll() {
    scrollFrame = 0;
    const current = gesture;
    if (!current || !dragging.value) return;
    const rect = current.listElement.getBoundingClientRect();
    if (current.x >= rect.left && current.x <= rect.right && current.y >= rect.top && current.y <= rect.bottom) {
      const edge = Math.min(28, rect.height / 4);
      const speed = current.y < rect.top + edge ? -8 : current.y > rect.bottom - edge ? 8 : 0;
      if (speed) { current.listElement.scrollTop += speed; preview(); }
    }
    if (gesture) scrollFrame = requestAnimationFrame(scroll);
  }

  function move(event: PointerEvent) {
    const current = gesture;
    if (!current || event.pointerId !== current.pointerId) return;
    if (!(event.buttons & 1)) { cancel(); return; }
    current.x = event.clientX; current.y = event.clientY;
    if (!dragging.value && Math.hypot(current.x - current.startX, current.y - current.startY) < 6) return;
    event.preventDefault();
    if (!dragging.value) {
      dragging.value = { list: current.list, name: current.name };
      scrollFrame = requestAnimationFrame(scroll);
    }
    preview();
  }

  async function finish(event: PointerEvent) {
    const current = gesture;
    if (!current || event.pointerId !== current.pointerId) return;
    current.x = event.clientX; current.y = event.clientY;
    preview();
    const destination = target.value;
    cancel();
    if (destination && options.sortable(current.list, current.name) && options.sortable(current.list, destination.name)) {
      await options.commit(current.list, current.name, destination.name, destination.after);
    }
  }

  function begin(event: PointerEvent, list: CatalogList, name: string) {
    cancel(); suppressClick = false;
    if (!event.isPrimary || event.button !== 0 || !options.sortable(list, name)) return;
    const element = event.currentTarget as HTMLElement;
    const listElement = element.closest<HTMLElement>('.catalog-list');
    if (!listElement) return;
    const listeners = new AbortController();
    gesture = { list, name, pointerId: event.pointerId, x: event.clientX, y: event.clientY,
      startX: event.clientX, startY: event.clientY, element, listElement, listeners };
    // 不阻止普通点击与焦点；移动超过阈值后才视为排序。
    element.setPointerCapture(event.pointerId);
    const { signal } = listeners;
    element.addEventListener('pointermove', move, { signal });
    element.addEventListener('pointerup', finish, { signal });
    element.addEventListener('pointercancel', cancel, { signal });
    element.addEventListener('lostpointercapture', cancel, { signal });
    window.addEventListener('blur', cancel, { signal });
    window.addEventListener('pagehide', cancel, { signal });
    window.addEventListener('keydown', event => {
      if (event.key === 'Escape') { event.preventDefault(); cancel(); }
    }, { signal });
    window.addEventListener('pointerdown', event => { if (event.pointerId !== gesture?.pointerId) cancel(); }, { signal });
    document.addEventListener('visibilitychange', () => { if (document.hidden) cancel(); }, { signal });
  }

  // 捕获松手仍可能生成 click；仅吞掉本次拖动的点击，键盘激活与下一次按下照常使用。
  function acceptClick(event: MouseEvent) {
    if (!suppressClick || event.detail === 0) return true;
    event.preventDefault(); event.stopPropagation(); return false;
  }

  function rowClass(list: CatalogList, name: string) {
    return { 'is-dragging': dragging.value?.list === list && dragging.value.name === name,
      'drop-before': target.value?.list === list && target.value.name === name && !target.value.after,
      'drop-after': target.value?.list === list && target.value.name === name && target.value.after };
  }

  onScopeDispose(cancel);
  return { begin, cancel, acceptClick, rowClass };
}
