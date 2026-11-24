/**
 * Deli Planner – Google Apps Script backend
 *
 * Paste this whole file into the Apps Script editor of the deli's Google Sheet
 * (Extensions > Apps Script), then deploy as a Web app. See README.md.
 *
 * Script properties (Project Settings > Script properties):
 *   DEVICE_KEY  – long random text; every tablet/PC must enter it to read or write
 *   EDIT_PIN    – PIN for Yehuda and Eli; needed to change the plan
 *   REPORT_EMAILS – who gets the weekly HACCP report, comma separated
 *   STAFF       – names for the tick list Staff dropdown, comma separated
 *   REPORT_FOLDER – (set automatically) Drive folder id for the reports
 *
 * Sheet tabs it uses (created automatically):
 *   Plans  – one row per week: week (Monday yyyy-mm-dd) | plan JSON | updated | changes
 *   Log    – every change: time | week | day | line id | product | qty | unit | note
 *   Recipes – one row per ingredient or method step (imported from CSV, never in the public repo):
 *             Product id | Recipe | Stage | Ingredient / step | Amount (g) | For (kg) | Note | Check
 *             Recipe blank = every recipe of that product; "Chilli" = the chilli franks add-on;
 *             "Cure" = brine rows added only when a cured product is planned.
 *             Stage blank for minced products; the stage name (Inject, Tumble, Cook…) for whole muscle.
 *             Amount + For filled = ingredient (grams for that many kg / litres). Both blank = method step.
 *             Check: cool8 | program:NNN | weight | core | chilli | saltbeef (what the tick list records).
 *   Records – one row per tick list (per batch): key | week | day | date | batch code | product | stage |
 *             staff | updated | flags | data JSON. Written by any connected device (device key only).
 *
 * Weekly report: run installFridayTrigger() once from the editor (Run button). It then runs
 * fridayReport() every Friday at 10:00 (set the project time zone to London in Project Settings).
 */

const PLANS = 'Plans';
const LOG = 'Log';

function props_() { return PropertiesService.getScriptProperties(); }

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

function checkKey_(key) {
  const k = props_().getProperty('DEVICE_KEY');
  return !!k && key === k;
}

function checkPin_(pin) {
  const p = props_().getProperty('EDIT_PIN');
  return !!p && String(pin || '') === p;
}

function sheet_(name, headers) {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let sh = ss.getSheetByName(name);
  if (!sh) {
    sh = ss.insertSheet(name);
    sh.appendRow(headers);
    sh.setFrozenRows(1);
  }
  return sh;
}

function plansSheet_() { return sheet_(PLANS, ['Week (Monday)', 'Plan JSON', 'Last updated', 'Changes']); }
function logSheet_() { return sheet_(LOG, ['Time', 'Week', 'Day', 'Line id', 'Product', 'Qty', 'Unit', 'Stage', 'Recipe', 'Note', 'Removed']); }

const RECIPE_HEADERS = ['Product id', 'Recipe', 'Stage', 'Ingredient / step', 'Amount (g)', 'For (kg)', 'Note', 'Check'];
function recipesSheet_() { return sheet_('Recipes', RECIPE_HEADERS); }

function readRecipes_() {
  const sh = recipesSheet_();
  const last = sh.getLastRow();
  if (last < 2) return [];
  return sh.getRange(2, 1, last - 1, RECIPE_HEADERS.length).getValues()
    .filter(function (r) {
      if (!r[0] || !r[3]) return false;
      const ing = Number(r[4]) > 0 && Number(r[5]) > 0, step = r[4] === '' && r[5] === '';
      return ing || step;
    })
    .map(function (r) {
      const o = { p: String(r[0]).trim(), r: String(r[1] || '').trim(), st: String(r[2] || '').trim(),
                  ing: String(r[3]).trim(), note: String(r[6] || '').trim(), chk: String(r[7] || '').trim() };
      if (r[4] === '' && r[5] === '') o.step = true; else { o.g = Number(r[4]); o.per = Number(r[5]); }
      return o;
    });
}

/* ---------- Tick list records ---------- */
const REC_HEADERS = ['Key', 'Week', 'Day', 'Date', 'Batch code', 'Product', 'Stage', 'Staff', 'Updated', 'Flags', 'Data JSON'];
function recordsSheet_() { return sheet_('Records', REC_HEADERS); }

