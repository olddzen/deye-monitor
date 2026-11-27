// node --loader ./test/html-loader.mjs test/guests.test.mjs — a guest connects their own Deye.
import assert from "node:assert/strict";
import crypto from "node:crypto";
import worker from "../src/index.js";

const kv = new Map();
const KV = { async get(k, t) { const v = kv.get(k); return v == null ? null : t === "json" ? JSON.parse(v) : v; },
             async put(k, v) { kv.set(k, v); }, async delete(k) { kv.delete(k); } };
const OWNER = "1", GUEST = "7", PASSWORD = "Sup3r-secret";
const pwHash = crypto.createHash("sha256").update(PASSWORD).digest("hex");
let sent = [], deleted = [], edits = [], tokenBodies = [];
const devices = { owner: { v: 230, soc: 80 }, guest: { v: 228, soc: 70 } };
const yasno = { "29.1": { today: { date: "2026-01-01T00:00:00+02:00", status: "ScheduleApplies", slots: [] } } };

globalThis.fetch = async (url, init = {}) => {
  url = String(url);
  const json = (o) => new Response(JSON.stringify(o));
  const body = init.body ? JSON.parse(init.body) : {};
  if (url.includes("/account/token")) {
    tokenBodies.push(body);
    const ok = body.password === pwHash || body.email === "owner@x";
    return json(ok ? { success: true, accessToken: body.email === "owner@x" ? "towner" : "tguest", expiresIn: "86400" }
                   : { success: false, code: "2101019" });
  }
  const auth = (init.headers || {}).Authorization || "";
  if (url.includes("/station/list")) return json({ success: true, stationList: [{ id: 5, name: "Дача" }] });
  if (url.includes("/station/device")) return json({ success: true, deviceListItems: [
    { deviceSn: "GSN1", deviceType: "INVERTER" }, { deviceSn: "LOG1", deviceType: "COLLECTOR" }] });
  if (url.includes("/device/latest")) {
    const who = auth.includes("tguest") ? "guest" : "owner";
    assert.equal(body.deviceList[0], who === "guest" ? "GSN1" : "sn");  // never someone else's inverter
    const d = devices[who];
    return json({ success: true, deviceDataList: [{ collectionTime: Date.now() / 1000, dataList: [
      { key: "GridVoltageL1L2", value: String(d.v) }, { key: "SOC", value: String(d.soc) },
      { key: "Temperature- Battery", value: "20" }, { key: "BatteryPower", value: "0" },
      { key: "TotalConsumptionPower", value: "400" }, { key: "BatteryRatedCapacity", value: "100" },
      { key: "BatteryVoltage", value: "52" }] }] });
  }
  if (url.includes("/historyRaw")) return json({ success: true, dataList: [] });
  if (url.includes("/alertList")) return json({ success: true, alertList: [] });
  if (url.includes("app.yasno.ua")) return json(yasno);
  if (url.includes("/sendMessage")) { sent.push({ chat: String(body.chat_id), text: body.text, kb: body.reply_markup }); return json({ ok: true }); }
  if (url.includes("/deleteMessage")) { deleted.push(body); return json({ ok: true }); }
  if (url.includes("/editMessageText")) { edits.push(body); return json({ ok: true }); }
  if (url.includes("/answerCallbackQuery")) return json({ ok: true });
  if (url.includes("/dispatches")) return new Response(null, { status: 204 });
  throw new Error("unexpected " + url);
};

const env = { KV, TELEGRAM_BOT_TOKEN: "123:ABC", TELEGRAM_CHAT_ID: OWNER, TELEGRAM_WEBHOOK_SECRET: "w",
  DEYE_CLOUD_DEVICE_SN: "sn", DEYE_CLOUD_EMAIL: "owner@x", DEYE_CLOUD_PASSWORD_SHA256: "h", DEYE_CLOUD_APP_ID: "app",
  DEYE_CLOUD_APP_SECRET: "s", GUEST_KEY: "guest-key-for-tests", WORKER_HOST: "w.example", GITHUB_REPO: "o/r", GITHUB_TOKEN: "g" };

let msgId = 100;
const post = async (update) => {
  const tasks = [];
  const r = await worker.fetch(new Request("https://w/telegram", { method: "POST", body: JSON.stringify(update),
    headers: { "X-Telegram-Bot-Api-Secret-Token": "w" } }), env, { waitUntil: (p) => tasks.push(p) });
  assert.equal(r.status, 200);
  await Promise.all(tasks);
};
const say = (chat, text) => post({ message: { message_id: ++msgId, chat: { id: Number(chat), type: "private" },
                                              from: { id: Number(chat), first_name: "Оля" }, text } });
const press = (chat, data) => post({ callback_query: { id: "q", data,
  message: { message_id: 9, chat: { id: Number(chat) }, text: "запит" } } });
const to = (chat) => sent.filter((m) => m.chat === chat);
const last = (chat) => to(chat).at(-1).text;
const cron = async (minute) => {
  const tasks = [];
  await worker.scheduled({ cron: "* * * * *", scheduledTime: Date.UTC(2026, 0, 1, 0, minute) }, env, { waitUntil: (p) => tasks.push(p) });
  await Promise.all(tasks);
};

// 1) a stranger asks: the owner gets approve/deny buttons; the stranger waits
await say(GUEST, "/start");
assert.match(last(OWNER), /Оля.*хоче підключити/);
assert.deepEqual(to(OWNER).at(-1).kb.inline_keyboard[0].map((b) => b.callback_data), ["g:ok:7", "g:no:7"]);
assert.match(last(GUEST), /Запит надіслано власнику/);
await say(GUEST, "/status");
assert.match(last(GUEST), /Чекаємо/);

