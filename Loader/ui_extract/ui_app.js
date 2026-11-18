(() => {
  'use strict';
  const L = window.loader;
  const I = window.i18n, t = value => I.t(value);
  const locale = () => I.lang === 'en' ? 'en-GB' : 'ru-RU';
  const $ = (s, el = document) => el.querySelector(s);
  const $$ = (s, el = document) => [...el.querySelectorAll(s)];
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  const RING = 119.38;
  const state = { me: null, skew: 0, busy: new Set(), timers: [], network: null, readiness: null, readyTime: '', readyFailed: false, progress: new Map() };

  // ───────── helpers ─────────
  const plural = (n, a, b, c) => { const m = Math.abs(n) % 100, d = m % 10; return m > 10 && m < 20 ? c : d > 1 && d < 5 ? b : d === 1 ? a : c; };
  const mb = (b) => (b / 1048576).toFixed(b >= 1048576 * 100 ? 0 : 1) + ' ' + t('МБ');
  const nowSrv = () => Date.now() / 1000 + state.skew;
  const fmtDate = (ts) => new Date(ts * 1000).toLocaleString(locale(), { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' });

  let toastTimer;
  function toast(msg, kind = 'err') {
    const t = $('#toast');
    t.dataset.message = msg || '';
    t.textContent = I.t(msg);
    t.className = 'toast show' + (kind === 'info' ? ' info' : '');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => t.classList.remove('show'), 4200);
  }

  // window controls
  document.addEventListener('click', (e) => {
    const b = e.target.closest('[data-win]');
    if (!b) return;
    if (b.dataset.win === 'min') L.minimize(); else L.close();
  });

  async function swapFrames(from, to, mode) {
    from.classList.add('leaving');
    await sleep(380);
    from.hidden = true;
    from.classList.remove('leaving');
    await L.setMode(mode);
    to.hidden = false;
    to.classList.add('entering');
    setTimeout(() => to.classList.remove('entering'), 600);
  }

  // ═════════════════════ LOGIN ═════════════════════
  const keyInput = $('#keyInput');
  const authBtn = $('#authBtn');

  keyInput.addEventListener('input', () => {
    const pos = keyInput.selectionStart;
    const v = keyInput.value.toUpperCase().replace(/[^A-Z0-9-]/g, '');
    if (v !== keyInput.value) { keyInput.value = v; keyInput.setSelectionRange(pos, pos); }
    $('#loginError').textContent = ''; $('#loginError').dataset.message = '';
  });

  function loginFail(msg) {
    $('#loginError').dataset.message = msg || '';
    $('#loginError').textContent = t(msg);
    const f = $('#keyField');
    f.classList.remove('shake'); void f.offsetWidth; f.classList.add('shake');
    keyInput.focus();
  }

  $('#keyForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const key = keyInput.value.trim();
    if (!key) return loginFail('Введите ключ');
    authBtn.className = 'btn-auth loading';
    $('#loginError').textContent = ''; $('#loginError').dataset.message = '';
    const res = await L.login(key, false);
    if (!res.ok) {
      authBtn.className = 'btn-auth';
      return loginFail(res.error);
    }
    authBtn.className = 'btn-auth success';
    await sleep(650);
    applyMe(res.data, true);
    await swapFrames($('#login'), $('#main'), 'main');
    if (res.data.key_remembered === false) toast('Вход выполнен, но сохранить ключ на этом ПК не удалось', 'info');
    loadReadiness();
    startTimers();
    checkUpdate();
  });

  async function pingServer() {
    const r = await L.ping();
    const on = r.ok && r.data; state.network = !!on;
    $('#netDot').className = 'net ' + (on ? 'on' : 'off');
    $('#netText').textContent = t(on ? 'Сервер в сети' : 'Сервер недоступен');
  }

  // ═════════════════════ MAIN ═════════════════════
  function applyMe(me, first = false) {
    state.me = me;
    state.skew = me.server_time - Date.now() / 1000;
    $('#keyMasked').textContent = me.key;
    renderSub();
    if (first) renderGames(me.games);
    else syncGames(me.games);
  }

  function renderSub() {
    const me = state.me; if (!me) return;
    const box = $('#subBox');
    const fg = $('#ringFg');
    if (me.lifetime) {
      $('#ringNum').textContent = '∞';
      $('#subLeft').textContent = t('Навсегда');
      $('#subUntil').textContent = t('Бессрочный доступ');
      fg.style.strokeDashoffset = 0;
      box.classList.remove('low');
      return;
    }
    const left = me.expires_at - nowSrv();
    if (left <= 0) { kick('Срок действия ключа истёк'); return; }
    const total = Math.max(1, me.days * 86400);
    const days = left >= 86400 ? Math.ceil(left / 86400 - 0.01) : 0;
    const hours = Math.floor(left / 3600);
    if (days >= 1) {
      $('#ringNum').textContent = days > 999 ? '999+' : days;
      $('#subLeft').textContent = I.lang === 'en' ? `${days} ${days === 1 ? 'day' : 'days'} left` : `Осталось ${days} ${plural(days, 'день', 'дня', 'дней')}`;
    } else {
      $('#ringNum').textContent = hours >= 1 ? `${hours}${I.lang === 'en' ? 'h' : 'ч'}` : `${Math.max(1, Math.floor(left / 60))}${I.lang === 'en' ? 'm' : 'м'}`;
      $('#subLeft').textContent = hours >= 1 ? (I.lang === 'en' ? `${hours} ${hours === 1 ? 'hour' : 'hours'} left` : `Осталось ${hours} ${plural(hours, 'час', 'часа', 'часов')}`) : t('Меньше часа');
    }
    $('#subUntil').textContent = `${I.lang === 'en' ? 'until' : 'до'} ${fmtDate(me.expires_at)}`;
    fg.style.strokeDashoffset = RING * (1 - Math.min(1, left / total));
    box.classList.toggle('low', left < 3 * 86400);
  }

  // background crossfade
  let bgFront = 'A', bgCurrent = '';
  function setBg(url) {
    if (!url || url === bgCurrent) return;
    bgCurrent = url;
    const next = bgFront === 'A' ? 'B' : 'A';
    const el = $('#bg' + next);
    el.style.backgroundImage = `url("${url.replace(/"/g, '%22')}")`;
    el.classList.add('show');
    $('#bg' + bgFront).classList.remove('show');
    bgFront = next;
  }

  function cardMeta(g) {
    const parts = [`v${g.version}`];
    if (g.has_package) parts.push(mb(g.package_size));
    if (g.run_steam) parts.push('Steam');
    return parts.map((p) => `<span>${p.replace(/[<>&]/g, '')}</span>`).join('');
  }

  function fillCard(card, g) {
    card.dataset.id = g.id;
    $('.badge.ok', card).textContent = t('Доступно');
    $('.btn-play span', card).textContent = t($('.btn-play', card).classList.contains('done') ? 'Запущено' : 'Запустить');
    $('.card-title', card).textContent = g.name;
    $('.card-desc', card).textContent = t(g.description || '');
    $('.ver', card).textContent = `v${g.version}`;
    $('.card-meta', card).innerHTML = cardMeta(g);
    const img = $('.card-img', card);
    if (g.image_url) {
      const probe = new Image();
      probe.onload = () => { img.style.backgroundImage = `url("${g.image_url.replace(/"/g, '%22')}")`; img.classList.remove('noimg'); };
      probe.onerror = () => img.classList.add('noimg');
      probe.src = g.image_url;
    } else img.classList.add('noimg');
  }

  function renderGames(games) {
    const wrap = $('#cards');
    wrap.innerHTML = '';
    games.forEach((g, i) => {
      const card = $('#cardTpl').content.firstElementChild.cloneNode(true);
      fillCard(card, g);
      card.style.animationDelay = `${0.25 + i * 0.08}s`;
      card.addEventListener('mouseenter', () => setBg(g.image_url));
      $('.btn-play', card).addEventListener('click', () => launch(card));
      wrap.appendChild(card);
    });
    $('#libEmpty').hidden = games.length > 0;
    $('#libCount').textContent = games.length
      ? I.lang === 'en' ? `${games.length} ${games.length === 1 ? 'game' : 'games'} available` : `Доступно ${games.length} ${plural(games.length, 'игра', 'игры', 'игр')}`
      : '';
    if (games[0]) setBg(games[0].image_url);
  }

  function syncGames(games) {
    const ids = games.map((g) => String(g.id)).join(',');
    const cur = $$('.card').map((c) => c.dataset.id).join(',');
    if (ids !== cur && state.busy.size === 0) return renderGames(games);
    games.forEach((g) => { const c = $(`.card[data-id="${g.id}"]`); if (c) fillCard(c, g); });
  }

  // ───────── launch ─────────
  const STAGES = { prepare: 'Подготовка', download: 'Загрузка', verify: 'Проверка', extract: 'Распаковка', launch: 'Запуск', initializing: 'Инициализация', waiting_game: 'Ожидание игры', ready: 'Готово', done: 'Готово' };

  function setProgress(card, stage, pct, detail = '') {
    $('.prog-stage', card).textContent = t(STAGES[stage] || stage);
    $('.prog-pct', card).textContent = pct == null ? '' : `${Math.floor(pct)}%`;
    const bar = $('.prog-bar', card);
    bar.classList.toggle('indet', pct == null);
    $('.prog-bar i', card).style.width = pct == null ? '' : `${pct}%`;
    $('.prog-detail', card).textContent = detail;
  }

  function renderProgress(p) {
    const card = $(`.card[data-id="${p.gameId}"]`);
    if (!card) return;
    switch (p.stage) {
      case 'download': {
        const pct = p.total ? (p.received / p.total) * 100 : null;
        const speed = p.elapsed > 300 ? (p.received / 1048576) / (p.elapsed / 1000) : 0;
        setProgress(card, 'download', pct, `${mb(p.received)}${p.total ? ' / ' + mb(p.total) : ''}${speed ? ` · ${speed.toFixed(1)} ${t('МБ/с')}` : ''}`);
        break;
      }
      case 'extract':
        setProgress(card, 'extract', p.total ? (p.done / p.total) * 100 : null, p.total > 1 ? `${p.done} / ${p.total} ${I.lang === 'en' ? 'files' : 'файлов'}` : '');
        break;
      case 'prepare': case 'verify': case 'launch': case 'initializing':
        setProgress(card, p.stage, null);
        break;
      case 'waiting_game':
        setProgress(card, p.stage, null, t('Запустите ROB RUN — окно можно оставить открытым'));
        break;
      case 'ready': case 'done':
        setProgress(card, p.stage, 100);
        break;
      default:
    }
  }
  L.onProgress(p => { state.progress.set(p.gameId, p); renderProgress(p); });

  async function launch(card) {
    const id = Number(card.dataset.id);
    if (state.busy.has(id)) return;
    if (updateBusy) return;
    state.busy.add(id);
    const btn = $('.btn-play', card);
    const prog = $('.prog', card);
    card.classList.add('busy');
    btn.hidden = true;
    prog.hidden = false;
    state.progress.set(id, {gameId:id,stage:'prepare'});
    setProgress(card, 'prepare', null);
    $('#sbMsg').textContent = '';
    $('#sbMsg').dataset.message = '';

    const res = await L.launch(id);

    prog.hidden = true;
    btn.hidden = false;
    card.classList.remove('busy');
    state.busy.delete(id);
    state.progress.delete(id);

    if (res.ok) {
      btn.classList.add('done');
      $('span', btn).textContent = t('Запущено');
      $('#sbMsg').textContent = `${$('.card-title', card).textContent} · ${t('Запущено').toLowerCase()} ${new Date().toLocaleTimeString(locale(), { hour: '2-digit', minute: '2-digit' })}`;
      setTimeout(() => { btn.classList.remove('done'); $('span', btn).textContent = t('Запустить'); }, 3500);
    } else if (res.status === 401 || res.status === 403 && /ключ|сесси|key|session/i.test(res.error)) {
      kick(res.error);
    } else {
      $('#sbMsg').dataset.message = res.error || 'Не удалось запустить';
      $('#sbMsg').textContent = t($('#sbMsg').dataset.message);
      toast(res.error);
    }
  }

  // ───────── readiness column (read-only status) ─────────
  const RD_ROWS = [
    ['defender', 'Windows Defender'], ['vbs', 'VBS'], ['hvci', 'HVCI'],
    ['faceit', 'FACEIT AC'], ['vanguard', 'Valorant AC'],
  ];
  const RD_LABEL = { on: 'ВКЛ', off: 'ВЫКЛ', unknown: '—' };

  function renderReadiness(checks) {
    const list = $('#readyList');
    list.innerHTML = '';
    checks.forEach((c) => {
      const li = $('#readyTpl').content.firstElementChild.cloneNode(true);
      li.className = 'rd ' + (c.state || 'unknown');
      $('b', li).textContent = c.name;
      $('.rd-text span', li).textContent = t(c.detail || '');
      $('.rd-text span', li).title = t(c.detail || '');
      $('.rd-state', li).textContent = t(RD_LABEL[c.state] || '—');
      list.appendChild(li);
    });
  }

  function readinessPending() {
    renderReadiness(RD_ROWS.map(([id, name]) => ({ id, name, detail: 'Проверка…', state: 'unknown' })));
    $$('#readyList .rd').forEach((li) => li.classList.add('pending'));
  }

  let readyBusy = false;
  async function loadReadiness(manual = false) {
    if (readyBusy) return;
    readyBusy = true;
    const btn = $('#readyRefresh');
    if (manual) btn.classList.add('spin');
    if (!$('#readyList').children.length || manual) readinessPending();
    const res = await L.readiness();
    btn.classList.remove('spin');
    readyBusy = false;
    if (!res.ok) { state.readyFailed = true; $('#readyFoot').textContent = t('Проверка не удалась'); return; }
    state.readyFailed = false; state.readiness = res.data.checks || []; state.readyTime = res.data.time;
    renderReadiness(res.data.checks || []);
    $('#readyFoot').textContent = `${I.lang === 'en' ? 'Checked at' : 'Проверено в'} ${res.data.time}`;
  }
  $('#readyRefresh').addEventListener('click', () => loadReadiness(true));

  let pendingUpdate = null, updateCheckError = '', updateChecking = false, updateBusy = false;
  function showUpdate(visible) {
    $('#loaderUpdate').hidden = !visible;
    $('#main').inert = visible;
    if (!visible && state.me) $('#refreshBtn').focus();
  }
  document.addEventListener('keydown', event => {
    if ($('#loaderUpdate').hidden) return;
    // Mandatory update — all keyboard shortcuts disabled; only the install
    // button reacts. Alt+F4 is blocked at the window level below.
    if (event.key === 'Escape' || event.key === 'F4') { event.preventDefault(); return; }
    if (event.key === 'Tab') {
      const controls = [...$('#loaderUpdate').querySelectorAll('button:not(:disabled)')];
      event.preventDefault();
      if (controls.length) controls[(controls.indexOf(document.activeElement) + (event.shiftKey ? controls.length - 1 : 1)) % controls.length].focus();
    }
  });
  async function checkUpdate() {
    if (!state.me || updateChecking || updateBusy || !L.checkUpdate) return;
    updateChecking = true;
    const session = state.me.key;
    try {
      const response = await L.checkUpdate();
      if (!state.me || state.me.key !== session) return;
      if (!response.ok) {
        if (!response.status && response.error && response.error !== updateCheckError) toast(response.error);
        updateCheckError = response.error || '';
        return;
      }
      updateCheckError = '';
      const previousRequest = pendingUpdate?.request_id;
      pendingUpdate = response.data;
      if (!pendingUpdate) { showUpdate(false); return; }
      if (state.busy.size) return;
      if (!$('#loaderUpdate').hidden && pendingUpdate.request_id === previousRequest) return;
      $('#loaderUpdateProgress').hidden = true;
      $('#loaderUpdateProgress').value = 0;
      $('#loaderUpdateVersion').textContent = `v${pendingUpdate.version} · ${mb(pendingUpdate.size)}`;
      $('#loaderUpdateStatus').textContent = '';
      showUpdate(true);
      $('#loaderUpdateInstall').focus();
      // Mandatory: if the user does not click within 3 seconds, the loader
      // starts the download on its own. The dialog has no dismiss path.
      setTimeout(() => { if (!updateBusy && !$('#loaderUpdate').hidden) $('#loaderUpdateInstall').click(); }, 3000);
    } catch { /* A later poll retries after a transport failure. */ } finally { updateChecking = false; }
  }
  if (L.onUpdateProgress) L.onUpdateProgress(progress => {
    const element = $('#loaderUpdateProgress'); element.hidden = false;
    element.value = progress.total ? 100 * progress.received / progress.total : 0;
    $('#loaderUpdateStatus').textContent = `${t('Загрузка')} · ${Math.floor(element.value)}%`;
  });
  $('#loaderUpdateInstall').addEventListener('click', async () => {
    if (updateBusy || !pendingUpdate) return;
    if (state.busy.size) return toast('Дождитесь окончания запуска');
    updateBusy = true;
    $('#loaderUpdateInstall').disabled = true;
    $('#loaderUpdateStatus').textContent = t('Загрузка');
    const response = await L.installUpdate(pendingUpdate.request_id);
    if (response.ok) { $('#loaderUpdateStatus').textContent = t('Перезапуск лоадера…'); return; }
    updateBusy = false;
    $('#loaderUpdateInstall').disabled = false;
    $('#loaderUpdateStatus').textContent = t(response.error || 'Не удалось обновить лоадер');
  });

  // ───────── refresh / session ─────────
  async function refresh(manual = false) {
    const btn = $('#refreshBtn');
    if (manual) btn.classList.add('spin');
    const res = await L.me();
    btn.classList.remove('spin');
    const st = $('.mt-status');
    if (res.ok) {
      st.classList.remove('off'); $('span:last-child', st).textContent = t('Подключено');
      applyMe(res.data);
      if (manual) toast('Данные обновлены', 'info');
    } else if (res.status === 401 || res.status === 403) {
      kick(res.error);
    } else {
      st.classList.add('off'); $('span:last-child', st).textContent = t('Нет связи');
      if (manual) toast(res.error);
    }
  }
  $('#refreshBtn').addEventListener('click', () => { checkUpdate(); refresh(true); loadReadiness(true); });

  function startTimers() {
    stopTimers();
    state.timers.push(setInterval(checkUpdate, 30 * 1000));
    state.timers.push(setInterval(renderSub, 30 * 1000));
    state.timers.push(setInterval(() => refresh(false), 5 * 60 * 1000));
    state.timers.push(setInterval(() => loadReadiness(false), 2 * 60 * 1000));
  }
  function stopTimers() { state.timers.forEach(clearInterval); state.timers = []; }

  let kicking = false;
  async function kick(message) {
    if (kicking) return;
    kicking = true;
    stopTimers();
    await L.logout();
    state.me = null; pendingUpdate = null;
    showUpdate(false);
    authBtn.className = 'btn-auth';
    await swapFrames($('#main'), $('#login'), 'login');
    if (message) loginFail(message);
    kicking = false;
  }
  $('#logoutBtn').addEventListener('click', () => {
    if (state.busy.size || updateBusy) return toast('Дождитесь окончания запуска');
    kick('');
  });

  document.querySelectorAll('[data-language]').forEach(button => button.addEventListener('click', () => I.setLanguage(I.lang === 'en' ? 'ru' : 'en')));
  document.querySelectorAll('[data-telegram]').forEach(button => button.addEventListener('click', async () => {
    const response = await L.telegram(); if (!response.ok) toast(response.error);
  }));
  window.addEventListener('languagechange', () => {
    document.querySelectorAll('[data-message]').forEach(el => { el.textContent = t(el.dataset.message); });
    $('#netText').textContent = t(state.network === null ? 'Подключение…' : state.network ? 'Сервер в сети' : 'Сервер недоступен');
    const connection = $('.mt-status');
    $('span:last-child', connection).textContent = t(connection.classList.contains('off') ? 'Нет связи' : 'Подключено');
    if (state.me) {
      renderSub(); state.me.games.forEach(game => { const card = $(`.card[data-id="${game.id}"]`); if (card) fillCard(card, game); });
      const count = state.me.games.length;
      $('#libCount').textContent = count ? (I.lang === 'en' ? `${count} ${count === 1 ? 'game' : 'games'} available` : `Доступно ${count} ${plural(count, 'игра', 'игры', 'игр')}`) : '';
    }
    if (state.readiness) renderReadiness(state.readiness);
    else if ($('#readyList').children.length) readinessPending();
    $('#readyFoot').textContent = state.readyFailed ? t('Проверка не удалась') : state.readyTime ? `${I.lang === 'en' ? 'Checked at' : 'Проверено в'} ${state.readyTime}` : t('Проверка…');
    state.progress.forEach(renderProgress);
  });
  I.setLanguage('en');

  // ───────── boot ─────────
  (async () => {
    // warm up every font face used on the main screen so it never flashes in late
    ['500 12px Unbounded', '700 12px Unbounded', '800 12px Unbounded', '400 12px Manrope', '500 12px Manrope',
      '600 12px Manrope', '700 12px Manrope', '500 12px "JetBrains Mono"', '600 12px "JetBrains Mono"']
      .forEach((f) => document.fonts.load(f, 'AZaz09АЯая').catch(() => {}));
    const info = await L.info();
    if (info.ok) {
      $('#loginVer').textContent = 'v' + info.data.version;
      if (info.data.savedKey) keyInput.value = info.data.savedKey;
    }
    keyInput.focus();
    pingServer();
  })();
})();
