// Guests: other people connect their own Deye to this bot (live status, alerts, schedule, Mini App).
//
// Each guest runs through exactly the owner's code with a derived env: their own chat, Deye login,
// inverter, YASNO group and a KV prefix ("g:<chatId>:"), so alerts and state never mix. The owner
// approves every guest. Long history and reports stay owner-only (they come from the GitHub workflow).
//
// Storage: one KV key "guests" = { [chatId]: record } (one read per cron run for all of them).
// The Deye password is kept only as its SHA-256 (what Deye's API takes), AES-GCM-encrypted with the
// GUEST_KEY worker secret. The bot never calls Deye control endpoints.

import { deye, esc, liveCheck, schedule, statusText } from "./index.js";

export const MAX_GUESTS = 10;
const KYIV = { region: "25", dso: "902" };  // YASNO: Kyiv city (DTEK Kyiv Electric Networks)
const INVERTER_CHOICES = [3600, 5000, 6000, 8000, 10000, 12000];
const V_KEYS = ["GridVoltageL1L2", "GridVoltageL1", "AC Voltage R/U/A", "GridVoltage"];

// ---------------------------------------------------------------- storage
export async function loadGuests(env) {
  return (await env.KV.get("guests", "json")) || {};
}
const saveGuests = (env, all) => env.KV.put("guests", JSON.stringify(all));

export function prefixedKV(kv, prefix) {
  return {
    get: (k, type) => kv.get(prefix + k, type),
    put: (k, v, opts) => kv.put(prefix + k, v, opts),
    delete: (k) => kv.delete(prefix + k),
  };
}

async function removeGuest(env, all, id) {
  delete all[id];
  await saveGuests(env, all);
  for (const k of ["live", "deye_token", "seen_alerts"]) await env.KV.delete(`g:${id}:${k}`);
}

// ---------------------------------------------------------------- crypto
const b64 = (bytes) => btoa(String.fromCharCode(...bytes));
const unb64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

async function aesKey(env) {
  if (!env.GUEST_KEY) throw new Error("GUEST_KEY is not set");
  const raw = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("deye-guest|" + env.GUEST_KEY));
  return crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
}

export async function seal(env, text) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await aesKey(env), new TextEncoder().encode(text));
  return `${b64(iv)}.${b64(new Uint8Array(ct))}`;
}

export async function unseal(env, sealed) {
  const [iv, ct] = String(sealed || "").split(".");
  if (!iv || !ct) throw new Error("bad sealed value");
  const pt = await crypto.subtle.decrypt({ name: "AES-GCM", iv: unb64(iv) }, await aesKey(env), unb64(ct));
  return new TextDecoder().decode(pt);
}

