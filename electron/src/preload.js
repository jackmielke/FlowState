'use strict';
const { contextBridge, ipcRenderer } = require('electron');

// The ONLY surface the renderer gets. Note what is absent: the sk-proj key.
contextBridge.exposeInMainWorld('vv', {
  bootstrap: () => ipcRenderer.invoke('vv:bootstrap'),

  // Returns { ok, value: 'ek_...', expiresAt, redacted } — ephemeral only.
  mintToken: (model) => ipcRenderer.invoke('vv:mint', model),

  capture: (opts) => ipcRenderer.invoke('vv:capture', opts),
  screenPermission: () => ipcRenderer.invoke('vv:screenPermission'),
  openScreenPrefs: () => ipcRenderer.invoke('vv:openScreenPrefs'),
  askMic: () => ipcRenderer.invoke('vv:askMic'),

  getSettings: () => ipcRenderer.invoke('vv:getSettings'),
  setSettings: (patch) => ipcRenderer.invoke('vv:setSettings', patch),

  log: (scope, msg) => ipcRenderer.send('vv:log', String(scope), String(msg)),

  onHotkeyScreenshot: (fn) => {
    const h = () => fn();
    ipcRenderer.on('vv:hotkey-screenshot', h);
    return () => ipcRenderer.removeListener('vv:hotkey-screenshot', h);
  },
});
