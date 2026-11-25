// node test/live.test.mjs — exercises the worker's live alerts and cached commands with fakes.
import assert from "node:assert/strict";
import worker from "../src/index.js";

const kv = new Map();
const KV = {
  async get(k, type) { const v = kv.get(k); return v === undefined ? null : type === "json" ? JSON.parse(v) : v; },
  async put(k, v) { kv.set(k, v); }, async delete(k) { kv.delete(k); },
};
let yasno = {};
let deyeNow = { v: 230, soc: 90, t: 0, temp: 22, bp: 300 }, alerts = [], sent = [], photos = 0, dispatched = 0;
globalThis.fetch = async (url, init = {}) => {
  url = String(url);
  const json = (o, status = 200) => new Response(JSON.stringify(o), { status });
  if (url.includes("/account/token")) return json({ success: true, accessToken: "t", expiresIn: "86400" });
  if (url.includes("/device/latest")) return json({ success: true, deviceDataList: [{ collectionTime: deyeNow.t,
    dataList: [{ key: "GridVoltageL1L2", value: String(deyeNow.v) }, { key: "SOC", value: String(deyeNow.soc) },
               { key: "Temperature- Battery", value: String(deyeNow.temp) }, { key: "BatteryPower", value: String(deyeNow.bp) },
               { key: "TotalConsumptionPower", value: "300" }] }] });
  if (url.includes("app.yasno.ua")) return json(yasno);
  if (url.includes("/device/alertList")) return json({ success: true, alertList: alerts });
  if (url.includes("/sendMessage")) { sent.push(JSON.parse(init.body).text); return json({ ok: true }); }
  if (url.includes("/sendPhoto")) { photos++; return json({ ok: true }); }
  if (url.includes("/dispatches")) { dispatched++; return new Response(null, { status: 204 }); }
  throw new Error("unexpected " + url);
};
const env = { KV, DEYE_CLOUD_DEVICE_SN: "sn", TELEGRAM_BOT_TOKEN: "b", TELEGRAM_CHAT_ID: "1",
  TELEGRAM_WEBHOOK_SECRET: "w", CACHE_SECRET: "c", GITHUB_REPO: "o/r", GITHUB_TOKEN: "g" };
const run = async (minute) => {
  const tasks = []; const now = Date.now() / 1000;
  deyeNow.t = deyeNow.t || now;
  await worker.scheduled({ scheduledTime: Date.UTC(2026, 0, 1, 0, minute) }, env, { waitUntil: (p) => tasks.push(p) });
  await Promise.all(tasks);
};
const tick = async (patch) => { Object.assign(deyeNow, patch, { t: Date.now() / 1000 }); await run(1); };

await tick({});                                   // first run: silent
assert.equal(sent.length, 0);
await tick({ v: 0 });                             // grid lost
assert.match(sent.at(-1), /Світло вимкнули/);
await tick({ v: 0, soc: 29 });                    // below 30 %
assert.match(sent.at(-1), /Батарея 29% \(поріг 30%\)/);
await tick({ v: 0, soc: 28 });                    // no repeat
assert.equal(sent.filter((m) => m.includes("поріг")).length, 1);
await tick({ v: 0, soc: 0, temp: -100 });         // BMS silent: no false alert
assert.equal(sent.filter((m) => m.includes("поріг")).length, 1);
await tick({ v: 231, soc: 40, temp: 22 });        // back
assert.match(sent.at(-1), /Світло дали[\s\S]*Не було/);

const before = sent.length;                       // stale data → one alert, then recovery
deyeNow.t = Date.now() / 1000 - 3600; await run(1); await run(1);
assert.equal(sent.length, before + 1); assert.match(sent.at(-1), /не отримує даних/);
await tick({});
assert.match(sent.at(-1), /знову надходять/);

await run(5); assert.equal(dispatched, 1);        // every 5th minute starts the workflow

