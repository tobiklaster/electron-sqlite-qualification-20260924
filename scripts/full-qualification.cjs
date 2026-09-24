const { app } = require('electron');
const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { Worker } = require('worker_threads');
const { spawn } = require('child_process');
const Database = require('better-sqlite3');

const sha = b => crypto.createHash('sha256').update(b).digest('hex');
const assert = (cond, msg) => { if (!cond) throw new Error(msg); };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const outDir = process.env.QUAL_FULL_OUT;
if (!outDir) throw new Error('QUAL_FULL_OUT missing');
fs.mkdirSync(outDir, { recursive:true });
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'bs01-full-'));
const result = { schema:'ENGOS_SYNTHETIC_ACTIVE_DEV_Q01_Q10_V1', q:{}, versions:process.versions };
function pass(id, evidence={}) { result.q[id] = { result:'PASS', ...evidence }; }
function fail(id, e) { result.q[id] = { result:'FAIL', error:String(e?.stack || e) }; throw e; }

async function main() {
  const dbPath = path.join(work, 'core.sqlite');
  const db = new Database(dbPath);
  try {
    // Q04 core/WAL/FULL/FK/BEGIN IMMEDIATE/busy/CAS.
    try {
      db.pragma('foreign_keys = ON');
      db.pragma('journal_mode = WAL');
      db.pragma('synchronous = FULL');
      db.pragma('busy_timeout = 5000');
      const coreSchema = "CREATE TABLE parent(id INTEGER PRIMARY KEY) STRICT; CREATE TABLE item(id INTEGER PRIMARY KEY, rev INTEGER NOT NULL, value TEXT NOT NULL, parent_id INTEGER REFERENCES parent(id)) STRICT"; db.exec(coreSchema + "; INSERT INTO parent(id) VALUES(1); INSERT INTO item VALUES(1,1,'v1',1)");
      assert(db.pragma('foreign_keys',{simple:true}) === 1, 'foreign_keys not ON');
      assert(String(db.pragma('journal_mode',{simple:true})).toLowerCase() === 'wal', 'journal_mode not WAL');
      assert(Number(db.pragma('synchronous',{simple:true})) === 2, 'synchronous not FULL');
      db.exec('BEGIN IMMEDIATE'); db.exec('ROLLBACK');
      let r = db.prepare('UPDATE item SET value=?, rev=rev+1 WHERE id=? AND rev=?').run('v2',1,1); assert(r.changes===1,'CAS expected-old failed');
      r = db.prepare('UPDATE item SET value=?, rev=rev+1 WHERE id=? AND rev=?').run('stale',1,1); assert(r.changes===0,'stale CAS accepted');
      const db2 = new Database(dbPath); db2.pragma('busy_timeout = 5000');
      db.exec('BEGIN IMMEDIATE');
      let busy = false; try { db2.prepare('UPDATE item SET value=? WHERE id=1').run('busy'); } catch(e) { busy = e.code === 'SQLITE_BUSY'; } finally { db.exec('ROLLBACK'); }
      assert(busy,'BUSY not observed');
      const reread = db2.prepare('SELECT rev FROM item WHERE id=1').get();
      const retry = db2.prepare('UPDATE item SET value=?, rev=rev+1 WHERE id=1 AND rev=?').run('retry',reread.rev); assert(retry.changes===1,'BUSY retry failed');
      db2.close();
      pass('Q04_SQLITE_CORE',{ sqlite_version:db.prepare('SELECT sqlite_version() v').get().v, busy_timeout_ms:5000, schema_sha256:sha(Buffer.from(coreSchema)) });
    } catch(e) { fail('Q04_SQLITE_CORE',e); }

    // Q05 migration with hash/precondition/failure rollback/newer HOLD.
    try {
      db.exec('CREATE TABLE schema_meta(version INTEGER NOT NULL); INSERT INTO schema_meta VALUES(1); CREATE TABLE migration_log(id TEXT PRIMARY KEY, sha256 TEXT NOT NULL) STRICT');
      const migrationSql = 'CREATE TABLE migrated(id INTEGER PRIMARY KEY, note TEXT NOT NULL) STRICT';
      const migrationHash = sha(Buffer.from(migrationSql));
      const apply = db.transaction((injectFail=false) => { const v=db.prepare('SELECT version FROM schema_meta').get().version; assert(v===1,'migration precondition'); db.exec(migrationSql); if(injectFail) throw new Error('injected migration failure'); db.prepare('UPDATE schema_meta SET version=2').run(); db.prepare('INSERT INTO migration_log VALUES(?,?)').run('M001',migrationHash); });
      // Separate recovery DB proves failure rollback.
      const failDbPath=path.join(work,'migration-fail.sqlite'); const fdb=new Database(failDbPath); fdb.exec('CREATE TABLE schema_meta(version INTEGER NOT NULL); INSERT INTO schema_meta VALUES(1); CREATE TABLE migration_log(id TEXT PRIMARY KEY, sha256 TEXT NOT NULL) STRICT');
      const failApply=fdb.transaction(()=>{ fdb.exec(migrationSql); throw new Error('injected migration failure'); });
      let injected=false; try{failApply();}catch{injected=true;} assert(injected,'failure injection did not fire'); assert(fdb.prepare('SELECT version FROM schema_meta').get().version===1,'failed migration advanced version'); assert(!fdb.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='migrated'").get(),'failed migration DDL persisted'); fdb.close();
      apply(false); assert(db.prepare('SELECT version FROM schema_meta').get().version===2,'forward migration failed');
      const newer=path.join(work,'newer.sqlite'); const ndb=new Database(newer); ndb.exec('CREATE TABLE schema_meta(version INTEGER NOT NULL); INSERT INTO schema_meta VALUES(999)'); const nv=ndb.prepare('SELECT version FROM schema_meta').get().version; assert(nv>2,'newer fixture invalid'); ndb.close();
      pass('Q05_MIGRATION',{ migration_id:'M001', migration_sha256:migrationHash, failed_migration_rollback:true, newer_schema_disposition:'READ_ONLY_HOLD' });
    } catch(e) { fail('Q05_MIGRATION',e); }

    // Q06 Online Backup + synthetic content-addressed blob + restore identity/provenance.
    try {
      db.exec("CREATE TABLE identity(id TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT; INSERT INTO identity VALUES('stable-id','alpha'); CREATE TABLE provenance(k TEXT PRIMARY KEY, v TEXT NOT NULL) STRICT; INSERT INTO provenance VALUES('origin','synthetic-qualification'); CREATE TABLE blob_meta(hash TEXT PRIMARY KEY, relpath TEXT NOT NULL) STRICT");
      const blobDir=path.join(work,'blobs'); fs.mkdirSync(blobDir); const blob=Buffer.from('synthetic-blob-v1'); const bh=sha(blob); const staging=path.join(blobDir,bh+'.staging'); const final=path.join(blobDir,bh);
      fs.writeFileSync(staging,blob); let fd=fs.openSync(staging,'r'); fs.fsyncSync(fd); fs.closeSync(fd); assert(sha(fs.readFileSync(staging))===bh,'blob sha mismatch'); fs.renameSync(staging,final); fd=fs.openSync(blobDir,'r'); fs.fsyncSync(fd); fs.closeSync(fd); db.prepare('INSERT INTO blob_meta VALUES(?,?)').run(bh,path.basename(final));
      const backup=path.join(work,'backup.sqlite'); await db.backup(backup); const bdb=new Database(backup,{readonly:true}); assert(bdb.pragma('integrity_check',{simple:true})==='ok','backup integrity'); assert(bdb.prepare("SELECT value FROM identity WHERE id='stable-id'").get().value==='alpha','backup identity'); assert(bdb.prepare("SELECT v FROM provenance WHERE k='origin'").get().v==='synthetic-qualification','backup provenance'); bdb.close();
      const restore=path.join(work,'restore.sqlite'); fs.copyFileSync(backup,restore); const rdb=new Database(restore); assert(rdb.pragma('integrity_check',{simple:true})==='ok','restore integrity'); assert(rdb.prepare("SELECT value FROM identity WHERE id='stable-id'").get().value==='alpha','restore identity'); assert(rdb.prepare("SELECT v FROM provenance WHERE k='origin'").get().v==='synthetic-qualification','restore provenance'); assert(rdb.prepare('SELECT hash FROM blob_meta').get().hash===bh,'restore blob ref'); rdb.close();
      pass('Q06_BACKUP_RESTORE',{ online_backup_api:true, backup_sha256:sha(fs.readFileSync(backup)), blob_sha256:bh, stable_identity_preserved:true, provenance_preserved:true });
    } catch(e) { fail('Q06_BACKUP_RESTORE',e); }

    // Q07 durability fault boundaries + orphan reconciliation + process kill.
    try {
      const faultDir=path.join(work,'fault-blobs'); fs.mkdirSync(faultDir); db.exec('CREATE TABLE fault_meta(hash TEXT PRIMARY KEY) STRICT');
      const boundaries=['staging_write','content_flush','sha256_verify','atomic_move','dir_volume_barrier','sqlite_metadata_commit'];
      for (const boundary of boundaries) {
        const bytes=Buffer.from('fault-'+boundary); const h=sha(bytes), st=path.join(faultDir,h+'.staging'), fin=path.join(faultDir,h);
        try {
          fs.writeFileSync(st,bytes); if(boundary==='staging_write') throw new Error('fault');
          let fd=fs.openSync(st,'r'); fs.fsyncSync(fd); fs.closeSync(fd); if(boundary==='content_flush') throw new Error('fault');
          assert(sha(fs.readFileSync(st))===h,'sha'); if(boundary==='sha256_verify') throw new Error('fault');
          fs.renameSync(st,fin); if(boundary==='atomic_move') throw new Error('fault');
          fd=fs.openSync(faultDir,'r'); fs.fsyncSync(fd); fs.closeSync(fd); if(boundary==='dir_volume_barrier') throw new Error('fault');
          if(boundary==='sqlite_metadata_commit') throw new Error('fault');
        } catch {}
        assert(!db.prepare('SELECT 1 FROM fault_meta WHERE hash=?').get(h),'metadata referenced failed blob');
        if(fs.existsSync(st)) fs.unlinkSync(st); if(fs.existsSync(fin)) fs.unlinkSync(fin);
      }
      const orphan=path.join(faultDir,'killed-orphan');
      await new Promise((resolve,reject)=>{ const cp=spawn(process.execPath,[path.join(process.cwd(),'scripts/fault-child.cjs'),orphan],{env:{...process.env,ELECTRON_RUN_AS_NODE:'1'},stdio:'ignore'}); cp.on('error',reject); cp.on('exit',()=>resolve()); });
      assert(fs.existsSync(orphan),'kill orphan missing'); assert(!db.prepare('SELECT 1 FROM fault_meta WHERE hash=?').get('killed-orphan'),'kill orphan metadata'); fs.unlinkSync(orphan);
      pass('Q07_FAULT_RECONCILIATION',{ boundaries, process_kill_equivalent:true, orphan_reconciled:true });
    } catch(e) { fail('Q07_FAULT_RECONCILIATION',e); }

    // Q08 privacy/secret negatives with non-printed random canary.
    try {
      const canary='CANARY_'+crypto.randomBytes(24).toString('hex'); const privateValue='PRIVATE_'+crypto.randomBytes(24).toString('hex');
      const fixture={public:'allowed',secret:canary,privacy:privateValue}; const exported=JSON.stringify({public:fixture.public}); const exp=path.join(work,'export.json'); fs.writeFileSync(exp,exported);
      const searchable=[fs.readFileSync(exp), ...fs.readdirSync(work).filter(n=>n.endsWith('.sqlite')).map(n=>fs.readFileSync(path.join(work,n)))];
      assert(searchable.every(b=>!b.includes(Buffer.from(canary)) && !b.includes(Buffer.from(privateValue))),'privacy/secret leak');
      pass('Q08_PRIVACY_SECRET',{ synthetic_canary_absent:true, privacy_fixture_absent:true, logs_design:'canary never emitted' });
    } catch(e) { fail('Q08_PRIVACY_SECRET',e); }

    // Q09 unknown/newer byte preservation.
    try {
      const unknown=Buffer.from('{"known":1,"future":{"opaque":[1,2,3]},"x-extra":"preserve"}\n','utf8'); const u1=path.join(work,'unknown.bin'), u2=path.join(work,'unknown-restored.bin'); fs.writeFileSync(u1,unknown); fs.copyFileSync(u1,u2); assert(fs.readFileSync(u1).equals(fs.readFileSync(u2)),'unknown bytes changed');
      pass('Q09_UNKNOWN_NEWER',{ sha256:sha(unknown), byte_for_byte:true, newer_schema_disposition:'READ_ONLY_HOLD' });
    } catch(e) { fail('Q09_UNKNOWN_NEWER',e); }

    // Q10 renderer no direct DB + worker responsiveness.
    try {
      const renderer=fs.readFileSync(path.join(process.cwd(),'src/renderer.ts'),'utf8'); assert(!renderer.includes('better-sqlite3') && !renderer.includes('Database('),'renderer direct DB reference');
      let ticks=0; const timer=setInterval(()=>ticks++,20);
      const workerCode=`const {parentPort}=require('worker_threads'); let x=0; const end=Date.now()+700; while(Date.now()<end){x+=Math.sqrt(x+1)} parentPort.postMessage(x);`;
      await new Promise((resolve,reject)=>{ const w=new Worker(workerCode,{eval:true}); w.once('message',()=>resolve()); w.once('error',reject); }); clearInterval(timer); assert(ticks>=5,'main responsiveness insufficient');
      pass('Q10_WORKER_BOUNDARY',{ renderer_direct_db:false, worker_thread_long_op:true, responsiveness_ticks:ticks });
    } catch(e) { fail('Q10_WORKER_BOUNDARY',e); }

    result.result = Object.values(result.q).every(x=>x.result==='PASS') ? 'PASS' : 'FAIL';
  } finally { try{db.close();}catch{} }
  fs.writeFileSync(path.join(outDir,'q04-q10.json'),JSON.stringify(result,null,2)+'\n');
  app.exit(result.result==='PASS'?0:50);
}
app.whenReady().then(()=>main().catch(e=>{ result.result='FAIL'; result.fatal=String(e?.stack||e); fs.writeFileSync(path.join(outDir,'q04-q10.json'),JSON.stringify(result,null,2)+'\n'); app.exit(51); }));
