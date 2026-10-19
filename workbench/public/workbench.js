// Kaishi Workbench page. Everything it shows comes from the server: the step
// registry and LLM config (/api/config), deck counts and their summaries
// (/api/decks), and command previews (/api/preview), so this file only renders
// and wires up events. Runs stream their output over Server-Sent Events.

'use strict';

const state = {
  config: null, // /api/config
  decks: null, // /api/decks
  deck: null, // selected deck name
  stepId: null,
  values: {}, // values[deck][stepId] = { optionKey: value }
  preview: null, // { commands } or { error }
  run: null, // the run in progress, or the last one this page saw
  result: null, // the last finished run, for the result note
  lastRequest: null, // the last POST /api/runs body, for "Run again"
  sentences: null, // /api/sentences
  backup: null, // /api/backup
  backupMessage: null, // "close Anki first" or "reopen Anki", until Anki is back
  anki: null
};

const $ = (id) => document.getElementById(id);

function h(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

async function api(path, options = {}) {
  const init = { headers: { Accept: 'application/json' }, ...options };
  if (options.body !== undefined) {
    init.method = init.method || 'POST';
    init.headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(options.body);
  }
  const response = await fetch(path, init);
  let data = null;
  try { data = await response.json(); } catch (e) { data = null; }
  if (!response.ok) {
    const error = new Error((data && data.error) || `${response.status} ${response.statusText}`);
    error.status = response.status;
    throw error;
  }
  return data;
}

function remembered(key, fallback) {
  try { return localStorage.getItem(`workbench.${key}`) ?? fallback; } catch (e) { return fallback; }
}

function remember(key, value) {
  try { localStorage.setItem(`workbench.${key}`, value); } catch (e) { /* private window */ }
}

// --- Lookups ---

function steps() { return state.config.steps; }
function step(id = state.stepId) { return steps().find((s) => s.id === id); }
function deckEntry(name = state.deck) { return state.decks && state.decks.decks.find((d) => d.name === name); }
function summary(name = state.deck) {
  if (!state.decks) return null;
  return state.decks.summaries[name] || state.decks.empty_summary;
}
function running() { return state.run && state.run.status === 'running'; }
function checkLabel(key) { return (state.decks.checks.find((c) => c.key === key) || {}).label || key; }

function modelDefault(task, provider) {
  return ((state.config.llm.defaults[task] || {})[provider]) || null;
}

// Starting values for a step's form: each option's default, then whatever
// was remembered for this deck (config/workbench.local.yaml).
function initialValues(s, deck) {
  const values = {};
  const saved = ((state.config.preferences[deck] || {})[s.id]) || {};
  s.options.forEach((o) => {
    switch (o.type) {
      case 'flag': values[o.key] = false; break;
      case 'toggle': values[o.key] = true; break;
      case 'provider': values[o.key] = state.config.llm.default_provider; break;
      case 'integer': values[o.key] = ''; break;
      case 'source': values[o.key] = (state.config.takoboto_decks[0] || {}).name || ''; break;
      case 'file': values[o.key] = o.default || (s.files[o.key] || [])[0] || ''; break;
      default: values[o.key] = o.default ?? '';
    }
  });
  s.options.filter((o) => o.remember && saved[o.key] !== undefined).forEach((o) => { values[o.key] = saved[o.key]; });
  const model = s.options.find((o) => o.type === 'model');
  if (model) {
    const listed = state.config.llm.providers[values.provider] || [];
    if (!listed.includes(values.model)) values.model = modelDefault(model.task, values.provider) || '';
  }
  return values;
}

function values(s = step(), deck = state.deck) {
  state.values[deck] = state.values[deck] || {};
  if (!state.values[deck][s.id]) state.values[deck][s.id] = initialValues(s, deck);
  return state.values[deck][s.id];
}

// What the server gets: blanks dropped, a model left out for Google.
function submittedValues(s) {
  const v = { ...values(s) };
  Object.keys(v).forEach((k) => { if (v[k] === '' || v[k] === null) delete v[k]; });
  if (v.provider === 'google') delete v.model;
  return v;
}

// --- Header ---

function renderDeckSelect() {
  const select = $('deck-select');
  const kaishi = state.decks.decks.map((d) => d.name);
  const others = state.decks.deck_names.filter((n) => !kaishi.includes(n) && n !== 'Kaishi 1.5k');
  const option = (name) => `<option value="${h(name)}"${name === state.deck ? ' selected' : ''}>${h(name)}</option>`;
  select.innerHTML = `<optgroup label="Decks with Kaishi cards">${kaishi.map(option).join('')}</optgroup>`
    + (others.length ? `<optgroup label="Other decks">${others.map(option).join('')}</optgroup>` : '');
}

function renderAnki() {
  const el = $('anki-status');
  el.className = `anki-status ${state.anki === null ? '' : state.anki ? 'up' : 'down'}`;
  el.querySelector('.text').textContent = state.anki === null ? 'Checking AnkiConnect…'
    : state.anki ? 'AnkiConnect connected' : 'Anki isn’t running (or AnkiConnect is off)';
}

function backupAge() {
  if (!state.backup || !state.backup.last) return null;
  return (Date.now() - new Date(state.backup.last).getTime()) / 1000;
}

function backupText() {
  const age = backupAge();
  if (age === null) return 'never';
  if (age < 90) return 'just now';
  if (age < 3600) return `${Math.round(age / 60)} min ago`;
  if (age < 86400) return `${Math.round(age / 3600)} h ago`;
  const days = Math.round(age / 86400);
  return `${days} day${days === 1 ? '' : 's'} ago`;
}

function backupStale() {
  const age = backupAge();
  return age === null || age > 86400;
}

function renderBackup() {
  const text = $('backup-text');
  text.textContent = `Last backup: ${state.backup ? backupText() : '…'}`;
  text.className = state.backup && backupStale() ? 'stale' : '';
  $('backup-button').disabled = running();
}

// --- Step list ---

function renderSteps() {
  const sum = summary();
  const groups = [
    { id: 'in', title: 'Get words in', sub: 'Whichever route the words took' },
    { id: 'fill', title: 'Fill in cards', sub: 'Suggested order. Any step can run any time.' }
  ];
  let num = 0;
  $('steps').innerHTML = groups.map((g) => {
    const rows = steps().filter((s) => s.group === g.id).map((s) => {
      const numbered = g.id === 'fill' && !s.optional;
      if (numbered) num += 1;
      const badge = sum ? sum.badges[s.id] : { text: '…', kind: 'info' };
      const suggested = sum && sum.suggested === s.id;
      return `<button type="button" class="step-row${suggested ? ' suggested' : ''}" data-step="${s.id}" aria-pressed="${s.id === state.stepId}">
        <span class="step-num${numbered ? '' : ' blank'}" aria-hidden="true">${numbered ? num : ''}</span>
        <span class="step-text"><span class="step-label">${h(s.label)}</span>${suggested ? '<span class="step-suggested">Suggested next</span>' : ''}</span>
        <span class="badge ${badge.kind}">${h(badge.text)}</span>
      </button>`;
    }).join('');
    return `<div class="group"><div class="group-head"><div class="group-title">${g.title}</div><div class="group-sub">${g.sub}</div></div>${rows}</div>`;
  }).join('');
}

// --- Selected step ---

function scriptLabel(s) {
  if (s.id === 'mined') return 'Yomitan · HoshiReader · Calibre';
  if (s.id === 'takoboto') return 'pull-from-takoboto.rb → add-cards.rb';
  return s.scripts.map((x) => x.path).join(' → ');
}

function optionField(s, o) {
  const v = values(s);
  const id = `opt-${o.key}`;
  let control;
  const select = (choices, current, disabled) => `<select id="${id}" data-key="${o.key}"${disabled ? ' disabled' : ''}>${
    choices.map((c) => `<option value="${h(c.value)}"${c.value === current ? ' selected' : ''}>${h(c.label)}</option>`).join('')}</select>`;
  switch (o.type) {
    case 'integer':
      control = `<input id="${id}" data-key="${o.key}" type="number" min="1" step="1" inputmode="numeric" value="${h(v[o.key])}" placeholder="All">`;
      break;
    case 'choice':
      control = select(o.choices, v[o.key]);
      break;
    case 'provider':
      control = select(o.providers.map((p) => ({ value: p, label: p === state.config.llm.default_provider ? `${p} (default)` : p })), v[o.key]);
      break;
    case 'model': {
      const list = state.config.llm.providers[v.provider];
      if (!list) {
        control = select([{ value: '', label: `n/a for ${v.provider}` }], '', true);
      } else {
        const def = modelDefault(o.task, v.provider);
        control = select(list.map((m) => ({ value: m, label: m === def ? `${m} (default)` : m })), v[o.key]);
      }
      break;
    }
    case 'file': {
      const files = s.files[o.key] || [];
      control = files.length ? select(files.map((f) => ({ value: f, label: f })), v[o.key])
        : select([{ value: '', label: `No files in ${o.globs.join(', ')}` }], '', true);
      break;
    }
    case 'source': {
      const decks = state.config.takoboto_decks;
      control = decks.length ? select(decks.map((d) => ({ value: d.name, label: `${d.name} (${d.count})` })), v[o.key])
        : select([{ value: '', label: 'No decks with Takoboto notes' }], '', true);
      break;
    }
    default:
      control = '';
  }
  let help = o.help || '';
  if (s.id === 'sentence_meanings' && o.type === 'provider') {
    const has = state.config.translation_notes.includes(state.deck);
    help = has ? `Uses prompts/translation/${state.deck}.md` : `No prompts/translation/${state.deck}.md for this deck`;
  }
  return `<div class="field"><label for="${id}">${h(o.label)}</label>${control}${help ? `<div class="help">${h(help)}</div>` : ''}</div>`;
}

function optionCheck(s, o) {
  const v = values(s);
  return `<label class="check"><input type="checkbox" data-key="${o.key}"${v[o.key] ? ' checked' : ''}><span>${h(o.label)}</span></label>`;
}

function miningTable() {
  return `<div class="field"><div class="section-label">Field mapping in the reader tool</div>
    <div class="table-wrap"><table class="mapping">
      <thead><tr><th>Kaishi field</th><th>Yomitan / HoshiReader</th><th>Calibre</th></tr></thead>
      <tbody>
        <tr><td>Word</td><td>Map</td><td>Map</td></tr>
        <tr><td>Word Reading</td><td>Map</td><td>Map</td></tr>
        <tr><td>Sentence</td><td>Map</td><td>Map</td></tr>
        <tr><td>Word Meaning</td><td>Leave unmapped; Add meanings fills it from JMdict</td><td>Map</td></tr>
      </tbody>
    </table></div></div>`;
}

// The generated sentences waiting for this deck, if any.
function pendingSentences() {
  const sn = state.sentences;
  if (!sn || !sn.exists || sn.error || sn.deck !== state.deck || !sn.ready || sn.written) return null;
  return sn;
}

function resultNote() {
  const r = state.result;
  if (!r || r.step !== state.stepId || r.deck !== state.deck) return '';
  const what = r.dry_run ? 'Dry run' : 'Run';
  switch (r.status) {
    case 'succeeded':
      return `<div class="note ok">${what} finished.${r.dry_run ? ' Nothing was written.' : ''}</div>`;
    case 'failed':
      return `<div class="note bad"><strong>${what} failed${r.exit_code !== null ? ` (exit ${r.exit_code})` : ''}</strong>The output below says what went wrong.</div>`;
    case 'usage_error':
      return `<div class="note bad"><strong>The script rejected the Workbench’s options (exit 2)</strong>That’s a Workbench bug: the command it built doesn’t match the script’s flags. The output below names the option.</div>`;
    case 'limit':
      return `<div class="note warn"><span><strong>Stopped by a usage or rate limit</strong>Run again later to resume where it stopped.</span><button type="button" class="btn" data-action="again">Run again</button></div>`;
    case 'cancelled':
      return '<div class="note plain">Cancelled. The scripts pick up where they stopped next time.</div>';
    default:
      return '';
  }
}

function renderStep() {
  const s = step();
  const sum = summary();
  const parts = [`<div class="step-head"><h1>${h(s.label)}</h1><div class="scripts">${h(scriptLabel(s))}</div><p>${h(s.description)}</p></div>`];

  const dep = sum && sum.dep_notes[s.id];
  if (dep) parts.push(`<div class="note dep" role="note"><strong>Out of the suggested order</strong>${h(dep)}</div>`);

  if (s.info) {
    parts.push(miningTable());
    $('step').innerHTML = parts.join('');
    return;
  }

  const fieldOpts = s.options.filter((o) => !['flag', 'toggle'].includes(o.type));
  const checkOpts = s.options.filter((o) => ['flag', 'toggle'].includes(o.type));
  if (fieldOpts.length) parts.push(`<div class="fields" id="fields">${fieldOpts.map((o) => optionField(s, o)).join('')}</div>`);
  if (checkOpts.length) parts.push(`<div class="checks">${checkOpts.map((o) => optionCheck(s, o)).join('')}</div>`);

  const pending = s.id === 'sentences' && pendingSentences();
  if (pending) {
    parts.push(`<div class="note plain">${pending.ready} generated sentence${pending.ready === 1 ? '' : 's'} for this deck in <span class="mono">${h(pending.path)}</span>. Read or edit the file, then write them to Anki.</div>`);
  }

  parts.push(`<div class="command"><div class="section-label">Command</div><div class="command-box" id="command"></div></div>`);

  if (state.backupMessage) {
    parts.push(`<div class="note warn" role="note"><span>${h(state.backupMessage)}</span><button type="button" class="btn" data-action="backup"${running() ? ' disabled' : ''}>Back up</button></div>`);
  } else if (s.bulk && state.backup && backupStale()) {
    parts.push(`<div class="note warn" role="note"><span>This step can change many cards, and the last backup was ${h(backupText())}. Backing up needs Anki closed for a moment.</span><button type="button" class="btn" data-action="backup"${running() ? ' disabled' : ''}>Back up now</button></div>`);
  }

  parts.push(resultNote());
  parts.push(`<div class="actions" id="actions"></div>`);
  $('step').innerHTML = parts.join('');
  renderCommand();
  renderActions();
}

function renderCommand() {
  const box = $('command');
  if (!box) return;
  const p = state.preview;
  if (!p) box.innerHTML = '<div class="dim">…</div>';
  else if (p.error) box.innerHTML = `<div class="error">${h(p.error)}</div>`;
  else box.innerHTML = p.commands.map((c) => `<div>${h(c)}</div>`).join('');
}

function runLabel(s) {
  if (s.id !== 'sentences') return 'Run';
  return values(s).pause ? 'Generate sentences' : 'Generate and write sentences';
}

function renderActions() {
  const el = $('actions');
  if (!el) return;
  const s = step();
  const busy = running();
  const invalid = !state.preview || state.preview.error;
  const buttons = [];
  if (s.id === 'sentences' && pendingSentences()) {
    buttons.push(`<button type="button" class="btn-go" data-action="write"${busy ? ' disabled' : ''}>Write ${pendingSentences().ready} sentences to Anki</button>`);
  }
  buttons.push(`<button type="button" class="btn-primary" data-action="run"${busy || invalid ? ' disabled' : ''}>${runLabel(s)}</button>`);
  if (s.dry_run) {
    const canDry = s.id !== 'sentences' || pendingSentences();
    buttons.push(`<button type="button" class="btn-secondary" data-action="dry"${busy || invalid || !canDry ? ' disabled' : ''}>Dry run</button>`);
  }
  if (busy) buttons.push('<button type="button" class="btn-stop" data-action="cancel">Cancel</button>');
  let hint = '';
  if (busy) hint = `Running ${h((step(state.run.step) || {}).label || state.run.step)} on ${h(state.run.deck)}…`;
  else if (state.anki === false) hint = 'Start Anki first: every step talks to AnkiConnect.';
  buttons.push(`<span class="hint">${hint}</span>`);
  el.innerHTML = buttons.join('');
}

// Debounced: typing in a number field shouldn't fire a request per key.
let previewTimer = null;
let previewSeq = 0;
function schedulePreview() {
  clearTimeout(previewTimer);
  previewTimer = setTimeout(updatePreview, 120);
}

async function updatePreview() {
  const s = step();
  if (!s || s.info) return;
  const seq = ++previewSeq;
  try {
    const data = await api('/api/preview', { body: { step: s.id, deck: state.deck, options: submittedValues(s) } });
    if (seq === previewSeq) state.preview = data;
  } catch (e) {
    if (seq === previewSeq) state.preview = { error: e.message };
  }
  if (seq === previewSeq) { renderCommand(); renderActions(); }
}

// --- Aside ---

function renderDeckList() {
  const list = state.decks.decks;
  $('deck-list').innerHTML = list.length ? list.map((d) => {
    const n = d.needs_work;
    return `<button type="button" class="deck-row" data-deck="${h(d.name)}" aria-pressed="${d.name === state.deck}">
      <span class="name">${h(d.name)}</span>
      <span class="badge ${n ? 'todo' : 'done'}">${n ? `${n} need work` : 'Complete'}</span></button>`;
  }).join('') : '<div class="empty">No decks with Kaishi cards yet.</div>';
}

// Which step (and preset) fixes a check.
function stepForCheck(key) {
  if (key === 'furigana_review') return { step: 'furigana', preset: { review_unreviewed: true } };
  const s = steps().find((x) => (x.checks || []).includes(key));
  return s ? { step: s.id } : null;
}

function renderHealth() {
  const d = deckEntry();
  if (!d) {
    $('health').innerHTML = `<div class="health-head"><h2>${h(state.deck)}</h2><div class="sub">No Kaishi cards yet</div></div>`;
    return;
  }
  const bars = state.decks.checks.map((c) => {
    const missing = d.counts[c.key];
    const pct = d.total ? Math.round(((d.total - missing) / d.total) * 100) : 100;
    const right = missing
      ? `<button type="button" data-check="${c.key}" aria-label="${h(`${c.label}: ${missing} missing; open the step`)}">${missing} missing</button>`
      : '<span class="complete">Complete</span>';
    return `<div class="bar-row"><div class="bar-top"><span>${h(c.label)}</span>${right}</div><div class="bar"><div style="width: ${pct}%"></div></div></div>`;
  }).join('');
  $('health').innerHTML = `<div class="health-head"><h2>${h(d.name)}</h2><div class="sub">${d.total} cards · ${d.needs_work ? `${d.needs_work} need work` : 'complete'}</div></div>${bars}`;
}

function renderAdvice() {
  const sum = summary();
  const items = sum ? sum.advice : [];
  $('advice').innerHTML = items.length ? items.map((a, i) => `<div class="advice-item ${a.kind}"><span class="dot" aria-hidden="true"></span>
      <div class="body"><span>${h(a.text)}</span>${a.action ? `<button type="button" data-advice="${i}">${h(a.action)}</button>` : ''}</div></div>`).join('')
    : '<div class="empty">Nothing to suggest.</div>';
}

function renderAside() {
  renderDeckList();
  renderHealth();
  renderAdvice();
}

function renderAll() {
  renderDeckSelect();
  renderSteps();
  renderStep();
  renderAside();
  renderBackup();
  schedulePreview();
}

// --- Output ---

function lineClass(line) {
  if (line.kind === 'cmd' || line.kind === 'err') return line.kind;
  if (/^\[\+\]/.test(line.text)) return 'ok';
  if (/^\[!\]/.test(line.text)) return 'warn';
  if (/^\[X\]|^Error:/.test(line.text)) return 'err';
  return '';
}

function appendLog(line) {
  const log = $('log');
  const empty = log.querySelector('.log-empty');
  if (empty) empty.remove();
  const atBottom = log.scrollHeight - log.scrollTop - log.clientHeight < 40;
  const div = document.createElement('div');
  div.className = lineClass(line);
  div.textContent = line.text;
  log.appendChild(div);
  if (atBottom) log.scrollTop = log.scrollHeight;
}

const STATE_TEXT = {
  running: 'Running…', succeeded: 'Finished', failed: 'Failed', usage_error: 'Bad options (Workbench bug)',
  limit: 'Stopped by a usage limit', cancelled: 'Cancelled'
};

function renderRunState() {
  const el = $('run-state');
  const r = state.run;
  el.className = `run-state ${r ? r.status : ''}`;
  el.textContent = r ? STATE_TEXT[r.status] || r.status : '';
}

// --- Runs ---

async function startRun(extra = {}) {
  const s = step();
  const body = { step: s.id, deck: state.deck, options: submittedValues(s), dry_run: false, ...extra };
  try {
    const run = await api('/api/runs', { body });
    state.lastRequest = body;
    state.result = null;
    follow(run);
  } catch (e) {
    appendLog({ text: `Couldn’t start: ${e.message}`, kind: 'err' });
  }
}

function follow(run) {
  state.run = run;
  renderRunState();
  renderStep();
  renderBackup();
  const source = new EventSource(`/runs/${run.id}/events`);
  source.addEventListener('line', (event) => appendLog(JSON.parse(event.data)));
  source.addEventListener('done', (event) => {
    source.close();
    finished(JSON.parse(event.data));
  });
}

async function finished(run) {
  state.run = run;
  state.result = run;
  renderRunState();
  if (run.step === 'backup') {
    state.backupMessage = run.status === 'succeeded' ? 'Backed up. Reopen Anki to carry on.' : null;
    await Promise.all([loadBackup(), loadStatus()]);
  } else if (!run.dry_run) {
    await refreshDeck(run.step === 'takoboto' ? null : run.deck);
  }
  if (run.step === 'sentences' || run.step === 'word_list') await loadSentencesAndConfig();
  renderAll();
}

async function refreshDeck(name) {
  try {
    if (name) {
      const data = await api(`/api/decks/${encodeURIComponent(name)}`);
      const decks = state.decks.decks.filter((d) => d.name !== name);
      if (data.entry) decks.push(data.entry);
      decks.sort((a, b) => (a.name < b.name ? -1 : 1));
      state.decks.decks = decks;
      state.decks.summaries[name] = data.summary;
    } else {
      await loadDecks(true);
    }
  } catch (e) {
    appendLog({ text: `Couldn’t refresh the deck counts: ${e.message}`, kind: 'err' });
  }
}

// --- Loading ---

async function loadStatus() {
  const was = state.anki;
  try {
    state.anki = (await api('/api/status')).anki;
  } catch (e) {
    state.anki = false;
  }
  renderAnki();
  if (state.anki && !was && state.backupMessage && state.config) {
    state.backupMessage = null;
    renderStep();
  }
}

async function loadDecks(refresh = false) {
  state.decks = await api(`/api/decks${refresh ? '?refresh=1' : ''}`);
}

async function loadSentencesAndConfig() {
  const [sentences, config] = await Promise.all([api('/api/sentences'), api('/api/config')]);
  state.sentences = sentences;
  state.config = config;
}

async function loadBackup() {
  try { state.backup = await api('/api/backup'); } catch (e) { state.backup = null; }
}

function selectStep(id, preset) {
  state.stepId = id;
  if (preset) Object.assign(values(step(id)), preset);
  state.preview = null;
  remember('step', id);
  renderSteps();
  renderStep();
  schedulePreview();
}

function selectDeck(name) {
  state.deck = name;
  state.preview = null;
  remember('deck', name);
  renderAll();
}

function defaultDeck() {
  const saved = remembered('deck', null);
  if (saved && state.decks.deck_names.includes(saved) && saved !== 'Kaishi 1.5k') return saved;
  const work = state.decks.decks.find((d) => d.needs_work > 0) || state.decks.decks[0];
  return work ? work.name : state.decks.deck_names.find((n) => n !== 'Kaishi 1.5k');
}

async function init() {
  loadStatus();
  setInterval(loadStatus, 15000);
  $('step').innerHTML = '<div class="empty">Counting cards in every deck (a few seconds)…</div>';
  try {
    await loadDecks();
    await Promise.all([loadSentencesAndConfig(), loadBackup()]);
  } catch (e) {
    $('step').innerHTML = `<div class="note bad"><strong>Couldn’t read the decks</strong>${h(e.message)}</div><div class="empty">Start Anki (with AnkiConnect), then reload this page.</div>`;
    return;
  }
  state.deck = defaultDeck();
  const savedStep = remembered('step', null);
  state.stepId = (savedStep && step(savedStep)) ? savedStep : (summary().suggested || 'mined');
  renderAll();
  try {
    const { run } = await api('/api/runs/current');
    if (run && run.status === 'running') follow(run);
  } catch (e) { /* nothing running */ }
}

// --- Events ---

document.addEventListener('DOMContentLoaded', () => {
  $('deck-select').addEventListener('change', (e) => selectDeck(e.target.value));
  $('backup-button').addEventListener('click', () => startBackup());
  $('clear-output').addEventListener('click', () => { $('log').innerHTML = '<div class="log-empty">Run a step to see its output here.</div>'; });

  $('steps').addEventListener('click', (e) => {
    const row = e.target.closest('[data-step]');
    if (row) selectStep(row.dataset.step);
  });

  $('deck-list').addEventListener('click', (e) => {
    const row = e.target.closest('[data-deck]');
    if (row) selectDeck(row.dataset.deck);
  });

  $('health').addEventListener('click', (e) => {
    const button = e.target.closest('[data-check]');
    const target = button && stepForCheck(button.dataset.check);
    if (target) selectStep(target.step, target.preset);
  });

  $('advice').addEventListener('click', (e) => {
    const button = e.target.closest('[data-advice]');
    if (!button) return;
    const item = summary().advice[Number(button.dataset.advice)];
    if (item && item.step) selectStep(item.step, item.preset);
  });

  const stepEl = $('step');
  stepEl.addEventListener('change', (e) => {
    const key = e.target.dataset.key;
    if (!key) return;
    const s = step();
    const v = values(s);
    v[key] = e.target.type === 'checkbox' ? e.target.checked : e.target.value;
    const option = s.options.find((o) => o.key === key);
    if (option.type === 'provider') {
      const model = s.options.find((o) => o.type === 'model');
      if (model) v.model = modelDefault(model.task, v.provider) || '';
      renderStep();
    } else if (key === 'pause') {
      renderActions();
    }
    schedulePreview();
  });
  stepEl.addEventListener('input', (e) => {
    if (e.target.type === 'number') {
      values()[e.target.dataset.key] = e.target.value;
      schedulePreview();
    }
  });
  stepEl.addEventListener('click', (e) => {
    const button = e.target.closest('[data-action]');
    if (!button || button.disabled) return;
    switch (button.dataset.action) {
      case 'run': startRun(); break;
      case 'dry': startRun({ dry_run: true }); break;
      case 'write': startRun({ phase: 'write' }); break;
      case 'again': if (state.lastRequest) api('/api/runs', { body: state.lastRequest }).then(follow).catch((err) => appendLog({ text: err.message, kind: 'err' })); break;
      case 'cancel': if (state.run) api(`/runs/${state.run.id}/cancel`, { method: 'POST' }); break;
      case 'backup': startBackup(); break;
      default:
    }
  });

  init();
});

// --- Backups ---

// backup-collection.sh needs Anki closed; closing and reopening it is up to
// the person, so the server refuses (409) while AnkiConnect still answers.
async function startBackup() {
  try {
    follow(await api('/api/backup', { method: 'POST' }));
  } catch (e) {
    state.backupMessage = e.message;
    renderStep();
    loadStatus();
  }
}
