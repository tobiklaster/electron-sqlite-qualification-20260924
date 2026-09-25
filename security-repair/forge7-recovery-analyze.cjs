const fs=require('fs');
const path=require('path');
const crypto=require('crypto');

const [resultsDir]=process.argv.slice(2);
if(!resultsDir) throw new Error('resultsDir required');
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const readJson=p=>JSON.parse(fs.readFileSync(p,'utf8'));
const isPkg=(p,name)=>p==='node_modules/'+name||p.endsWith('/node_modules/'+name);

const packageJson=readJson('package.json');
const lockBytes=fs.readFileSync('package-lock.json');
const lock=JSON.parse(lockBytes.toString('utf8'));
if(lock.lockfileVersion!==3) throw new Error('lockfileVersion must be 3');
const root=lock.packages?.[''];
if(!root) throw new Error('lock root missing');

const expected={
  dependencies:{react:'19.3.0','react-dom':'19.3.0','better-sqlite3':'13.0.3'},
  devDependencies:{electron:'44.4.4','@electron-forge/cli':'7.11.2','@electron-forge/plugin-vite':'7.11.2',vite:'8.3.1',typescript:'7.0.2'}
};
for(const [group,deps] of Object.entries(expected)){
  for(const [name,version] of Object.entries(deps)){
    if(root[group]?.[name]!==version) throw new Error(`root ${group}.${name} != ${version}`);
  }
}

