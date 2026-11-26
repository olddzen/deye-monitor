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
const BATTERY_WH = 11800, CUTOFF_SOC = 10;
const V_HIGH = 250, V_LOW = 200, V_OK = [205, 245];  // grid voltage alert band with hysteresis
const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;
// Deye single-phase LV hybrid: 6 kW from the battery; the grid relay passes ~35 A (≈ 8 kW).
const INVERTER_W = 6000, BYPASS_W = 8000, NEAR_LIMIT = 0.85, PEAK_COOLDOWN_S = 1800;
const DEFAULT_SELF_USE_W = 35;          // inverter's own draw off-grid until the workflow measures it
const HOT_C = 65, HOT_OK_C = 55;        // inverter heatsink
const NOT_CHARGING_MIN = 60;            // grid back this long and the battery still isn't charging
// Planned outage schedule (YASNO / DTEK Kyiv). The group is a secret: YASNO_GROUP, e.g. "12.1".
const YASNO_URL = "https://app.yasno.ua/api/blackout-service/public/shutdowns";
const SCHEDULE_REMIND_MIN = 30;
// SmartThings (appliance energy). OAuth app credentials: ST_CLIENT_ID / ST_CLIENT_SECRET; tokens live in KV.
// ST_WATCH: comma-separated device ids worth a reminder when the grid goes down (e.g. a boiler's smart plug).
const ST_API = "https://api.smartthings.com/v1";
const ST_AUTH = "https://auth-global.api.smartthings.com/oauth/token";
const ST_SCOPE = "r:devices:* x:devices:* r:locations:*";
const SCHEDULE_STATUS = { ScheduleApplies: "діє графік", WaitingForSchedule: "графік ще не опубліковано",
                          EmergencyShutdowns: "екстрені відключення (графік не діє)" };
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
    if (request.method === "POST" && url.pathname === "/cache/days") {
      // per-day point archives for the app's day picker
      if (!env.CACHE_SECRET || request.headers.get("X-Cache-Secret") !== env.CACHE_SECRET) {
        return new Response("forbidden", { status: 403 });
      }
      const body = await request.json().catch(() => null);
      const days = (body && body.days) || {};
      const keys = Object.keys(days).filter((k) => DAY_RE.test(k)).slice(0, 20);
      for (const k of keys) {
        await env.KV.put(`day:${k}`, JSON.stringify(days[k]), { expirationTtl: 400 * 86400 });
      }
      return new Response("stored");
    }
    if (request.method === "GET" && url.pathname === "/api/day") return dayData(request, env, url);
    if (request.method === "GET" && url.pathname === "/st/callback") return stCallback(env, url);
    if (request.method === "GET" && url.pathname === "/schedule") {
      // planned outages for the workflow, which archives them to measure how well the schedule holds
      if (!env.CACHE_SECRET || request.headers.get("X-Cache-Secret") !== env.CACHE_SECRET) {
        return new Response("forbidden", { status: 403 });
      }
      const sched = await schedule(env).catch(() => null);
      return new Response(JSON.stringify(sched), { headers: { "Content-Type": "application/json" } });
    }
    if (request.method === "GET" && url.pathname === "/st/snapshot") {
      // appliance snapshot for the GitHub workflow (history is kept there)
      if (!env.CACHE_SECRET || request.headers.get("X-Cache-Secret") !== env.CACHE_SECRET) {
        return new Response("forbidden", { status: 403 });
      }
      const snap = await stSnapshot(env).catch((e) => ({ error: String(e.message || e.name) }));
      return new Response(JSON.stringify(snap), { headers: { "Content-Type": "application/json" } });
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
    ctx.waitUntil(stKeepFresh(env).catch((e) => console.log("st refresh failed:", e && e.message)));
    if (new Date(event.scheduledTime).getUTCMinutes() % 5 === 0) {
      ctx.waitUntil(dispatchWorkflow(env, "").catch((e) => console.log("dispatch failed:", e && e.message)));
    }
  },
};

