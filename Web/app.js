import { renderMarkdown } from "./markdown.js?v=__V__";
import { t, setLanguage } from "./i18n.js?v=__V__";

// ---------- helpers ----------
const $ = (sel, root = document) => root.querySelector(sel);
function h(tag, attrs = {}, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === "class") el.className = v;
    else if (k === "html") el.innerHTML = v;
    else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (k === "value") el.value = v;
    else if (k === "checked") el.checked = !!v;
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const c of children.flat(Infinity)) {
    if (c == null || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}
const svg = (d) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${d}</svg>`;
const I = {
  plus: svg('<path d="M12 5v14M5 12h14"/>'),
  send: svg('<path d="M12 19V5M5 12l7-7 7 7"/>'),
  stop: svg('<rect x="7" y="7" width="10" height="10" rx="1.5" fill="currentColor"/>'),
  clip: svg('<path d="M21.4 11.1l-9.2 9.2a6 6 0 01-8.5-8.5l9.2-9.2a4 4 0 015.7 5.7l-9.2 9.2a2 2 0 01-2.8-2.8l8.5-8.5"/>'),
  mic: svg('<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0014 0M12 18v3"/>'),
  wave: svg('<path d="M3 12h2M7 8v8M11 5v14M15 8v8M19 11v2"/>'),
  speaker: svg('<path d="M11 5L6 9H3v6h3l5 4V5z"/><path d="M15.5 8.5a5 5 0 010 7M18.5 5.5a9 9 0 010 13"/>'),
  copy: svg('<rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V5a2 2 0 012-2h10"/>'),
  spark: svg('<path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8zM19 16l.7 2 2 .7-2 .7-.7 2-.7-2-2-.7 2-.7z"/>'),
  refresh: svg('<path d="M21 12a9 9 0 11-3-6.7L21 8M21 3v5h-5"/>'),
  menu: svg('<path d="M4 6h16M4 12h16M4 18h16"/>'),
  x: svg('<path d="M18 6L6 18M6 6l12 12"/>'),
  gear: svg('<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 00.3 1.8l.1.1a2 2 0 11-2.8 2.8l-.1-.1a1.7 1.7 0 00-1.8-.3 1.7 1.7 0 00-1 1.5V21a2 2 0 11-4 0v-.1a1.7 1.7 0 00-1.1-1.5 1.7 1.7 0 00-1.8.3l-.1.1a2 2 0 11-2.8-2.8l.1-.1a1.7 1.7 0 00.3-1.8 1.7 1.7 0 00-1.5-1H3a2 2 0 110-4h.1a1.7 1.7 0 001.5-1.1 1.7 1.7 0 00-.3-1.8l-.1-.1a2 2 0 112.8-2.8l.1.1a1.7 1.7 0 001.8.3H9a1.7 1.7 0 001-1.5V3a2 2 0 114 0v.1a1.7 1.7 0 001 1.5 1.7 1.7 0 001.8-.3l.1-.1a2 2 0 112.8 2.8l-.1.1a1.7 1.7 0 00-.3 1.8V9a1.7 1.7 0 001.5 1H21a2 2 0 110 4h-.1a1.7 1.7 0 00-1.5 1z"/>'),
  shield: svg('<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>'),
  users: svg('<path d="M17 21v-2a4 4 0 00-4-4H5a4 4 0 00-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 00-3-3.9M16 3.1a4 4 0 010 7.8"/>'),
  logout: svg('<path d="M9 21H5a2 2 0 01-2-2V5a2 2 0 012-2h4M16 17l5-5-5-5M21 12H9"/>'),
  trash: svg('<path d="M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6"/>'),
  pencil: svg('<path d="M12 20h9M16.5 3.5a2.1 2.1 0 013 3L7 19l-4 1 1-4z"/>'),
  code: svg('<path d="M16 18l6-6-6-6M8 6l-6 6 6 6"/>'),
  download: svg('<path d="M12 4v11M7 10l5 5 5-5M5 20h14"/>'),
  file: svg('<path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z"/><path d="M14 2v6h6"/>'),
  key: svg('<circle cx="7.5" cy="15.5" r="5.5"/><path d="M21 2l-9.6 9.6M15.5 7.5l3 3L22 7l-3-3"/>'),
};
const icon = (name) => h("span", { html: I[name], style: "display:inline-flex" });

const BUILD = "__V__";
class ApiError extends Error {}

/** An open tab or home-screen app keeps running old code after the server was updated.
 *  Reload as soon as the app comes to the foreground and the server has a newer build. */
async function checkBuild(force = false) {
  try {
    const i = await fetch("/api/info", { cache: "no-store" }).then((r) => r.json());
    if (!i.build || i.build === BUILD) return;
    const busy = document.querySelector(".voice-overlay") || els?.input?.value;
    if (force || !busy) location.reload();
  } catch {}
}
document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") checkBuild(); });
async function api(method, path, body, opts = {}) {
  // Extra headers are merged, never replace the CSRF header.
  const { headers: extra, raw, ...rest } = opts;
  const init = { method, credentials: "same-origin", ...rest, headers: { "X-Family-AI": "1" } };
  if (body instanceof Blob || body instanceof ArrayBuffer) { init.body = body; }
  else if (body !== undefined) { init.headers["Content-Type"] = "application/json"; init.body = JSON.stringify(body); }
  Object.assign(init.headers, extra || {});
  const res = await fetch(`/api/${path}`, init);
  if (raw) { if (!res.ok) throw new ApiError(await errText(res)); return res; }
  if (res.status === 401 && path !== "login" && path !== "me") { location.reload(); throw new ApiError("401"); }
  if (res.status === 403 && !raw) {
    // Old code after a server update (e.g. a renamed CSRF header): reload once to get the new version.
    const ct0 = res.headers.get("content-type") || "";
    const msg = ct0.includes("json") ? (await res.clone().json().catch(() => ({}))).error || "" : "";
    if (/CSRF/.test(msg)) { await checkBuild(true); }
  }
  const ct = res.headers.get("content-type") || "";
  const data = ct.includes("json") ? await res.json() : await res.text();
  if (!res.ok) throw new ApiError((data && data.error) || res.statusText);
  return data;
}
async function errText(res) { try { const j = await res.json(); return j.error || res.statusText; } catch { return res.statusText; } }

function toast(msg) {
  const el = h("div", { class: "toast" }, msg);
  document.body.append(el);
  setTimeout(() => el.remove(), 2600);
}
const store = {
  get(k, d) { try { const v = localStorage.getItem("fai." + k); return v == null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem("fai." + k, JSON.stringify(v)); } catch {} },
};
const initials = (n) => (n || "?").split(/\s+/).map((p) => p[0]).join("").slice(0, 2).toUpperCase();
const fmtMoney = (v) => (v == null ? "–" : v < 0.01 && v > 0 ? "<0,01" : v.toFixed(2).replace(".", ","));

// ---------- state ----------
const S = {
  info: null, me: null, models: [], defaultModel: null, chats: [], chat: null, messages: [],
  readOnly: false, ownerName: "", abort: null, pending: [], devices: [], kids: [], streaming: false,
};

// ---------- boot ----------
async function boot() {
  S.info = await api("GET", "info");
  if (S.info?.aiName) document.title = S.info.aiName;
  setLanguage(S.info.language);
  if (S.info.needsSetup) return renderSetup();
  try { S.me = await api("GET", "me"); } catch { return renderLogin(); }
  setLanguage(S.me.language);
  await startApp();
}

function brand(sub) {
  return h("div", { class: "brand" }, h("img", { src: "/icon-192.png", alt: "" }),
    h("div", {}, h("h1", {}, S.info?.aiName || "Lumi"), sub ? h("p", {}, sub) : null));
}

function renderSetup() {
  const err = h("div", { class: "error-text" });
  const f = {
    username: h("input", { type: "text", autocomplete: "username", required: true }),
    displayName: h("input", { type: "text" }),
    password: h("input", { type: "password", autocomplete: "new-password", required: true }),
    aiName: h("input", { type: "text", value: "Lumi" }),
    familyName: h("input", { type: "text" }),
    apiKey: h("input", { type: "password", placeholder: "sk-or-…" }),
    language: h("select", {}, h("option", { value: "de" }, "Deutsch"), h("option", { value: "en" }, "English")),
  };
  const form = h("form", { class: "auth-card", onsubmit: async (e) => {
    e.preventDefault(); err.textContent = "";
    try {
      await api("POST", "setup", Object.fromEntries(Object.entries(f).map(([k, el]) => [k, el.value.trim()])));
      location.reload();
    } catch (x) { err.textContent = x.message; }
  } },
    brand(t("setupTitle")), h("p", { class: "hint" }, t("welcomeSetup")),
    field(t("username"), f.username), field(t("displayName"), f.displayName), field(t("password"), f.password),
    field(t("aiName"), f.aiName), field(t("familyName"), f.familyName), field(t("apiKey"), f.apiKey), field(t("language"), f.language),
    err, h("button", { class: "btn primary", type: "submit" }, t("createAdmin")));
  document.body.replaceChildren(h("div", { class: "auth" }, form));
}

function field(label, input, hint) {
  return h("label", { class: "field" }, h("span", {}, label), input, hint ? h("div", { class: "hint" }, hint) : null);
}

function renderLogin() {
  const err = h("div", { class: "error-text" });
  const user = h("input", { type: "text", autocomplete: "username webauthn", autocapitalize: "none", required: true });
  const pw = h("input", { type: "password", autocomplete: "current-password", required: true });
  const form = h("form", { class: "auth-card", onsubmit: async (e) => {
    e.preventDefault(); err.textContent = "";
    try { await api("POST", "login", { username: user.value, password: pw.value }); location.reload(); }
    catch (x) { err.textContent = x.message; }
  } },
    brand(), field(t("username"), user), field(t("password"), pw), err,
    h("button", { class: "btn primary", type: "submit" }, t("login")),
    S.info.passkeys && window.PublicKeyCredential ? [h("div", { class: "divider" }, t("or")),
      h("button", { class: "btn", type: "button", onclick: () => passkeyLogin(err) }, icon("key"), t("passkeyLogin"))] : null);
  document.body.replaceChildren(h("div", { class: "auth" }, form));
  user.focus();
}

// ---------- passkeys ----------
const b64u = {
  dec(s) { s = s.replace(/-/g, "+").replace(/_/g, "/"); while (s.length % 4) s += "="; return Uint8Array.from(atob(s), (c) => c.charCodeAt(0)); },
  enc(buf) { return btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""); },
};
const toBytes = (v) => (Array.isArray(v) ? new Uint8Array(v) : b64u.dec(v));

async function passkeyLogin(err) {
  try {
    const { challengeId, options } = await api("POST", "passkeys/login/begin", {});
    const pub = { ...options, challenge: toBytes(options.challenge) };
    if (pub.allowCredentials) pub.allowCredentials = pub.allowCredentials.map((c) => ({ ...c, id: toBytes(c.id) }));
    if (pub.timeout) pub.timeout = Number(pub.timeout);
    const cred = await navigator.credentials.get({ publicKey: pub });
    const r = cred.response;
    await api("POST", "passkeys/login/finish", { challengeId, credential: {
      id: cred.id, rawId: b64u.enc(cred.rawId), type: cred.type,
      response: { clientDataJSON: b64u.enc(r.clientDataJSON), authenticatorData: b64u.enc(r.authenticatorData),
        signature: b64u.enc(r.signature), userHandle: r.userHandle ? b64u.enc(r.userHandle) : null } } });
    location.reload();
  } catch (x) { err.textContent = x.message || String(x); }
}

async function passkeyRegister() {
  const { challengeId, options } = await api("POST", "passkeys/register/begin", {});
  const pub = { ...options, challenge: toBytes(options.challenge), user: { ...options.user, id: toBytes(options.user.id) } };
  if (pub.excludeCredentials) pub.excludeCredentials = pub.excludeCredentials.map((c) => ({ ...c, id: toBytes(c.id) }));
  if (pub.timeout) pub.timeout = Number(pub.timeout);
  const cred = await navigator.credentials.create({ publicKey: pub });
  const r = cred.response;
  const name = /iPhone|iPad/.test(navigator.userAgent) ? "iPhone/iPad" : /Mac/.test(navigator.userAgent) ? "Mac" : /Windows/.test(navigator.userAgent) ? "Windows" : "Gerät";
  await api("POST", "passkeys/register/finish", { challengeId, name, credential: {
    id: cred.id, rawId: b64u.enc(cred.rawId), type: cred.type,
    response: { clientDataJSON: b64u.enc(r.clientDataJSON), attestationObject: b64u.enc(r.attestationObject) } } });
}

// ---------- app shell ----------
let els = {};
async function startApp() {
  const p = S.me.user.profile;
  els.chatList = h("div", { class: "chat-list" });
  els.search = h("input", { type: "text", placeholder: t("search"), oninput: debounce(loadChats, 250) });
  els.title = h("div", { class: "title" });
  els.modelSelect = h("select", { class: "model-select", onchange: onModelChange });
  els.messages = h("div", { class: "messages" });
  els.inner = h("div", { class: "messages-inner" });
  els.messages.append(els.inner);
  els.input = h("textarea", { rows: 1, placeholder: t("writePlaceholder", { ai: S.me.aiName }), oninput: autosize, onkeydown: onKey });
  els.pending = h("div", { class: "pending-files" });
  els.fileInput = h("input", { type: "file", multiple: true, class: "hidden", accept: "image/*,.pdf,.txt,.md,.docx,.doc,.rtf,.csv,.json,.html,.py,.js,.swift,.java,.c,.cpp,.cs,.ts", onchange: onFiles });
  els.send = h("button", { class: "send-btn", title: t("send"), html: I.send, onclick: onSendClick });
  els.mic = p.voice ? h("button", { class: "icon-btn", title: t("dictate"), html: I.mic, onclick: toggleDictation }) : null;
  els.voice = p.voice ? h("button", { class: "icon-btn", title: t("voiceChat"), html: I.wave, onclick: startVoiceMode }) : null;
  els.notice = h("div", { class: "notice hidden" });
  els.composer = h("div", { class: "composer-wrap" }, els.notice,
    h("div", { class: "composer" }, els.pending, els.input,
      h("div", { class: "composer-row" },
        h("button", { class: "icon-btn", title: t("attach"), html: I.clip, onclick: () => els.fileInput.click() }), els.fileInput,
        els.mic, h("div", { class: "spacer" }), els.voice, els.send)));
  els.kidsBox = h("div");
  const sidebar = h("aside", { class: "sidebar" },
    h("div", { class: "sidebar-head" }, h("img", { src: "/icon-192.png", alt: "" }), h("strong", {}, S.me.aiName),
      h("button", { class: "icon-btn menu-toggle", html: I.x, onclick: closeDrawer })),
    h("button", { class: "btn new-chat", onclick: () => newChatMenu() }, icon("plus"), t("newChat")),
    h("div", { class: "search" }, els.search),
    els.chatList, els.kidsBox,
    h("div", { class: "sidebar-foot" },
      S.me.user.role === "admin" ? h("button", { class: "nav-item", onclick: openAdmin }, icon("shield"), t("admin")) : null,
      h("button", { class: "nav-item", onclick: openSettings }, h("span", { class: "avatar" }, initials(S.me.user.displayName)),
        h("span", { style: "flex:1" }, S.me.user.displayName), h("span", { html: I.gear, style: "display:inline-flex;color:var(--muted)" }))));
  const main = h("main", { class: "main" },
    h("div", { class: "topbar" },
      h("button", { class: "icon-btn menu-toggle", html: I.menu, onclick: openDrawer }),
      els.title, els.modelSelect,
      h("button", { class: "icon-btn", title: t("newChat"), html: I.pencil, onclick: () => newChatMenu() })),
    els.messages, els.composer);
  els.app = h("div", { class: "app" }, sidebar, h("div", { class: "scrim", onclick: closeDrawer }), main);
  document.body.replaceChildren(els.app);
  if (S.me.parentNotice) { els.notice.textContent = t("parentNotice"); els.notice.classList.remove("hidden"); }
  if (!S.me.hasKey) { els.notice.textContent = t("noKey"); els.notice.classList.remove("hidden"); }

  const m = await api("GET", "models");
  S.models = m.models; S.defaultModel = m.default;
  S.escalation = !!m.escalation;
  fillModelSelect(S.defaultModel);
  if (p.code) S.devices = await api("GET", "devices").catch(() => []);
  if (["parent", "admin"].includes(S.me.user.role)) loadKids();
  await loadChats();
  window.addEventListener("hashchange", route);
  route();
}

function fillModelSelect(selected) {
  els.modelSelect.replaceChildren(...S.models.map((m) => h("option", { value: m.id }, m.name.replace(/^[^:]+:\s*/, ""))));
  if (selected) els.modelSelect.value = selected;
  els.modelSelect.classList.toggle("hidden", S.models.length < 2);
}

function openDrawer() { els.app.classList.add("drawer-open"); }
function closeDrawer() { els.app.classList.remove("drawer-open"); }
function debounce(fn, ms) { let tm; return (...a) => { clearTimeout(tm); tm = setTimeout(() => fn(...a), ms); }; }
function autosize() { els.input.style.height = "auto"; els.input.style.height = Math.min(els.input.scrollHeight, 220) + "px"; }
function onKey(e) {
  const mobile = matchMedia("(max-width: 820px)").matches;
  if (e.key === "Enter" && !e.shiftKey && !mobile && !e.isComposing) { e.preventDefault(); onSendClick(); }
}

async function loadChats() {
  const q = els.search.value.trim();
  S.chats = await api("GET", "chats" + (q ? `?q=${encodeURIComponent(q)}` : ""));
  renderChatList();
}

function renderChatList() {
  const groups = { [t("today")]: [], [t("yesterday")]: [], [t("week")]: [], [t("older")]: [] };
  const now = new Date(); const start = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime() / 1000;
  for (const c of S.chats) {
    const ts = c.updatedAt;
    const g = ts >= start ? t("today") : ts >= start - 86400 ? t("yesterday") : ts >= start - 6 * 86400 ? t("week") : t("older");
    groups[g].push(c);
  }
  els.chatList.replaceChildren(...Object.entries(groups).filter(([, v]) => v.length).flatMap(([title, list]) => [
    h("div", { class: "group-title" }, title),
    list.map((c) => h("a", { class: "chat-item" + (S.chat && S.chat.id === c.id ? " active" : ""), href: `#/c/${c.id}`, onclick: closeDrawer },
      c.mode === "code" ? h("span", { class: "badge", html: I.code, style: "display:inline-flex;width:16px" }) : null,
      h("span", { class: "title" }, c.title))),
  ].flat()));
}

