import type { ProjectProfile, TabStatus } from './types.js';
interface State { projects: ProjectProfile[]; tabs: TabStatus[]; paused: boolean; nativeError: string; extensionId: string; host: string }
const el = (id: string) => document.getElementById(id)!;
let state: State;
async function send(message: Record<string, unknown>) { const result = await chrome.runtime.sendMessage(message); if (result?.error) throw new Error(result.error); return result; }
function note(message: string) { el('message').textContent = message; }
function button(text: string, action: () => Promise<unknown>) { const b = document.createElement('button'); b.textContent = text; b.addEventListener('click', () => { b.disabled = true; void action().then(() => refresh()).catch(e => note(String(e))).finally(() => { b.disabled = false; }); }); return b; }
function row(name: string, detail: string) { const r = document.createElement('div'); r.className = 'row'; const n = document.createElement('div'); n.className = 'name'; n.textContent = name; const d = document.createElement('div'); d.className = 'detail'; d.textContent = detail; r.append(n, d); return r; }
async function refresh() {
  state = await send({ kind: 'getState' });
  el('connection').textContent = state.nativeError || 'Connected to the Native Browser Lens Mac application.';
  el('extension-id').textContent = state.extensionId; el('host').textContent = state.host;
  el('pause').textContent = state.paused ? 'Resume collection' : 'Pause collection';
  el('projects').replaceChildren();
  for (const p of state.projects) {
    const r = row(p.name, p.origins.join(' · '));
    for (const origin of p.origins) {
      const granted = await chrome.permissions.contains({ origins: [`${origin}/*`] });
      r.append(button(granted ? `Revoke ${origin}` : `Enable ${origin}`, async () => {
        // The request itself must remain directly in this click gesture before any await.
        const operation = granted ? chrome.permissions.remove({ origins: [`${origin}/*`] }) : chrome.permissions.request({ origins: [`${origin}/*`] });
        const accepted = await operation;
        note(accepted ? `${origin}: ${granted ? 'access removed' : 'access enabled'}.` : 'Browser access was not changed.');
        await send({ kind: 'refresh' });
      }));
    }
    el('projects').append(r);
  }
  if (!state.projects.length) el('projects').textContent = 'No profiles yet. Add a project in the native app or import its profiles below.';
  el('tabs').replaceChildren();
  for (const t of state.tabs) {
    const r = row(`${t.title || t.url} · ${t.mode}`, `${t.url} · Window ${t.windowId} · ${t.reason || t.capabilities.join(', ')}`);
    r.append(button('Capture', async () => { await send({ kind: 'capture', tabId: t.tabId }); note('Capture sent to the native notebook.'); }));
    if (t.mode === 'unavailable') r.append(button('Resume tab', async () => { await send({ kind: 'resumeTab', tabId: t.tabId }); }));
    el('tabs').append(r);
  }
  if (!state.tabs.length) el('tabs').textContent = 'Open a configured project in Chrome to begin.';
}
el('pause').addEventListener('click', () => { void send({ kind: 'pause', paused: !state.paused }).then(refresh).catch(e => note(String(e))); });
el('reconnect').addEventListener('click', () => { void send({ kind: 'reconnect' }).then(refresh).catch(e => note(String(e))); });
el('import').addEventListener('click', () => { try { const projects = JSON.parse((el('profiles') as HTMLTextAreaElement).value); void send({ kind: 'configure', projects }).then(() => { note('Profiles imported. Grant each origin above.'); return refresh(); }).catch(e => note(String(e))); } catch (e) { note(String(e)); } });
void refresh().catch(e => note(String(e)));
setInterval(() => { void refresh().catch(() => {}); }, 5000);
