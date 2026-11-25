// Cloudflare Worker for deye-monitor:
//  - Telegram webhook: /status answered instantly from Deye Cloud; report commands answered instantly
//    from reports the GitHub workflow pre-renders every 5 min and uploads to POST /cache.
//  - Cron every minute: live alerts (grid on/off, low battery, Deye failures, lost data) straight
//    from Deye Cloud; every 5 min it also starts the GitHub workflow (history, stats, reports).

import APP_HTML from "./app.html";

const DEYE_URL = "https://eu1-developer.deyecloud.com";
const GRID_MIN_V = 180;
const STALE_MIN = 20;
const REPORT_COMMANDS = {
  week: "Звіт за 7 днів з графіком",
  month: "Звіт за 30 днів з графіком",
  battery: "Батарея: цикли, ємність, розряди",
  history: "Останні відключення",
  stats: "Коротка статистика відключень",
  errors: "Серйозні помилки інвертора",
};
const COMMANDS = { status: "Чи є світло зараз, заряд батареї (миттєво)",
                   dashboard: "Дашборд: графіки, батарея, відключення", ...REPORT_COMMANDS };
const SOC_ALERTS = [30, 15];
const CACHE_MAX_AGE_MIN = 30;
const FAULT_HINTS = {
  F13: "змінився режим роботи (мережа/батарея)",
  F25: "проблема з батареєю на боці AC (інвертор втратив батарею під навантаженням)",
  F47: "завищена частота мережі — нестабільна мережа, часто при подачі/відключенні світла",
  F56: "низька напруга батареї (DC)",
  F58: "немає зв'язку з BMS батареї",
  F64: "перегрів радіатора інвертора",
};

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === "/telegram") {
      // Telegram sends the secret we registered with setWebhook; anything else is not Telegram.
      if (request.headers.get("X-Telegram-Bot-Api-Secret-Token") !== env.TELEGRAM_WEBHOOK_SECRET) {
        return new Response("forbidden", { status: 403 });
      }
      const update = await request.json().catch(() => null);
      ctx.waitUntil(handleUpdate(update, env).catch((e) => console.log("update failed:", e && e.name)));
      return new Response("ok");
    }
    if (request.method === "POST" && url.pathname === "/cache") {
      // pre-rendered reports from the GitHub workflow
      if (!env.CACHE_SECRET || request.headers.get("X-Cache-Secret") !== env.CACHE_SECRET) {
        return new Response("forbidden", { status: 403 });
      }
      const body = await request.text();
      if (body.length > 5_000_000) return new Response("too large", { status: 413 });
      await env.KV.put("reports", body);
      return new Response("stored");
    }
    if (request.method === "GET" && (url.pathname === "/app" || url.pathname === "/app/")) {
      return new Response(APP_HTML, { headers: { "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-cache", "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer" } });
    }
    if (request.method === "GET" && url.pathname === "/api/data") return dashboardData(request, env);
    return new Response("deye-monitor bot\n");
  },

  async scheduled(event, env, ctx) {
    ctx.waitUntil(liveCheck(env).catch((e) => console.log("live check failed:", e && e.message)));
    if (new Date(event.scheduledTime).getUTCMinutes() % 5 === 0) {
      ctx.waitUntil(dispatchWorkflow(env, "").catch((e) => console.log("dispatch failed:", e && e.message)));
    }
  },
};

// ---------------------------------------------------------------- Telegram
async function handleUpdate(update, env) {
  const msg = update && update.message;
  if (!msg || !msg.chat || typeof msg.text !== "string") return;
  if (String(msg.chat.id) !== String(env.TELEGRAM_CHAT_ID)) return; // only the owner
  const text = msg.text.trim();
  if (!text.startsWith("/")) return;
  const cmd = text.split(/\s+/)[0].slice(1).split("@")[0].toLowerCase();

  if (cmd === "status") {
    let reply;
    try {
      reply = await statusText(env);
    } catch (e) {
      reply = `Не вдалося отримати дані з Deye: ${esc(e.message || e.name)}`;
    }
    return sendMessage(env, reply);
  }
  if (cmd === "dashboard" || cmd === "app") {
    return sendMessage(env, "📊 Дашборд", { inline_keyboard: [[{ text: "Відкрити дашборд",
      web_app: { url: `https://${env.WORKER_HOST}/app` } }]] });
  }
  if (cmd in REPORT_COMMANDS) {
    const cache = await env.KV.get("reports", "json").catch(() => null);
    const item = cache && cache.items && cache.items[cmd];
    const ageMin = cache ? (Date.now() / 1000 - cache.generated_at) / 60 : Infinity;
    if (item && ageMin <= CACHE_MAX_AGE_MIN) {
      if (item.png) await sendPhoto(env, item.png);
      return sendMessage(env, `${item.text}\n\n<i>дані на ${clock(cache.generated_at)}</i>`);
    }
    try {  // no fresh cache yet: let the workflow answer
      await dispatchWorkflow(env, cmd);
      return sendMessage(env, "⏳ Готую, буде за хвилину-дві");
    } catch (e) {
      return sendMessage(env, `Не вдалося запустити: ${esc(e.message || e.name)}`);
    }
  }
  const help = Object.entries(COMMANDS).map(([c, d]) => `/${c} — ${d}`).join("\n");
  return sendMessage(env, `Команди:\n${help}`);
}

