// Cloudflare Worker for deye-monitor:
//  - Telegram webhook: /status answered instantly from Deye Cloud; report commands start the
//    GitHub Actions workflow, which sends the report with a chart about a minute later.
//  - Cron every 5 min: starts the monitoring workflow on GitHub (GitHub's own cron is unreliable).

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
const COMMANDS = { status: "Чи є світло зараз, заряд батареї (миттєво)", ...REPORT_COMMANDS };

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
    return new Response("deye-monitor bot\n");
  },

  async scheduled(event, env, ctx) {
    ctx.waitUntil(dispatchWorkflow(env, "").catch((e) => console.log("dispatch failed:", e && e.message)));
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
  if (cmd in REPORT_COMMANDS) {
    try {
      await dispatchWorkflow(env, cmd);
      return sendMessage(env, "⏳ Готую, буде за хвилину-дві");
    } catch (e) {
      return sendMessage(env, `Не вдалося запустити: ${esc(e.message || e.name)}`);
    }
  }
  const help = Object.entries(COMMANDS).map(([c, d]) => `/${c} — ${d}`).join("\n");
  return sendMessage(env, `Команди:\n${help}`);
}

async function sendMessage(env, text) {
  const resp = await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ chat_id: env.TELEGRAM_CHAT_ID, text, parse_mode: "HTML",
                           disable_web_page_preview: true }),
  });
  if (!resp.ok) console.log("sendMessage failed:", resp.status);
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

async function statusText(env) {
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
  const ageMin = updated ? (nowSec - updated) / 60 : null;
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

  const lines = [];
  const holds = since ? ` вже ${duration(nowSec - since)}` : beyondDay ? " понад добу" : "";
  lines.push(gridOn ? `<b>💡 Світло є${holds}</b>` : `<b>🔌 Світла немає${holds}</b>`);
  if (since && !gridOn) lines.push(`вимкнули о ${clock(since)}`);

  const soc = num("SOC");
  const bmsTemp = num("Temperature- Battery");
  if (soc === null || soc <= 0 || (bmsTemp !== null && bmsTemp <= -50)) {
    lines.push("🔋 немає даних від BMS");
  } else {
    const bp = num("BatteryPower") || 0;
    const mode = bp < -20 ? "заряджається" : bp > 20 ? "розряджається" : "у спокої";
    let bat = `🔋 ${soc}% (${mode}, ${Math.abs(bp)} Вт)`;
    if (bp > 50) {
      const hours = ((soc - 10) / 100) * 11800 / bp;
      if (hours > 0) bat += `, вистачить ≈ ${duration(hours * 3600)}`;
    }
    lines.push(bat);
  }
  const load = num("TotalConsumptionPower");
  if (load !== null) lines.push(`🏠 Навантаження: ${load} Вт`);
  if (voltage !== null) {
    const f = num("GridFrequency");
    lines.push(`⚡ Мережа: ${Math.round(voltage)} В${f ? `, ${f.toFixed(1)} Гц` : ""}`);
  }
  const temps = [];
  if (bmsTemp !== null && bmsTemp > -50) temps.push(`батарея ${Math.round(bmsTemp)} °C`);
  const dc = num("DC Temperature");
  if (dc !== null) temps.push(`інвертор ${Math.round(dc)} °C`);
  if (temps.length) lines.push(`🌡 ${temps.join(", ")}`);
  if (ageMin !== null) {
    if (ageMin > STALE_MIN) {
      lines.push(`⚠️ Deye не отримує даних ${duration(ageMin * 60)}: можливо, у квартирі немає світла й інтернету`);
    } else {
      lines.push(`⏱ дані Deye на ${clock(updated)} (${Math.max(0, Math.round(ageMin))} хв тому)`);
    }
  }
  return lines.join("\n");
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
