// Auto-update via electron-updater + GitHub Releases.
//
// Flow: check on launch and every few hours -> if a newer release exists, tell
// the renderer (it shows the update card) -> user picks Download & Install or
// Later -> download in the background with progress -> user confirms Restart
// -> quitAndInstall. Nothing downloads or installs without the user's click.
//
// Trust: the feed is the GitHub Releases of the repo configured under
// build.publish in package.json (baked into app-update.yml at build time).
// electron-updater only installs a file whose SHA-512 matches latest.yml from
// that release, fetched over HTTPS; if the app is code-signed it also checks
// the installer is signed by the same publisher.

const { app, ipcMain } = require("electron");
const { autoUpdater } = require("electron-updater");
const { CancellationToken } = require("builder-util-runtime");   // electron-updater's own dependency
const fs = require("node:fs");
const path = require("node:path");

const FIRST_CHECK_DELAY_MS = 10 * 1000;
const CHECK_EVERY_MS = 4 * 60 * 60 * 1000;      // 4 hours
const LATER_SNOOZE_MS = 24 * 60 * 60 * 1000;    // "Later" hides that version for a day
const STALL_MS = 2 * 60 * 1000;                  // no download progress for this long = stalled
const STALL_POLL_MS = 15 * 1000;
const APP_ORIGIN = "app://practice-manager";

let getWindow = () => null;
let state = { state: "idle", currentVersion: app.getVersion() };
let userInitiated = false;   // a manual check / download — errors are shown, not swallowed
let busy = false;
// The download in flight, if any: its cancellation token and when it last made
// progress. Set from the Download click until that download settles — while
// set, no second download or check starts.
let download = null;

// ---- small persisted prefs + log, both in the user-data folder ----------------
const prefsFile = () => path.join(app.getPath("userData"), "update-prefs.json");
function readPrefs() {
  try { return JSON.parse(fs.readFileSync(prefsFile(), "utf8")) || {}; } catch { return {}; }
}
function writePrefs(p) {
  try { fs.writeFileSync(prefsFile(), JSON.stringify(p, null, 2)); } catch (e) { log("prefs write failed", e.message); }
}
function log(...args) {
  const line = `[${new Date().toISOString()}] ${args.map(String).join(" ")}\n`;
  try {
    const dir = path.join(app.getPath("userData"), "logs");
    fs.mkdirSync(dir, { recursive: true });
    fs.appendFileSync(path.join(dir, "updater.log"), line);
  } catch { /* logging must never break the app */ }
}

// Release notes arrive as HTML (or a list of them); the renderer only ever
// shows plain text.
function notesToText(notes) {
  if (!notes) return "";
  const list = Array.isArray(notes) ? notes.map((n) => n && n.note) : [notes];
  return list.filter(Boolean).join("\n\n")
    .replace(/<\s*br\s*\/?>/gi, "\n").replace(/<\/(p|li|h\d|div)>/gi, "\n").replace(/<li[^>]*>/gi, "• ")
    .replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/g, " ").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'").replace(/&amp;/g, "&")
    .replace(/\n{3,}/g, "\n\n").trim().slice(0, 4000);
}

function send(next) {
  state = { ...state, ...next, currentVersion: app.getVersion() };
  const win = getWindow();
  if (win && !win.isDestroyed()) win.webContents.send("updater:status", state);
}

function snoozed(version) {
  const p = readPrefs();
  return p.laterVersion === version && Date.now() - (p.laterAt || 0) < LATER_SNOOZE_MS;
}

function isOffline(err) {
  return /ENOTFOUND|ECONNREFUSED|ECONNRESET|ETIMEDOUT|EAI_AGAIN|ERR_INTERNET_DISCONNECTED|ERR_NAME_NOT_RESOLVED|ERR_NETWORK_CHANGED|ERR_CONNECTION|net::/i
    .test(String(err && (err.code || err.message || err)));
}

async function check(manual) {
  if (busy || download || state.state === "downloading" || state.state === "downloaded") return state;
  userInitiated = !!manual;
  busy = true;
  try {
    await autoUpdater.checkForUpdates();
  } catch (err) {
    // the 'error' event already reported it
  } finally {
    busy = false;
  }
  return state;
}