async function sendMessage(env, text, replyMarkup) {
  const resp = await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ chat_id: env.TELEGRAM_CHAT_ID, text, parse_mode: "HTML",
                           disable_web_page_preview: true, ...(replyMarkup ? { reply_markup: replyMarkup } : {}) }),
  });
  if (!resp.ok) console.log("sendMessage failed:", resp.status);
}

async function sendPhoto(env, pngBase64) {
  const bytes = Uint8Array.from(atob(pngBase64), (c) => c.charCodeAt(0));
  const form = new FormData();
  form.append("chat_id", String(env.TELEGRAM_CHAT_ID));
  form.append("photo", new Blob([bytes], { type: "image/png" }), "chart.png");
  const resp = await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendPhoto`,
                           { method: "POST", body: form });
  if (!resp.ok) console.log("sendPhoto failed:", resp.status);
}

// ---------------------------------------------------------------- live alerts (cron, every minute)
async function liveCheck(env) {
  const sn = env.DEYE_CLOUD_DEVICE_SN;
  const nowSec = Date.now() / 1000;
  const state = (await env.KV.get("live", "json")) || {};
  const save = () => env.KV.put("live", JSON.stringify(state));  // only on changes (KV write quota)

  const latest = await deye(env, "/v1.0/device/latest", { deviceList: [sn] });
  const dev = (latest.deviceDataList || [])[0] || {};
  const p = {};
  for (const item of dev.dataList || []) p[item.key] = item.value;
  const num = (k) => (p[k] === undefined || p[k] === null || p[k] === "" ? null : Number(p[k]));
  const updated = Number(dev.collectionTime) || 0;

  // lost data: the stick stopped uploading (often: no power and no internet in the flat)
  const stale = !updated || nowSec - updated > STALE_MIN * 60;
  if (stale && !state.stale) {
    state.stale = true;
    await save();
    return sendMessage(env, `📵 Deye не отримує даних ${updated ? duration(nowSec - updated) : ""}\n` +
      "Найімовірніше, у квартирі немає світла і разом з ним інтернету, або стік втратив Wi-Fi.");
  }
  if (stale) return;
  if (state.stale) {
    state.stale = false;
    await save();
    await sendMessage(env, "📶 Дані від Deye знову надходять");
  }

  const voltage = num("GridVoltageL1L2");
  if (voltage === null) return;
  const gridOn = voltage >= GRID_MIN_V;
  const socRaw = num("SOC");
  const bmsTemp = num("Temperature- Battery");
  const soc = socRaw === null || socRaw <= 0 || (bmsTemp !== null && bmsTemp <= -50) ? null : socRaw;
  const socText = soc === null ? "немає даних від BMS" : `${soc}%`;

  if (state.gridOn === undefined) {  // first run: remember silently
    Object.assign(state, { gridOn, since: updated, socFired: [] });
    return save();
  }
  if (gridOn !== state.gridOn) {
    const was = state.since ? duration(updated - state.since) : null;
    if (gridOn) {
      await sendMessage(env, `💡 <b>Світло дали</b> о ${clock(updated)}` +
        (was ? `\nНе було: <b>${was}</b>` : "") + `\n🔋 Батарея: ${socText}`);
    } else {
      await sendMessage(env, `🔌 <b>Світло вимкнули</b> о ${clock(updated)}` + (was ? `\nБуло: ${was}` : "") +
        `\n🔋 Батарея: ${socText} · навантаження ${num("TotalConsumptionPower") ?? "?"} Вт`);
    }
    Object.assign(state, { gridOn, since: updated, socFired: [] });
    await save();
  }

  if (!gridOn && soc !== null) {
    const fired = state.socFired || [];
    const crossed = SOC_ALERTS.filter((l) => soc <= l && !fired.includes(l));
    if (crossed.length) {
      const lowest = Math.min(...crossed);
      const bp = num("BatteryPower") || 0;
      const hours = bp > 50 ? ((soc - 10) / 100) * 11800 / bp : 0;
      await sendMessage(env, `🪫 Батарея ${soc}% (поріг ${lowest}%)` +
        (hours > 0 ? `\nВистачить приблизно на ${duration(hours * 3600)}` : ""));
      state.socFired = fired.concat(SOC_ALERTS.filter((x) => x >= lowest && !fired.includes(x)));
      await save();
    }
  }

  // serious Deye alerts, checked every 5 minutes
  if (new Date().getUTCMinutes() % 5 === 0) await checkDeyeAlerts(env, sn, nowSec);
}

async function checkDeyeAlerts(env, sn, nowSec) {
  const data = await deye(env, "/v1.0/device/alertList", {
    deviceSn: sn, startTimestamp: Math.floor(nowSec - 6 * 3600), endTimestamp: Math.floor(nowSec),
    page: 1, size: 100 });
  const seen = (await env.KV.get("seen_alerts", "json")) || null;
  const items = (data.alertList || []).filter((a) => Number(a.level) >= 2);
  if (seen === null) {  // first run: don't replay old alerts
    return env.KV.put("seen_alerts", JSON.stringify(items.map((a) => String(a.alertId))));
  }
  const fresh = items.filter((a) => !seen.includes(String(a.alertId)));
  if (!fresh.length) return;
  for (const a of fresh) {
    const name = String(a.alertName || a.alertCode || "?");
    const parts = [`⚠️ <b>Deye: ${esc(name)}</b> (Failure)`];
    const hint = a.description || FAULT_HINTS[name.split("_")[0].slice(0, 3)];
    if (hint) parts.push(esc(hint));
    if (String(a.status) === "0" && a.alertStartTime && a.alertEndTime) {
      parts.push(`Тривала ${duration(a.alertEndTime - a.alertStartTime)}, вже минула (о ${clock(a.alertEndTime)})`);
    }
    if (a.solution) parts.push(`Що робити: ${esc(a.solution)}`);
    await sendMessage(env, parts.join("\n"));
  }
  await env.KV.put("seen_alerts", JSON.stringify(seen.concat(fresh.map((a) => String(a.alertId))).slice(-300)));
}

// ---------------------------------------------------------------- GitHub
async function dispatchWorkflow(env, command) {
  const resp = await fetch(
    `https://api.github.com/repos/${env.GITHUB_REPO}/actions/workflows/monitor.yml/dispatches`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.GITHUB_TOKEN}`,
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "deye-monitor-worker",
      },
      body: JSON.stringify({ ref: "main", inputs: command ? { command } : {} }),
    });
  if (resp.status !== 204) throw new Error(`GitHub ${resp.status}`);
}

