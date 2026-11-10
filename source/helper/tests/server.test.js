const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const crypto = require('node:crypto');
const { EventEmitter } = require('node:events');
const { createGalleryServer } = require('../gallery-helper');
const VERSION = 'ver_12345678';
const TARGET = 'ver_636b0ac227d23f7bf741';
const bytes = Buffer.from('verified package');
const sha = crypto.createHash('sha256').update(bytes).digest('hex');

async function fixture(t, options = {}) {
  assert.equal(typeof createGalleryServer, 'function', 'exports an injectable server factory');
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'gallery-test-'));
  const stateRoot = path.join(root, 'state');
  await fs.mkdir(path.join(root, 'app'), { recursive: true });
  for (const name of ['index.html', 'app.js', 'styles.css']) await fs.writeFile(path.join(root, 'app', name), name);
  let calls = [];
  let metadata = { id: VERSION, name: 'Test', packageBytes: bytes.length, packageSha256: sha, displayMeta: { platforms: ['windows'] } };
  const upstream = http.createServer((req, res) => {
    calls.push(req.url);
    if (req.url.endsWith('/download')) { res.end(options.package || bytes); return; }
    setTimeout(() => { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(req.url.startsWith('/v1/themes?') ? { items: [metadata] } : metadata)); }, 10);
  });
  await new Promise(resolve => upstream.listen(0, '127.0.0.1', resolve));
  const server = createGalleryServer({ root, stateRoot, upstream: 'http://127.0.0.1:' + upstream.address().port, ...options });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = 'http://127.0.0.1:' + server.address().port;
  t.after(async () => { await new Promise(r => server.close(r)); await new Promise(r => upstream.close(r)); await fs.rm(root, { recursive: true, force: true }); });
  const health = await (await fetch(base + '/api/health')).json();
  async function request(url, body, headers = {}) {
    const res = await fetch(base + url, body === undefined ? { headers } : { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Gallery-Token': health.token, Origin: base, ...headers }, body: JSON.stringify(body) });
    return { status: res.status, body: await res.json(), headers: res.headers };
  }
  async function saved(id = 'local-theme') {
    await fs.mkdir(path.join(stateRoot, 'themes', id), { recursive: true });
    await fs.writeFile(path.join(stateRoot, 'themes', id, 'theme.json'), JSON.stringify({ id, name: 'Local theme', appearance: 'dark', image: 'art.png' }));
    await fs.writeFile(path.join(stateRoot, 'themes', id, 'art.png'), Buffer.from([137,80,78,71]));
    return { id, name: 'Local theme' };
  }
  async function finish(job) {
    for (let i = 0; i < 100; i++) {
      const r = await request('/api/jobs/' + job.id);
      if (['success', 'error'].includes(r.body.status)) return r.body;
      await new Promise(r => setTimeout(r, 5));
    }
    throw new Error('job did not finish');
  }
  return { root, stateRoot, base, request, health, calls, saved, finish, setMetadata: value => { metadata = { ...metadata, ...value }; } };
}

test('health v2, same-origin protection and static whitelist', async t => {
  const f = await fixture(t);
  assert.deepEqual(Object.keys(f.health).sort(), ['ok', 'token', 'version']);
  assert.equal(f.health.version, 2);
  assert.match(f.health.token, /^[a-f0-9]{64}$/);
  assert.equal((await f.request('/api/health', undefined, { Origin: 'https://evil.test' })).status, 403);
  const hostStatus = await new Promise((resolve, reject) => {
    http.get(f.base + '/api/health', { headers: { Host: 'evil.test' } }, res => { res.resume(); resolve(res.statusCode); }).on('error', reject);
  });
  assert.equal(hostStatus, 403);
  assert.equal((await f.request('/api/apply', { themeId: 'local' }, { 'X-Gallery-Token': '' })).status, 403);
  assert.equal((await f.request('/api/apply', { themeId: 'local' }, { Origin: 'null' })).status, 403);
  const page = await fetch(f.base + '/');
  assert.equal(await page.text(), 'index.html');
  assert.match(page.headers.get('content-security-policy'), /script-src 'self'/);
  assert.ok(page.headers.get('content-security-policy').includes('https://api.dreamskin.cc'));
  assert.equal(page.headers.get('access-control-allow-origin'), null);
  assert.equal((await fetch(f.base + '/helper/gallery-helper.js')).status, 404);
  assert.equal((await fetch(f.base + '/app.js')).status, 200);
  assert.equal((await fetch(f.base + '/styles.css')).status, 200);
});

test('remote JSON normalizes query, coalesces requests and refreshes cache', async t => {
  const f = await fixture(t);
  await Promise.all([f.request('/api/themes?sort=latest&limit=99&q=hello'), f.request('/api/themes?sort=latest&limit=99&q=hello')]);
  assert.deepEqual(f.calls, ['/v1/themes?limit=24&offset=0&sort=recent&q=hello']);
  await f.request('/api/themes?sort=latest&limit=99&q=hello');
  assert.equal(f.calls.length, 1);
  await f.request('/api/themes?sort=latest&limit=99&q=hello&refresh=1');
  assert.equal(f.calls.length, 2);
  assert.equal((await f.request('/api/theme?versionId=' + VERSION)).body.id, VERSION);
  assert.equal((await f.request('/api/theme?versionId=../bad')).status, 400);
});

test('saved reads real files, active state and previews without remote access or stale cache', async t => {
  const f = await fixture(t);
  assert.deepEqual((await f.request('/api/saved')).body, { items: [], current: null, paused: false });
  const theme = await f.saved();
  await fs.mkdir(path.join(f.stateRoot, 'active-theme'), { recursive: true });
  await fs.writeFile(path.join(f.stateRoot, 'active-theme', 'theme.json'), '\uFEFF' + JSON.stringify(theme));
  await fs.writeFile(path.join(f.stateRoot, 'paused'), '');
  assert.deepEqual((await f.request('/api/saved')).body, { items: [{ ...theme, appearance: 'dark', current: true, imageUrl: '/preview?id=local-theme', sourceVersion: null, adapted: false }], current: theme, paused: true });
  assert.equal((await fetch(f.base + '/preview?id=local-theme')).status, 200);
  assert.equal((await fetch(f.base + '/preview?id=../escape')).status, 400);
  assert.equal(f.calls.length, 0);
});

test('install uses verified archive and authoritative saved result before mapping source', async t => {
  let f, captured;
  f = await fixture(t, { runEngine: async request => { captured = request; return { ok: true, theme: await f.saved(), message: 'saved' }; } });
  assert.deepEqual((await f.request('/api/jobs/latest')).body, { job: null });
  const started = await f.request('/api/install', { versionId: VERSION, adaptWindows: false });
  assert.equal(started.status, 202);
  const job = await f.finish(started.body);
  assert.equal(job.status, 'success');
  assert.equal(job.themeId, 'local-theme');
  assert.equal(captured.action, 'import');
  assert.equal(captured.expectedBytes, bytes.length);
  assert.equal(captured.expectedSha256, sha);
  assert.deepEqual(await fs.readFile(captured.archivePath), bytes);
  const item = (await f.request('/api/saved')).body.items[0];
  assert.equal(item.sourceVersion, VERSION);
  assert.equal(item.adapted, false);
  assert.equal((await f.request('/api/jobs/latest')).body.job.id, job.id);
});

test('same active request returns existing job and different work conflicts', async t => {
  let release, f;
  f = await fixture(t, { runEngine: async () => { await new Promise(r => { release = r; }); return { ok: true, theme: await f.saved() }; } });
  const a = await f.request('/api/install', { versionId: VERSION });
  const b = await f.request('/api/install', { versionId: VERSION });
  assert.equal(b.status, 202); assert.equal(b.body.id, a.body.id);
  assert.equal((await f.request('/api/install', { versionId: TARGET })).status, 409);
  while (!release) await new Promise(r => setTimeout(r, 5));
  assert.equal((await f.request('/api/jobs/' + a.body.id)).body.status, 'running');
  release(); assert.equal((await f.finish(a.body)).status, 'success');
});

for (const [name, change, packageBytes, message] of [
  ['platform', { displayMeta: { platforms: ['macos'] } }, bytes, /windows|platform/i],
  ['length', {}, Buffer.from('short'), /length|size|bytes/i],
  ['hash', { packageSha256: '0'.repeat(64) }, bytes, /hash|sha256/i]
]) test('install fails on ' + name + ' before engine invocation', async t => {
  let engines = 0;
  const f = await fixture(t, { package: packageBytes, runEngine: async () => { engines++; } });
  f.setMetadata(change);
  const job = await f.finish((await f.request('/api/install', { versionId: VERSION })).body);
  assert.equal(job.status, 'error'); assert.match(job.message, message); assert.equal(engines, 0);
});

test('adaptWindows restricted to approved target and recorded as local adaptation', async t => {
  let f;
  f = await fixture(t, { runEngine: async request => { assert.equal(request.adaptWindows, true); return { ok: true, theme: await f.saved('target-windows-local') }; } });
  assert.equal((await f.request('/api/install', { versionId: VERSION, adaptWindows: true })).status, 400);
  f.setMetadata({ id: TARGET, displayMeta: { platforms: ['macos'] } });
  assert.equal((await f.finish((await f.request('/api/install', { versionId: TARGET, adaptWindows: true })).body)).status, 'success');
  assert.equal((await f.request('/api/saved')).body.items[0].adapted, true);
});

for (const result of [undefined, { ok: false, message: 'engine rejected' }, { ok: true, theme: { id: 'missing', name: 'Missing' } }]) {
  test('engine missing, negative or unconfirmed result is an error: ' + JSON.stringify(result), async t => {
    const f = await fixture(t, { runEngine: async () => result });
    const job = await f.finish((await f.request('/api/install', { versionId: VERSION })).body);
    assert.equal(job.status, 'error');
    assert.deepEqual((await f.request('/api/saved')).body.items, []);
    await assert.rejects(fs.access(path.join(f.root, 'data', 'installed.json')));
  });
}

test('apply validates saved id and waits for engine result', async t => {
  let captured, f;
  f = await fixture(t, { runEngine: async request => { captured = request; return { ok: true, theme: { id: request.themeId, name: 'Local theme' } }; } });
  assert.equal((await f.request('/api/apply', { themeId: '../escape' })).status, 400);
  await f.saved();
  const job = await f.finish((await f.request('/api/apply', { themeId: 'local-theme' })).body);
  assert.equal(job.status, 'success'); assert.equal(captured.action, 'apply'); assert.equal(captured.themeId, 'local-theme');
});

test('default bridge hides PowerShell, writes contract and reads result only after exit', async t => {
  let f, spawnArgs;
  f = await fixture(t, { spawn: (exe, args, options) => {
    spawnArgs = { exe, args, options };
    const child = new EventEmitter();
    setImmediate(async () => {
      const request = JSON.parse(await fs.readFile(args[args.indexOf('-RequestPath') + 1], 'utf8'));
      assert.equal(request.action, 'import');
      const result = { ok: true, theme: await f.saved(), message: 'real bridge' };
      await fs.writeFile(args[args.indexOf('-ResultPath') + 1], JSON.stringify(result));
      child.emit('exit', 0);
    });
    return child;
  } });
  const job = await f.finish((await f.request('/api/install', { versionId: VERSION })).body);
  assert.equal(job.status, 'success'); assert.equal(spawnArgs.exe, 'powershell.exe');
  assert.deepEqual(spawnArgs.args.slice(0, 4), ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File']);
  assert.equal(spawnArgs.options.stdio, 'ignore'); assert.equal(spawnArgs.options.windowsHide, true);
  assert.equal(spawnArgs.args.at(-1), f.stateRoot);
});

test('open allowlist rejects other hosts and handles asynchronous spawn failure', async t => {
  const f = await fixture(t, { spawn: () => { const child = new EventEmitter(); setImmediate(() => child.emit('error', new Error('missing browser'))); return child; } });
  assert.equal((await f.request('/api/open?url=https://evil.test')).status, 403);
  assert.equal((await f.request('/api/open?url=' + encodeURIComponent('https://dreamskin.cc/gallery'))).status, 500);
});

test('malformed platform metadata cannot authorize Windows import', async t => {
  let called = false;
  const f = await fixture(t, { runEngine: async () => { called = true; return { ok: false, message: 'should not reach engine' }; } });
  f.setMetadata({ displayMeta: { platforms: 'windows' } });
  const job = await f.finish((await f.request('/api/install', { versionId: VERSION })).body);
  assert.equal(job.status, 'error');
  assert.equal(called, false);
});

test('unavailable upstream returns 502 and does not compromise offline saved list', async t => {
  const f = await fixture(t, { upstream: 'http://127.0.0.1:1' });
  assert.equal((await f.request('/api/themes')).status, 502);
  assert.equal((await f.request('/api/saved')).status, 200);
});

for (const mode of ['missing', 'false', 'nonzero', 'spawn-error']) test('default bridge fails on ' + mode, async t => {
  const f = await fixture(t, { spawn: (exe, args) => {
    const child = new EventEmitter();
    setImmediate(async () => {
      if (mode === 'spawn-error') { child.emit('error', new Error('powershell missing')); return; }
      if (mode === 'false') await fs.writeFile(args[args.indexOf('-ResultPath') + 1], JSON.stringify({ ok: false, message: 'worker rejected' }));
      child.emit('exit', mode === 'nonzero' ? 1 : 0);
    });
    return child;
  } });
  const job = await f.finish((await f.request('/api/install', { versionId: VERSION })).body);
  assert.equal(job.status, 'error');
});

test('default bridge cannot succeed merely because result exists before process exits', async t => {
  let f, exit, ready;
  const written = new Promise(r => { ready = r; });
  f = await fixture(t, { spawn: (exe, args) => {
    const child = new EventEmitter();
    exit = () => child.emit('exit', 0);
    setImmediate(async () => {
      await fs.writeFile(args[args.indexOf('-ResultPath') + 1], JSON.stringify({ ok: true, theme: await f.saved() }));
      ready();
    });
    return child;
  } });
  const job = (await f.request('/api/install', { versionId: VERSION })).body;
  await written;
  assert.equal((await f.request('/api/jobs/' + job.id)).body.status, 'running');
  exit();
  assert.equal((await f.finish(job)).status, 'success');
});

test('dotted engine theme IDs remain visible, previewable and applicable', async t => {
 let f; const id='guiming.ink.rainwashed-celadon-windows-local';
 f=await fixture(t,{runEngine:async()=>({ok:true,theme:await f.saved(id)})});
 const job=await f.finish((await f.request('/api/install',{versionId:VERSION})).body);
 assert.equal(job.status,'success',job.message);
 const saved=(await f.request('/api/saved')).body.items;
 assert.equal(saved[0].id,id);
 assert.equal((await fetch(f.base+'/preview?id='+id)).status,200);
 assert.equal((await f.finish((await f.request('/api/apply',{themeId:id})).body)).status,'success');
 for(const bad of ['CON','aux.txt','bad.','../outside']) assert.equal((await f.request('/api/apply',{themeId:bad})).status,400);
});
test('nonzero worker exit preserves its actionable result message',async t=>{
 const f=await fixture(t,{spawn:(exe,args)=>{const child=new EventEmitter();setImmediate(async()=>{await fs.writeFile(args[args.indexOf('-ResultPath')+1],JSON.stringify({ok:false,message:'Theme package does not support windows'}));child.emit('exit',1);});return child;}});
 const job=await f.finish((await f.request('/api/install',{versionId:VERSION})).body);
 assert.equal(job.status,'error');assert.match(job.message,/does not support windows/);
});
test('hung worker has a deadline and remains locked until process tree exits',async t=>{
 let child,finishKill,killCalled=false;
 const f=await fixture(t,{engineTimeoutMs:20,spawn:(exe,args)=>{
  if(exe==='taskkill.exe'){killCalled=true;const killer=new EventEmitter();finishKill=()=>{child.emit('exit',1);killer.emit('exit',0);};return killer;}
  child=new EventEmitter();child.pid=98765;return child;
 }});
 const job=(await f.request('/api/install',{versionId:VERSION})).body;
 t.after(()=>finishKill?.());
 for(let i=0;i<100 && !killCalled;i++)await new Promise(r=>setTimeout(r,5));
 assert.equal(killCalled,true,'deadline must terminate hung worker tree');
 assert.equal((await f.request('/api/install',{versionId:TARGET})).status,409);
 finishKill();const done=await f.finish(job);assert.equal(done.status,'error');assert.match(done.message,/timeout|timed out/i);
});
test('successful termination releases lock when worker exits before taskkill exits',async t=>{
 let child;
 const f=await fixture(t,{engineTimeoutMs:10,killRetryDelayMs:5,killTimeoutMs:100,exitWaitMs:200,spawn:(exe)=>{
  if(exe==='taskkill.exe'){const k=new EventEmitter();setTimeout(()=>k.emit('exit',0),40);return k;}
  child=new EventEmitter();child.pid=99001;setTimeout(()=>child.emit('exit',1),20);return child;
 }});
 const job=(await f.request('/api/install',{versionId:VERSION})).body;
 const done=await f.finish(job);
 assert.equal(done.status,'error');
 assert.match(done.message,/timeout/i);
 assert.doesNotMatch(done.message,/unconfirmed/);
 assert.notEqual((await f.request('/api/install',{versionId:TARGET})).status,409,'successful termination must release the lock');
});
test('successful termination releases lock when taskkill exits before worker exits',async t=>{
 let child;
 const f=await fixture(t,{engineTimeoutMs:10,killRetryDelayMs:5,killTimeoutMs:100,exitWaitMs:200,spawn:(exe)=>{
  if(exe==='taskkill.exe'){const k=new EventEmitter();setTimeout(()=>k.emit('exit',0),20);return k;}
  child=new EventEmitter();child.pid=99002;setTimeout(()=>child.emit('exit',1),40);return child;
 }});
 const job=(await f.request('/api/install',{versionId:VERSION})).body;
 const done=await f.finish(job);
 assert.equal(done.status,'error');
 assert.match(done.message,/timeout/i);
 assert.doesNotMatch(done.message,/unconfirmed/);
 assert.notEqual((await f.request('/api/install',{versionId:TARGET})).status,409);
});
test('unconfirmed tree termination keeps writes locked with accurate recovery guidance',async t=>{
 let child,killCount=0;
 const f=await fixture(t,{engineTimeoutMs:10,killRetryDelayMs:5,killTimeoutMs:50,exitWaitMs:50,spawn:(exe)=>{
  if(exe==='taskkill.exe'){killCount++;const k=new EventEmitter();setImmediate(()=>k.emit('exit',1));return k;}
  child=new EventEmitter();child.pid=98766;child.kill=()=>{};return child;
 }});
 const job=(await f.request('/api/install',{versionId:VERSION})).body;
 const done=await f.finish(job);
 assert.equal(done.status,'error');
 assert.match(done.message,/unconfirmed/);
 assert.match(done.message,/重启|本地服务/,'recovery guidance must be accurate and actionable');
 assert.ok(killCount>=2,'tree termination must be retried before giving up');
 assert.equal((await f.request('/api/install',{versionId:TARGET})).status,409);
 assert.equal((await f.request('/api/install',{versionId:VERSION})).status,409);
});
test('maintenance latch blocks new write tasks until cleared',async t=>{
 let f; f=await fixture(t,{runEngine:async()=>({ok:true,theme:await f.saved()})});
 assert.equal((await f.request('/api/maintenance',{enabled:true},{'X-Gallery-Token':''})).status,403);
 assert.equal((await f.request('/api/maintenance',{enabled:'yes'})).status,400);
 const on=await f.request('/api/maintenance',{enabled:true});
 assert.equal(on.status,200);assert.equal(on.body.maintenance,true);
 assert.equal((await f.request('/api/install',{versionId:VERSION})).status,503);
 assert.equal((await f.request('/api/apply',{themeId:'local-theme'})).status,503);
 const off=await f.request('/api/maintenance',{enabled:false});
 assert.equal(off.body.maintenance,false);
 const resumed=await f.finish((await f.request('/api/install',{versionId:VERSION})).body);
 assert.equal(resumed.status,'success',resumed.message);
});