// ---------------------------------------------------------------- Telegram
async function handleUpdate(update, env) {
  if (update && update.callback_query) return handleCallback(update.callback_query, env);
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
  if (cmd === "smartthings") {
    if (!env.ST_CLIENT_ID) return sendMessage(env, "SmartThings ще не налаштовано (немає ST_CLIENT_ID).");
    const state = crypto.randomUUID();
    await env.KV.put("st_state", state, { expirationTtl: 900 });
    const link = "https://api.smartthings.com/oauth/authorize?" + new URLSearchParams({
      client_id: env.ST_CLIENT_ID, response_type: "code", scope: ST_SCOPE, state,
      redirect_uri: `https://${env.WORKER_HOST}/st/callback` });
    return sendMessage(env, "🔗 Дозволь доступ до техніки SmartThings (посилання діє 15 хв):",
                       { inline_keyboard: [[{ text: "Підключити SmartThings", url: link }]] });
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
  if (stale) return scheduleAlerts(env, state, save, { nowSec, soc: null, load: null });
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
        (was ? `\nНе було: <b>${was}</b>` : "") + `\n🔋 Батарея: ${socText}` +
        outageSummary(state, soc) + (await planDiff(env, state.since, updated)));
    } else {
      const load = num("TotalConsumptionPower");
      const su = await selfUseW(env);
      const h = runtimeHours(soc, (load || 0) + su);
      await sendMessage(env, `🔌 <b>Світло вимкнули</b> о ${clock(updated)}` + (was ? `\nБуло: ${was}` : "") +
        `\n🔋 Батарея: ${socText} · навантаження ${load ?? "?"} Вт` +
        (h !== null ? `\n⏳ Вистачить ≈ ${duration(h * 3600)} (до ~${clock(updated + h * 3600)})` +
                      `\n<i>з урахуванням ≈ ${su} Вт, які споживає сам інвертор</i>` : ""));
    }
    await stOutageReminder(env, gridOn).catch((e) => console.log("st reminder failed:", e && e.message));
    Object.assign(state, { gridOn, since: updated, socFired: [], etaFired: false, chgFired: false,
                           socOff: gridOn ? null : soc, socOn: gridOn ? soc : null,
                           fullArmed: gridOn && soc !== null && soc < 95, fullFrom: gridOn ? updated : null });
    await save();
  }

  if (!gridOn && soc !== null) {
    const fired = state.socFired || [];
    const crossed = SOC_ALERTS.filter((l) => soc <= l && !fired.includes(l));
    if (crossed.length) {
      const lowest = Math.min(...crossed);
      const hours = runtimeHours(soc, Math.max(num("BatteryPower") || 0, (num("TotalConsumptionPower") || 0) + await selfUseW(env)));
      await sendMessage(env, `🪫 Батарея ${soc}% (поріг ${lowest}%)` +
        (hours !== null ? `\nВистачить приблизно на ${duration(hours * 3600)} (до ~${clock(updated + hours * 3600)})` : ""));
      state.socFired = fired.concat(SOC_ALERTS.filter((x) => x >= lowest && !fired.includes(x)));
      await save();
    }
  }

  // last hour of battery during an outage: one heads-up with what to switch off
  if (!gridOn && soc !== null && !state.etaFired) {
    const load = num("TotalConsumptionPower");
    const h = runtimeHours(soc, Math.max(num("BatteryPower") || 0, (load || 0) + await selfUseW(env)));
    if (h !== null && h <= 1) {
      state.etaFired = true;
      await save();
      await sendMessage(env, `⏰ <b>Батареї залишилось ≈ ${duration(h * 3600)}</b> (до ~${clock(updated + h * 3600)})\n` +
        `Зараз ${soc}% · ${load ?? "?"} Вт. Вимкніть потужні прилади (бойлер, обігрівач, духовку), щоб протриматись довше.`);
    }
  }

  // charged back to full after an outage
  if (gridOn && soc !== null && state.fullArmed && soc >= 100) {
    state.fullArmed = false;
    await save();
    await sendMessage(env, `🔋 Батарея знову повна` +
      (state.fullFrom ? ` — зарядилась за ${duration(updated - state.fullFrom)} після появи світла` : ""));
  }

  // grid voltage out of the safe band (only while the grid is on)
  if (gridOn && !state.vBad && (voltage > V_HIGH || voltage < V_LOW)) {
    state.vBad = true;
    await save();
    await sendMessage(env, `⚡️ <b>Напруга в мережі ${Math.round(voltage)} В</b> — ${voltage > V_HIGH ? "завищена" : "занижена"}\n` +
      "Норма 207–253 В. Інвертор може перейти на батарею; чутливу техніку краще не вмикати.");
  } else if (state.vBad && gridOn && voltage >= V_OK[0] && voltage <= V_OK[1]) {
    state.vBad = false;
    await save();
  }

  await techAlerts(env, state, save, { gridOn, soc, updated, num });
  await scheduleAlerts(env, state, save, { nowSec, soc, load: num("TotalConsumptionPower") });

  // serious Deye alerts, checked every 5 minutes
  if (new Date().getUTCMinutes() % 5 === 0) {
    await checkDeyeAlerts(env, sn, nowSec);
    await appExpiryReminder(env, state, save, nowSec);
  }
}

