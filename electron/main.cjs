// Electron main process for the Practice Manager desktop app.
//
// The renderer is the same Vite build the website uses (dist/), served from a
// custom app:// scheme instead of file:// so the page gets a stable, secure
// origin (app://practice-manager). localStorage — where Supabase keeps the
// signed-in session — is tied to that origin and lives in the user-data folder
// (%APPDATA%\Practice Manager), which installs and updates never touch, so
// employees stay signed in across updates.
//
// Security: contextIsolation on, nodeIntegration off, sandboxed renderer, a
// preload that exposes only the update bridge, no navigation away from the
// app, and external links opened in the default browser.

const { app, BrowserWindow, protocol, net, session, shell, Menu } = require("electron");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const updater = require("./updater.cjs");

const SCHEME = "app";
const HOST = "practice-manager";
const APP_ORIGIN = `${SCHEME}://${HOST}`;
const DIST = path.join(__dirname, "..", "dist");

protocol.registerSchemesAsPrivileged([{
  scheme: SCHEME,
  privileges: { standard: true, secure: true, supportFetchAPI: true, corsEnabled: true, stream: true },
}]);

// One running copy only — a second launch focuses the existing window.
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  let win = null;

  app.on("second-instance", () => {
    if (!win) return;
    if (win.isMinimized()) win.restore();
    win.focus();
  });

  // Serve dist/ on app://practice-manager/. Anything outside dist/ is refused;
  // unknown paths fall back to index.html (single-page app).
  function serveDist() {
    protocol.handle(SCHEME, async (req) => {
      const url = new URL(req.url);
      if (url.host !== HOST) return new Response("Not found", { status: 404 });
      let rel = decodeURIComponent(url.pathname);
      if (rel === "/" || rel === "") rel = "/index.html";
      const file = path.normalize(path.join(DIST, rel));
      if (!file.startsWith(DIST + path.sep)) return new Response("Forbidden", { status: 403 });
      const res = await net.fetch(pathToFileURL(file).toString()).catch(() => null);
      if (res && res.ok) return res;
      return net.fetch(pathToFileURL(path.join(DIST, "index.html")).toString());
    });
  }

  function lockDownSession() {
    const ses = session.defaultSession;
    // Attendance punch-in needs the device location; nothing else is granted.
    ses.setPermissionRequestHandler((wc, permission, cb, details) => {
      const fromApp = (details.requestingUrl || "").startsWith(APP_ORIGIN + "/");
      cb(fromApp && permission === "geolocation");
    });
    ses.setPermissionCheckHandler((wc, permission, origin) =>
      origin === APP_ORIGIN && permission === "geolocation");
  }

  function createWindow() {
    win = new BrowserWindow({
      width: 1360,
      height: 860,
      minWidth: 900,
      minHeight: 600,
      show: false,
      backgroundColor: "#B1CB98",
      // Fyn icon: .ico on Windows (taskbar / title bar, all sizes), .png elsewhere
      icon: path.join(__dirname, "..", "build", process.platform === "win32" ? "icon.ico" : "icon.png"),
      webPreferences: {
        preload: path.join(__dirname, "preload.cjs"),
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
        webSecurity: true,
        spellcheck: true,
      },
    });

    // Stay inside the app; http(s) and mailto links open in the default browser.
    const isApp = (u) => u.startsWith(APP_ORIGIN + "/");
    const openOutside = (u) => {
      if (/^(https?:|mailto:)/i.test(u)) shell.openExternal(u);
    };
    win.webContents.setWindowOpenHandler(({ url }) => {
      if (!isApp(url)) openOutside(url);
      return { action: "deny" };
    });
    win.webContents.on("will-navigate", (e, url) => {
      if (isApp(url)) return;
      e.preventDefault();
      openOutside(url);
    });

    win.once("ready-to-show", () => win.show());
    win.on("closed", () => { win = null; });
    win.loadURL(APP_ORIGIN + "/index.html");
    return win;
  }

  app.whenReady().then(() => {
    // No menu bar on Windows (copy/paste shortcuts still work in text fields).
    if (process.platform !== "darwin") Menu.setApplicationMenu(null);
    serveDist();
    lockDownSession();
    createWindow();
    updater.init(() => win);
  });

  app.on("window-all-closed", () => app.quit());
}
