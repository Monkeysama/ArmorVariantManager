import { onBeforeUnmount, onMounted, shallowRef } from 'vue';
import { REFF_UI_VERSION } from '@reff/ui';
import { createEmbeddedTransport, createReffClient, installInputFocusReporter } from '@reff-sdk/index';
import type { Perform, Snapshot } from './types';
import { normalizeSnapshot } from './snapshot';

export function useAvm() {
  const client = createReffClient(createEmbeddedTransport());
  const stopInput = installInputFocusReporter(client);
  const snapshot = shallowRef<Snapshot | null>(null);
  const busy = shallowRef(false);
  const loading = shallowRef(true);
  const error = shallowRef('');
  const notice = shallowRef('');
  let disposed = false;
  let ready = false;
  let read: Promise<void> | undefined;
  let timer: number | undefined;

  function refresh() {
    if (disposed || busy.value || read || document.hidden || !ready) return;
    read = client.call<Snapshot>('monkeysama.avm.snapshot').then(value => {
      if (!disposed) snapshot.value = normalizeSnapshot(value);
    }).catch(reason => { if (!disposed) error.value = reason instanceof Error ? reason.message : String(reason); })
      .finally(() => { read = undefined; loading.value = false; });
    return read;
  }
  async function connect() {
    loading.value = true;
    error.value = '';
    try {
      await client.ready();
      ready = true;
      await refresh();
    } catch (reason) { error.value = reason instanceof Error ? reason.message : String(reason); }
    finally { loading.value = false; }
  }
  // Reads and writes share one lane: an older poll can never overwrite an action result.
  const perform: Perform = async actions => {
    if (busy.value || !ready || disposed) return false;
    const bodyId = snapshot.value?.bodyId ?? '';
    busy.value = true;
    notice.value = '';
    try {
      await read;
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
    } finally { busy.value = false; }
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
  return { snapshot, busy, loading, error, notice, perform, connect };
}
