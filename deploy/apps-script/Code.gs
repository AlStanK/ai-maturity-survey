/**
 * Прошарок між анкетою ШІ-зрілості (GitHub Pages) і Google Sheets.
 *
 * Розгортання: Extensions → Apps Script у таблиці-приймачі, вставити цей файл,
 * Deploy → New deployment → Web app, Execute as: Me, Who has access: Anyone.
 * Отриманий /exec URL прописати в SHEETS_URL всередині index.html.
 *
 * Аркуші та заголовки створюються самі при першому записі — нічого руками
 * готувати не треба.
 */

var SHEETS = {
  responses: [
    "id", "created_at",
    "company", "industry", "company_size", "market", "sensitivity",
    "fn", "tenure", "leads",
    "usage_freq", "account_type", "hours_saved", "shadow_ai",
    "ps_index", "gv_index", "ef_index", "maturity_now", "maturity_target",
    "coverage_scope", "ai_awareness", "confidence", "unknown_share",
    "policy_known", "claim_supported",
    "answers", "scores", "version"
  ],
  report_subscribers: ["id", "created_at", "email"]
};

function doPost(e) {
  try {
    var req = JSON.parse(e.postData.contents);
    var table = String(req.table || "");
    if (!SHEETS[table]) return reply({ ok: false, error: "unknown table" });

    var body = req.body || {};
    if (table === "report_subscribers") {
      var email = String(body.email || "").trim();
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return reply({ ok: false, error: "bad email" });
      body = { email: email };
    } else if (String(body.company || "").trim().length < 2) {
      return reply({ ok: false, error: "company required" });
    }

    append(table, body);
    return reply({ ok: true });
  } catch (err) {
    return reply({ ok: false, error: String(err) });
  }
}

/** GET віддає лише ознаку життя — читати дані назовні не можна. */
function doGet() {
  return reply({ ok: true, service: "ai-maturity-survey", version: "3.2" });
}

function append(table, body) {
  var cols = SHEETS[table];
  var lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    var sheet = sheetFor(table, cols);
    body.id = Utilities.getUuid();
    body.created_at = new Date().toISOString();

    var row = cols.map(function (c) {
      var v = body[c];
      if (v === undefined || v === null) return "";
      // answers і scores зберігаємо як JSON-рядок: розбирати їх все одно
      // доведеться на етапі імпорту в Postgres.
      if (typeof v === "object") return JSON.stringify(v);
      if (typeof v === "boolean") return v ? "TRUE" : "FALSE";
      return v;
    });
    sheet.appendRow(row);
  } finally {
    lock.releaseLock();
  }
}

function sheetFor(table, cols) {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(table);
  if (!sheet) sheet = ss.insertSheet(table);
  if (sheet.getLastRow() === 0) {
    sheet.appendRow(cols);
    sheet.setFrozenRows(1);
    sheet.getRange(1, 1, 1, cols.length).setFontWeight("bold");
  }
  return sheet;
}

function reply(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