function readRecords_(week) {
  const sh = recordsSheet_();
  const last = sh.getLastRow();
  if (last < 2) return [];
  return sh.getRange(2, 1, last - 1, REC_HEADERS.length).getValues()
    .filter(function (r) { return String(r[1]) === week || Utilities.formatDate(new Date(r[1]), 'Europe/London', 'yyyy-MM-dd') === week; })
    .map(function (r) { try { return JSON.parse(r[10]); } catch (e) { return null; } })
    .filter(function (x) { return x; });
}

function saveRecord_(rec) {
  const sh = recordsSheet_();
  const last = sh.getLastRow();
  let row = 0;
  if (last >= 2) {
    const keys = sh.getRange(2, 1, last - 1, 1).getValues();
    for (let i = 0; i < keys.length; i++) if (keys[i][0] === rec.key) { row = i + 2; break; }
  }
  rec.updated = new Date().toISOString();
  const vals = [[rec.key, rec.week, rec.day, rec.date || '', rec.code || '', rec.product || '', rec.stage || '',
                 rec.staff || '', new Date(), (rec.flags || []).join('; '), JSON.stringify(rec)]];
  if (!row) row = sh.getLastRow() + 1;
  sh.getRange(row, 2, 1, 1).setNumberFormat('@');
  sh.getRange(row, 1, 1, vals[0].length).setValues(vals);
}

/* ---------- Smokehouse cooks (sent from Eli's PC by tools/FOODLOG-sync.ps1) ---------- */
// FOOD.LOG analog channels: 1 = chamber °C, 2 = core °C, 3 = humidity % (checked against a FOOD.LOG PDF)
const COOK_HEADERS = ['Event id', 'Start', 'End', 'Program', 'Recipe no', 'Completed', 'Error', 'Type',
  'Chamber min', 'Chamber max', 'Core min', 'Core max', 'Humidity min', 'Humidity max', 'Readings', 'Synced'];
function cooksSheet_() { return sheet_('Smokehouse', COOK_HEADERS); }
function num_(v) { return v === '' || v == null || isNaN(Number(v)) ? null : Math.round(Number(v) * 10) / 10; }
function saveCooks_(cooks) {
  const sh = cooksSheet_();
  const last = sh.getLastRow();
  const ids = last > 1 ? sh.getRange(2, 1, last - 1, 1).getValues().map(function (r) { return String(r[0]); }) : [];
  const now = new Date();
  let added = 0, updated = 0;
  cooks.forEach(function (c) {
    if (!c || c.id == null) return;
    const row = [String(c.id), "'" + (c.start || ''), "'" + (c.end || ''), c.program || '', c.recipe == null ? '' : c.recipe, c.completed ? 'yes' : 'no',
      c.error == null ? '' : c.error, c.type == null ? '' : c.type,
      num_(c.c1min), num_(c.c1max), num_(c.c2min), num_(c.c2max), num_(c.c3min), num_(c.c3max), c.n || 0, now];
    const i = ids.indexOf(String(c.id));
    if (i >= 0) { sh.getRange(i + 2, 1, 1, row.length).setValues([row]); updated++; }
    else { sh.appendRow(row); ids.push(String(c.id)); added++; }
  });
  return { added: added, updated: updated };
}
function readCooks_(week) {
  const sh = cooksSheet_();
  const last = sh.getLastRow();
  if (last < 2) return [];
  const from = week, to = Utilities.formatDate(new Date(new Date(week + 'T12:00:00').getTime() + 7 * 864e5), 'Europe/London', 'yyyy-MM-dd');
  return sh.getRange(2, 1, last - 1, COOK_HEADERS.length).getValues()
    .map(function (r) {
      return { eid: String(r[0]), start: String(r[1]), end: String(r[2]), name: String(r[3]), recipe: r[4], completed: r[5] === 'yes',
        error: r[6], type: r[7], chMin: num_(r[8]), chMax: num_(r[9]), coreMin: num_(r[10]), coreMax: num_(r[11]),
        humMin: num_(r[12]), humMax: num_(r[13]), n: r[14], synced: r[15] ? Utilities.formatDate(new Date(r[15]), 'Europe/London', 'dd/MM/yyyy HH:mm') : '' };
    })
    .filter(function (c) { const d = c.start.slice(0, 10); return d >= from && d < to; })
    .sort(function (a, b) { return a.start.localeCompare(b.start); });
}
function isCleaning_(name) { return /CLEAN|RINS|TEST/i.test(name || ''); }
function cooksHtml_(week, recs) {
  const cooks = readCooks_(week);
  const linked = {};
  recs.forEach(function (r) { Object.keys(r.vals || {}).forEach(function (k) { const v = r.vals[k];
    if (v && v.fl && v.fl.eid) (linked[v.fl.eid] = linked[v.fl.eid] || []).push((r.product || '') + ' ' + (r.code || '')); }); });
  if (!cooks.length) return '<h2>Smokehouse (FOOD.LOG)</h2><p class="bad">No smokehouse data for this week. Check the FOOD.LOG sync on Eli\'s PC.</p>';
  const rows = cooks.map(function (c) {
    const clean = isCleaning_(c.name), alarm = String(c.type) !== '1';
    const secs = c.end && c.start ? (new Date(c.end) - new Date(c.start)) / 1000 : 0;
    const cover = alarm ? 1 : Math.min(1, (Number(c.n) || 0) / Math.max(1, Math.floor(secs / 30)));
    const gap = !alarm && cover < 0.9 ? ' <span class="bad">temperatures ' + Math.round(cover * 100) + '% recorded</span>' : '';
    const link = linked[c.eid] ? esc_(linked[c.eid].join(', ')) : (clean || alarm ? '' : '<span class="bad">not linked to a batch</span>');
    return '<tr><td>' + esc_(c.start.replace('T', ' ').slice(0, 16)) + '</td><td>' + esc_((c.end || '').replace('T', ' ').slice(11, 16)) + '</td><td>' +
      esc_(c.name) + (alarm ? ' (alarm' + (c.error ? ' ' + esc_(c.error) : '') + ')' : '') + '</td><td>' + (c.coreMax == null ? '—' : c.coreMax + '°C') +
      '</td><td>' + (c.chMax == null ? '—' : c.chMax + '°C') + gap + '</td><td>' + link + '</td></tr>';
  }).join('');
  return '<h2>Smokehouse (FOOD.LOG) – every cycle this week</h2><table><tr><td><b>Start</b></td><td><b>End</b></td><td><b>Program</b></td><td><b>Core max</b></td><td><b>Chamber max</b></td><td><b>Batch</b></td></tr>' +
    rows + '</table>';
}