function wire() {
  autoUpdater.autoDownload = false;
  autoUpdater.autoInstallOnAppQuit = false;     // install only on the user's Restart click
  autoUpdater.allowPrerelease = false;
  autoUpdater.allowDowngrade = false;
  autoUpdater.disableWebInstaller = true;       // we publish the full NSIS installer only
  autoUpdater.logger = { info: (m) => log("info", m), warn: (m) => log("warn", m), error: (m) => log("error", m), debug: () => {} };

  autoUpdater.on("checking-for-update", () => {
    if (userInitiated) send({ state: "checking" });
  });
  autoUpdater.on("update-available", (info) => {
    log("update available", info.version);
    const payload = {
      state: "available", version: info.version, releaseDate: info.releaseDate || "",
      releaseNotes: notesToText(info.releaseNotes), message: "",
    };
    if (!userInitiated && snoozed(info.version)) {
      state = { ...state, ...payload, snoozed: true };   // remembered, not shown
      return;
    }
    send({ ...payload, snoozed: false });
  });
  autoUpdater.on("update-not-available", (info) => {
    send({ state: "not-available", version: info && info.version, message: userInitiated ? "You're on the latest version." : "" });
  });
  autoUpdater.on("download-progress", (p) => {
    // A late event from a download already cancelled as stalled must not flip
    // the card back to "Downloading".
    if (!download || download.token.cancelled) return;
    download.lastProgressAt = Date.now();
    send({ state: "downloading", percent: Math.round(p.percent || 0), transferred: p.transferred, total: p.total, bytesPerSecond: p.bytesPerSecond });
  });
  autoUpdater.on("update-downloaded", (info) => {
    log("update downloaded", info.version);
    send({ state: "downloaded", version: info.version, percent: 100 });
  });
  // electron-updater writes every 'error' event to autoUpdater.logger itself,
  // so it is not logged again here.
  autoUpdater.on("error", (err) => {
    const wasDownloading = state.state === "downloading";
    // A repository with no releases yet simply means there is nothing newer.
    if (!wasDownloading && /No published versions/i.test(String(err && err.message))) {
      send({ state: "not-available", message: userInitiated ? "You're on the latest version." : "" });
      return;
    }
    // Background checks fail quietly (e.g. no internet); the next check retries.
    if (!userInitiated && !wasDownloading) { if (state.state === "checking") send({ state: "idle" }); return; }
    send({
      state: "error",
      message: isOffline(err)
        ? "Can't reach the update server — check your internet connection and try again."
        : wasDownloading ? "The update download failed. Please try again." : "Couldn't check for updates. Please try again later.",
      retry: wasDownloading ? "download" : "check",
    });
  });
}

function fromApp(event) {
  const url = (event.senderFrame && event.senderFrame.url) || "";
  return url.startsWith(APP_ORIGIN + "/");
}

function registerIpc() {
  const handle = (channel, fn) => ipcMain.handle(channel, (event, ...args) => {
    if (!fromApp(event)) throw new Error("Blocked");
    return fn(...args);
  });
  handle("updater:get-state", () => state);
  handle("updater:check", () => check(true));
  handle("updater:download", async () => {
    if (download) return state;   // one download at a time (incl. one still being cancelled)
    if (state.state !== "available" && !(state.state === "error" && state.retry === "download")) return state;
    userInitiated = true;
    const run = download = { token: new CancellationToken(), lastProgressAt: Date.now() };
    send({ state: "downloading", percent: 0, message: "" });
    // Stall watchdog: cancelling makes downloadUpdate() reject with a
    // CancellationError, which electron-updater does not report as 'error'
    // and which clears its in-progress download, so "Try again" starts afresh.
    const watchdog = setInterval(() => {
      if (run.token.cancelled || Date.now() - run.lastProgressAt < STALL_MS) return;
      log("warn", `download stalled — no progress for ${STALL_MS / 1000}s; cancelling`);
      run.token.cancel();
      send({ state: "error", message: "The update download stopped making progress. Check your connection and try again.", retry: "download" });
    }, STALL_POLL_MS);
    try {
      await autoUpdater.downloadUpdate(run.token);
    } catch { /* reported by 'error', or cancelled as stalled */ }
    finally {
      clearInterval(watchdog);
      download = null;
    }
    return state;
  });
  handle("updater:later", () => {
    if (state.version) writePrefs({ ...readPrefs(), laterVersion: state.version, laterAt: Date.now() });
    send({ state: "idle" });
    return state;
  });
  handle("updater:install", () => {
    if (state.state !== "downloaded") return state;
    log("installing", state.version);
    // isSilent=false shows the installer's progress; isForceRunAfter=true relaunches the app.
    setImmediate(() => autoUpdater.quitAndInstall(false, true));
    return state;
  });
}

function init(windowGetter) {
  getWindow = windowGetter;
  registerIpc();
  if (!app.isPackaged) {
    // Development run (npm run electron:dev): there is no installed version to update.
    state = { state: "disabled", currentVersion: app.getVersion(), message: "Updates are available in the installed app only." };
    return;
  }
  wire();
  setTimeout(() => check(false), FIRST_CHECK_DELAY_MS);
  setInterval(() => check(false), CHECK_EVERY_MS);
}

module.exports = { init };
