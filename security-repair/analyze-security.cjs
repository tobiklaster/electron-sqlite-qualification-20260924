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
const byName={rebuild:[],packager:[],tar:[],extractZip:[],internalExtractZip:[],tmp:[],externalEditor:[]};
for(const [pkgPath,meta] of Object.entries(lock.packages||{})){
  if(!pkgPath||meta.link) continue;
  const rec={path:pkgPath,version:meta.version||null,resolved:meta.resolved||null,integrity:meta.integrity||null,
    dependencies:meta.dependencies||null,optionalDependencies:meta.optionalDependencies||null,
    peerDependencies:meta.peerDependencies||null,dev:Boolean(meta.dev)};
  graph.push(rec);
  if(isPkg(pkgPath,'@electron/rebuild')) byName.rebuild.push(rec);
  if(isPkg(pkgPath,'@electron/packager')) byName.packager.push(rec);
  if(isPkg(pkgPath,'tar')) byName.tar.push(rec);
  if(isPkg(pkgPath,'extract-zip')) byName.extractZip.push(rec);
  if(isPkg(pkgPath,'@electron-internal/extract-zip')) byName.internalExtractZip.push(rec);
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
const tarRegistry=readJson(path.join(resultsDir,'tar-registry-metadata.json'));
const compatibility=readJson(path.join(resultsDir,'compatibility-preflight.json'));

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
const extractZipVersions=versions(byName.extractZip),internalExtractZipVersions=versions(byName.internalExtractZip),tmpVersions=versions(byName.tmp);
const overrides=packageJson.overrides||{};
const exactOverrides=overrides['@electron/rebuild']==='4.2.0'&&overrides['@electron/packager']==='20.3.0'&&overrides['external-editor']?.tmp==='0.2.7';

const checks={
  lockfile_v3:lock.lockfileVersion===3,
  exact_r3_overrides:exactOverrides,
  rebuild_exact_4_2_0:byName.rebuild.length>0&&byName.rebuild.every(x=>x.version==='4.2.0'),
  packager_exact_20_3_0:byName.packager.length>0&&byName.packager.every(x=>x.version==='20.3.0'),
  full_npm_ls_clean:fullStatus.exit_code===0&&(!fullLs.problems||fullLs.problems.length===0),
  focused_npm_ls_clean:focusedStatus.exit_code===0&&(!focusedLs.problems||focusedLs.problems.length===0),
  no_invalid_or_extraneous:fullStatus.exit_code===0,
  external_editor_tmp_exact_0_2_7:compatibility.external_editor_tmp?.version==='0.2.7',
  extract_zip_2_0_1_absent:!extractZipVersions.includes('2.0.1'),
  forge_packaging_path_no_vulnerable_extract_zip:compatibility.forge_packager?.version==='20.3.0'&&!extractZipVersions.includes('2.0.1'),
  replacement_extractor_proven:compatibility.replacement_extractor?.name==='@electron-internal/extract-zip'&&Boolean(compatibility.replacement_extractor?.version),
  engine_requirement_satisfied:compatibility.packager_engine?.satisfied===true,
  forge_resolves_packager_20_3_0:compatibility.forge_packager?.version==='20.3.0',
  no_high_or_critical:highCritical.length===0,
  sri_complete_for_registry_packages:sriMissing.length===0,
  tar_6_2_1_absent:!tarVersions.includes('6.2.1'),
  tar_registry_metadata_complete:tarVersions.every(v=>tarRegistry[v]?.version===v)
};
const result=Object.values(checks).every(Boolean)?'PASS':'HOLD';
const inventoryBytes=Buffer.from(JSON.stringify(advisoryInventory));
const out={
  schema:'ENGOS_PUBLIC_SYNTHETIC_TOOLCHAIN_SECURITY_PREFLIGHT_R3_V1',result,checks,host,compatibility,
  root_toolchain:expected,
  forced_overrides:{'@electron/rebuild':'4.2.0','@electron/packager':'20.3.0','external-editor':{tmp:'0.2.7'}},
  lock:{lockfileVersion:lock.lockfileVersion,packageCount:graph.length,raw_sha256:sha(lockBytes),
    normalized_graph_sha256:sha(graphBytes),sri_complete:sriMissing.length===0,sri_missing_paths:sriMissing},
  npm_ls:{full_exit_code:fullStatus.exit_code,full_problems:fullLs.problems||[],focused_exit_code:focusedStatus.exit_code,
    focused_problems:focusedLs.problems||[],rebuild_versions:rebuildVersions,rebuild_entries:byName.rebuild,
    packager_versions:packagerVersions,packager_entries:byName.packager,tar_versions:tarVersions,tar_entries:byName.tar,
    extract_zip_versions:extractZipVersions,extract_zip_entries:byName.extractZip,
    internal_extract_zip_versions:internalExtractZipVersions,internal_extract_zip_entries:byName.internalExtractZip,
    tmp_versions:tmpVersions,tmp_entries:byName.tmp,external_editor_entries:byName.externalEditor},
  audit:{raw_sha256:sha(fs.readFileSync(path.join(resultsDir,'npm-audit.json'))),metadata:audit.metadata||null,
    advisory_inventory_sha256:sha(inventoryBytes),advisory_inventory:advisoryInventory,high_or_critical:highCritical},
  tar_registry_metadata:tarRegistry,
  semantic_ceiling:'QUALIFICATION_EVIDENCE_ONLY__NO_BASELINE_ADOPTION'
};
fs.writeFileSync(path.join(resultsDir,'security-preflight.json'),JSON.stringify(out,null,2)+'\n');
fs.writeFileSync(path.join(resultsDir,'normalized-dependency-graph.json'),JSON.stringify(graph,null,2)+'\n');
fs.writeFileSync(path.join(resultsDir,'normalized-advisory-inventory.json'),JSON.stringify(advisoryInventory,null,2)+'\n');
console.log(JSON.stringify({result,rebuildVersions,packagerVersions,tarVersions,extractZipVersions,internalExtractZipVersions,tmpVersions,
  lockSha256:out.lock.raw_sha256,graphSha256:out.lock.normalized_graph_sha256,auditSha256:out.audit.raw_sha256,
  advisoryInventorySha256:out.audit.advisory_inventory_sha256,highCritical:highCritical.length,sriMissing:sriMissing.length,
  engineSatisfied:compatibility.packager_engine?.satisfied,forgePackager:compatibility.forge_packager?.version,
  replacementExtractor:compatibility.replacement_extractor}));
process.exit(result==='PASS'?0:42);