/* ---------- Smoker live view + alerts (sent every 5 min by tools/FOODLOG-live.ps1) ---------- */
// Script property ALERT_TO: comma-separated emails for smoker alerts (default shimshi@mhmeats.co.uk).
function liveSheet_() { return sheet_('Live', ['Live JSON', 'Received']); }
// Script property ALERT_ERRORS_TO: emails that get ERRORS ONLY (smoker alarm, no data from Eli's PC). Default eli@mhmeats.co.uk.
// Anyone listed there is taken off the full list, so they never get "cycle finished" or "data is back" emails.
function emails_(v) { return String(v || '').split(',').map(function (x) { return x.trim().toLowerCase(); }).filter(String); }
function errorsTo_() { const v = props_().getProperty('ALERT_ERRORS_TO'); return emails_(v === null ? 'eli@mhmeats.co.uk' : v); }
function alertTo_(isError) {
  const errs = errorsTo_();
  const all = emails_(props_().getProperty('ALERT_TO') || 'shimshi@mhmeats.co.uk').filter(function (e) { return errs.indexOf(e) < 0; });
  return (isError ? all.concat(errs) : all).filter(function (e, i, a) { return a.indexOf(e) === i; }).join(',');
}
function hm_(iso) { return iso ? String(iso).replace('T', ' ').slice(0, 16) : ''; }
function saveLive_(live) {
  const sh = liveSheet_();
  const now = new Date();
  sh.getRange(2, 1, 1, 2).setValues([[JSON.stringify(live), now]]);
  const p = props_();
  const prev = JSON.parse(p.getProperty('LIVE_STATE') || 'null');
  const cycles = live.cycles || [], alarms = live.alarms || [];
  const run = cycles.filter(function (c) { return !c.end; })[0] || null;
  const state = { running: run ? String(run.id) : null, alarms: alarms.map(function (a) { return String(a.id); }), stale: false };
  const mails = [];
  if (prev) {
    if (prev.running && prev.running !== state.running) {
      const done = cycles.filter(function (c) { return String(c.id) === prev.running; })[0];
      if (done && !isCleaning_(done.program)) mails.push([false, 'Smoker: ' + done.program + ' finished',
        '<p><b>' + esc_(done.program) + '</b> finished at ' + esc_(hm_(done.end)) + ' (started ' + esc_(hm_(done.start)) + ').</p>' +
        '<p>Core max ' + (done.coreMax == null ? '—' : done.coreMax + '°C') + ' · chamber max ' + (done.chMax == null ? '—' : done.chMax + '°C') + '</p>']);
    }
    alarms.forEach(function (a) {
      if ((prev.alarms || []).indexOf(String(a.id)) < 0) mails.push([true, 'Smoker ALARM: ' + a.info + (a.error ? ' (error ' + a.error + ')' : ''),
        '<p>The smoker raised <b>' + esc_(a.info) + '</b>' + (a.error ? ' (error ' + esc_(a.error) + ')' : '') + ' at ' + esc_(hm_(a.start)) + '.</p><p>Someone needs to check it.</p>']);
    });
    if (prev.stale) mails.push([false, 'Smoker data is back', '<p>Readings from Eli\'s PC are coming through again.</p>']);
  }
  p.setProperty('LIVE_STATE', JSON.stringify(state));
  mails.forEach(function (m) { const to = alertTo_(m[0]); if (!to) return; try { MailApp.sendEmail({ to: to, subject: m[1], htmlBody: m[2] + '<p style="color:#666">Deli Planner smoker alert · live view: https://yehudabcode.github.io/deli-planner/smoker.html</p>' }); } catch (e) {} });
  return { alerts: mails.length };
}
function readLive_() {
  const sh = liveSheet_();
  if (sh.getLastRow() < 2) return null;
  const v = sh.getRange(2, 1, 1, 2).getValues()[0];
  try { const live = JSON.parse(v[0]); live.received = v[1] ? new Date(v[1]).toISOString() : null; return live; } catch (e) { return null; }
}
/** Time trigger (every 15 min): emails once if no readings have arrived from Eli's PC for 30 minutes. */
function checkLive() {
  const live = readLive_();
  const p = props_();
  const state = JSON.parse(p.getProperty('LIVE_STATE') || '{}');
  const age = live && live.received ? (Date.now() - new Date(live.received).getTime()) / 60000 : 9999;
  if (age > 30 && !state.stale) {
    state.stale = true; p.setProperty('LIVE_STATE', JSON.stringify(state));
    try { MailApp.sendEmail({ to: alertTo_(true), subject: 'Smoker: no data from Eli\'s PC',
      htmlBody: '<p>No smoker readings have arrived for ' + Math.round(age) + ' minutes.</p><p>Eli\'s PC may be off or asleep, or FOOD.LOG closed. <b>Temperatures are not being recorded until it is fixed.</b></p>' }); } catch (e) {}
  }
}
/** Run once from the editor to switch on the 'no data' alert. */
function installLiveTrigger() {
  ScriptApp.getProjectTriggers().forEach(function (t) { if (t.getHandlerFunction() === 'checkLive') ScriptApp.deleteTrigger(t); });
  ScriptApp.newTrigger('checkLive').timeBased().everyMinutes(15).create();
}

