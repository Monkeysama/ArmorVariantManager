import { computed, onBeforeUnmount, onMounted, shallowRef, watch, type Ref } from 'vue';
import { REFF_UI_VERSION } from '@reff/ui';
import { createEmbeddedTransport, createReffClient, installInputFocusReporter } from '@reff-sdk/index';
import type { Documentation, Imports, Perform, Snapshot } from './types';
import { normalizeDocumentation, normalizeImports, normalizeSnapshot } from './snapshot';

export function useAvm(helpOpen: Readonly<Ref<boolean>>) {
  const client = createReffClient(createEmbeddedTransport());
  const stopInput = installInputFocusReporter(client);
  const snapshot = shallowRef<Snapshot | null>(null);
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

  function refresh() {
    if (disposed || busy.value || read || documentationRead || importsRead || document.hidden || !ready) return;
    read = client.call<Snapshot>('monkeysama.avm.snapshot').then(value => {
      if (!disposed) snapshot.value = normalizeSnapshot(value);
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
  const perform: Perform = async actions => {
    if (busy.value || !ready || disposed) return false;
    const bodyId = snapshot.value?.bodyId ?? '';
    busy.value = true;
    notice.value = '';
    try {
      await read;
      await documentationRead;
      // The picker displays list-read errors; they must not block unrelated writes.
      await importsRead?.catch(() => undefined);
      for (const action of Array.isArray(actions) ? actions : [actions]) {
        const params = action.kind === 'mode' || action.kind === 'theme' ? action : { ...action, bodyId };
        const value = await client.call<Snapshot>('monkeysama.avm.action', params);
        if (disposed) return false;
        snapshot.value = normalizeSnapshot(value);
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
    window.parent.postMessage({ type: 'reff:plugin-ready', pluginId: 'monkeysama.avm', uiVersion: REFF_UI_VERSION, styled: true }, '*');
  });
  onBeforeUnmount(() => {
    disposed = true;
    window.clearInterval(timer);
    document.removeEventListener('visibilitychange', visible);
    stopInput(); client.dispose();
  });
  return { snapshot, busy, loading, error, notice, perform, connect, documentation, documentationLoading, documentationError, retryDocumentation: () => loadDocumentation(true), loadImports };
}