// a guest can't approve themselves
await press(GUEST, "g:ok:7");
assert.match(last(GUEST), /Чекаємо/);
assert.equal(JSON.parse(kv.get("guests"))[GUEST].status, "pending");

// 2) the owner approves → the guest is asked for the Deye email
await press(OWNER, "g:ok:7");
assert.match(last(GUEST), /email/);
assert.match(edits.at(-1).text, /Дозволено/);

// 3) email, then a wrong password: the message is deleted, the login fails, we start again
await say(GUEST, "not-an-email");
assert.match(last(GUEST), /не схоже на email/);
await say(GUEST, "olia@example.com");
assert.match(last(GUEST), /пароль/);
await say(GUEST, "wrong");
assert.equal(deleted.at(-1).message_id, msgId);
assert.match(last(GUEST), /Deye не пустив[\s\S]*email ще раз/);

// 4) the right password: inverter found, battery size read, inverter power asked
await say(GUEST, "olia@example.com");
await say(GUEST, PASSWORD);
assert.equal(deleted.at(-1).message_id, msgId);
assert.match(last(GUEST), /потужність/);
const rec = JSON.parse(kv.get("guests"))[GUEST];
assert.equal(rec.sn, "GSN1");
assert.equal(rec.batteryWh, 5120);  // 100 Ah × 51.2 V
assert.ok(!kv.get("guests").includes(PASSWORD) && !kv.get("guests").includes(pwHash), "password stored encrypted");
assert.ok(tokenBodies.some((b) => b.email === "olia@example.com" && b.password === pwHash));

// 5) 5 kW, then a YASNO group that doesn't exist, then a real one
await press(GUEST, "g:inv:5000");
assert.match(last(GUEST), /групу відключень/);
await say(GUEST, "99.9");
assert.match(last(GUEST), /Групи 99\.9 немає/);
await say(GUEST, "29.1");
assert.ok(to(GUEST).some((m) => /Готово/.test(m.text)));
assert.match(last(GUEST), /Світло є/);
assert.match(last(OWNER), /Оля: Deye підключено/);
assert.equal(JSON.parse(kv.get("guests"))[GUEST].status, "active");

// 6) even minutes check guests: first run silent, then the guest's grid drops → only the guest hears it
const ownerBefore = to(OWNER).length;
await cron(2);
devices.guest.v = 0;
await cron(2);
assert.match(last(GUEST), /Світло вимкнули[\s\S]*Батарея: 70%/);
assert.equal(to(OWNER).length, ownerBefore, "the owner doesn't get the guest's alerts");
assert.equal(JSON.parse(kv.get("g:7:live")).gridOn, false, "guest state is kept apart");
assert.equal(JSON.parse(kv.get("live")).gridOn, true, "the owner's state is untouched");
// odd minutes don't touch guests
devices.guest.v = 228;
await cron(1);
assert.equal(JSON.parse(kv.get("g:7:live")).gridOn, false);
devices.guest.v = 0;

// 7) the Mini App: the guest sees their own inverter; strangers don't
function initData(userId) {
  const fields = { auth_date: String(Math.floor(Date.now() / 1000)), user: JSON.stringify({ id: Number(userId) }) };
  const check = Object.keys(fields).sort().map((k) => `${k}=${fields[k]}`).join("\n");
  const secret = crypto.createHmac("sha256", "WebAppData").update(env.TELEGRAM_BOT_TOKEN).digest();
  return new URLSearchParams({ ...fields, hash: crypto.createHmac("sha256", secret).update(check).digest("hex") }).toString();
}
const api = (uid) => worker.fetch(new Request("https://w/api/data", { headers: { "X-Telegram-Init-Data": initData(uid) } }), env, {});
let r = await api(GUEST);
assert.equal(r.status, 200);
const body = await r.json();
assert.equal(body.guest, true);
assert.equal(body.data, null);
assert.equal(body.live.gridOn, false);
assert.equal(body.live.limits.inverterW, 5000);
assert.equal(body.schedule.group, "29.1");
assert.equal((await api("8")).status, 403);
r = await api(OWNER);
assert.equal((await r.json()).live.limits.inverterW, 6000);
assert.equal((await worker.fetch(new Request("https://w/api/day?date=2026-01-01",
  { headers: { "X-Telegram-Init-Data": initData(GUEST) } }), env, {})).status, 403, "day archive is owner-only");

// 8) the owner lists and removes; a denied stranger is ignored afterwards
await say(OWNER, "/guests");
assert.match(last(OWNER), /Оля — підключений, група 29\.1/);
await say("9", "/start");
await press(OWNER, "g:no:9");
assert.match(last("9"), /відхилив/);
const n9 = to("9").length;
await say("9", "/start");
assert.equal(to("9").length, n9);
await press(OWNER, "g:del:7");
assert.match(last(GUEST), /вимкнув твій доступ/);
assert.equal(JSON.parse(kv.get("guests"))[GUEST], undefined);
assert.equal(kv.get("g:7:live"), undefined);

// 9) /stop by the guest themselves
await say("11", "/start"); await press(OWNER, "g:ok:11");
await say("11", "/stop");
assert.match(last("11"), /відключено/);
assert.equal(JSON.parse(kv.get("guests"))["11"], undefined);
console.log("guest tests passed");