/* ---------- Weekly HACCP report ---------- */
function esc_(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }

function reportFolder_(week) {
  let id = props_().getProperty('REPORT_FOLDER'), root = null;
  try { if (id) root = DriveApp.getFolderById(id); } catch (e) { root = null; }
  if (!root) { root = DriveApp.createFolder('Deli HACCP Reports'); props_().setProperty('REPORT_FOLDER', root.getId()); }
  const name = 'w-c ' + week;
  const it = root.getFoldersByName(name);
  return it.hasNext() ? it.next() : root.createFolder(name);
}

function recordHtml_(r) {
  const flags = (r.flags || []).length ? '<p class="bad">' + esc_(r.flags.join(' · ')) + '</p>' : '';
  const checks = (r.checks || []).map(function (c) {
    return '<tr><td>' + esc_(c.label) + '</td><td>' + esc_(c.value || '—') + '</td></tr>';
  }).join('');
  const ticks = r.stepsTotal ? (r.stepsDone || 0) + ' of ' + r.stepsTotal + ' steps ticked' : '';
  return '<div class="rec"><h3>' + esc_(r.product) + ' · ' + esc_(r.stage || '') + ' · ' + esc_(r.code || '') + '</h3>' +
    '<p>' + esc_(r.date) + ' · ' + esc_(r.kg ? r.kg + ' kg' : '') + ' · Staff: ' + esc_(r.staff || '—') + ' · Probe: ' + esc_(r.probe || '—') +
    (ticks ? ' · ' + esc_(ticks) : '') + '</p>' + flags +
    '<table>' + checks + '</table>' + (r.note ? '<p>Note: ' + esc_(r.note) + '</p>' : '') + '</div>';
}