/** The inverter's own off-grid draw, measured by the workflow from real SOC drops (median). */
async function selfUseW(env) {
  const cache = await env.KV.get("reports", "json").catch(() => null);
  const w = cache && cache.data && cache.data.battery && cache.data.battery.self_use_w;
  return Number.isFinite(w) && w > 0 ? Math.round(w) : DEFAULT_SELF_USE_W;
}

/** "Витрачено 3% (≈ 0.35 кВт·год)" for the grid-back message. */
function outageSummary(state, soc) {
  if (soc === null || state.socOff === null || state.socOff === undefined) return "";
  const used = Math.max(0, state.socOff - soc);
  return `\n📉 Витрачено: ${used}% (≈ ${(used / 100 * BATTERY_WH / 1000).toFixed(2).replace(".", ",")} кВт·год)`;
}

/** How the outage matched the YASNO schedule: "за графіком 19:00–24:00 · вимкнули на 34 хв пізніше". */
async function planDiff(env, start, end) {
  if (!start) return "";
  const sched = await schedule(env).catch(() => null);
  const t = sched && sched.today;
  if (!t || t.status !== "ScheduleApplies") return "";
  const midnight = Date.parse(t.date) / 1000;
  const slot = t.off.find(([s, e]) => midnight + s * 60 < end && midnight + e * 60 > start);
  if (!slot) return start >= midnight ? "\n📅 Поза графіком" : "";
  const delta = (sec) => Math.abs(sec) < 300 ? "вчасно" : `на ${duration(Math.abs(sec))} ${sec > 0 ? "пізніше" : "раніше"}`;
  return `\n📅 За графіком ${slotText(slot)}: вимкнули ${delta(start - (midnight + slot[0] * 60))}, ` +
         `дали ${delta(end - (midnight + slot[1] * 60))}`;
}

/** Battery not charging with the grid back, load near the inverter's limits, inverter too hot. */
async function techAlerts(env, state, save, { gridOn, soc, updated, num }) {
  // 1) grid is back for an hour and the battery isn't taking charge
  const limitA = num("ChargeCurrentLimit");
  const onMin = state.since ? (updated - state.since) / 60 : 0;
  if (gridOn && soc !== null && soc < 97 && onMin >= NOT_CHARGING_MIN && !state.chgFired &&
      (limitA === 0 || (state.socOn !== null && state.socOn !== undefined && soc <= state.socOn))) {
    state.chgFired = true;
    await save();
    await sendMessage(env, `🔋❗️ <b>Світло є вже ${duration(onMin * 60)}, а батарея не заряджається</b>\nЗаряд ${soc}%` +
      (limitA === 0 ? "\nБатарея (BMS) сама заборонила заряд — ліміт струму 0 А. Якщо так триматиметься й далі, варто показати установнику."
                    : "\nЗаряд не виріс з моменту появи світла. Перевірте налаштування заряду від мережі в Deye."));
  }
  // 2) close to the power limit
  const load = num("TotalConsumptionPower") || 0, grid = num("TotalGridPower") || 0;
  const draw = gridOn ? Math.max(grid, load) : load, limit = gridOn ? BYPASS_W : INVERTER_W;
  if (draw >= NEAR_LIMIT * limit && !(state.peakAt && updated - state.peakAt < PEAK_COOLDOWN_S)) {
    state.peakAt = updated;
    await save();
    const kw = (draw / 1000).toFixed(1).replace(".", ",");
    await sendMessage(env, gridOn
      ? `⚠️ <b>З мережі йде ${kw} кВт</b> — близько до межі ~8 кВт, яку інвертор пропускає з мережі.\nЯкщо триматиметься довго, може вибити вступний автомат. Вимкніть щось потужне.`
      : `⚠️ <b>Навантаження ${kw} кВт</b> — близько до межі інвертора 6 кВт.\nВін може вимкнути живлення квартири. Вимкніть щось потужне (бойлер, духовку, обігрівач).`);
  }
  // 3) inverter heatsink too hot
  const dc = num("DC Temperature");
  if (dc !== null && dc >= HOT_C && !state.hot) {
    state.hot = true;
    await save();
    await sendMessage(env, `🌡 <b>Інвертор нагрівся до ${Math.round(dc)}°</b>\nНорма до ${HOT_C}°. Перевірте, чи нічого не закриває вентиляцію, і зменшіть навантаження.`);
  } else if (state.hot && dc !== null && dc < HOT_OK_C) {
    state.hot = false;
    await save();
  }
}