async function loadKids() {
  S.kids = await api("GET", "family/children").catch(() => []);
  if (!S.kids.length) { els.kidsBox.replaceChildren(); return; }
  els.kidsBox.replaceChildren(h("div", { class: "group-title", style: "padding: 8px 16px 4px" }, t("children")),
    ...S.kids.map((k) => h("a", { class: "chat-item", style: "margin: 0 8px", href: `#/kid/${k.id}`, onclick: closeDrawer },
      h("span", { class: "avatar", style: "width:22px;height:22px;font-size:11px" }, initials(k.displayName)), h("span", { class: "title" }, k.displayName))));
}

// ---------- routing ----------
async function route() {
  const hash = location.hash;
  let m;
  if ((m = hash.match(/^#\/c\/([\w-]+)/))) return openChat(m[1]);
  if ((m = hash.match(/^#\/kid\/([\w-]+)/))) return openKid(m[1]);
  showEmpty();
}

function setComposerVisible(v) { els.composer.classList.toggle("hidden", !v); }

function showEmpty(mode = "chat", deviceId = null) {
  S.chat = null; S.messages = []; S.readOnly = false; S.newMode = mode; S.newDevice = deviceId;
  els.title.textContent = mode === "code" ? t("codeOn", { device: S.devices.find((d) => d.id === deviceId)?.name || "" }) : "";
  setComposerVisible(true);
  els.modelSelect.disabled = false;
  fillModelSelect(store.get("lastModel", S.defaultModel) && S.models.some((m) => m.id === store.get("lastModel")) ? store.get("lastModel") : S.defaultModel);
  const sug = t("suggestions").filter((s, i) => i !== 2 || S.me.user.profile.images);
  els.inner.replaceChildren(h("div", { class: "empty" },
    h("img", { src: "/icon-192.png", alt: "" }),
    h("h2", {}, t("hello", { name: S.me.user.displayName.split(" ")[0] })), h("p", {}, t("howHelp")),
    mode === "chat" ? h("div", { class: "suggestions" }, sug.map((s) => h("button", { onclick: () => { els.input.value = s; autosize(); els.input.focus(); } }, s))) : null));
  els.messages.style.height = "";
  renderChatList();
  if (!matchMedia("(max-width: 820px)").matches) els.input.focus();
}

function newChatMenu() {
  closeDrawer();
  const devs = S.me.user.profile.code ? S.devices : [];
  if (!devs.length) { location.hash = "#/"; showEmpty(); return; }
  const ov = overlay(t("chooseMode"), h("div", {},
    h("button", { class: "nav-item", onclick: () => { ov.remove(); location.hash = "#/"; showEmpty(); } }, icon("plus"), t("plainChat")),
    devs.map((d) => h("button", { class: "nav-item", onclick: () => { ov.remove(); location.hash = "#/"; showEmpty("code", d.id); } },
      icon("code"), t("codeOn", { device: d.name }), h("span", { class: "tag " + (d.online ? "ok" : "") }, d.online ? t("online") : t("offline"))))));
}

async function openChat(id) {
  if (S.chat?.id === id && S.streaming) return;
  if (S.streaming) S.abort?.abort();
  let data;
  try { data = await api("GET", `chats/${id}`); } catch { location.hash = "#/"; return; }
  S.chat = data.chat; S.messages = data.messages; S.readOnly = data.readOnly; S.ownerName = data.ownerName || "";
  els.title.textContent = S.chat.title;
  setComposerVisible(!S.readOnly);
  if (!S.models.some((m) => m.id === S.chat.model)) els.modelSelect.append(h("option", { value: S.chat.model }, S.chat.model));
  els.modelSelect.value = S.chat.model;
  els.modelSelect.disabled = S.readOnly;
  els.modelSelect.classList.toggle("hidden", S.models.length < 2 && !S.readOnly);
  renderMessages();
  renderChatList();
}

async function openKid(kidId) {
  if (!S.kids?.some((k) => k.id === kidId)) await loadKids(); // direct load: sidebar may not be filled yet
  const kid = S.kids.find((k) => k.id === kidId);
  const [chats, memories] = await Promise.all([
    api("GET", `family/children/${kidId}/chats`).catch(() => []),
    api("GET", `family/children/${kidId}/memories`).catch(() => []),
  ]);
  S.chat = null;
  els.title.textContent = kid?.displayName || "";
  setComposerVisible(false);
  els.inner.replaceChildren(h("div", { style: "padding: 8px 0" },
    h("h2", { style: "margin: 0 0 12px" }, kid?.displayName),
    chats.length ? chats.map((c) => h("a", { class: "chat-item", href: `#/c/${c.id}` }, h("span", { class: "title" }, c.title),
      h("span", { class: "hint" }, new Date(c.updatedAt * 1000).toLocaleDateString()))) : h("p", { class: "hint" }, "–"),
    h("h3", { style: "margin: 24px 0 8px" }, t("memory")),
    h("p", { class: "hint" }, t("kidMemoryHint", { ai: S.me.aiName, name: kid?.displayName || "" })),
    memories.length ? memories.map((m) => h("div", { class: "list-item" }, h("div", { class: "grow" }, m.content))) : h("p", { class: "hint" }, "–")));
}

async function onModelChange() {
  const model = els.modelSelect.value;
  store.set("lastModel", model);
  if (S.chat && !S.readOnly) {
    S.chat = await api("PATCH", `chats/${S.chat.id}`, { model });
  }
}

// ---------- messages ----------
function renderMessages() {
  els.inner.replaceChildren();
  if (S.readOnly) els.inner.append(h("div", { class: "notice" }, t("readOnly", { name: S.ownerName })));
  S.messages.forEach((m, i) => els.inner.append(messageEl(m, i === S.messages.length - 1)));
  scrollDown(true);
}

function scrollDown(force) {
  const el = els.messages;
  if (force || el.scrollHeight - el.scrollTop - el.clientHeight < 160) el.scrollTop = el.scrollHeight;
}

function attachmentsEl(atts) {
  if (!atts?.length) return null;
  return h("div", { class: "attachments" }, atts.map((a) =>
    a.kind === "image" || a.kind === "generated"
      ? h("img", { src: `/api/files/${a.fileId}`, alt: a.name, loading: "lazy", onclick: () => lightbox(`/api/files/${a.fileId}`) })
      : h("a", { class: "file-chip", href: `/api/files/${a.fileId}`, target: "_blank" }, icon("file"), a.name)));
}

function lightbox(src) {
  const lb = h("div", { class: "lightbox", onclick: () => lb.remove() }, h("img", { src }));
  document.body.append(lb);
}

function messageEl(m, isLast) {
  if (m.role === "user") {
    return h("div", { class: "msg user" }, h("div", { class: "bubble" }, m.content, attachmentsEl(m.attachments)));
  }
  const body = h("div", { class: "md" });
  body.innerHTML = renderMarkdown(m.content);
  wireCodeCopy(body);
  const meta = m.meta || {};
  const actions = S.readOnly ? null : h("div", { class: "msg-actions" + (isLast ? " show" : "") },
    h("button", { class: "icon-btn", title: t("copy"), html: I.copy, onclick: () => { navigator.clipboard.writeText(m.content); toast(t("copied")); } }),
    S.me.user.profile.voice ? h("button", { class: "icon-btn", title: t("readAloud"), html: I.speaker, onclick: (e) => speak(m.content, e.currentTarget) }) : null,
    isLast ? h("button", { class: "icon-btn", title: t("regenerate"), html: I.refresh, onclick: () => regenerate() }) : null,
    isLast && S.escalation ? h("button", { class: "icon-btn escalate", title: t("escalateHint"), onclick: () => regenerate(true) }, h("span", { html: I.spark }), t("escalate")) : null,
    meta.cost ? h("span", { class: "meta-line", style: "margin-left:6px;align-self:center" }, `${fmtMoney(meta.cost)} $`) : null);
  return h("div", { class: "msg assistant" },
    h("img", { class: "ai-avatar", src: "/icon-192.png", alt: "" }),
    h("div", { class: "bubble" }, body, attachmentsEl(m.attachments),
      meta.sources?.length ? h("div", { class: "sources" }, meta.sources.map((s) => h("a", { href: s.url, target: "_blank", rel: "noopener noreferrer" }, s.title || new URL(s.url).hostname))) : null,
      meta.error ? h("div", { class: "error-text" }, meta.error) : null,
      actions));
}

function wireCodeCopy(root) {
  root.querySelectorAll("pre .copy").forEach((b) => b.addEventListener("click", () => {
    navigator.clipboard.writeText(b.nextElementSibling.textContent); b.textContent = t("copied");
    setTimeout(() => (b.textContent = t("copy")), 1500);
  }));
}

// ---------- sending ----------
function onSendClick() {
  if (S.streaming) { S.abort?.abort(); return; }
  send(els.input.value);
}

async function ensureChat() {
  if (S.chat) return S.chat;
  const chat = await api("POST", "chats", { model: els.modelSelect.value, mode: S.newMode || "chat", deviceId: S.newDevice });
  S.chat = chat; S.messages = [];
  history.replaceState(null, "", `#/c/${chat.id}`);
  els.inner.replaceChildren();
  return chat;
}

async function send(text, { voice = false } = {}) {
  text = (text || "").trim();
  if (!text && !S.pending.length) return null;
  if (S.pending.some((p) => p.uploading)) { toast("…"); return null; }
  const attachments = S.pending.map((p) => p.id);
  els.input.value = ""; autosize();
  S.pending = []; renderPending();
  const chat = await ensureChat();
  return stream(`chats/${chat.id}/messages`, { content: text, attachments }, { voice });
}

async function regenerate(escalate = false) {
  if (!S.chat || S.streaming) return;
  const last = S.messages[S.messages.length - 1];
  if (last?.role === "assistant") { S.messages.pop(); els.inner.lastElementChild?.remove(); }
  return stream(`chats/${S.chat.id}/regenerate`, escalate ? { escalate: true } : {});
}

async function stream(path, body, { voice = false } = {}) {
  S.streaming = true;
  els.send.innerHTML = I.stop; els.send.title = t("stop");
  const live = { content: "", attachments: [], sources: [], status: [] };
  const bodyEl = h("div", { class: "md" }, h("div", { class: "typing" }, h("span"), h("span"), h("span")));
  const statusEl = h("div");
  const attEl = h("div");
  const srcEl = h("div");
  const bubble = h("div", { class: "msg assistant" }, h("img", { class: "ai-avatar", src: "/icon-192.png", alt: "" }),
    h("div", { class: "bubble" }, statusEl, bodyEl, attEl, srcEl));
  let final = null;
  const streamChat = S.chat?.id;
  S.abort = new AbortController();
  let pendingRender = false;
  const renderLive = () => {
    if (pendingRender) return; pendingRender = true;
    requestAnimationFrame(() => { pendingRender = false; bodyEl.innerHTML = renderMarkdown(live.content); scrollDown(); });
  };
  try {
    const res = await api("POST", path, body, { raw: true, signal: S.abort.signal });
    const reader = res.body.getReader();
    const dec = new TextDecoder();
    let buf = "";
    let appended = false;
    if (!path.endsWith("regenerate")) { /* user message comes as first event */ } else { els.inner.append(bubble); appended = true; }
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let idx;
      while ((idx = buf.indexOf("\n\n")) >= 0) {
        const chunk = buf.slice(0, idx); buf = buf.slice(idx + 2);
        if (!chunk.startsWith("data:")) continue;
        let ev; try { ev = JSON.parse(chunk.slice(5)); } catch { continue; }
        switch (ev.t) {
          case "user":
            if (S.chat?.id !== streamChat) break;
            S.messages.push(ev.message);
            els.inner.querySelector(".empty")?.remove();
            els.inner.append(messageEl(ev.message));
            els.inner.append(bubble); appended = true; scrollDown(true);
            break;
          case "text": live.content += ev.v; renderLive(); break;
          case "status": statusEl.append(h("div", { class: "status-line" }, ev.v)); scrollDown(); break;
          case "image": attEl.append(attachmentsEl([{ fileId: ev.fileId, kind: "generated", name: "" }])); scrollDown(); break;
          case "source": live.sources.push(ev); break;
          case "error": statusEl.append(h("div", { class: "error-text" }, ev.v)); break;
          case "done": final = ev.message; break;
          case "title":
            els.title.textContent = ev.v;
            if (S.chat) S.chat.title = ev.v;
            loadChats();
            break;
        }
      }
    }
    if (!appended && S.chat?.id === streamChat) els.inner.append(bubble);
  } catch (x) {
    if (x.name !== "AbortError") statusEl.append(h("div", { class: "error-text" }, x.message));
  } finally {
    S.streaming = false; S.abort = null;
    els.send.innerHTML = I.send; els.send.title = t("send");
  }
  if (S.chat?.id !== streamChat) { loadChats(); return final; }
  if (final) {
    S.messages.push(final);
    const el = messageEl(final, true);
    if (statusEl.childElementCount) el.querySelector(".bubble").prepend(...statusEl.childNodes);
    els.inner.querySelectorAll(".msg-actions.show").forEach((e) => e.classList.remove("show"));
    bubble.replaceWith(el);
    if (store.get("autoRead", false) && !voice && S.me.user.profile.voice) speak(final.content);
  } else if (S.chat) {
    // Generation continues on the server if the connection dropped; reload shortly.
    setTimeout(() => S.chat && openChat(S.chat.id), 1500);
  }
  loadChats();
  scrollDown();
  return final;
}

// ---------- files ----------
async function onFiles() {
  const files = [...els.fileInput.files];
  els.fileInput.value = "";
  for (const file of files) await uploadFile(file);
}

async function uploadFile(file, { library = false } = {}) {
  const entry = { name: file.name, uploading: true, preview: file.type.startsWith("image/") ? URL.createObjectURL(file) : null };
  if (!library) { S.pending.push(entry); renderPending(); }
  try {
    const res = await fetch(`/api/files${library ? "?library=1" : ""}`, { method: "POST", body: file, credentials: "same-origin",
      headers: { "X-Family-AI": "1", "Content-Type": file.type || "application/octet-stream", "X-Filename": encodeURIComponent(file.name) } });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || res.statusText);
    Object.assign(entry, { id: data.id, uploading: false, kind: data.kind });
    return data;
  } catch (x) {
    toast(`${file.name}: ${x.message}`);
    S.pending = S.pending.filter((p) => p !== entry);
  } finally { renderPending(); }
}

function renderPending() {
  els.pending.replaceChildren(...S.pending.map((p) => h("span", { class: "file-chip" },
    p.preview ? h("img", { src: p.preview, alt: "" }) : icon("file"), p.uploading ? "…" : "", p.preview ? null : p.name,
    h("button", { html: "×", title: t("delete"), onclick: () => { S.pending = S.pending.filter((x) => x !== p); renderPending(); } }))));
}

document.addEventListener("paste", (e) => {
  if (!els.input || document.activeElement !== els.input) return;
  const files = [...(e.clipboardData?.files || [])];
  if (files.length) { e.preventDefault(); files.forEach((f) => uploadFile(f)); }
});
document.addEventListener("dragover", (e) => { if (els.input) e.preventDefault(); });
document.addEventListener("drop", (e) => {
  if (!els.input || S.readOnly) return;
  e.preventDefault(); [...(e.dataTransfer?.files || [])].forEach((f) => uploadFile(f));
});

// ---------- voice ----------
// iOS/Safari only allow audio.play() on an element that was started inside a user
// gesture. One shared element is "unlocked" by the first tap and reused afterwards,
// so playback also works after the async TTS request (and in hands-free voice chat).
const player = new Audio();
let playerUnlocked = false, currentAudio = null;
/** A valid 0.1 s silent WAV (an empty one is rejected by some browsers). */
function silentWav() {
  const n = 800, b = new DataView(new ArrayBuffer(44 + n * 2));
  const str = (o, s) => [...s].forEach((c, i) => b.setUint8(o + i, c.charCodeAt(0)));
  str(0, "RIFF"); b.setUint32(4, 36 + n * 2, true); str(8, "WAVEfmt "); b.setUint32(16, 16, true);
  b.setUint16(20, 1, true); b.setUint16(22, 1, true); b.setUint32(24, 8000, true); b.setUint32(28, 16000, true);
  b.setUint16(32, 2, true); b.setUint16(34, 16, true); str(36, "data"); b.setUint32(40, n * 2, true);
  return URL.createObjectURL(new Blob([b], { type: "audio/wav" }));
}
function unlockAudio() {
  if (playerUnlocked) return;
  playerUnlocked = true;
  player.src = silentWav();
  player.play().catch(() => { playerUnlocked = false; });
}
document.addEventListener("pointerdown", unlockAudio, { capture: true });
document.addEventListener("keydown", unlockAudio, { capture: true });

async function speak(text, btn) {
  if (currentAudio) { player.pause(); currentAudio = null; if (btn?.classList.contains("active")) { btn.classList.remove("active"); return; } }
  btn?.classList.add("active");
  unlockAudio();
  try {
    const res = await api("POST", "tts", { text }, { raw: true });
    const url = URL.createObjectURL(await res.blob());
    currentAudio = player;
    player.src = url;
    await new Promise((resolve, reject) => {
      player.onended = resolve;
      player.onerror = () => reject(new Error(t("audioFailed")));
      player.play().catch(reject);
    });
    URL.revokeObjectURL(url);
  } catch (x) { toast(x.name === "NotAllowedError" ? t("audioBlocked") : x.message); }
  finally { btn?.classList.remove("active"); currentAudio = null; }
}

function recorderMime() {
  for (const m of ["audio/webm;codecs=opus", "audio/webm", "audio/mp4", "audio/ogg"]) if (window.MediaRecorder?.isTypeSupported?.(m)) return m;
  return "";
}

/** Browsers only expose the microphone in a secure context (HTTPS or localhost). */
function micProblem() {
  if (navigator.mediaDevices?.getUserMedia && window.MediaRecorder) return null;
  if (window.isSecureContext) return { text: t("micUnsupported") };
  const url = (S.info?.publicURL || "").replace(/\/+$/, "");
  return url && /^https:\/\//i.test(url) ? { text: t("micNeedsHttpsAt", { url }), url } : { text: t("micNeedsHttps") };
}

function showMicProblem(p) {
  overlay(t("micTitle"), h("div", {},
    h("p", {}, p.text),
    p.url ? h("div", { style: "margin-top:12px" }, h("a", { class: "btn primary", href: p.url + location.pathname + location.search }, t("micOpenHttps"))) : null));
}

/** Records until stop() or (with autoStop) ~1.3 s of silence after speech. */
async function record({ autoStop = false, onLevel } = {}) {
  const streamM = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } });
  const mime = recorderMime();
  const rec = new MediaRecorder(streamM, mime ? { mimeType: mime } : {});
  const chunks = [];
  rec.ondataavailable = (e) => e.data.size && chunks.push(e.data);
  let ctx, raf;
  const done = new Promise((resolve) => {
    rec.onstop = () => {
      streamM.getTracks().forEach((tr) => tr.stop());
      cancelAnimationFrame(raf); ctx?.close();
      resolve(new Blob(chunks, { type: rec.mimeType || mime || "audio/webm" }));
    };
  });
  rec.start(250);
  if (autoStop || onLevel) {
    ctx = new AudioContext();
    const an = ctx.createAnalyser(); an.fftSize = 1024;
    ctx.createMediaStreamSource(streamM).connect(an);
    const data = new Uint8Array(an.fftSize);
    let spoke = false, silentSince = performance.now(); const started = performance.now();
    const loop = () => {
      an.getByteTimeDomainData(data);
      let sum = 0; for (const v of data) sum += (v - 128) ** 2;
      const rms = Math.sqrt(sum / data.length) / 128;
      onLevel?.(rms);
      const nowT = performance.now();
      if (rms > 0.04) { spoke = true; silentSince = nowT; }
      if (autoStop && rec.state === "recording") {
        if (spoke && nowT - silentSince > 1300) return rec.stop();
        if (!spoke && nowT - started > 12000) return rec.stop();
        if (nowT - started > 90000) return rec.stop();
      }
      raf = requestAnimationFrame(loop);
    };
    loop();
  }
  return { stop: () => rec.state !== "inactive" && rec.stop(), done };
}

async function transcribe(blob) {
  if (blob.size < 1500) return "";
  const res = await api("POST", "stt", blob, { headers: { "Content-Type": blob.type } });
  return (res.text || "").trim();
}

let dictation = null;
async function toggleDictation() {
  if (dictation) { dictation.stop(); return; }
  const problem = micProblem();
  if (problem) return showMicProblem(problem);
  try {
    dictation = await record();
    els.mic.classList.add("recording");
    const blob = await dictation.done;
    dictation = null; els.mic.classList.remove("recording");
    els.mic.disabled = true;
    const text = await transcribe(blob);
    if (text) { els.input.value = (els.input.value ? els.input.value + " " : "") + text; autosize(); els.input.focus(); }
  } catch (x) { toast(x.message || String(x)); dictation = null; els.mic.classList.remove("recording"); }
  finally { els.mic.disabled = false; }
}

async function startVoiceMode() {
  const problem = micProblem();
  if (problem) return showMicProblem(problem);
  const orb = h("div", { class: "duo idle" }, h("div", { class: "spin" }, h("i", { class: "c1" }), h("i", { class: "c2" })));
  const status = h("div", { class: "voice-status" }, t("voiceHint"));
  let active = true, rec = null;
  const ov = h("div", { class: "voice-overlay" }, orb, status,
    h("button", { class: "btn", onclick: () => { active = false; rec?.stop(); currentAudio?.pause(); ov.remove(); } }, icon("x"), t("tapToEnd")));
  $(".main").append(ov);
  while (active) {
    try {
      orb.className = "duo listening"; status.textContent = t("listening");
      let smooth = 0;
      rec = await record({ autoStop: true, onLevel: (v) => { smooth = Math.max(Math.min(1, v * 7), smooth * 0.82); orb.style.setProperty("--lvl", smooth.toFixed(3)); } });
      const blob = await rec.done; rec = null;
      if (!active) break;
      orb.className = "duo thinking"; orb.style.setProperty("--lvl", 0); status.textContent = t("thinking");
      const text = await transcribe(blob);
      if (!text) continue;
      status.textContent = `„${text}“`;
      const answer = await send(text, { voice: true });
      if (!active || !answer?.content) continue;
      orb.className = "duo speaking"; orb.style.setProperty("--lvl", 0); status.textContent = t("speaking");
      await speak(answer.content);
    } catch (x) {
      status.textContent = x.message || String(x);
      orb.className = "duo idle";
      await new Promise((r) => setTimeout(r, 2500));
      if (/Permission|NotAllowed/i.test(String(x))) break;
    }
  }
}

// ---------- overlays ----------
function overlay(title, content, { wide = false, tabs = null } = {}) {
  const ov = h("div", { class: "overlay", onclick: (e) => { if (e.target === ov) ov.remove(); } },
    h("div", { class: "modal" + (wide ? " wide" : "") },
      h("div", { class: "modal-head" }, h("h2", {}, title), h("button", { class: "icon-btn", html: I.x, onclick: () => ov.remove() })),
      tabs, h("div", { class: "modal-body" }, content)));
  document.body.append(ov);
  return ov;
}

function tabbed(title, tabs, opts) {
  const body = h("div");
  const bar = h("div", { class: "tabs" });
  const show = (i) => {
    [...bar.children].forEach((b, j) => b.classList.toggle("active", i === j));
    body.replaceChildren(h("div", { class: "hint" }, "…"));
    Promise.resolve(tabs[i][1]()).then((c) => body.replaceChildren(c)).catch((x) => body.replaceChildren(h("div", { class: "error-text" }, x.message)));
  };
  tabs.forEach(([name], i) => bar.append(h("button", { onclick: () => show(i) }, name)));
  const ov = overlay(title, body, { ...opts, tabs: bar });
  show(0);
  return ov;
}

const sw = (label, checked, onchange) => h("label", { class: "switch" }, h("span", {}, label), h("input", { type: "checkbox", checked, onchange }));

// ---------- personal settings ----------
function openSettings() {
  closeDrawer();
  const p = S.me.user.profile;
  const tabs = [[t("account"), accountTab]];
  if (p.memory) tabs.push([t("memory"), memoryTab]);
  if (p.documents) tabs.push([t("documents"), documentsTab]);
  if (p.code) tabs.push([t("devices"), devicesTab]);
  tabbed(t("settings"), tabs);
}

async function accountTab() {
  const box = h("div");
  const b = await api("GET", "me/budget").catch(() => null);
  if (b?.available) {
    const used = b.limit != null && b.remaining != null ? b.limit - b.remaining : b.usage;
    const pct = b.limit ? Math.min(100, (used / b.limit) * 100) : 0;
    box.append(h("div", { class: "section" }, h("h3", {}, t("budget")),
      b.limit ? [h("div", {}, t("budgetOf", { used: fmtMoney(used), limit: fmtMoney(b.limit) }),
        b.reset ? h("span", { class: "hint" }, ` · ${t("reset")}: ${t("reset" + b.reset[0].toUpperCase() + b.reset.slice(1))}`) : null),
        h("div", { class: "bar" }, h("div", { style: `width:${pct}%` }))] : h("div", { class: "hint" }, t("noLimit"))));
  }
  const prefs = h("div", { class: "section" }, h("h3", {}, t("preferences")),
    S.me.user.profile.voice ? sw(t("autoRead"), store.get("autoRead", false), (e) => store.set("autoRead", e.target.checked)) : null);
  const oldPw = h("input", { type: "password", autocomplete: "current-password" });
  const newPw = h("input", { type: "password", autocomplete: "new-password" });
  const err = h("div", { class: "error-text" });
  const pwBox = h("div", { class: "section" }, h("h3", {}, t("changePassword")), field(t("oldPassword"), oldPw), field(t("newPassword"), newPw), err,
    h("button", { class: "btn", onclick: async () => {
      err.textContent = "";
      try { await api("POST", "me/password", { old: oldPw.value, new: newPw.value }); oldPw.value = newPw.value = ""; toast(t("passwordChanged")); }
      catch (x) { err.textContent = x.message; }
    } }, t("save")));
  const pkList = h("div");
  const loadPk = async () => {
    const list = await api("GET", "passkeys").catch(() => []);
    pkList.replaceChildren(...list.map((k) => h("div", { class: "list-item" }, icon("key"), h("div", { class: "grow" }, k.name,
      h("div", { class: "hint" }, new Date(k.createdAt * 1000).toLocaleDateString())),
      h("button", { class: "icon-btn", html: I.trash, onclick: async () => { await api("DELETE", `passkeys/${encodeURIComponent(k.id)}`); loadPk(); } }))));
  };
  loadPk();
  const pkErr = h("div", { class: "error-text" });
  const pkBox = h("div", { class: "section" }, h("h3", {}, t("passkeys")), pkList,
    S.info.passkeys && window.PublicKeyCredential
      ? h("button", { class: "btn", onclick: async () => { pkErr.textContent = ""; try { await passkeyRegister(); loadPk(); toast(t("saved")); } catch (x) { pkErr.textContent = x.message || String(x); } } }, icon("key"), t("addPasskey"))
      : h("div", { class: "hint" }, t("passkeysNeedURL")), pkErr);
  box.append(prefs, pwBox, pkBox,
    h("button", { class: "btn danger", onclick: async () => { await api("POST", "logout", {}); location.hash = ""; location.reload(); } }, icon("logout"), t("logout")));
  return box;
}

async function memoryTab() {
  const list = h("div");
  const load = async () => {
    const mems = await api("GET", "memories");
    list.replaceChildren(...mems.map((m) => h("div", { class: "list-item" }, h("div", { class: "grow" }, m.content),
      h("button", { class: "icon-btn", html: I.trash, onclick: async () => { await api("DELETE", `memories/${m.id}`); load(); } }))));
  };
  await load();
  const input = h("input", { type: "text", placeholder: t("addMemory") });
  return h("div", {}, h("p", { class: "hint" }, t("memoryHint", { ai: S.me.aiName })), list,
    h("div", { class: "row", style: "margin-top:12px" }, h("div", { class: "grow" }, input),
      h("button", { class: "btn", onclick: async () => { if (!input.value.trim()) return; await api("POST", "memories", { content: input.value }); input.value = ""; load(); } }, t("add"))));
}

async function documentsTab() {
  const list = h("div");
  const load = async () => {
    const docs = await api("GET", "documents");
    list.replaceChildren(...docs.map((d) => h("div", { class: "list-item" }, icon("file"),
      h("div", { class: "grow" }, h("a", { href: `/api/files/${d.id}`, target: "_blank" }, d.name)),
      h("span", { class: "tag " + (d.indexed ? "ok" : "") }, d.indexed ? t("indexed") : t("indexing")),
      h("button", { class: "icon-btn", html: I.trash, onclick: async () => { await api("DELETE", `documents/${d.id}`); load(); } }))));
  };
  await load();
  const input = h("input", { type: "file", multiple: true, class: "hidden", accept: ".pdf,.txt,.md,.docx,.doc,.rtf,.csv,.json,.html", onchange: async () => {
    for (const f of input.files) await uploadFile(f, { library: true });
    input.value = ""; load(); setTimeout(load, 4000);
  } });
  return h("div", {}, h("p", { class: "hint" }, t("documentsHint", { ai: S.me.aiName })), list,
    h("button", { class: "btn", style: "margin-top:12px", onclick: () => input.click() }, icon("plus"), t("upload")), input);
}

const RUNNER_FILES = [
  ["family-ai-runner-windows-x64.exe", "Windows (Intel/AMD)"],
  ["family-ai-runner-windows-arm64.exe", "Windows (ARM)"],
  ["family-ai-runner-macos", "macOS"],
  ["family-ai-runner-linux-x64", "Linux (x64)"],
  ["family-ai-runner-linux-arm64", "Linux (ARM)"],
];

async function runnerHelp(token) {
  const server = location.origin;
  // SHA256SUMS lists exactly the runner builds bundled with this server.
  const sums = await fetch("/runner/SHA256SUMS", { cache: "no-store" }).then((r) => (r.ok ? r.text() : "")).catch(() => "");
  const files = RUNNER_FILES.filter(([f]) => sums.includes(f));
  const ua = navigator.userAgent;
  const mine = /Windows/.test(ua) ? "family-ai-runner-windows-x64.exe" : /Mac OS X/.test(ua) && !/iPhone|iPad/.test(ua) ? "family-ai-runner-macos" : "";
  return h("div", { class: "card" },
    h("p", {}, t("tokenOnce")), h("div", { class: "code-block" }, token),
    h("p", {}, h("strong", {}, "1. "), t("runnerStep1")),
    files.length
      ? h("div", { class: "row", style: "flex-wrap:wrap;gap:8px" }, files.map(([f, label]) =>
          h("a", { class: "btn" + (f === mine ? " primary" : ""), href: `/runner/${f}`, download: f }, icon("download"), label)))
      : h("p", { class: "hint" }, t("runnerMissing")),
    h("p", {}, h("strong", {}, "2. "), t("runnerStep2")),
    h("div", { class: "code-block" }, `${t("runnerServer")}: ${server}\n${t("runnerToken")}: ${token}\n${t("runnerWorkspace")}: ${t("runnerWorkspaceEx")}`),
    h("p", { class: "hint" }, t("runnerSmartScreen")),
    h("p", { class: "hint" }, t("runnerMac")),
    h("details", {}, h("summary", { class: "hint" }, t("runnerCli")),
      h("div", { class: "code-block" }, `family-ai-runner-windows-x64.exe --server ${server} --token ${token} --workspace C:\\Projekte\\…`),
      h("p", { class: "hint" }, t("runnerFlags"))));
}

async function devicesTab() {
  const list = h("div");
  const out = h("div");
  const load = async () => {
    S.devices = await api("GET", "devices");
    list.replaceChildren(...S.devices.map((d) => h("div", { class: "list-item" }, icon("code"),
      h("div", { class: "grow" }, d.name, h("div", { class: "hint" }, [d.platform, d.workspace].filter(Boolean).join(" · "))),
      h("span", { class: "tag " + (d.online ? "ok" : "") }, d.online ? t("online") : t("offline")),
      h("button", { class: "icon-btn", html: I.trash, onclick: async () => { await api("DELETE", `devices/${d.id}`); load(); } }))));
  };
  await load();
  const name = h("input", { type: "text", placeholder: t("deviceName") });
  return h("div", {}, h("p", { class: "hint" }, t("devicesHint", { ai: S.me.aiName })), list,
    h("div", { class: "row", style: "margin-top:12px" }, h("div", { class: "grow" }, name),
      h("button", { class: "btn", onclick: async () => {
        const r = await api("POST", "devices", { name: name.value || "Computer" });
        name.value = ""; load();
        out.replaceChildren(await runnerHelp(r.token));
      } }, t("addDevice"))), out);
}

// ---------- admin ----------
let catalogCache = null;
async function getCatalog() { if (!catalogCache) catalogCache = await api("GET", "admin/catalog"); return catalogCache; }

function openAdmin() {
  closeDrawer();
  tabbed(t("admin"), [[t("people"), peopleTab], [t("family"), familyTab], [t("budgets"), budgetsTab]], { wide: true });
}

async function peopleTab() {
  const users = await api("GET", "admin/users");
  const box = h("div");
  const roleName = (r) => t("role" + r[0].toUpperCase() + r.slice(1));
  box.append(...users.map((u) => h("div", { class: "list-item" }, h("span", { class: "avatar" }, initials(u.displayName)),
    h("div", { class: "grow" }, h("strong", {}, u.displayName), " ", h("span", { class: "hint" }, `@${u.username}`),
      h("div", { class: "row", style: "gap:6px;margin-top:2px" }, h("span", { class: "tag" }, roleName(u.role)),
        h("span", { class: "tag " + (u.hasKey ? "ok" : "warn") }, u.hasKey ? t("keySet") : t("keyMissing")),
        u.disabled ? h("span", { class: "tag warn" }, t("disabled")) : null)),
    h("button", { class: "btn", onclick: () => editUser(u, box) }, t("edit")))));
  box.append(h("button", { class: "btn primary", style: "margin-top:12px", onclick: () => editUser(null, box) }, icon("plus"), t("addPerson")));
  return box;
}

function modelPicker(catalog, selected, { single = false, name = "mp" + Math.random() } = {}) {
  const sel = new Set(selected || []);
  const filter = h("input", { type: "text", placeholder: t("filterModels"), style: "margin-bottom:6px" });
  const list = h("div", { class: "model-picker" });
  const render = () => {
    const q = filter.value.toLowerCase();
    const items = catalog.filter((m) => !q || m.id.toLowerCase().includes(q) || m.name.toLowerCase().includes(q))
      .sort((a, b) => (sel.has(b.id) - sel.has(a.id)) || a.id.localeCompare(b.id)).slice(0, 200);
    list.replaceChildren(...items.map((m) => h("label", {},
      h("input", { type: single ? "radio" : "checkbox", name, checked: sel.has(m.id), onchange: (e) => {
        if (single) { sel.clear(); sel.add(m.id); } else e.target.checked ? sel.add(m.id) : sel.delete(m.id);
      } }), h("span", {}, m.name), h("small", {}, m.prompt != null ? `${(m.prompt * 1e6).toFixed(2)} / ${(m.completion * 1e6).toFixed(2)} $` : ""))));
  };
  filter.addEventListener("input", render);
  render();
  return { el: h("div", {}, filter, list), value: () => [...sel] };
}

async function editUser(u, listBox) {
  const isNew = !u;
  const p = u?.profile || { images: true, voice: true, webSearch: true, memory: true, documents: true, code: false, parentalView: false, allowedModels: [], systemPrompt: "" };
  const catalog = (await getCatalog()).filter((m) => m.out.includes("text"));
  const f = {
    displayName: h("input", { type: "text", value: u?.displayName || "" }),
    username: h("input", { type: "text", value: u?.username || "", disabled: !isNew, autocapitalize: "none" }),
    role: h("select", {}, ["child", "parent", "admin"].map((r) => h("option", { value: r }, t("role" + r[0].toUpperCase() + r.slice(1))))),
    password: h("input", { type: "password", autocomplete: "new-password" }),
    apiKey: h("input", { type: "password", placeholder: u?.hasKey ? "••••••• (" + t("keepKey") + ")" : "sk-or-…" }),
    systemPrompt: h("textarea", { rows: 4 }, p.systemPrompt || ""),
    defaultModel: h("select", {}, h("option", { value: "" }, t("familyDefault")), catalog.map((m) => h("option", { value: m.id }, m.name))),
    escalation: h("select", {}, h("option", { value: "" }, t("familyDefault")), h("option", { value: "off" }, t("escalationOff")),
      catalog.map((m) => h("option", { value: m.id }, m.name))),
  };
  f.role.value = u?.role || "child";
  f.defaultModel.value = p.defaultModel || "";
  if (p.escalationModel && p.escalationModel !== "off" && !catalog.some((m) => m.id === p.escalationModel)) f.escalation.append(h("option", { value: p.escalationModel }, p.escalationModel));
  f.escalation.value = p.escalationModel || "";
  const picker = modelPicker(catalog, p.allowedModels);
  const feats = { images: p.images, voice: p.voice, webSearch: p.webSearch, memory: p.memory, documents: p.documents, code: p.code, parentalView: p.parentalView };
  const featBox = h("div", { class: "card" },
    [["images", "fImages"], ["voice", "fVoice"], ["webSearch", "fWeb"], ["memory", "fMemory"], ["documents", "fDocs"], ["code", "fCode"], ["parentalView", "parentalView"]]
      .map(([k, label]) => sw(t(label), feats[k], (e) => (feats[k] = e.target.checked))));
  const err = h("div", { class: "error-text" });
  const ov = overlay(isNew ? t("addPerson") : u.displayName, h("div", {},
    h("div", { class: "grid2" }, field(t("displayName"), f.displayName), field(t("username"), f.username),
      field(t("role"), f.role), field(isNew ? t("password") : t("newPasswordOpt"), f.password)),
    field(t("apiKey"), f.apiKey),
    h("h3", {}, t("features")), featBox,
    h("h3", { style: "margin-top:16px" }, t("allowedModels")), h("p", { class: "hint" }, t("allowedModelsHint")), picker.el,
    field(t("defaultModel"), f.defaultModel), field(t("escalationModel"), f.escalation), h("p", { class: "hint" }, t("escalationHint")), field(t("systemPrompt"), f.systemPrompt),
    err,
    h("div", { class: "row", style: "margin-top:8px" },
      !isNew ? h("button", { class: "btn danger", onclick: async () => {
        if (!confirm(t("confirmDeleteUser"))) return;
        try { await api("DELETE", `admin/users/${u.id}`); ov.remove(); listBox.replaceWith(await peopleTab()); } catch (x) { err.textContent = x.message; }
      } }, icon("trash"), t("delete")) : null,
      !isNew ? h("label", { class: "row hint" }, h("input", { type: "checkbox", checked: u.disabled, onchange: (e) => (feats.disabled = e.target.checked) }), t("disabled")) : null,
      h("div", { class: "grow" }),
      h("button", { class: "btn", onclick: () => ov.remove() }, t("cancel")),
      h("button", { class: "btn primary", onclick: async () => {
        err.textContent = "";
        const profile = { ...p, images: feats.images, voice: feats.voice, webSearch: feats.webSearch, memory: feats.memory, documents: feats.documents,
          code: feats.code, parentalView: feats.parentalView, escalationModel: f.escalation.value, allowedModels: picker.value(), defaultModel: f.defaultModel.value || null, systemPrompt: f.systemPrompt.value };
        const body = { displayName: f.displayName.value, role: f.role.value, profile };
        if (f.password.value) body.password = f.password.value;
        if (f.apiKey.value.trim()) body.apiKey = f.apiKey.value.trim();
        if (feats.disabled !== undefined) body.disabled = feats.disabled;
        try {
          if (isNew) await api("POST", "admin/users", { ...body, username: f.username.value.trim() });
          else await api("PUT", `admin/users/${u.id}`, body);
          ov.remove(); toast(t("userSaved")); listBox.replaceWith(await peopleTab());
        } catch (x) { err.textContent = x.message; }
      } }, t("save")))));
}

async function familyTab() {
  const s = await api("GET", "admin/settings");
  const catalog = await getCatalog();
  const inp = (k, type = "text") => h("input", { type, value: s[k] ?? "", oninput: (e) => (s[k] = type === "number" ? Number(e.target.value) : e.target.value) });
  const lang = h("select", { onchange: (e) => (s.language = e.target.value) }, h("option", { value: "de" }, "Deutsch"), h("option", { value: "en" }, "English"));
  lang.value = s.language;
  const opts = (filter) => catalog.filter(filter).map((m) => h("option", { value: m.id }, m.id));
  const sel = (k, filter) => { const e = h("select", { onchange: (ev) => (s[k] = ev.target.value) }, h("option", { value: "" }, "–"), opts(filter)); e.value = s[k]; if (s[k] && e.value !== s[k]) { e.append(h("option", { value: s[k] }, s[k])); e.value = s[k]; } return e; };
  const catPicker = modelPicker(catalog.filter((m) => m.out.includes("text")), s.catalog);
  const smtpSec = h("select", { onchange: (e) => (s.smtpSecurity = e.target.value) },
    ["none", "starttls", "tls"].map((v) => h("option", { value: v }, t("smtpSec_" + v))));
  smtpSec.value = s.smtpSecurity || "none";
  const smtpPw = h("input", { type: "password", autocomplete: "new-password", placeholder: s.smtpPasswordSet ? t("smtpPwSet") : "" });
  delete s.smtpPasswordSet;
  const err = h("div", { class: "error-text" });
  return h("div", {},
    h("div", { class: "grid2" }, field(t("aiName"), inp("aiName")), field(t("familyName"), inp("familyName")),
      field(t("language"), lang), field(t("publicURL"), inp("publicURL", "url"))),
    h("div", { class: "card" },
      sw(t("kidNotice"), s.kidNoticeVisible, (e) => (s.kidNoticeVisible = e.target.checked)),
      sw(t("adminLocal"), s.adminLocalOnly, (e) => (s.adminLocalOnly = e.target.checked))),
    h("div", { class: "grid2" },
      field(t("imageModel"), sel("imageModel", (m) => m.out.includes("image"))),
      field(t("ttsModel"), sel("ttsModel", (m) => m.out.includes("speech"))),
      field(t("ttsVoice"), inp("ttsVoice")),
      field(t("sttModel"), sel("sttModel", (m) => m.out.includes("transcription"))),
      field(t("embedModel"), inp("embedModel")),
      field(t("titleModel"), sel("titleModel", (m) => m.out.includes("text"))),
      field(t("defaultModel"), sel("defaultModel", (m) => m.out.includes("text"))),
      field(t("escalationModel"), sel("escalationModel", (m) => m.out.includes("text"))),
      field(t("retention"), inp("retentionDays", "number")),
      field(t("webResults"), inp("webSearchMaxResults", "number"))),
    h("h3", {}, t("catalog")), h("p", { class: "hint" }, t("catalogHint")), catPicker.el,
    h("h3", { style: "margin-top:16px" }, t("mail")),
    h("div", { class: "card" }, sw(t("notifyBudget"), s.notifyOnBudget, (e) => (s.notifyOnBudget = e.target.checked))),
    h("div", { class: "grid2" }, field(t("threshold"), inp("budgetThreshold", "number")), field(t("mailTo"), inp("mailRecipient", "email")),
      field(t("mailFrom"), inp("mailSender", "email")), field(t("smtpHost"), inp("smtpHost")), field(t("smtpPort"), inp("smtpPort", "number")),
      field(t("smtpSecurity"), smtpSec), field(t("smtpUser"), inp("smtpUser")), field(t("smtpPassword"), smtpPw)),
    err,
    h("div", { class: "row" },
      h("button", { class: "btn", onclick: async () => {
        err.textContent = "";
        const r = await api("POST", "admin/test-mail", {});
        toast(r.ok ? t("mailOk") : t("mailFail"));
        if (!r.ok && r.error) err.textContent = r.error;
      } }, t("testMail")),
      h("div", { class: "grow" }),
      h("button", { class: "btn primary", onclick: async () => {
        err.textContent = "";
        try {
          s.catalog = catPicker.value();
          const body = { ...s };
          if (smtpPw.value) body.smtpPassword = smtpPw.value;
          else if (!s.smtpUser) body.smtpPassword = "";
          await api("PUT", "admin/settings", body);
          smtpPw.value = "";
          toast(t("saved"));
        } catch (x) { err.textContent = x.message; }
      } }, t("save"))));
}

async function budgetsTab() {
  const rows = await api("GET", "admin/budgets");
  return h("div", {}, rows.map((r) => {
    const used = r.limit != null && r.remaining != null ? r.limit - r.remaining : r.usage;
    const pct = r.limit ? Math.min(100, (used / r.limit) * 100) : 0;
    return h("div", { class: "card" }, h("div", { class: "row" }, h("strong", { class: "grow" }, r.displayName),
      !r.hasKey ? h("span", { class: "tag warn" }, t("keyMissing")) :
        r.limit ? h("span", {}, t("budgetOf", { used: fmtMoney(used), limit: fmtMoney(r.limit) })) : h("span", { class: "hint" }, `${fmtMoney(r.usage)} $ · ${t("noLimit")}`)),
      r.limit ? h("div", { class: "bar" }, h("div", { style: `width:${pct}%` })) : null);
  }));
}

// ---------- service worker ----------
if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => {});

boot().catch((x) => {
  document.body.replaceChildren(h("div", { class: "auth" }, h("div", { class: "auth-card" }, h("h2", {}, t("error")), h("p", {}, x.message),
    h("button", { class: "btn", onclick: () => location.reload() }, t("retry")))));
});

document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return;
  const lb = document.querySelector(".lightbox");
  if (lb) return lb.remove();
  const ovs = document.querySelectorAll(".overlay");
  if (ovs.length) ovs[ovs.length - 1].remove();
});