// ---------------------------------------------------------------- Deye Cloud
async function deyeToken(env) {
  const cached = await env.KV.get("deye_token", "json");
  if (cached && cached.until > Date.now()) return cached.token;
  const resp = await fetch(`${deyeBase(env)}/v1.0/account/token?appId=${encodeURIComponent(env.DEYE_CLOUD_APP_ID)}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ appSecret: env.DEYE_CLOUD_APP_SECRET, email: env.DEYE_CLOUD_EMAIL,
                           password: env.DEYE_CLOUD_PASSWORD_SHA256 }),
  });
  const data = await resp.json();
  if (!data.success || !data.accessToken) throw new Error(`token ${data.code || resp.status}`);
  const token = data.accessToken.replace(/^bearer\s+/i, "");
  const ttl = Math.max(300, (Number(data.expiresIn) || 86400) - 3600);
  await env.KV.put("deye_token", JSON.stringify({ token, until: Date.now() + ttl * 1000 }),
                   { expirationTtl: ttl });
  return token;
}

function deyeBase(env) {
  return (env.DEYE_CLOUD_URL || DEYE_URL).replace(/\/$/, "");
}

async function deye(env, path, body, retry = true) {
  const token = await deyeToken(env);
  const resp = await fetch(`${deyeBase(env)}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  });
  const data = await resp.json().catch(() => ({}));
  if (!data.success) {
    if (retry && resp.status === 401) {
      await env.KV.delete("deye_token");
      return deye(env, path, body, false);
    }
    throw new Error(`${path} ${data.code || resp.status}`);
  }
  return data;
}

