import { onBeforeUnmount, shallowRef } from 'vue';

// 拖动排序。不用 HTML5 原生拖放：REFF 是 WebView2 离屏渲染、鼠标由插件转发，宿主没有接系统级的
// OLE 拖放，一开始原生拖动页面就卡在拖动状态里。这里只用 pointer 事件：在手柄上按下，
// 移动时按指针位置找落点，松开时提交。监听挂在 window 上，不依赖 setPointerCapture。
//
// itemSelector 选出参与排序的条目(按页面顺序);onMove(from, to) 的下标从 0 开始,to 是移动后的位置。
export function usePointerReorder(itemSelector: string, onMove: (from: number, to: number) => unknown) {
  const from = shallowRef(-1);
  const drop = shallowRef<{ index: number; after: boolean } | null>(null);
  let startY = 0, moved = false;

  const items = () => Array.from(document.querySelectorAll<HTMLElement>(itemSelector));
  function locate(y: number) {
    const list = items();
    if (!list.length) return null;
    for (const [i, el] of list.entries()) {
      const r = el.getBoundingClientRect();
      if (y < r.bottom || i === list.length - 1) return { index: i, after: y > r.top + r.height / 2 };
    }
    return null;
  }
  function onPointerMove(e: PointerEvent) {
    if (from.value < 0) return;
    if (!moved && Math.abs(e.clientY - startY) < 4) return;
    moved = true;
    e.preventDefault();
    drop.value = locate(e.clientY);
  }
  function stop() {
    window.removeEventListener('pointermove', onPointerMove);
    window.removeEventListener('pointerup', onPointerUp);
    window.removeEventListener('pointercancel', cancel);
    window.removeEventListener('keydown', onKey);
    document.body.classList.remove('re4-reordering');
    from.value = -1; drop.value = null; moved = false;
  }
  function cancel() { stop(); }
  function onKey(e: KeyboardEvent) { if (e.key === 'Escape') stop(); }
  function onPointerUp() {
    const f = from.value, d = drop.value, did = moved;
    stop();
    if (!did || f < 0 || !d) return;
    let to = d.index + (d.after ? 1 : 0);
    if (to > f) to--;
    if (to !== f) void onMove(f, to);
  }
  function start(e: PointerEvent, index: number) {
    if (e.button !== 0) return;
    e.preventDefault();
    stop();
    from.value = index; startY = e.clientY; moved = false;
    document.body.classList.add('re4-reordering');
    window.addEventListener('pointermove', onPointerMove);
    window.addEventListener('pointerup', onPointerUp);
    window.addEventListener('pointercancel', cancel);
    window.addEventListener('keydown', onKey);
  }
  onBeforeUnmount(stop);
  return { from, drop, start };
}
