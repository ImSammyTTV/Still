const { contextBridge, ipcRenderer, webUtils } = require('electron');

const listen = (channel, callback) => {
  const handler = (_event, ...args) => callback(...args);
  ipcRenderer.on(channel, handler);
  return () => ipcRenderer.removeListener(channel, handler);
};

contextBridge.exposeInMainWorld('still', {
  platform: process.platform,
  invoke: (channel, ...args) => ipcRenderer.invoke(channel, ...args),
  send: (channel, ...args) => ipcRenderer.send(channel, ...args),
  on: listen,
  pathForFile: (file) => webUtils.getPathForFile(file),
  fileUrl: (file) => `file://${file.replace(/\\/g, '/').replace(/^([A-Za-z]):/, '/$1:').split('/').map(encodeURIComponent).join('/').replace(/%3A/g, ':')}`
});