function reportDoc_(title, recs, week, extra) {
  const css = 'body{font-family:Arial,sans-serif;font-size:11px;color:#000}h1{font-size:18px}h2{font-size:14px;margin:14px 0 4px;border-bottom:1px solid #000}' +
    'h3{font-size:12px;margin:8px 0 2px}.rec{page-break-inside:avoid;border-bottom:1px solid #ccc;padding:4px 0}table{border-collapse:collapse}' +
    'td{border:1px solid #ccc;padding:2px 6px}.bad{color:#b00;font-weight:bold}';
  return '<html><head><style>' + css + '</style></head><body><h1>' + esc_(title) + '</h1><p>Week commencing ' + esc_(week) +
    ' · made ' + Utilities.formatDate(new Date(), 'Europe/London', 'dd/MM/yyyy HH:mm') + ' · ' + recs.length + ' tick list(s)</p>' +
    recs.map(recordHtml_).join('') + (extra || '') + '</body></html>';
}

function makeReport_(week, mode) {
  mode = mode || 'email'; // 'email' | 'download' | 'both' | 'none'
  const recs = readRecords_(week).sort(function (a, b) { return (a.date + a.product + a.code).localeCompare(b.date + b.product + b.code); });
  const folder = reportFolder_(week);
  const files = [];
  const byProduct = {};
  recs.forEach(function (r) { (byProduct[r.product] = byProduct[r.product] || []).push(r); });
  let cooksPart = '';
  try { cooksPart = cooksHtml_(week, recs); } catch (e) { cooksPart = '<p class="bad">Smokehouse section failed: ' + esc_(e.message) + '</p>'; }
  const full = Utilities.newBlob(reportDoc_('Deli HACCP report – full week', recs, week, cooksPart), 'text/html', 'x.html')
    .getAs('application/pdf').setName('HACCP week ' + week + ' – ALL.pdf');
  files.push(full);
  Object.keys(byProduct).sort().forEach(function (p) {
    files.push(Utilities.newBlob(reportDoc_('Deli HACCP report – ' + p, byProduct[p], week), 'text/html', 'x.html')
      .getAs('application/pdf').setName('HACCP week ' + week + ' – ' + p + '.pdf'));
  });
  files.forEach(function (f) {
    const old = folder.getFilesByName(f.getName());
    while (old.hasNext()) old.next().setTrashed(true);
    folder.createFile(f);
  });
  const flagged = recs.filter(function (r) { return (r.flags || []).length; });
  const flPdfs = [];
  recs.forEach(function (r) { Object.keys(r.vals || {}).forEach(function (k) { const v = r.vals[k];
    if (v && v.fl && v.fl.id) { try { flPdfs.push(DriveApp.getFileById(v.fl.id).getBlob()); } catch (e) {} } }); });
  const to = props_().getProperty('REPORT_EMAILS');
  const sendMail = !!to && (mode === 'email' || mode === 'both');
  if (sendMail) {
    MailApp.sendEmail({
      to: to,
      subject: 'Deli HACCP report – w/c ' + week + (flagged.length ? ' – ' + flagged.length + ' flagged' : ''),
      htmlBody: '<p>Attached: the full week plus one PDF per product (' + recs.length + ' tick lists), and ' + flPdfs.length + ' FOOD.LOG cook report(s).</p>' +
        (flagged.length ? '<p><b>Flagged:</b><br>' + flagged.map(function (r) { return esc_(r.product + ' ' + r.code + ': ' + r.flags.join(', ')); }).join('<br>') + '</p>' : '<p>Nothing flagged.</p>') +
        '<p>Saved in Google Drive: <a href="' + folder.getUrl() + '">' + esc_(folder.getName()) + '</a></p>',
      attachments: files.concat(flPdfs)
    });
  }
  const out = { folder: folder.getUrl(), count: recs.length, flagged: flagged.length, emailed: sendMail };
  if (mode === 'download' || mode === 'both') { out.pdf = Utilities.base64Encode(full.getBytes()); out.pdfName = full.getName(); }
  return out;
}

