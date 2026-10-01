/**
 * Desktop update notification (Electron app only).
 *
 * Talks to the main process through window.desktopApp.updates, which the
 * preload bridge exposes (electron/preload.cjs). In a normal browser that
 * object does not exist and this module does nothing.
 *
 * Shows a small non-blocking card in the bottom-right corner:
 *   available  -> version, release notes, [Later] [Download & Install]
 *   downloading-> progress bar (download continues if the card is hidden)
 *   downloaded -> [Later] [Restart & Install]
 *   error      -> message, [Close] [Try again]
 * plus a version line with "Check for updates" at the bottom of the sidebar.
 * Release notes are inserted as text only, never as HTML.
 */

const bridge = typeof window !== 'undefined' && window.desktopApp && window.desktopApp.updates;

if (bridge) {
  const css = `
  .upd-card{position:fixed;right:18px;bottom:18px;z-index:9999;width:min(380px,calc(100vw - 36px));
    background:var(--card,#fff);color:var(--ink,#3a4555);border:1px solid var(--rule,#DCE0D9);
    border-radius:var(--r,12px);box-shadow:0 10px 30px rgba(27,42,65,.18);padding:16px 18px;
    font-family:var(--sans,system-ui);font-size:13px;line-height:1.45}
  .upd-card[hidden]{display:none}
  .upd-eyebrow{font-family:var(--mono,monospace);font-size:9.5px;letter-spacing:.14em;text-transform:uppercase;color:var(--ink-3,#56606b)}
  .upd-title{font-family:var(--serif,Georgia,serif);font-size:16.5px;font-weight:600;margin:4px 0 6px;color:var(--ink,#3a4555)}
  .upd-text{color:var(--ink-2,#234163)}
  .upd-notes{margin-top:10px;max-height:150px;overflow:auto;white-space:pre-wrap;font-size:12.5px;
    background:var(--rule-2,#EDEFEA);border-radius:8px;padding:8px 10px;color:var(--ink,#3a4555)}
  .upd-notes:empty{display:none}
  .upd-bar{height:6px;border-radius:3px;background:var(--rule-2,#EDEFEA);margin:10px 0 6px;overflow:hidden}
  .upd-bar > i{display:block;height:100%;width:0;background:var(--ink,#3a4555);transition:width .3s}
  .upd-meta{font-size:11.5px;color:var(--ink-3,#56606b)}
  .upd-actions{display:flex;gap:8px;justify-content:flex-end;margin-top:14px}
  .upd-actions:empty{display:none}
  .upd-version{font-size:11px;color:var(--ink-3,#56606b);margin-top:8px}
  .upd-version button{background:none;border:0;padding:0;font:inherit;color:var(--ink-2,#234163);
    text-decoration:underline;text-underline-offset:2px;cursor:pointer}
  .upd-version button:disabled{opacity:.6;cursor:default}`;
  const style = document.createElement('style');
  style.textContent = css;
  document.head.appendChild(style);

  const card = document.createElement('div');
  card.className = 'upd-card';
  card.hidden = true;
  card.setAttribute('role', 'status');
  card.setAttribute('aria-live', 'polite');
  card.innerHTML =
    '<div class="upd-eyebrow">Practice Manager update</div>' +
    '<div class="upd-title"></div><div class="upd-text"></div>' +
    '<div class="upd-progress" hidden><div class="upd-bar"><i></i></div><div class="upd-meta"></div></div>' +
    '<div class="upd-notes"></div><div class="upd-actions"></div>';
  const $ = (s) => card.querySelector(s);

  let current = null;           // last status from the main process
  let hiddenFor = null;         // state+version the user closed locally
  let autoHide = null;

  const mb = (n) => (n / 1048576).toFixed(1) + ' MB';
  const button = (label, primary, onClick) => {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'btn sm' + (primary ? '' : ' ghost');
    b.textContent = label;
    b.addEventListener('click', onClick);
    return b;
  };
  const hide = () => { card.hidden = true; if (current) hiddenFor = current.state + ':' + (current.version || ''); };

  function render(s) {
    current = s;
    clearTimeout(autoHide);
    renderVersionLine(s);
    const key = s.state + ':' + (s.version || '');
    const visible = ['checking', 'available', 'downloading', 'downloaded', 'error', 'not-available'].includes(s.state)
      && !(s.state === 'available' && s.snoozed)
      && !(s.state === 'not-available' && !s.message)
      && hiddenFor !== key;
    card.hidden = !visible;
    if (!visible) return;

    const actions = $('.upd-actions');
    actions.replaceChildren();
    $('.upd-progress').hidden = true;
    $('.upd-notes').textContent = '';

    if (s.state === 'checking') {
      $('.upd-title').textContent = 'Checking for updates…';
      $('.upd-text').textContent = 'You are on version ' + s.currentVersion + '.';
    } else if (s.state === 'not-available') {
      $('.upd-title').textContent = 'You’re up to date';
      $('.upd-text').textContent = 'Version ' + s.currentVersion + ' is the latest version.';
      autoHide = setTimeout(hide, 5000);
    } else if (s.state === 'available') {
      $('.upd-title').textContent = 'Version ' + s.version + ' is available';
      $('.upd-text').textContent = 'You are on version ' + s.currentVersion +
        '. The update downloads in the background — you can keep working.';
      $('.upd-notes').textContent = s.releaseNotes || '';
      actions.append(
        button('Later', false, () => { bridge.later(); hide(); }),
        button('Download & Install', true, () => bridge.download()));
    } else if (s.state === 'downloading') {
      const pct = Math.max(0, Math.min(100, s.percent || 0));
      $('.upd-title').textContent = 'Downloading version ' + (s.version || '') + '…';
      $('.upd-text').textContent = 'You can keep working. We’ll ask before restarting.';
      $('.upd-progress').hidden = false;
      $('.upd-bar > i').style.width = pct + '%';
      $('.upd-meta').textContent = pct + '%' + (s.total ? ' · ' + mb(s.transferred || 0) + ' of ' + mb(s.total) : '');
      actions.append(button('Hide', false, hide));
    } else if (s.state === 'downloaded') {
      $('.upd-title').textContent = 'Update ready to install';
      $('.upd-text').textContent = 'Restart Practice Manager to install version ' + s.version +
        '. Save anything you are editing first — you will stay signed in.';
      actions.append(
        button('Later', false, hide),
        button('Restart & Install', true, (e) => { e.target.disabled = true; e.target.textContent = 'Restarting…'; bridge.install(); }));
    } else if (s.state === 'error') {
      $('.upd-title').textContent = 'Update problem';
      $('.upd-text').textContent = s.message || 'Something went wrong with the update.';
      actions.append(
        button('Close', false, hide),
        button('Try again', true, () => { hiddenFor = null; s.retry === 'download' ? bridge.download() : bridge.check(); }));
    }
  }

  // "Version x.y.z · Check for updates" under the sidebar's Sign out button.
  let versionLine = null;
  function renderVersionLine(s) {
    const host = document.querySelector('#sidebar .whoami');
    if (!host) return;
    if (!versionLine) {
      versionLine = document.createElement('div');
      versionLine.className = 'upd-version';
      host.appendChild(versionLine);
    }
    versionLine.replaceChildren(document.createTextNode('Version ' + (s.currentVersion || '') + ' · '));
    if (s.state === 'disabled') { versionLine.append('development build'); return; }
    let link;
    if (s.state === 'downloaded') {
      link = button('Restart to update', false, () => { hiddenFor = null; render(current); });
    } else if (s.state === 'available') {
      link = button('Update to ' + s.version, false, () => { hiddenFor = null; render({ ...current, snoozed: false }); });
    } else {
      link = button(s.state === 'checking' ? 'Checking…' : s.state === 'downloading' ? 'Downloading…' : 'Check for updates', false,
        () => { hiddenFor = null; bridge.check(); });
      link.disabled = s.state === 'checking' || s.state === 'downloading';
    }
    link.className = '';
    versionLine.append(link);
  }

  const start = () => {
    document.body.appendChild(card);
    bridge.onStatus(render);
    bridge.getState().then(render).catch(() => {});
  };
  if (document.body) start(); else document.addEventListener('DOMContentLoaded', start);
}
