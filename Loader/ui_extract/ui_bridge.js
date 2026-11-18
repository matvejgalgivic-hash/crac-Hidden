// Bridge between the page and the native WebView2 host (src/Loader.cs).
(() => {
  'use strict';
  const wv = window.chrome && window.chrome.webview;
  if (!wv) return;

  const pending = new Map();
  const listeners = new Set();
  const updateListeners = new Set();
  let seq = 0;

  wv.addEventListener('message', (e) => {
    const m = e.data;
    if (!m) return;
    if (m.type === 'reply') {
      const resolve = pending.get(m.id);
      if (resolve) { pending.delete(m.id); resolve(m.result); }
    } else if (m.type === 'loader-progress') {
      updateListeners.forEach(cb => cb(m.data));
    } else if (m.type === 'progress') {
      listeners.forEach((cb) => cb(m.data));
    }
  });

  const invoke = (cmd, ...args) => new Promise((resolve) => {
    const id = ++seq;
    pending.set(id, resolve);
    wv.postMessage({ id, cmd, args });
  });
  const send = (cmd) => wv.postMessage({ cmd });

  window.loader = {
    info: () => invoke('app:info'),
    checkUpdate: () => invoke('loader:check'),
    installUpdate: id => invoke('loader:install', id),
    onUpdateProgress: cb => { updateListeners.add(cb); return () => updateListeners.delete(cb); },
    ping: () => invoke('app:ping'),
    telegram: () => invoke('app:telegram'),
    readiness: () => invoke('sys:readiness'),
    login: (key, remember) => invoke('auth:login', key, !!remember),
    me: () => invoke('auth:me'),
    logout: () => invoke('auth:logout'),
    setMode: (mode) => invoke('win:mode', mode),
    launch: (id) => invoke('game:launch', id),
    minimize: () => send('win:minimize'),
    close: () => send('win:close'),
    onProgress: (cb) => { listeners.add(cb); return () => listeners.delete(cb); },
  };

  // drag the borderless window by any [data-drag] area that is not a control
  document.addEventListener('mousedown', (e) => {
    if (e.button !== 0) return;
    if (!e.target.closest('[data-drag]')) return;
    if (e.target.closest('button, input, label, a, .card, .key-chip')) return;
    e.preventDefault();
    send('win:drag');
  });

  // window corner radius matches the native one (Win10 region / Win11 DWM)
  const r = new URLSearchParams(location.search).get('r');
  if (r) document.documentElement.style.setProperty('--win-r', r + 'px');
})();