// Live snapshot shared by /status and the dashboard.
async function liveData(env) {
  const sn = env.DEYE_CLOUD_DEVICE_SN;
  const nowSec = Date.now() / 1000;
  const [latest, history] = await Promise.all([
    deye(env, "/v1.0/device/latest", { deviceList: [sn] }),
    deye(env, "/v1.0/device/historyRaw", { deviceSn: sn, measurePoints: ["GridVoltageL1L2"],
                                           startTimestamp: Math.floor(nowSec - 86400),
                                           endTimestamp: Math.floor(nowSec) }).catch(() => null),
  ]);
  const dev = (latest.deviceDataList || [])[0] || {};
  const p = {};
  for (const item of dev.dataList || []) p[item.key] = item.value;
  const num = (k) => (p[k] === undefined || p[k] === null || p[k] === "" ? null : Number(p[k]));

  const updated = Number(dev.collectionTime) || null;
  const voltage = num("GridVoltageL1L2");
  const gridOn = voltage !== null && voltage >= GRID_MIN_V;

  // since when the current state holds, from the last 24 h of 5-min history
  let since = null, beyondDay = false;
  const pts = ((history && history.dataList) || [])
    .map((d) => ({ t: Number(d.time), v: Number(((d.itemList || [])[0] || {}).value) }))
    .filter((d) => d.t && !Number.isNaN(d.v)).sort((a, b) => a.t - b.t);
  if (pts.length) {
    let i = pts.length - 1;
    while (i >= 0 && (pts[i].v >= GRID_MIN_V) === gridOn) i--;
    if (i < 0) beyondDay = true;
    else since = (pts[i].t + pts[i + 1].t) / 2;
  }
  const socRaw = num("SOC");
  const bmsTemp = num("Temperature- Battery");
  const bmsSilent = socRaw === null || socRaw <= 0 || (bmsTemp !== null && bmsTemp <= -50);
  const batteryPower = bmsSilent ? null : num("BatteryPower") || 0;
  const soc = bmsSilent ? null : socRaw;
  const runtimeH = soc !== null && batteryPower > 50 ? Math.max(0, ((soc - 10) / 100) * 11800 / batteryPower) : null;
  return {
    now: nowSec, updated, stale: !updated || nowSec - updated > STALE_MIN * 60,
    gridOn, since, beyondDay, voltage, freq: num("GridFrequency"),
    gridPower: num("TotalGridPower"), load: num("TotalConsumptionPower"),
    soc, batteryPower, runtimeH,
    batteryTemp: bmsSilent ? null : bmsTemp, inverterTemp: num("DC Temperature"),
    relay: p.GridRelayStatus || null,
    // detailed battery / energy points for the app's battery screen
    battery: {
      voltage: num("BatteryVoltage"), current: num("BatteryCurrent"),
      bmsVoltage: num("BMSVoltage"), bmsCurrent: num("BMSCurrent"),
      chargeVoltage: num("BMSChargeVoltage"),
      chargeLimitA: num("ChargeCurrentLimit"), dischargeLimitA: num("DischargeCurrentLimit"),
      ratedAh: num("BatteryRatedCapacity"),
      todayChargedKwh: num("DailyChargingEnergy"), todayDischargedKwh: num("DailyDischargingEnergy"),
      totalChargedKwh: num("TotalChargeEnergy"), totalDischargedKwh: num("TotalDischargeEnergy"),
    },
    today: {
      consumptionKwh: num("DailyConsumption"), importedKwh: num("DailyEnergyPurchased"),
    },
    acTemp: num("AC Temperature"),
  };
}