function mondayOf_(d) { const x = new Date(d); const wd = x.getDay(); x.setDate(x.getDate() - ((wd + 6) % 7)); return Utilities.formatDate(x, 'Europe/London', 'yyyy-MM-dd'); }

/** Runs every Friday 10:00 once installFridayTrigger() has been run. */
/** Run this from the editor to test the report (and authorise Drive/Gmail). Makes this week's PDFs but sends no email. */
function testReport() { Logger.log(JSON.stringify(makeReport_(mondayOf_(new Date()), 'none'))); }

function fridayReport() { makeReport_(mondayOf_(new Date())); }

/** Run this ONCE from the editor to switch on the Friday 10:00 report. */
function installFridayTrigger() {
  ScriptApp.getProjectTriggers().forEach(function (t) { if (t.getHandlerFunction() === 'fridayReport') ScriptApp.deleteTrigger(t); });
  ScriptApp.newTrigger('fridayReport').timeBased().onWeekDay(ScriptApp.WeekDay.FRIDAY).atHour(10).nearMinute(0).everyWeeks(1).create();
}

function validWeek_(w) { return /^\d{4}-\d{2}-\d{2}$/.test(String(w || '')); }

function findWeekRow_(sh, week) {
  const last = sh.getLastRow();
  if (last < 2) return 0;
  const weeks = sh.getRange(2, 1, last - 1, 1).getDisplayValues();
  for (let i = 0; i < weeks.length; i++) if (weeks[i][0] === week) return i + 2;
  return 0;
}

function readWeek_(week) {
  const sh = plansSheet_();
  const row = findWeekRow_(sh, week);
  if (!row) return { days: {} };
  try { return JSON.parse(sh.getRange(row, 2).getValue() || '{"days":{}}'); }
  catch (e) { return { days: {} }; }
}

function doGet(e) {
  const p = (e && e.parameter) || {};
  if (!checkKey_(p.key)) return json_({ ok: false, code: 'bad_key' });
  if (p.action === 'ping') return json_({ ok: true, canEdit: checkPin_(p.pin) });
  if (p.action === 'week') {
    if (!validWeek_(p.week)) return json_({ ok: false, code: 'bad_week' });
    return json_({ ok: true, plan: readWeek_(p.week) });
  }
  if (p.action === 'recipes') {
    const staff = String(props_().getProperty('STAFF') || '').split(',').map(function (x) { return x.trim(); }).filter(String);
    return json_({ ok: true, recipes: readRecipes_(), staff: staff });
  }
  if (p.action === 'live') return json_({ ok: true, live: readLive_(), now: new Date().toISOString() });
  if (p.action === 'cooks') {
    if (!validWeek_(p.week)) return json_({ ok: false, code: 'bad_week' });
    return json_({ ok: true, cooks: readCooks_(p.week) });
  }
  if (p.action === 'records') {
    if (!validWeek_(p.week)) return json_({ ok: false, code: 'bad_week' });
    return json_({ ok: true, records: readRecords_(p.week) });
  }
  return json_({ ok: false, code: 'bad_action' });
}