/** The iPhone app is signed by a free Apple team: it stops opening 7 days after install. */
async function appExpiryReminder(env, state, save, nowSec) {
  const exp = Number(await env.KV.get("app_expires"));
  if (!exp || state.expWarned === exp || nowSec > exp || exp - nowSec > 26 * 3600) return;
  const hour = Number(new Date(nowSec * 1000).toLocaleString("en-GB", { timeZone: "Europe/Kyiv", hour: "2-digit", hour12: false }));
  if (hour < 9 || hour >= 22) return;
  state.expWarned = exp;
  await save();
  const when = new Intl.DateTimeFormat("uk-UA", { timeZone: "Europe/Kyiv", day: "numeric", month: "long",
                                                 hour: "2-digit", minute: "2-digit" }).format(new Date(exp * 1000));
  await sendMessage(env, `📱 <b>Застосунок «Світло» перестане відкриватись ${when}</b>\n` +
    "Безкоштовний підпис Apple діє лише 7 днів — застосунок треба перезібрати й встановити знову.");
}

/** Hours until the cut-off at a given draw in watts, or null when unknown / not discharging. */
function runtimeHours(soc, watts) {
  if (soc === null || soc === undefined || !(watts > 50)) return null;
  return Math.max(0, ((soc - CUTOFF_SOC) / 100) * BATTERY_WH / watts);
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

// ---------------------------------------------------------------- SmartThings
async function stCallback(env, url) {
  const page = (text, status = 200) => new Response(
    `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">` +
    `<body style="font:17px -apple-system,sans-serif;padding:40px;text-align:center">${text}</body>`,
    { status, headers: { "Content-Type": "text/html; charset=utf-8" } });
  const want = await env.KV.get("st_state");
  if (!want || url.searchParams.get("state") !== want) return page("Посилання застаріло. Надішли боту /smartthings ще раз.", 400);
  await env.KV.delete("st_state");
  const code = url.searchParams.get("code");
  if (!code) return page("SmartThings не надав доступ.", 400);
  try {
    await stTokenRequest(env, { grant_type: "authorization_code", code,
                                redirect_uri: `https://${env.WORKER_HOST}/st/callback` });
  } catch (e) {
    return page(`Не вдалося отримати доступ: ${esc(e.message)}`, 502);
  }
  await sendMessage(env, "✅ SmartThings підключено: техніка тепер у статистиці.");
  return page("✅ Готово! SmartThings підключено, можна закрити сторінку.");
}

async function stTokenRequest(env, params) {
  const resp = await fetch(ST_AUTH, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded",
               Authorization: "Basic " + btoa(`${env.ST_CLIENT_ID}:${env.ST_CLIENT_SECRET}`) },
    body: new URLSearchParams({ client_id: env.ST_CLIENT_ID, ...params }),
  });
  if (!resp.ok) throw new Error(`SmartThings auth HTTP ${resp.status}`);
  const t = await resp.json();
  const auth = { access: t.access_token, refresh: t.refresh_token, until: Date.now() + (Number(t.expires_in) || 86399) * 1000 };
  await env.KV.put("st_auth", JSON.stringify(auth));  // the refresh token rotates: keep the new one
  return auth;
}

/** Access token. Only the minute cron refreshes it ahead of time (the refresh token rotates, so two
 *  concurrent refreshes would lose access); a request finds an expired token only if the cron failed. */