async function statusText(env) {
  const d = await liveData(env);
  const lines = [];
  const holds = d.since ? ` вже ${duration(d.now - d.since)}` : d.beyondDay ? " понад добу" : "";
  lines.push(d.gridOn ? `<b>💡 Світло є${holds}</b>` : `<b>🔌 Світла немає${holds}</b>`);
  if (d.since && !d.gridOn) lines.push(`вимкнули о ${clock(d.since)}`);
  if (d.soc === null) {
    lines.push("🔋 немає даних від BMS");
  } else {
    const bp = d.batteryPower;
    const mode = bp < -20 ? "заряджається" : bp > 20 ? "розряджається" : "у спокої";
    lines.push(`🔋 ${d.soc}% (${mode}, ${Math.abs(bp)} Вт)` +
      (d.runtimeH ? `, вистачить ≈ ${duration(d.runtimeH * 3600)}` : ""));
  }
  if (d.load !== null) lines.push(`🏠 Навантаження: ${d.load} Вт`);
  if (d.voltage !== null) {
    lines.push(`⚡ Мережа: ${Math.round(d.voltage)} В${d.freq ? `, ${d.freq.toFixed(1)} Гц` : ""}`);
  }
  const temps = [];
  if (d.batteryTemp !== null) temps.push(`батарея ${Math.round(d.batteryTemp)} °C`);
  if (d.inverterTemp !== null) temps.push(`інвертор ${Math.round(d.inverterTemp)} °C`);
  if (temps.length) lines.push(`🌡 ${temps.join(", ")}`);
  if (d.updated) {
    const ageMin = (d.now - d.updated) / 60;
    lines.push(d.stale
      ? `⚠️ Deye не отримує даних ${duration(ageMin * 60)}: можливо, у квартирі немає світла й інтернету`
      : `⏱ дані Deye на ${clock(d.updated)} (${Math.max(0, Math.round(ageMin))} хв тому)`);
  }
  return lines.join("\n");
}

// ---------------------------------------------------------------- Mini App
// Telegram signs initData with the bot token; only the owner may read the dashboard data.
async function verifyInitData(initData, env) {
  if (!initData) return false;
  const params = new URLSearchParams(initData);
  const hash = params.get("hash");
  if (!hash) return false;
  params.delete("hash");
  const check = [...params.entries()].map(([k, v]) => `${k}=${v}`).sort().join("\n");
  const enc = new TextEncoder();
  const hmac = async (key, msg) => new Uint8Array(await crypto.subtle.sign("HMAC",
    await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]), enc.encode(msg)));
  const secret = await hmac(enc.encode("WebAppData"), env.TELEGRAM_BOT_TOKEN);
  const sig = [...(await hmac(secret, check))].map((b) => b.toString(16).padStart(2, "0")).join("");
  if (sig.length !== hash.length) return false;
  let diff = 0;
  for (let i = 0; i < sig.length; i++) diff |= sig.charCodeAt(i) ^ hash.charCodeAt(i);
  if (diff) return false;
  const authDate = Number(params.get("auth_date"));
  if (!authDate || Date.now() / 1000 - authDate > 86400) return false;
  let user = null;
  try { user = JSON.parse(params.get("user") || "null"); } catch { return false; }
  return !!user && String(user.id) === String(env.TELEGRAM_CHAT_ID);
}

// The iOS app has no Telegram signature: it sends a long random APP_TOKEN instead.
function appTokenOk(request, env) {
  const auth = request.headers.get("Authorization") || "";
  const given = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  const want = env.APP_TOKEN || "";
  if (!want || given.length !== want.length) return false;
  let diff = 0;
  for (let i = 0; i < want.length; i++) diff |= want.charCodeAt(i) ^ given.charCodeAt(i);
  return diff === 0;
}

async function dashboardData(request, env) {
  if (!appTokenOk(request, env) && !(await verifyInitData(request.headers.get("X-Telegram-Init-Data"), env))) {
    return new Response("forbidden", { status: 403 });
  }
  const [live, cache] = await Promise.all([
    liveData(env).catch((e) => ({ error: String(e.message || e.name) })),
    env.KV.get("reports", "json").catch(() => null),
  ]);
  return new Response(JSON.stringify({ live, data: cache && cache.data, generated_at: cache && cache.generated_at }), {
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

// ---------------------------------------------------------------- formatting
function duration(seconds) {
  const minutes = Math.round(seconds / 60);
  if (minutes < 1) return "менше хвилини";
  const d = Math.floor(minutes / 1440), h = Math.floor((minutes % 1440) / 60), m = minutes % 60;
  const parts = [];
  if (d) parts.push(`${d} д`);
  if (h) parts.push(`${h} год`);
  if (m && !d) parts.push(`${m} хв`);
  return parts.join(" ");
}

function clock(ts) {
  return new Intl.DateTimeFormat("uk-UA", { timeZone: "Europe/Kyiv", hour: "2-digit", minute: "2-digit" })
    .format(new Date(ts * 1000));
}

function esc(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