// smart alerts: runtime on outage, last hour, full again, voltage band
await tick({ v: 0, soc: 90, bp: 300 });
assert.match(sent.at(-1), /вимкнули[\s\S]*Вистачить ≈ .* \(до ~/);
await tick({ v: 0, soc: 12, bp: 3000 });
assert.ok(sent.some((m) => m.includes("Батареї залишилось")));
const lastHour = sent.filter((m) => m.includes("залишилось")).length;
await tick({ v: 0, soc: 11, bp: 3000 });
assert.equal(sent.filter((m) => m.includes("залишилось")).length, lastHour);   // once per outage
await tick({ v: 231, soc: 50, bp: -2000 });
assert.match(sent.at(-1), /Світло дали/);
await tick({ v: 231, soc: 100, bp: 0 });
assert.match(sent.at(-1), /знову повна/);
await tick({ v: 262, soc: 100 });
assert.match(sent.at(-1), /Напруга в мережі 262 В/);
const n = sent.length;
await tick({ v: 258 }); assert.equal(sent.length, n);                          // no repeat
await tick({ v: 230 }); await tick({ v: 195 });
assert.match(sent.at(-1), /занижена/);
await tick({ v: 230 });

// cached reports answer instantly
const req = (path, body, headers) => new Request("https://w" + path, { method: "POST", body, headers });
let r = await worker.fetch(req("/cache", "{}", { "X-Cache-Secret": "nope" }), env, { waitUntil() {} });
assert.equal(r.status, 403);
const png = Buffer.from([137, 80, 78, 71]).toString("base64");
r = await worker.fetch(req("/cache", JSON.stringify({ generated_at: Date.now() / 1000,
  items: { week: { text: "📊 тиждень", png } } }), { "X-Cache-Secret": "c" }), env, { waitUntil() {} });
assert.equal(r.status, 200);
const tasks = [];
await worker.fetch(req("/telegram", JSON.stringify({ message: { chat: { id: 1 }, text: "/week" } }),
  { "X-Telegram-Bot-Api-Secret-Token": "w" }), env, { waitUntil: (p) => tasks.push(p) });
await Promise.all(tasks);
assert.equal(photos, 1); assert.match(sent.at(-1), /тиждень[\s\S]*дані на/);
assert.equal(dispatched, 1);                      // served from cache, no workflow run
// planned schedule (YASNO): published, changed, 30-min heads-up, /status line
env.YASNO_GROUP = "9.1";
const midnight = (() => { const d = new Date(); d.setUTCHours(0, 0, 0, 0); return d; })();
const iso = (d) => d.toISOString().replace(".000Z", "+00:00");
const nowMin = Math.floor((Date.now() - midnight.getTime()) / 60000);
const day = (date, slots, status = "ScheduleApplies") => ({ date: iso(date), status, slots });
const tomorrowDate = new Date(midnight.getTime() + 86400000);
yasno = { "9.1": { today: day(midnight, [{ start: 0, end: 1440, type: "NotPlanned" }]),
                   tomorrow: day(tomorrowDate, [], "WaitingForSchedule") } };
const m0 = sent.length;
await tick({ v: 230 });
assert.equal(sent.length, m0);                                                 // first sight of today: silent
yasno["9.1"].tomorrow = day(tomorrowDate, [{ start: 480, end: 600, type: "Definite" }, { start: 600, end: 690, type: "Definite" }]);
await tick({ v: 230 });
assert.match(sent.at(-1), /Графік на завтра[\s\S]*08:00–11:30/);              // adjacent slots merged
await tick({ v: 230 }); assert.equal(sent.filter((m) => m.includes("Графік на завтра")).length, 1);
if (nowMin + 20 < 1440) {
  yasno["9.1"].today = day(midnight, [{ start: nowMin + 20, end: Math.min(nowMin + 140, 1440), type: "Definite" }]);
  await tick({ v: 230, soc: 100, bp: 0 });
  assert.ok(sent.some((m) => /Графік на сьогодні змінився/.test(m)));
  assert.ok(sent.some((m) => /відключення за графіком[\s\S]*Батарея 100%[\s\S]*з запасом/.test(m)));
  const k = sent.length; await tick({ v: 230, soc: 100 }); assert.equal(sent.length, k);   // once
  const statusTasks = [];
  await worker.fetch(req("/telegram", JSON.stringify({ message: { chat: { id: 1 }, text: "/status" } }),
    { "X-Telegram-Bot-Api-Secret-Token": "w" }), env, { waitUntil: (p) => statusTasks.push(p) });
  await Promise.all(statusTasks);
  assert.match(sent.at(-1), /За графіком \(група 9\.1\)/);
}

// day archives for the app's day picker
env.APP_TOKEN = "a";
r = await worker.fetch(req("/cache/days", JSON.stringify({ days: { "2026-11-20": { date: "2026-11-20", points: [] },
  "../x": {} } }), { "X-Cache-Secret": "c" }), env, { waitUntil() {} });
assert.equal(r.status, 200); assert.ok(kv.has("day:2026-11-20")); assert.ok(!kv.has("day:../x"));
const get = (path, auth) => worker.fetch(new Request("https://w" + path, { headers: auth ? { Authorization: auth } : {} }),
                                        env, { waitUntil() {} });
assert.equal((await get("/api/day?date=2026-11-20")).status, 403);
assert.equal((await get("/api/day?date=2026-11-20", "Bearer a")).status, 200);
assert.equal((await get("/api/day?date=2026-11-21", "Bearer a")).status, 404);
assert.equal((await get("/api/day?date=x", "Bearer a")).status, 400);
const dash = await (await get("/api/data", "Bearer a")).json();
assert.deepEqual(dash.schedule.today.off.length, nowMin + 20 < 1440 ? 1 : 0);
console.log("worker tests passed:", sent.length, "messages");