function doPost(e) {
  let body;
  try { body = JSON.parse(e.postData.contents); } catch (err) { return json_({ ok: false, code: 'bad_body' }); }
  if (!checkKey_(body.key)) return json_({ ok: false, code: 'bad_key' });

  if (body.action === 'record') {
    const r = body.record;
    if (!r || !r.key || !validWeek_(r.week)) return json_({ ok: false, code: 'bad_body' });
    const lock = LockService.getScriptLock(); lock.waitLock(20000);
    try { saveRecord_(r); return json_({ ok: true }); } finally { lock.releaseLock(); }
  }
  if (body.action === 'live') {
    if (!body.live) return json_({ ok: false, code: 'bad_body' });
    const lock = LockService.getScriptLock(); lock.waitLock(20000);
    try { return json_({ ok: true, result: saveLive_(body.live) }); } finally { lock.releaseLock(); }
  }
  if (body.action === 'cooks') {
    if (!Array.isArray(body.cooks)) return json_({ ok: false, code: 'bad_body' });
    const lock = LockService.getScriptLock(); lock.waitLock(20000);
    try { return json_({ ok: true, result: saveCooks_(body.cooks) }); } finally { lock.releaseLock(); }
  }
  if (body.action === 'flupload') {
    if (!validWeek_(body.week) || !body.data) return json_({ ok: false, code: 'bad_body' });
    const folder = reportFolder_(body.week);
    const name = String(body.name || 'FOOD.LOG report.pdf').replace(/[\\/]/g, '-');
    const old = folder.getFilesByName(name); while (old.hasNext()) old.next().setTrashed(true);
    const f = folder.createFile(Utilities.newBlob(Utilities.base64Decode(body.data), 'application/pdf', name));
    return json_({ ok: true, file: { id: f.getId(), url: f.getUrl(), file: name } });
  }
  if (body.action === 'report') {
    if (!checkPin_(body.pin)) return json_({ ok: false, code: 'bad_pin' });
    if (!validWeek_(body.week)) return json_({ ok: false, code: 'bad_week' });
    try { return json_({ ok: true, result: makeReport_(body.week, body.mode || 'email') }); }
    catch (err) { return json_({ ok: false, code: 'report_failed', message: String(err && err.message || err) }); }
  }
  // Devices without the edit PIN (e.g. production tablets) may only enter the ACTUAL kg of a line already in the plan.
  if (body.action === 'actual') {
    if (!validWeek_(body.week) || !/^(mon|tue|wed|thu|fri)$/.test(body.day) || !body.id) return json_({ ok: false, code: 'bad_body' });
    const aq = body.aq === null || body.aq === '' || body.aq === undefined ? null : Number(body.aq);
    if (aq !== null && !(isFinite(aq) && aq >= 0 && aq < 100000)) return json_({ ok: false, code: 'bad_body' });
    const lock = LockService.getScriptLock(); lock.waitLock(20000);
    try {
      const plans = {};
      const get = function (w) { if (!plans[w]) plans[w] = readWeek_(w); return plans[w]; };
      const plan = get(body.week);
      const line = plan.days && plan.days[body.day] && plan.days[body.day].lines && plan.days[body.day].lines[body.id];
      if (!line) return json_({ ok: false, code: 'no_line' });
      if (line.src) return json_({ ok: false, code: 'linked_line' });
      const setA = function (l) { if (l.pq === undefined) l.pq = l.qty == null ? null : l.qty; l.aq = aq; l.qty = aq !== null ? aq : l.pq; };
      setA(line);
      const links = (line.links || (line.cki ? [{ id: line.cki, wk: line.ckw, dk: line.ckd }] : [])).concat(line.cookedLink ? [line.cookedLink] : []);
      links.forEach(function (k) {
        const lp = get(k.wk), ll = lp.days && lp.days[k.dk] && lp.days[k.dk].lines && lp.days[k.dk].lines[k.id];
        if (ll) setA(ll);
      });
      const now = new Date(), sh = plansSheet_();
      Object.keys(plans).forEach(function (w) {
        let row = findWeekRow_(sh, w);
        if (!row) { sh.appendRow([w, '', '', 0]); row = sh.getLastRow(); sh.getRange(row, 1).setNumberFormat('@').setValue(w); }
        plans[w].weekOf = w;
        sh.getRange(row, 2, 1, 3).setValues([[JSON.stringify(plans[w]), now, Number(sh.getRange(row, 4).getValue() || 0) + 1]]);
      });
      logSheet_().appendRow([now, body.week, body.day, body.id, line.p || '', line.qty == null ? '' : line.qty, line.unit || '', line.st || '', line.v || '', 'Actual kg entered (no PIN): ' + (aq === null ? 'cleared' : aq), '']);
      return json_({ ok: true });
    } finally { lock.releaseLock(); }
  }
  // "Into the oven" ticked on every batch of a raw line: add (or remove) the Cooked line on the next working day.
  // Device key only, so production tablets can do it. The cooked line copies the raw line; it can't be used to edit the plan.
  if (body.action === 'cooked') {
    const days = /^(mon|tue|wed|thu|fri)$/;
    if (!validWeek_(body.week) || !days.test(body.day) || !body.id) return json_({ ok: false, code: 'bad_body' });
    const lock = LockService.getScriptLock(); lock.waitLock(20000);
    try {
      const plans = {};
      const get = function (w) { if (!plans[w]) { plans[w] = readWeek_(w); plans[w].days = plans[w].days || {}; } return plans[w]; };
      const dl = function (pl, d) { pl.days[d] = pl.days[d] || { lines: {} }; pl.days[d].lines = pl.days[d].lines || {}; return pl.days[d].lines; };
      const src = dl(get(body.week), body.day)[body.id];
      if (!src || src.cooked) return json_({ ok: false, code: 'no_line' });
      const old = src.cookedLink;
      if (old && validWeek_(old.wk) && days.test(old.dk)) delete dl(get(old.wk), old.dk)[old.id];
      delete src.cookedLink;
      if (body.on) {
        if (!validWeek_(body.cw) || !days.test(body.cd)) return json_({ ok: false, code: 'bad_body' });
        const cid = 'ck_' + body.id, label = String(body.label || '').slice(0, 80);
        dl(get(body.cw), body.cd)[cid] = { p: src.p, qty: src.qty, pq: src.pq === undefined ? src.qty : src.pq, aq: src.aq == null ? null : src.aq,
          unit: src.unit || 'kg', v: src.v || null, st: 'Cooked', cooked: 1, src: 1,
          codes: Array.isArray(body.codes) ? body.codes.slice(0, 20).map(String) : [], from: body.from || { wk: body.week, dk: body.day, id: body.id },
          note: label, o: (src.o || 0) + 1000 };
        src.cookedLink = { id: cid, wk: body.cw, dk: body.cd, label: label };
      }
      const now = new Date(), sh = plansSheet_();
      Object.keys(plans).forEach(function (w) {
        let row = findWeekRow_(sh, w);
        if (!row) { sh.appendRow([w, '', '', 0]); row = sh.getLastRow(); sh.getRange(row, 1).setNumberFormat('@').setValue(w); }
        plans[w].weekOf = w;
        sh.getRange(row, 2, 1, 3).setValues([[JSON.stringify(plans[w]), now, Number(sh.getRange(row, 4).getValue() || 0) + 1]]);
      });
      logSheet_().appendRow([now, body.week, body.day, body.id, src.p || '', src.qty == null ? '' : src.qty, src.unit || '', src.st || '', src.v || '',
        body.on ? 'Into the oven: cooked line added ' + body.cw + ' ' + body.cd : 'Into the oven unticked: cooked line removed', '']);
      return json_({ ok: true });
    } finally { lock.releaseLock(); }
  }
  if (body.action === 'patch') {
    if (!checkPin_(body.pin)) return json_({ ok: false, code: 'bad_pin' });
    if (!validWeek_(body.week) || !Array.isArray(body.changes)) return json_({ ok: false, code: 'bad_body' });
    const lock = LockService.getScriptLock();
    lock.waitLock(20000);
    try {
      const sh = plansSheet_();
      let row = findWeekRow_(sh, body.week);
      const plan = readWeek_(body.week);
      plan.weekOf = body.week;
      plan.days = plan.days || {};
      const log = [];
      const now = new Date();
      body.changes.forEach(function (c) {
        if (!c || !/^(mon|tue|wed|thu|fri)$/.test(c.day) || !c.id) return;
        plan.days[c.day] = plan.days[c.day] || { lines: {} };
        plan.days[c.day].lines = plan.days[c.day].lines || {};
        const prev = plan.days[c.day].lines[c.id];
        if (c.line === null) { delete plan.days[c.day].lines[c.id]; }
        else { plan.days[c.day].lines[c.id] = c.line; }
        const l = c.line || prev || {};
        log.push([now, body.week, c.day, c.id, l.p || '', l.qty == null ? '' : l.qty, l.unit || '', l.st || '', l.v || '', l.note || '', c.line === null ? 'yes' : '']);
      });
      if (!row) { sh.appendRow([body.week, '', '', 0]); row = sh.getLastRow(); sh.getRange(row, 1).setNumberFormat('@').setValue(body.week); }
      const count = Number(sh.getRange(row, 4).getValue() || 0) + log.length;
      sh.getRange(row, 2, 1, 3).setValues([[JSON.stringify(plan), now, count]]);
      if (log.length) { const ls = logSheet_(); ls.getRange(ls.getLastRow() + 1, 1, log.length, log[0].length).setValues(log); }
      return json_({ ok: true });
    } finally {
      lock.releaseLock();
    }
  }
  return json_({ ok: false, code: 'bad_action' });
}

/** Optional: run once from the editor to check the sheet tabs get created. */
function setupSheets() { plansSheet_(); logSheet_(); recipesSheet_(); recordsSheet_(); cooksSheet_(); }