async function stToken(env) {
  const auth = await env.KV.get("st_auth", "json");
  if (!auth) return null;
  if (auth.until > Date.now()) return auth.access;
  return (await stTokenRequest(env, { grant_type: "refresh_token", refresh_token: auth.refresh })).access;
}

async function stKeepFresh(env) {
  const auth = await env.KV.get("st_auth", "json");
  if (auth && auth.until - Date.now() < 2 * 3600 * 1000) {
    await stTokenRequest(env, { grant_type: "refresh_token", refresh_token: auth.refresh });
  }
}

async function st(env, path, init = {}) {
  const token = await stToken(env);
  if (!token) throw new Error("SmartThings не підключено");
  const resp = await fetch(ST_API + path, { ...init,
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", ...(init.headers || {}) } });
  if (!resp.ok) throw new Error(`SmartThings HTTP ${resp.status}`);
  return resp.status === 204 ? null : resp.json();
}

function stKind(caps, dev) {
  if (caps.has("airConditionerMode")) return "ac";
  if (caps.has("washerOperatingState")) return "washer";
  if (caps.has("dryerOperatingState")) return "dryer";
  if (caps.has("dishwasherOperatingState")) return "dishwasher";
  if (caps.has("refrigeration") || caps.has("contactSensor") && /fridge|refriger/i.test(dev.name || "")) return "fridge";
  if (caps.has("tvChannel") || /TV/.test(dev.deviceTypeName || "") || /\bTV\b/.test(dev.ocf && dev.ocf.deviceType || "")) return "tv";
  if (dev.type === "VIPER" || /plug/i.test(dev.name || "")) return "plug";
  return "other";
}

/** Appliances that report energy or a running cycle, with their current numbers (edge-cached 60 s). */
async function stSnapshot(env) {
  const key = new Request(`https://${env.WORKER_HOST || "w"}/_st_snapshot_cache`);
  const cache = typeof caches !== "undefined" ? caches.default : null;
  const hit = cache && await cache.match(key).catch(() => null);
  if (hit) return hit.json();
  const snap = await stSnapshotFresh(env);
  if (cache) await cache.put(key, new Response(JSON.stringify(snap), { headers: { "Cache-Control": "max-age=60" } })).catch(() => {});
  return snap;
}

async function stSnapshotFresh(env) {
  const list = await st(env, "/devices");
  const devices = (list.items || []).map((d) => {
    const caps = new Set((d.components || []).flatMap((c) => (c.capabilities || []).map((x) => x.id)));
    return { d, caps };
  }).filter(({ caps }) => caps.has("powerConsumptionReport") || caps.has("powerMeter") || caps.has("energyMeter"));
  const out = await Promise.all(devices.map(async ({ d, caps }) => {
    const s = await st(env, `/devices/${d.deviceId}/status`).catch(() => null);
    const m = (s && s.components && s.components.main) || {};
    const v = (cap, attr) => m[cap] && m[cap][attr] ? m[cap][attr].value : null;
    const rep = v("powerConsumptionReport", "powerConsumption") || {};
    const op = m["samsungce.washerOperatingState"] || m["samsungce.dryerOperatingState"] || null;
    return {
      id: d.deviceId, label: d.label || d.name, kind: stKind(caps, d),
      on: v("switch", "switch") === "on",
      power: v("powerMeter", "power") ?? (typeof rep.power === "number" ? rep.power : null),
      energyWh: typeof rep.energy === "number" ? rep.energy : v("energyMeter", "energy"),
      deltaWh: typeof rep.deltaEnergy === "number" ? rep.deltaEnergy : null,
      reportEnd: rep.end ? Date.parse(rep.end) / 1000 : null,
      state: op ? (op.operatingState && op.operatingState.value) : null,
      job: op ? ((op.washerJobState || op.dryerJobState || {}).value || null) : null,
      remainingMin: op && op.remainingTime ? op.remainingTime.value : null,
      watched: (env.ST_WATCH || "").split(",").includes(d.deviceId),
    };
  }));
  return { at: Date.now() / 1000, devices: out };
}

/** Grid lost / back: remind about watched appliances (e.g. the boiler) with a one-tap switch. */
async function stOutageReminder(env, gridOn) {
  if (!env.ST_WATCH) return;
  const ids = env.ST_WATCH.split(",").filter(Boolean);
  for (const id of ids) {
    const [dev, status] = await Promise.all([st(env, `/devices/${id}`), st(env, `/devices/${id}/status`)]);
    const on = (((status.components || {}).main || {}).switch || {}).switch;
    const label = esc(dev.label || dev.name || "Прилад");
    if (!gridOn && on && on.value === "on") {
      await sendMessage(env, `🔥 <b>${label} увімкнено, а світла немає</b>\nВін швидко посадить батарею.`,
        { inline_keyboard: [[{ text: `Вимкнути: ${dev.label || "прилад"}`, callback_data: `st:off:${id}` }]] });
    } else if (gridOn && on && on.value === "off") {
      await sendMessage(env, `💡 Світло є, а <b>${label}</b> вимкнено.`,
        { inline_keyboard: [[{ text: `Увімкнути: ${dev.label || "прилад"}`, callback_data: `st:on:${id}` }]] });
    }
  }
}

async function handleCallback(q, env) {
  const chat = q.message && q.message.chat && q.message.chat.id;
  if (String(chat) !== String(env.TELEGRAM_CHAT_ID)) return;  // only the owner's chat
  const [kind, action, id] = String(q.data || "").split(":");
  let note = "Невідома дія";
  if (kind === "st" && (action === "on" || action === "off") && (env.ST_WATCH || "").split(",").includes(id)) {
    try {
      await st(env, `/devices/${id}/commands`, { method: "POST",
        body: JSON.stringify({ commands: [{ component: "main", capability: "switch", command: action }] }) });
      note = action === "off" ? "Вимкнено ✅" : "Увімкнено ✅";
      await sendMessage(env, action === "off" ? "🔌 Вимкнув. Батарея протримається довше." : "🔌 Увімкнув.");
    } catch (e) {
      note = "Не вдалося";
      await sendMessage(env, `Не вдалося керувати приладом: ${esc(e.message)}`);
    }
  }
  await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/answerCallbackQuery`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ callback_query_id: q.id, text: note }) });
}

// ---------------------------------------------------------------- planned schedule (YASNO)
/** Today's / tomorrow's planned outages for our group: {group, updatedOn, today, tomorrow}, each day
 *  {date, status, off: [[startMin, endMin], ...]} with adjacent slots merged. Cached 5 min at the edge. */
async function schedule(env) {
  if (!env.YASNO_GROUP) return null;
  const region = env.YASNO_REGION || "25", dso = env.YASNO_DSO || "902";
  const resp = await fetch(`${YASNO_URL}/regions/${region}/dsos/${dso}/planned-outages`,
                           { cf: { cacheTtl: 300, cacheEverything: true } });
  if (!resp.ok) throw new Error(`YASNO HTTP ${resp.status}`);
  const g = (await resp.json())[env.YASNO_GROUP];
  if (!g) return null;
  const day = (d) => {
    if (!d) return null;
    const off = [];
    for (const sl of d.slots || []) {
      if (sl.type !== "Definite") continue;
      const last = off[off.length - 1];
      if (last && last[1] === sl.start) last[1] = sl.end; else off.push([sl.start, sl.end]);
    }
    return { date: d.date, status: d.status, off };
  };
  return { group: env.YASNO_GROUP, updatedOn: g.updatedOn || null, today: day(g.today), tomorrow: day(g.tomorrow) };
}

const hhmm = (m) => `${String(Math.floor(m / 60) % 24).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`;
const slotText = ([s, e]) => `${hhmm(s)}–${e >= 1440 ? "24:00" : hhmm(e)}`;

/** Telegram: tomorrow's schedule published / today's changed, and a heads-up before a planned outage. */
async function scheduleAlerts(env, state, save, ctx) {
  const sched = await schedule(env).catch(() => null);
  if (!sched) return;
  const { nowSec, soc, load } = ctx;
  const g = esc(sched.group);
  for (const [which, d] of [["today", sched.today], ["tomorrow", sched.tomorrow]]) {
    if (!d || d.status !== "ScheduleApplies") continue;
    const key = `${d.date}|${JSON.stringify(d.off)}`;
    const stateKey = which === "today" ? "schedToday" : "schedTomorrow";
    if (state[stateKey] === key) continue;
    const prev = state[stateKey];
    // tomorrow becomes today at midnight: don't announce the same schedule twice
    const known = which === "today" && state.schedTomorrow === key;
    state[stateKey] = key;
    await save();
    if (known || prev === undefined && which === "today") continue;
    const changed = prev && prev.split("|")[0] === d.date;
    const label = which === "today" ? "сьогодні" : "завтра";
    await sendMessage(env, `📅 <b>${changed ? `Графік на ${label} змінився` : `Графік на ${label}`}</b> (група ${g})\n` +
      (d.off.length ? d.off.map(slotText).join(", ") : "Відключень не заплановано ✨"));
  }
  const t = sched.today;
  if (!t || t.status !== "ScheduleApplies") return;
  const nowMin = (nowSec * 1000 - Date.parse(t.date)) / 60000;
  const next = t.off.find(([s]) => s - nowMin > 0 && s - nowMin <= SCHEDULE_REMIND_MIN);
  const remindKey = next && `${t.date}|${next[0]}`;
  if (next && state.schedReminded !== remindKey) {
    state.schedReminded = remindKey;
    await save();
    const outageH = (next[1] - next[0]) / 60;
    const h = runtimeHours(soc, load === null ? null : load + await selfUseW(env));
    let battery = "";
    if (soc !== null) {
      battery = `\n🔋 Батарея ${soc}%` + (h === null ? "" : h >= outageH
        ? ` — при ${load} Вт вистачить на ${duration(h * 3600)}, з запасом`
        : ` — при ${load} Вт вистачить лише на ${duration(h * 3600)}, менше за відключення`);
    }
    await sendMessage(env, `⏰ <b>О ${hhmm(next[0])} відключення за графіком</b> до ${next[1] >= 1440 ? "24:00" : hhmm(next[1])}` +
      ` (${duration(outageH * 3600)})${battery}`);
  }
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
  // off-grid the battery really gives the flat's load plus the inverter's own use (the power reading is noisy)
  const draw = gridOn ? batteryPower : Math.max(batteryPower || 0, (num("TotalConsumptionPower") || 0) + await selfUseW(env));
  const runtimeH = soc !== null && draw > 50 ? Math.max(0, ((soc - CUTOFF_SOC) / 100) * BATTERY_WH / draw) : null;
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

function scheduleLine(sched, nowSec) {
  if (!sched || !sched.today) return null;
  const t = sched.today;
  if (t.status !== "ScheduleApplies") return `📅 Група ${esc(sched.group)}: ${SCHEDULE_STATUS[t.status] || esc(t.status)}`;
  const nowMin = (nowSec * 1000 - Date.parse(t.date)) / 60000;
  const left = t.off.filter(([, e]) => e > nowMin);
  return `📅 За графіком (група ${esc(sched.group)}): ` +
    (left.length ? left.map(slotText).join(", ") : "сьогодні більше відключень немає");
}

async function statusText(env) {
  const [d, sched] = await Promise.all([liveData(env), schedule(env).catch(() => null)]);
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
  const sl = scheduleLine(sched, d.now);
  if (sl) lines.push(sl);
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
  const exp = Number(request.headers.get("X-App-Expires"));
  if (exp > 1.7e9 && exp < 2.2e9 && String(Math.round(exp)) !== (await env.KV.get("app_expires"))) {
    await env.KV.put("app_expires", String(Math.round(exp)));
  }
  const [live, cache, sched, appliances] = await Promise.all([
    liveData(env).catch((e) => ({ error: String(e.message || e.name) })),
    env.KV.get("reports", "json").catch(() => null),
    schedule(env).catch(() => null),
    stSnapshot(env).catch(() => null),
  ]);
  return new Response(JSON.stringify({ live, data: cache && cache.data, generated_at: cache && cache.generated_at,
                                       schedule: sched, appliances }), {
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

async function dayData(request, env, url) {
  if (!appTokenOk(request, env) && !(await verifyInitData(request.headers.get("X-Telegram-Init-Data"), env))) {
    return new Response("forbidden", { status: 403 });
  }
  const day = url.searchParams.get("date") || "";
  if (!DAY_RE.test(day)) return new Response("bad date", { status: 400 });
  const body = await env.KV.get(`day:${day}`);
  if (!body) return new Response("no data", { status: 404 });
  return new Response(body, { headers: { "Content-Type": "application/json", "Cache-Control": "private, max-age=300" } });
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
