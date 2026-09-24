import { contextBridge, ipcRenderer } from 'electron';
contextBridge.exposeInMainWorld('qualification', {
  ready: () => ipcRenderer.send('qualification-renderer-ready')
});
