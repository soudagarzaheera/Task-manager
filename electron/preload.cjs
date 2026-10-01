// Preload (sandboxed, context-isolated). The page gets exactly one object,
// window.desktopApp, with fixed update actions — no ipcRenderer, no Node, no
// arbitrary channels.

const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("desktopApp", Object.freeze({
  isDesktop: true,
  updates: Object.freeze({
    getState: () => ipcRenderer.invoke("updater:get-state"),
    check: () => ipcRenderer.invoke("updater:check"),
    download: () => ipcRenderer.invoke("updater:download"),
    later: () => ipcRenderer.invoke("updater:later"),
    install: () => ipcRenderer.invoke("updater:install"),
    // Returns an unsubscribe function. The listener only receives the status object.
    onStatus: (fn) => {
      if (typeof fn !== "function") return () => {};
      const listener = (_event, status) => fn(status);
      ipcRenderer.on("updater:status", listener);
      return () => ipcRenderer.removeListener("updater:status", listener);
    },
  }),
}));
