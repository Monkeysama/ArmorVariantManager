import { test } from 'node:test';
import assert from 'node:assert/strict';
import { effectScope } from 'vue';
import { useCatalogSort } from '../src/useCatalogSort.ts';

// DOM 生命周期单测；实际命中与指针捕获另由独立浏览器使用真实输入验证。
function fixture() {
  const originals = new Map(['window', 'document', 'requestAnimationFrame', 'cancelAnimationFrame'].map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
  const frames = new Map(), calls = [];
  let frameId = 0, hit = null;
  const win = new EventTarget(), doc = new EventTarget();
  doc.hidden = false; doc.elementFromPoint = () => hit;
  globalThis.window = win; globalThis.document = doc;
  globalThis.requestAnimationFrame = callback => { frames.set(++frameId, callback); return frameId; };
  globalThis.cancelAnimationFrame = id => frames.delete(id);
  const list = { scrollTop: 0, contains: row => row.list === list,
    getBoundingClientRect: () => ({ left: 0, right: 100, top: 0, bottom: 200, height: 200 }) };
  class Row extends EventTarget {
    constructor(name, top) { super(); this.name = name; this.top = top; this.list = list; this.capture = false; this.visible = true; this.dataset = { sortList: 'group', sortName: name }; }
    closest(selector) { return selector === '.catalog-list' ? list : this; }
    getBoundingClientRect() { return { top: this.top, height: 30 }; }
    getClientRects() { return this.visible ? [{}] : []; }
    setPointerCapture() { this.capture = true; }
    hasPointerCapture() { return this.capture; }
    releasePointerCapture() { this.capture = false; this.dispatchEvent(new Event('lostpointercapture')); }
  }
  const source = new Row('source', 30), target = new Row('target', 90), fixed = new Row('fixed', 0);
  const scope = effectScope();
  const sort = scope.run(() => useCatalogSort({ sortable: (_list, name) => ['source', 'target'].includes(name),
    commit: async (...args) => { calls.push(args); return false; } }));
  for (const row of [source, target, fixed]) row.addEventListener('pointerdown', event => sort.begin(event, 'group', row.name));
  function pointer(target, type, values = {}) {
    const event = new Event(type, { cancelable: true });
    Object.assign(event, { pointerId: 1, isPrimary: true, button: 0, buttons: type === 'pointerup' ? 0 : 1, clientX: 50, clientY: 45, ...values });
    target.dispatchEvent(event); return event;
  }
  function click(detail = 1) { const event = new Event('click', { cancelable: true }); Object.assign(event, { detail }); return sort.acceptClick(event); }
  function start() { pointer(source, 'pointerdown'); hit = target; pointer(source, 'pointermove', { clientY: 110 }); }
  function clean() {
    scope.stop();
    for (const [key, descriptor] of originals) { if (descriptor) Object.defineProperty(globalThis, key, descriptor); else delete globalThis[key]; }
  }
  return { sort, calls, source, target, fixed, scope, win, doc, list, frames, pointer, click, start, clean,
    hit: value => { hit = value; }, frame: () => { const [id, callback] = frames.entries().next().value; frames.delete(id); callback(); } };
}

test('click/jitter stay clicks; active release commits once and suppresses only its trailing pointer click', () => {
  const f = fixture();
  try {
    f.pointer(f.source, 'pointerdown'); f.pointer(f.source, 'pointermove', { clientY: 48 }); f.pointer(f.source, 'pointerup');
    assert.equal(f.click(), true); assert.equal(f.calls.length, 0);
    f.start(); assert.equal(f.source.capture, true); assert.equal(f.sort.rowClass('group', 'source')['is-dragging'], true);
    f.pointer(f.source, 'pointerup', { clientY: 110 });
    assert.deepEqual(f.calls, [['group', 'source', 'target', true]]);
    assert.equal(f.source.capture, false); assert.equal(f.frames.size, 0); assert.equal(f.click(), false); assert.equal(f.click(0), true);
    f.pointer(f.source, 'pointerup', { clientY: 110 }); assert.equal(f.calls.length, 1);
    f.pointer(f.source, 'pointerdown'); f.pointer(f.source, 'pointerup'); assert.equal(f.click(), true);
    // A rejected save has no retained capture or in-flight gesture, so the next drag can retry.
    f.start(); f.pointer(f.source, 'pointerup', { clientY: 110 }); assert.equal(f.calls.length, 2);
  } finally { f.clean(); }
});

test('fixed rows, other lists and releases outside the catalog never reorder', () => {
  const f = fixture();
  try {
    f.pointer(f.fixed, 'pointerdown'); assert.equal(f.fixed.capture, false);
    for (const destination of [f.fixed, null, { ...f.target, dataset: { sortList: 'preset', sortName: 'target' }, closest() { return this; } }]) {
      f.start(); f.hit(destination); f.pointer(f.source, 'pointerup', { clientY: 110 });
      assert.equal(f.calls.length, 0); assert.equal(f.source.capture, false);
    }
  } finally { f.clean(); }
});

for (const reason of ['pointercancel', 'lostpointercapture', 'blur', 'pagehide', 'hidden', 'Escape', 'second-pointer', 'missing-button', 'hidden-pane', 'context', 'unmount']) {
  test(`${reason} releases capture/scroll/listeners; late pointerup cannot save`, () => {
    const f = fixture();
    try {
      f.start();
      if (reason === 'pointercancel' || reason === 'lostpointercapture') f.source.dispatchEvent(new Event(reason));
      else if (reason === 'blur' || reason === 'pagehide') f.win.dispatchEvent(new Event(reason));
      else if (reason === 'hidden') { f.doc.hidden = true; f.doc.dispatchEvent(new Event('visibilitychange')); }
      else if (reason === 'Escape') { const event = new Event('keydown', { cancelable: true }); Object.assign(event, { key: 'Escape' }); f.win.dispatchEvent(event); assert.equal(event.defaultPrevented, true); }
      else if (reason === 'second-pointer') f.pointer(f.win, 'pointerdown', { pointerId: 2, isPrimary: false });
      else if (reason === 'missing-button') f.pointer(f.source, 'pointermove', { buttons: 0 });
      else if (reason === 'hidden-pane') { f.source.visible = false; f.pointer(f.source, 'pointermove'); }
      else if (reason === 'context') f.sort.cancel();
      else f.scope.stop();
      f.pointer(f.source, 'pointerup', { clientY: 110 });
      assert.equal(f.calls.length, 0); assert.equal(f.source.capture, false); assert.equal(f.frames.size, 0);
      assert.equal(f.sort.rowClass('group', 'source')['is-dragging'], false);
      if (reason !== 'unmount') {
        f.source.visible = true; f.doc.hidden = false; f.start(); f.pointer(f.source, 'pointerup', { clientY: 110 });
        assert.equal(f.calls.length, 1);
      }
    } finally { f.clean(); }
  });
}

test('edge scrolling stops on cancel and cannot leave an animation loop behind', () => {
  const f = fixture();
  try {
    f.start(); f.pointer(f.source, 'pointermove', { clientY: 195 }); f.frame();
    assert.equal(f.list.scrollTop, 8); assert.equal(f.frames.size, 1);
    f.sort.cancel(); assert.equal(f.frames.size, 0);
  } finally { f.clean(); }
});
