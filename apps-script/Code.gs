/**
 * Deli Planner – Google Apps Script backend
 *
 * Paste this whole file into the Apps Script editor of the deli's Google Sheet
 * (Extensions > Apps Script), then deploy as a Web app. See README.md.
 *
 * Script properties (Project Settings > Script properties):
 *   DEVICE_KEY  – long random text; every tablet/PC must enter it to read or write
 *   EDIT_PIN    – PIN for Yehuda and Eli; needed to change the plan
 *
 * Sheet tabs it uses (created automatically):
 *   Plans  – one row per week: week (Monday yyyy-mm-dd) | plan JSON | updated | changes
 *   Log    – every change: time | week | day | line id | product | qty | unit | note
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
  return json_({ ok: false, code: 'bad_action' });
}

function doPost(e) {
  let body;
  try { body = JSON.parse(e.postData.contents); } catch (err) { return json_({ ok: false, code: 'bad_body' }); }
  if (!checkKey_(body.key)) return json_({ ok: false, code: 'bad_key' });

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
function setupSheets() { plansSheet_(); logSheet_(); }
