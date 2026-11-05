import { computed, onBeforeUnmount, onMounted, shallowRef, watch, type Ref } from 'vue';
import { REFF_UI_VERSION } from '@reff/ui';
import { createEmbeddedTransport, createReffClient, installInputFocusReporter } from '@reff-sdk/index';
import type { AnyAction, AnySnapshot, Documentation, Imports } from './types';
import { normalizeDocumentation, normalizeImports, normalizeSnapshot } from './snapshot';
import { normalizeRe4 } from './re4/snapshot';

// 同一条通道服务多款游戏：RE4 的快照走自己的归一化，MH 的保持原样。
const normalize = (value: AnySnapshot): AnySnapshot => value.game === 'RE4' ? normalizeRe4(value) : normalizeSnapshot(value);

export function useAvm(helpOpen: Readonly<Ref<boolean>>) {
  const client = createReffClient(createEmbeddedTransport());
  const stopInput = installInputFocusReporter(client);
  const snapshot = shallowRef<AnySnapshot | null>(null);
  const busy = shallowRef(false);
  const loading = shallowRef(true);
  const error = shallowRef('');
  const notice = shallowRef('');
  const documentation = shallowRef<Documentation | null>(null);
  const documentationLoading = shallowRef(false);
  const documentationError = shallowRef('');
  const documentationKey = computed(() => snapshot.value ? `${snapshot.value.game}:${snapshot.value.language}` : '');
  const documentationCache = new Map<string, Documentation>();
  let disposed = false;
  let ready = false;
  let read: Promise<void> | undefined;
  let documentationRead: Promise<void> | undefined;
  let importsRead: Promise<Imports> | undefined;
  let timer: number | undefined;
  // 轮询每次都整份替换快照，整页随之重渲染；打字时这一下会让输入框周期性顿住。
  // 所以最近有键盘输入时跳过轮询，快照内容没变时也不替换（不触发重渲染）。
  // 不用 document.activeElement 判断：REFF 的原生输入代理接管焦点后，页面里常常已不是输入框。
  const TYPING_PAUSE_MS = 1500;
  let lastTyping = 0;
  let lastRaw = '';
  const markTyping = () => { lastTyping = performance.now(); };
  function accept(value: AnySnapshot) {
    const raw = JSON.stringify(value);
    if (raw === lastRaw && snapshot.value) return;
    lastRaw = raw;
    snapshot.value = normalize(value);
  }

  function refresh() {
    if (disposed || busy.value || read || documentationRead || importsRead || document.hidden || !ready) return;
    if (performance.now() - lastTyping < TYPING_PAUSE_MS) return;
    read = client.call<AnySnapshot>('monkeysama.avm.snapshot').then(value => {
      if (!disposed) accept(value);
    }).catch(reason => { if (!disposed) error.value = reason instanceof Error ? reason.message : String(reason); })
      .finally(() => { read = undefined; loading.value = false; });
    return read;
  }
  function loadDocumentation(retry = false) {
    if (retry) documentationError.value = '';
    if (disposed || !ready || !helpOpen.value || !documentationKey.value || documentation.value || documentationError.value || busy.value || documentationRead || importsRead) return;
    documentationLoading.value = true;
    documentationRead = (async () => {
      await read;
      const key = documentationKey.value;
      try {
        const value = normalizeDocumentation(await client.call<Documentation>('monkeysama.avm.documentation'));
        if (disposed) return;
        documentationCache.set(key, value);
        if (documentationKey.value === key) documentation.value = value;
      } catch (reason) {
        if (!disposed && documentationKey.value === key) documentationError.value = reason instanceof Error ? reason.message : String(reason);
      }
    })().finally(() => {
      documentationRead = undefined;
      documentationLoading.value = false;
      loadDocumentation();
    });
  }
  watch([helpOpen, documentationKey], () => {
    documentation.value = documentationCache.get(documentationKey.value) ?? null;
    documentationError.value = '';
    loadDocumentation();
  });
  function loadImports(): Promise<Imports> {
    if (importsRead) return importsRead;
    importsRead = (async () => {
      await read;
      await documentationRead;
      return normalizeImports(await client.call<Imports>('monkeysama.avm.imports'));
    })().finally(() => { importsRead = undefined; loadDocumentation(); });
    return importsRead;
  }
  async function connect() {
    loading.value = true;
    error.value = '';
    try {
      await client.ready();
      await client.call('ui.layout.set', { padding: 0 });
      ready = true;
      await refresh();
    } catch (reason) { error.value = reason instanceof Error ? reason.message : String(reason); }
    finally { loading.value = false; }
  }
  // Polls, on-demand reads and writes share one lane; older reads cannot overwrite action results.
  const perform = async (actions: AnyAction | AnyAction[]): Promise<boolean> => {
    if (busy.value || !ready || disposed) return false;
    const current = snapshot.value;
    const bodyId = current && current.game !== 'RE4' ? current.bodyId : '';
    busy.value = true;
    notice.value = '';
    try {
      await read;
      await documentationRead;
      // The picker displays list-read errors; they must not block unrelated writes.
      await importsRead?.catch(() => undefined);
      for (const action of Array.isArray(actions) ? actions : [actions]) {
        // RE4 的操作自带角色 id，不附加 MH 的装备 id。
        const params = current?.game === 'RE4' ? { ...action }
          : action.kind === 'mode' || action.kind === 'theme' ? action : { ...action, bodyId };
        const value = await client.call<AnySnapshot>('monkeysama.avm.action', params);
        if (disposed) return false;
        accept(value);
      }
      error.value = '';
      return true;
    } catch (reason) {
      if (!disposed) error.value = reason instanceof Error ? reason.message : String(reason);
      return false;
    } finally { busy.value = false; loadDocumentation(); }
  };
  const visible = () => { if (!document.hidden) void refresh(); };
  onMounted(() => {
    void connect();
    timer = window.setInterval(refresh, 1000);
    document.addEventListener('visibilitychange', visible);
    window.addEventListener('keydown', markTyping, true);
    window.addEventListener('input', markTyping, true);
    window.addEventListener('compositionupdate', markTyping, true);
    window.parent.postMessage({ type: 'reff:plugin-ready', pluginId: 'monkeysama.avm', uiVersion: REFF_UI_VERSION, styled: true }, '*');
  });
  onBeforeUnmount(() => {
    disposed = true;
    window.clearInterval(timer);
    document.removeEventListener('visibilitychange', visible);
    window.removeEventListener('keydown', markTyping, true);
    window.removeEventListener('input', markTyping, true);
    window.removeEventListener('compositionupdate', markTyping, true);
    stopInput(); client.dispose();
  });
  return { client, snapshot, busy, loading, error, notice, perform, connect, documentation, documentationLoading, documentationError, retryDocumentation: () => loadDocumentation(true), loadImports };
}