async function sha256hex(s) {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
  return [...d].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// ---------------------------------------------------------------- the guest's env
/** The owner's env with this guest's chat, Deye login, device, group and a private KV prefix. */
export async function guestEnv(env, g, pwHash) {
  const e = Object.create(env);
  return Object.assign(e, {
    IS_GUEST: true,
    TELEGRAM_CHAT_ID: String(g.id),
    DEYE_CLOUD_EMAIL: g.email || "",
    DEYE_CLOUD_PASSWORD_SHA256: pwHash || (g.pw ? await unseal(env, g.pw) : ""),
    DEYE_CLOUD_DEVICE_SN: g.sn || "",
    YASNO_GROUP: g.group || "", YASNO_REGION: KYIV.region, YASNO_DSO: KYIV.dso,
    INVERTER_W: g.inverterW || 0, BATTERY_WH: g.batteryWh || 0, GRID_V_KEY: g.vKey || "",
    SELF_USE_W: 35,
    // owner-only integrations are switched off for guests
    ST_CLIENT_ID: "", ST_WATCH: "", APP_TOKEN: "", GITHUB_TOKEN: "",
    KV: prefixedKV(env.KV, `g:${g.id}:`),
  });
}

/** Every 2nd minute, in a request of its own: the owner's live checks, run for every active guest. */
export async function guestsLiveCheck(env) {
  const all = await loadGuests(env);
  const base = Object.assign(Object.create(env), { YASNO_MEMO: new Map() });  // one YASNO download per run
  for (const g of Object.values(all)) {
    if (g.status !== "active") continue;
    try {
      await liveCheck(await guestEnv(base, g));
    } catch (e) {
      console.log("guest check failed:", e && e.message);
    }
  }
}

// ---------------------------------------------------------------- Telegram
async function tg(env, method, body) {
  const r = await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/${method}`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
  return r.json().catch(() => ({}));
}
const say = (env, chat, text, markup) => tg(env, "sendMessage", {
  chat_id: chat, text, parse_mode: "HTML", disable_web_page_preview: true,
  ...(markup ? { reply_markup: markup } : {}) });

const GUEST_HELP = "Команди:\n/status — чи є світло, заряд батареї\n/dashboard — дашборд у Telegram\n" +
  "/group — змінити групу графіка YASNO\n/stop — відключити свій Deye і видалити дані";

const dashboardButton = (env) => ({ inline_keyboard: [[{ text: "Відкрити дашборд",
  web_app: { url: `https://${env.WORKER_HOST}/app` } }]] });

/** Messages from anyone who isn't the owner. */
export async function guestUpdate(msg, env) {
  if (msg.chat.type !== "private") return;
  const id = String(msg.chat.id);
  const text = msg.text.trim();
  const cmd = text.startsWith("/") ? text.split(/\s+/)[0].slice(1).split("@")[0].toLowerCase() : null;
  const all = await loadGuests(env);
  let g = all[id];

  if (!g) {
    if (Object.values(all).filter((x) => x.status !== "denied").length >= MAX_GUESTS) {
      return say(env, id, "Вибач, зараз немає вільних місць у цьому боті.");
    }
    const f = msg.from || {};
    const name = [f.first_name, f.last_name].filter(Boolean).join(" ") + (f.username ? ` (@${f.username})` : "");
    g = all[id] = { id, name: name || id, status: "pending", created: Math.floor(Date.now() / 1000) };
    await saveGuests(env, all);
    await say(env, env.TELEGRAM_CHAT_ID, `👤 <b>${esc(g.name)}</b> хоче підключити свій Deye до бота.`,
      { inline_keyboard: [[{ text: "✅ Дозволити", callback_data: `g:ok:${id}` },
                           { text: "❌ Відхилити", callback_data: `g:no:${id}` }]] });
    return say(env, id, "👋 Цей бот стежить за інвертором Deye: чи є світло, заряд батареї, графік відключень, " +
      "сповіщення.\n\nЗапит надіслано власнику бота. Щойно він підтвердить, я попрошу дані для входу в Deye Cloud.");
  }
  if (g.status === "denied") return;
  if (g.status === "pending") return say(env, id, "⏳ Чекаємо, поки власник бота підтвердить доступ.");
  if (cmd === "stop") {
    await removeGuest(env, all, id);
    return say(env, id, "Готово: твій Deye відключено, дані для входу видалено. Щоб підключитись знову — /start.");
  }
  if (g.status === "approved") return onboarding(env, all, g, msg, text, cmd);

  // active
  if (g.step === "group" && !cmd) return setGroup(env, all, g, text);
  if (cmd === "status") {
    try {
      return say(env, id, await statusText(await guestEnv(env, g)));
    } catch (e) {
      return say(env, id, `Не вдалося отримати дані з Deye: ${esc(e.message || e.name)}`);
    }
  }
  if (cmd === "dashboard" || cmd === "app") return say(env, id, "📊 Дашборд", dashboardButton(env));
  if (cmd === "group") {
    g.step = "group";
    await saveGuests(env, all);
    return askGroup(env, id);
  }
  return say(env, id, GUEST_HELP);
}

// ---------------------------------------------------------------- onboarding
function askEmail(env, id) {
  return say(env, id, "1/4 · Надішли <b>email</b>, з яким входиш у застосунок Deye Cloud.\n" +
    "<i>Підтримується лише вхід за email, акаунт має бути в європейському дата-центрі Deye.</i>");
}

function askGroup(env, id) {
  return say(env, id, "Напиши свою <b>групу відключень YASNO</b>, наприклад <code>29.1</code>.\n" +
    "Її видно на yasno.ua за твоєю адресою. Працює лише для Києва (ДТЕК Київські електромережі).",
    { inline_keyboard: [[{ text: "Без графіка", callback_data: "g:grp:none" }]] });
}

async function onboarding(env, all, g, msg, text, cmd) {
  const id = g.id;
  if (cmd === "start" || !g.step) {
    g.step = "email";
    await saveGuests(env, all);
    return askEmail(env, id);
  }
  if (cmd) return say(env, id, "Спершу завершимо підключення. Почати спочатку — /start, скасувати — /stop.");

  if (g.step === "email") {
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(text)) return say(env, id, "Це не схоже на email. Спробуй ще раз.");
    g.email = text.toLowerCase();
    g.step = "password";
    await saveGuests(env, all);
    return say(env, id, "2/4 · Тепер <b>пароль</b> від Deye Cloud.\nЯ одразу видалю твоє повідомлення, " +
      "а зберігаю лише зашифрований хеш пароля — сам пароль ніде не записується. Бот лише читає дані й нічого не змінює в інверторі.");
  }

  if (g.step === "password") {
    await tg(env, "deleteMessage", { chat_id: id, message_id: msg.message_id });
    const pwHash = await sha256hex(text);
    await say(env, id, "🔐 Перевіряю вхід у Deye Cloud…");
    let inverters;
    try {
      const genv = await guestEnv(env, { ...g, sn: "" }, pwHash);
      const stations = (await deye(genv, "/v1.0/station/list", { page: 1, size: 20 })).stationList || [];
      inverters = [];
      for (const s of stations.slice(0, 5)) {
        const devs = (await deye(genv, "/v1.0/station/device", { stationIds: [s.id] })).deviceListItems || [];
        for (const d of devs) {
          if (String(d.deviceType || "").toUpperCase() === "INVERTER") inverters.push({ sn: String(d.deviceSn), station: s.name || "" });
        }
      }
    } catch (e) {
      g.step = "email";
      await saveGuests(env, all);
      await say(env, id, `❌ Deye не пустив: ${esc(e.message || e.name)}.\nПеревір email і пароль (той самий, що в застосунку Deye Cloud). ` +
        "Надішли email ще раз.");
      return say(env, env.TELEGRAM_CHAT_ID, `ℹ️ ${esc(g.name)}: вхід у Deye не вдався (${esc(e.message || e.name)}).`);
    }
    if (!inverters.length) {
      g.step = "email";
      await saveGuests(env, all);
      return say(env, id, "Вхід вдався, але в акаунті немає жодного інвертора. Надішли email іншого акаунта або /stop.");
    }
    g.pw = await seal(env, pwHash);
    if (inverters.length === 1) return pickInverter(env, all, g, inverters[0].sn);
    g.step = "device";
    g.candidates = inverters.map((x) => x.sn).slice(0, 8);
    await saveGuests(env, all);
    return say(env, id, "У тебе кілька інверторів. Який підключити?", { inline_keyboard:
      inverters.slice(0, 8).map((x) => [{ text: `${x.station ? x.station + " · " : ""}${x.sn}`, callback_data: `g:sn:${x.sn}` }]) });
  }

  if (g.step === "group") return setGroup(env, all, g, text);
  return say(env, id, "Натисни одну з кнопок вище або почни спочатку: /start");
}

/** Remember the inverter and read what we need from its latest data (voltage key, battery size). */
async function pickInverter(env, all, g, sn) {
  g.sn = sn;
  delete g.candidates;
  try {
    const genv = await guestEnv(env, g);
    const latest = await deye(genv, "/v1.0/device/latest", { deviceList: [sn] });
    const p = {};
    for (const item of ((latest.deviceDataList || [])[0] || {}).dataList || []) p[item.key] = Number(item.value);
    g.vKey = V_KEYS.find((k) => Number.isFinite(p[k])) || "GridVoltageL1L2";
    const ah = p.BatteryRatedCapacity, v = p.BatteryVoltage;
    if (ah > 0) g.batteryWh = Math.round(ah * (v > 0 && v < 60 ? 51.2 : v > 0 ? v : 51.2));
  } catch (e) {
    console.log("guest probe failed:", e && e.message);
  }
  g.step = "inverter";
  await saveGuests(env, all);
  return say(env, g.id, "3/4 · Яка <b>потужність</b> твого інвертора? Потрібно, щоб попереджати, коли навантаження близько до межі.",
    { inline_keyboard: [
      INVERTER_CHOICES.slice(0, 3).map((w) => ({ text: `${w / 1000} кВт`, callback_data: `g:inv:${w}` })),
      INVERTER_CHOICES.slice(3).map((w) => ({ text: `${w / 1000} кВт`, callback_data: `g:inv:${w}` })),
      [{ text: "Не знаю", callback_data: "g:inv:0" }]] });
}

async function setGroup(env, all, g, text) {
  const group = text.trim().replace(",", ".");
  if (!/^\d{1,2}\.\d$/.test(group)) return say(env, g.id, "Група має вигляд <code>29.1</code>. Спробуй ще раз або натисни «Без графіка».");
  const probe = await schedule(Object.assign(Object.create(env), { YASNO_GROUP: group, YASNO_REGION: KYIV.region,
                                                                    YASNO_DSO: KYIV.dso })).catch(() => null);
  if (!probe) return say(env, g.id, `Групи ${esc(group)} немає в графіку YASNO для Києва. Перевір на yasno.ua.`);
  g.group = group;
  return finish(env, all, g);
}

async function finish(env, all, g) {
  const wasActive = g.status === "active";
  g.status = "active";
  delete g.step;
  await saveGuests(env, all);
  if (wasActive) return say(env, g.id, g.group ? `✅ Група ${esc(g.group)} збережена.` : "✅ Графік вимкнено.");
  await say(env, g.id, "4/4 · ✅ <b>Готово!</b> Тепер я пишу, коли зникає й зʼявляється світло, коли сідає батарея, " +
    "про графік і про проблеми інвертора.\n\n" + GUEST_HELP, dashboardButton(env));
  await say(env, env.TELEGRAM_CHAT_ID, `✅ ${esc(g.name)}: Deye підключено.`);
  try {
    await say(env, g.id, await statusText(await guestEnv(env, g)));
  } catch (e) {
    console.log("first status failed:", e && e.message);
  }
}

// ---------------------------------------------------------------- buttons
/** Callback data "g:<action>:<arg>": approvals from the owner, onboarding choices from guests. */
export async function guestCallback(q, env) {
  const chat = String((q.message && q.message.chat && q.message.chat.id) || "");
  const [, action, arg] = String(q.data || "").split(":");
  const all = await loadGuests(env);
  let note = "";
  if (chat === String(env.TELEGRAM_CHAT_ID) && ["ok", "no", "del"].includes(action)) {
    const g = all[arg];
    if (!g) note = "Цього запиту вже немає";
    else if (action === "ok" && g.status === "pending") {
      g.status = "approved";
      g.step = "email";
      await saveGuests(env, all);
      await say(env, arg, "✅ Власник дозволив доступ. Підключимо твій Deye за 4 кроки.");
      await askEmail(env, arg);
      note = "Дозволено";
    } else if (action === "no" && g.status === "pending") {
      g.status = "denied";
      await saveGuests(env, all);
      await say(env, arg, "Власник бота відхилив запит.");
      note = "Відхилено";
    } else if (action === "del") {
      await removeGuest(env, all, arg);
      await say(env, arg, "Власник бота вимкнув твій доступ. Дані для входу в Deye видалено.");
      note = "Видалено";
    } else note = "Вже вирішено";
    if (q.message && note) {
      await tg(env, "editMessageText", { chat_id: chat, message_id: q.message.message_id,
        text: `${q.message.text || ""}\n\n${note}` });
    }
  } else {
    const g = all[chat];
    if (g && action === "sn" && g.step === "device" && (g.candidates || []).includes(arg)) {
      await pickInverter(env, all, g, arg);
      note = "Інвертор вибрано";
    } else if (g && action === "inv" && g.step === "inverter") {
      const w = Number(arg);
      g.inverterW = INVERTER_CHOICES.includes(w) ? w : 0;
      g.step = "group";
      await saveGuests(env, all);
      await askGroup(env, chat);
      note = "Збережено";
    } else if (g && action === "grp" && arg === "none" && g.step === "group") {
      g.group = "";
      await finish(env, all, g);
      note = "Без графіка";
    } else note = "Ця кнопка вже не діє";
  }
  await tg(env, "answerCallbackQuery", { callback_query_id: q.id, text: note });
}

/** Owner: /guests — who is connected, with a button to remove each. */
export async function ownerGuests(env) {
  const list = Object.values(await loadGuests(env)).filter((g) => g.status !== "denied");
  if (!list.length) {
    return say(env, env.TELEGRAM_CHAT_ID, "Гостей поки немає. Хто напише боту /start, той надішле тобі запит на доступ.");
  }
  const label = { pending: "чекає підтвердження", approved: "підключається", active: "підключений" };
  const lines = list.map((g) => `• ${esc(g.name)} — ${label[g.status] || g.status}${g.group ? `, група ${esc(g.group)}` : ""}`);
  return say(env, env.TELEGRAM_CHAT_ID, `👥 <b>Гості</b> (${list.length} з ${MAX_GUESTS})\n${lines.join("\n")}`,
    { inline_keyboard: list.map((g) => [{ text: `Видалити ${g.name}`.slice(0, 60), callback_data: `g:del:${g.id}` }]) });
}

/** The Mini App's viewer: a Telegram user id → an env, or null. */
export async function guestEnvFor(env, userId) {
  const g = (await loadGuests(env))[String(userId)];
  return g && g.status === "active" ? guestEnv(env, g) : null;
}
