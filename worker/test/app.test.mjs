// node --loader ./test/html-loader.mjs test/app.test.mjs — Mini App route and signed data API.
import assert from "node:assert/strict";
import crypto from "node:crypto";
import worker from "../src/index.js";

const kv = new Map([["reports", JSON.stringify({ generated_at: 1, data: { week: { count: 2 } } })]]);
const KV = { async get(k, t) { const v = kv.get(k); return v == null ? null : t === "json" ? JSON.parse(v) : v; },
             async put(k, v) { kv.set(k, v); }, async delete(k) { kv.delete(k); } };
globalThis.fetch = async (url) => {
  url = String(url);
  const json = (o) => new Response(JSON.stringify(o));
  if (url.includes("/account/token")) return json({ success: true, accessToken: "t", expiresIn: "86400" });
  if (url.includes("/device/latest")) return json({ success: true, deviceDataList: [{ collectionTime: Date.now() / 1000,
    dataList: [{ key: "GridVoltageL1L2", value: "221" }, { key: "SOC", value: "90" }, { key: "Temperature- Battery", value: "20" }] }] });
  if (url.includes("/historyRaw")) return json({ success: true, dataList: [] });
  throw new Error("unexpected " + url);
};
const env = { KV, TELEGRAM_BOT_TOKEN: "123:ABC", TELEGRAM_CHAT_ID: "42", DEYE_CLOUD_DEVICE_SN: "sn" };

function initData(userId, botToken = env.TELEGRAM_BOT_TOKEN, authDate = Math.floor(Date.now() / 1000)) {
  const fields = { auth_date: String(authDate), query_id: "q", user: JSON.stringify({ id: userId, first_name: "D" }) };
  const check = Object.keys(fields).sort().map((k) => `${k}=${fields[k]}`).join("\n");
  const secret = crypto.createHmac("sha256", "WebAppData").update(botToken).digest();
  const hash = crypto.createHmac("sha256", secret).update(check).digest("hex");
  return new URLSearchParams({ ...fields, hash }).toString();
}
const get = (path, headers = {}) => worker.fetch(new Request("https://w" + path, { headers }), env, { waitUntil() {} });

let r = await get("/app");
assert.equal(r.status, 200);
assert.match(await r.text(), /Deye монітор/);

assert.equal((await get("/api/data")).status, 403);                                         // no signature
assert.equal((await get("/api/data", { "X-Telegram-Init-Data": initData(7) })).status, 403);  // someone else
assert.equal((await get("/api/data", { "X-Telegram-Init-Data": initData(42, "999:XYZ") })).status, 403); // forged
assert.equal((await get("/api/data", { "X-Telegram-Init-Data": initData(42, undefined, 1) })).status, 403); // expired
r = await get("/api/data", { "X-Telegram-Init-Data": initData(42) });
assert.equal(r.status, 200);
const body = await r.json();
assert.equal(body.live.gridOn, true);
assert.equal(body.live.soc, 90);
assert.equal(body.data.week.count, 2);
console.log("app tests passed");