const graph=[],sriMissing=[];
const byName={rebuild:[],packager:[],tar:[],extractZipPath:[],internalExtractZipPath:[],tmp:[],externalEditor:[]};
for(const [pkgPath,meta] of Object.entries(lock.packages||{})){
  if(!pkgPath||meta.link) continue;
  const rec={path:pkgPath,name:meta.name||null,version:meta.version||null,resolved:meta.resolved||null,integrity:meta.integrity||null,
    dependencies:meta.dependencies||null,optionalDependencies:meta.optionalDependencies||null,
    peerDependencies:meta.peerDependencies||null,engines:meta.engines||null,dev:Boolean(meta.dev)};
  graph.push(rec);
  if(isPkg(pkgPath,'@electron/rebuild')) byName.rebuild.push(rec);
  if(isPkg(pkgPath,'@electron/packager')) byName.packager.push(rec);
  if(isPkg(pkgPath,'tar')) byName.tar.push(rec);
  if(isPkg(pkgPath,'extract-zip')) byName.extractZipPath.push(rec);
  if(isPkg(pkgPath,'@electron-internal/extract-zip')) byName.internalExtractZipPath.push(rec);
  if(isPkg(pkgPath,'tmp')) byName.tmp.push(rec);
  if(isPkg(pkgPath,'external-editor')) byName.externalEditor.push(rec);
  if(typeof meta.resolved==='string'&&/^https:\/\/registry\.npmjs\.(org|com)\//.test(meta.resolved)&&!meta.integrity) sriMissing.push(pkgPath);
}
graph.sort((a,b)=>a.path.localeCompare(b.path));
for(const list of Object.values(byName)) list.sort((a,b)=>a.path.localeCompare(b.path));
const graphBytes=Buffer.from(JSON.stringify(graph));

const fullLs=readJson(path.join(resultsDir,'npm-ls-full.json'));
const fullStatus=readJson(path.join(resultsDir,'npm-ls-full-status.json'));
const focusedLs=readJson(path.join(resultsDir,'npm-ls-focused.json'));
const focusedStatus=readJson(path.join(resultsDir,'npm-ls-focused-status.json'));
const audit=readJson(path.join(resultsDir,'npm-audit.json'));
const host=readJson(path.join(resultsDir,'host-identity.json'));
const resolution=readJson(path.join(resultsDir,'resolution-preflight.json'));
const tarRegistry=readJson(path.join(resultsDir,'tar-registry-metadata.json'));

const vulnerabilities=audit.vulnerabilities||{};
const advisoryInventory=Object.entries(vulnerabilities).map(([name,v])=>({
  name,severity:v.severity||null,isDirect:Boolean(v.isDirect),
  via:Array.isArray(v.via)?v.via.map(x=>typeof x==='string'?x:{
    source:x.source??null,name:x.name??null,dependency:x.dependency??null,title:x.title??null,
    url:x.url??null,severity:x.severity??null,range:x.range??null
  }):[],effects:v.effects||[],range:v.range||null,nodes:v.nodes||[],fixAvailable:v.fixAvailable??null
})).sort((a,b)=>a.name.localeCompare(b.name));
const highCritical=advisoryInventory.filter(v=>['high','critical'].includes(String(v.severity).toLowerCase()));
const versions=list=>[...new Set(list.map(x=>x.version))].sort();
const rebuildVersions=versions(byName.rebuild),packagerVersions=versions(byName.packager),tarVersions=versions(byName.tar);
const extractZipPathVersions=versions(byName.extractZipPath),internalExtractZipPathVersions=versions(byName.internalExtractZipPath);
const tmpVersions=versions(byName.tmp);

const ov=packageJson.overrides||{};
const exactOverrides=
  ov['@electron/rebuild']==='4.2.0' &&
  ov['@electron/packager']?.['.']==='18.4.4' &&
  ov['@electron/packager']?.['extract-zip']==='npm:@electron-internal/extract-zip@1.0.5' &&
  ov['external-editor']?.tmp==='0.2.7';

const vulnerableExtractZipResolved=graph.filter(x=>
  x.version==='2.0.1' &&
  (
    isPkg(x.path,'extract-zip') ||
    (typeof x.resolved==='string' && /(?:^|\/)extract-zip\/-\/extract-zip-2\.0\.1\.tgz(?:$|\?)/.test(x.resolved))
  )
);

const checks={
  lockfile_v3:lock.lockfileVersion===3,
  exact_recovery_overrides:exactOverrides,
  rebuild_exact_4_2_0:byName.rebuild.length>0&&byName.rebuild.every(x=>x.version==='4.2.0'),
  packager_exact_18_4_4:byName.packager.length>0&&byName.packager.every(x=>x.version==='18.4.4'),
  forge_declares_packager_caret_18_3_5:resolution.forge_core?.declared_packager_range==='^18.3.5',
  forge_resolves_packager_18_4_4:resolution.forge_packager?.version==='18.4.4',
  packager_declares_extract_zip_caret_2_0_0:resolution.installed_packager?.declared_extract_zip_range==='^2.0.0',
  scoped_alias_identity_exact:resolution.packager_extract_zip?.underlying_name==='@electron-internal/extract-zip'&&resolution.packager_extract_zip?.underlying_version==='1.0.5',
  scoped_alias_node_engine_satisfied:resolution.packager_extract_zip?.engine_satisfied===true,
  host_require_module_supported:resolution.host?.require_module===true,
  full_npm_ls_clean:fullStatus.exit_code===0&&(!fullLs.problems||fullLs.problems.length===0),
  focused_npm_ls_clean:focusedStatus.exit_code===0&&(!focusedLs.problems||focusedLs.problems.length===0),
  no_invalid_or_extraneous:fullStatus.exit_code===0,
  external_editor_tmp_exact_0_2_7:resolution.external_editor_tmp?.version==='0.2.7',
  vulnerable_extract_zip_2_0_1_absent:vulnerableExtractZipResolved.length===0,
  no_high_or_critical:highCritical.length===0,
  sri_complete_for_registry_packages:sriMissing.length===0,
  tar_6_2_1_absent:!tarVersions.includes('6.2.1'),
  tar_registry_metadata_complete:tarVersions.every(v=>tarRegistry[v]?.version===v)
};

const result=Object.values(checks).every(Boolean)?'PASS':'HOLD';
const inventoryBytes=Buffer.from(JSON.stringify(advisoryInventory));
const out={
  schema:'ENGOS_PUBLIC_SYNTHETIC_FORGE7_DECLARED_RANGE_SECURITY_PREFLIGHT_V1',
  result,checks,host,resolution,
  root_toolchain:expected,
  forced_overrides:{
    '@electron/rebuild':'4.2.0',
    '@electron/packager':{'.':'18.4.4','extract-zip':'npm:@electron-internal/extract-zip@1.0.5'},
    'external-editor':{tmp:'0.2.7'}
  },
  lock:{lockfileVersion:lock.lockfileVersion,packageCount:graph.length,raw_sha256:sha(lockBytes),
    normalized_graph_sha256:sha(graphBytes),sri_complete:sriMissing.length===0,sri_missing_paths:sriMissing},
  npm_ls:{full_exit_code:fullStatus.exit_code,full_problems:fullLs.problems||[],focused_exit_code:focusedStatus.exit_code,
    focused_problems:focusedLs.problems||[],rebuild_versions:rebuildVersions,rebuild_entries:byName.rebuild,
    packager_versions:packagerVersions,packager_entries:byName.packager,tar_versions:tarVersions,tar_entries:byName.tar,
    extract_zip_path_versions:extractZipPathVersions,extract_zip_path_entries:byName.extractZipPath,
    internal_extract_zip_path_versions:internalExtractZipPathVersions,internal_extract_zip_path_entries:byName.internalExtractZipPath,
    tmp_versions:tmpVersions,tmp_entries:byName.tmp,external_editor_entries:byName.externalEditor},
  vulnerable_extract_zip_2_0_1_entries:vulnerableExtractZipResolved,
  audit:{raw_sha256:sha(fs.readFileSync(path.join(resultsDir,'npm-audit.json'))),metadata:audit.metadata||null,
    advisory_inventory_sha256:sha(inventoryBytes),advisory_inventory:advisoryInventory,high_or_critical:highCritical},
  tar_registry_metadata:tarRegistry,
  semantic_ceiling:'QUALIFICATION_EVIDENCE_ONLY__NO_BASELINE_ADOPTION'
};
fs.writeFileSync(path.join(resultsDir,'security-preflight.json'),JSON.stringify(out,null,2)+'\n');
fs.writeFileSync(path.join(resultsDir,'normalized-dependency-graph.json'),JSON.stringify(graph,null,2)+'\n');
fs.writeFileSync(path.join(resultsDir,'normalized-advisory-inventory.json'),JSON.stringify(advisoryInventory,null,2)+'\n');
console.log(JSON.stringify({result,rebuildVersions,packagerVersions,tarVersions,extractZipPathVersions,internalExtractZipPathVersions,tmpVersions,
  lockSha256:out.lock.raw_sha256,graphSha256:out.lock.normalized_graph_sha256,auditSha256:out.audit.raw_sha256,
  advisoryInventorySha256:out.audit.advisory_inventory_sha256,highCritical:highCritical.length,sriMissing:sriMissing.length,
  forgePackager:resolution.forge_packager?.version,alias:resolution.packager_extract_zip}));
process.exit(result==='PASS'?0:42);
