import { app, BrowserWindow, ipcMain } from 'electron';
import path from 'node:path';
import fs from 'node:fs';
import Database from 'better-sqlite3';

function writeReceipt(payload: unknown) {
  const target = process.env.QUAL_RUNTIME_RECEIPT;
  if (!target) return;
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, JSON.stringify(payload, null, 2) + '\n');
}

async function run() {
  const dbPath = path.join(app.getPath('temp'), `qual-${process.pid}.sqlite`);
  let win: BrowserWindow | null = null;
  try {
    const db = new Database(dbPath);
    db.pragma('foreign_keys = ON');
    db.exec('CREATE TABLE smoke(id INTEGER PRIMARY KEY, value TEXT NOT NULL) STRICT');
    db.prepare('INSERT INTO smoke(value) VALUES (?)').run('ok');
    const row = db.prepare('SELECT value FROM smoke WHERE id=1').get() as {value:string};
    const sqlite = (db.prepare('SELECT sqlite_version() AS v').get() as {v:string}).v;
    db.close();
    if (row.value !== 'ok') throw new Error('db smoke mismatch');

    win = new BrowserWindow({
      show: false,
      webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false }
    });
    const ready = new Promise<void>((resolve, reject) => {
      const t = setTimeout(() => reject(new Error('renderer ready timeout')), 20000);
      ipcMain.once('qualification-renderer-ready', () => { clearTimeout(t); resolve(); });
    });
    if (MAIN_WINDOW_VITE_DEV_SERVER_URL) await win.loadURL(MAIN_WINDOW_VITE_DEV_SERVER_URL);
    else await win.loadFile(path.join(__dirname, `../renderer/${MAIN_WINDOW_VITE_NAME}/index.html`));
    await ready;
    writeReceipt({
      result: 'PASS',
      phase: process.env.QUAL_PHASE || 'unknown',
      versions: process.versions,
      sqlite_version: sqlite,
      renderer_ready: true,
      native_binding_loaded: true
    });
    app.exit(0);
  } catch (e: any) {
    writeReceipt({ result:'FAIL', phase:process.env.QUAL_PHASE || 'unknown', error:String(e?.stack || e), versions:process.versions });
    app.exit(42);
  }
}
app.whenReady().then(run);
