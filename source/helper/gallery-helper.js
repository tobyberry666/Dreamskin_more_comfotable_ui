// Codex 皮肤廊 · 同源本地服务 (Node 22+, no dependencies)
'use strict';
const http = require('node:http');
const https = require('node:https');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const childProcess = require('node:child_process');

const PORT = 9336;
const UPSTREAM = 'https://api.dreamskin.cc';
const ADAPTABLE_VERSION = 'ver_636b0ac227d23f7bf741';
const VERSION_ID = /^ver_[a-z0-9]{8,64}$/;
const THEME_ID = /^(?!(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:[.]|$))(?!.*[.]$)[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$/i;
const SORTS = { latest: 'recent', recent: 'recent', popular: 'popular', favorites: 'favorites' };
const CSP = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' https://api.dreamskin.cc; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'";

function fail(status, message) { return Object.assign(new Error(message), { status }); }
function clampInt(value, fallback, min, max) {
  const n = parseInt(value, 10);
  return Number.isNaN(n) ? fallback : Math.max(min, Math.min(max, n));
}
function buildUpstreamPath(query) {
  const parts = ['limit=' + clampInt(query.get('limit'), 12, 1, 24),
    'offset=' + clampInt(query.get('offset'), 0, 0, 5000),
    'sort=' + (SORTS[query.get('sort') || 'latest'] || 'recent')];
  const q = String(query.get('q') || '').trim().slice(0, 60);
  if (q) parts.push('q=' + encodeURIComponent(q));
  return '/v1/themes?' + parts.join('&');
}
function send(res, status, body, type) {
  res.writeHead(status, { 'Content-Type': type || 'application/json; charset=utf-8',
    'Cache-Control': 'no-store', 'Content-Security-Policy': CSP,
    'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer' });
  res.end(type ? body : JSON.stringify(body));
}
function parseJson(text) { return JSON.parse(text.replace(/^﻿/, '')); }
async function optionalJson(file, fallback) {
  try { return parseJson(await fs.readFile(file, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return fallback; throw error; }
}
async function exists(file) {
  try { await fs.access(file); return true; }
  catch (error) { if (error.code === 'ENOENT') return false; throw error; }
}
async function inside(base, file) {
  const [realBase, realFile] = await Promise.all([fs.realpath(base), fs.realpath(file)]);
  const relative = path.relative(realBase, realFile);
  if (!relative || relative === '..' || relative.startsWith('..' + path.sep) || path.isAbsolute(relative)) throw fail(400, 'unsafe_path');
  return realFile;
}
function requestBytes(url, maxBytes, timeoutMs) {
  return new Promise((resolve, reject) => {
    const transport = url.protocol === 'https:' ? https : http;
    const req = transport.get(url, { headers: { Accept: '*/*', 'User-Agent': 'CodexSkinGallery/2.0' } }, res => {
      if (res.statusCode !== 200) { res.resume(); reject(fail(502, 'upstream_http_' + res.statusCode)); return; }
      if (Number(res.headers['content-length']) > maxBytes) { res.destroy(); reject(fail(502, 'package_bytes_limit')); return; }
      let size = 0;
      const chunks = [];
      res.on('data', chunk => {
        size += chunk.length;
        if (size > maxBytes) { res.destroy(fail(502, 'package_bytes_limit')); return; }
        chunks.push(chunk);
      });
      res.on('end', () => resolve(Buffer.concat(chunks)));
      res.on('error', reject);
    });
    const deadline = setTimeout(() => req.destroy(fail(502, 'upstream_timeout')), timeoutMs);
    req.on('close', () => clearTimeout(deadline));
    req.on('error', reject);
  });
}
async function readBody(req) {
  if ((req.headers['content-type'] || '').split(';')[0].trim().toLowerCase() !== 'application/json') throw fail(415, 'json_required');
  const chunks = []; let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > 8192) throw fail(413, 'body_too_large');
    chunks.push(chunk);
  }
  try {
    const value = parseJson(Buffer.concat(chunks).toString('utf8'));
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error();
    return value;
  } catch { throw fail(400, 'invalid_json'); }
}

function createGalleryServer(options = {}) {
  const root = path.resolve(options.root || path.join(__dirname, '..'));
  const stateRoot = path.resolve(options.stateRoot || path.join(process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local'), 'CodexDreamSkin'));
  const themesRoot = path.join(stateRoot, 'themes');
  const dataRoot = path.join(root, 'data');
  const jobsRoot = path.join(dataRoot, 'jobs');
  const mappingPath = path.join(dataRoot, 'installed.json');
  const upstream = new URL(options.upstream || UPSTREAM);
  const spawn = options.spawn || childProcess.spawn;
  const token = crypto.randomBytes(32).toString('hex');
  const cache = new Map(); const inflight = new Map(); const jobs = new Map();
  let latest = null; let active = null; let activeKey = null; let maintenance = false;

  async function remoteJson(route, refresh = false) {
    if (inflight.has(route)) return inflight.get(route);
    const cached = cache.get(route);
    if (!refresh && cached && cached.expires > Date.now()) return cached.value;
    const promise = (async () => {
      let bytes;
      try { bytes = await requestBytes(new URL(route, upstream), 2 * 1024 * 1024, 15000); }
      catch (error) { throw error.status ? error : fail(502, 'upstream_unreachable'); }
      let value;
      try { value = parseJson(bytes.toString('utf8')); } catch { throw fail(502, 'upstream_invalid_json'); }
      // Bound memory even when searches produce distinct URLs.
      if (cache.size >= 128) cache.delete(cache.keys().next().value);
      cache.set(route, { value, expires: Date.now() + 30000 });
      return value;
    })();
    inflight.set(route, promise);
    try { return await promise; } finally { inflight.delete(route); }
  }
  async function savedTheme(id) {
    if (!THEME_ID.test(id)) throw fail(400, 'invalid_theme_id');
    const directory = await inside(themesRoot, path.join(themesRoot, id));
    const file = await inside(directory, path.join(directory, 'theme.json'));
    const theme = parseJson(await fs.readFile(file, 'utf8'));
    if (theme.id !== id || typeof theme.name !== 'string' || !theme.name) throw fail(400, 'invalid_saved_theme');
    return { theme, directory };
  }
  async function savedList() {
    const [currentTheme, mapping, paused] = await Promise.all([
      optionalJson(path.join(stateRoot, 'active-theme', 'theme.json'), null),
      optionalJson(mappingPath, {}), exists(path.join(stateRoot, 'paused'))]);
    const current = currentTheme && typeof currentTheme.id === 'string' && typeof currentTheme.name === 'string'
      ? { id: currentTheme.id, name: currentTheme.name } : null;
    let entries;
    try { entries = await fs.readdir(themesRoot, { withFileTypes: true }); }
    catch (error) { if (error.code !== 'ENOENT') throw error; entries = []; }
    const items = (await Promise.all(entries.filter(entry => entry.isDirectory() && THEME_ID.test(entry.name)).map(async entry => {
      try {
        const { theme } = await savedTheme(entry.name);
        const source = Object.hasOwn(mapping, theme.id) ? mapping[theme.id] : null;
        return { id: theme.id, name: theme.name, appearance: theme.appearance || null,
          current: !!current && current.id === theme.id, imageUrl: theme.image ? '/preview?id=' + encodeURIComponent(theme.id) : null,
          sourceVersion: source?.sourceVersion || null, adapted: source?.adapted === true };
      } catch (error) {
        if (error.code === 'ENOENT' || error instanceof SyntaxError || error.status === 400) return null;
        throw error;
      }
    }))).filter(Boolean).sort((a, b) => a.name.localeCompare(b.name));
    return { items, current, paused };
  }
  function runTaskkill(pid, timeoutMs) {
    // Bounded taskkill: a hung taskkill is a failure, not an indefinite wait.
    return new Promise(resolve => {
      let settled = false; let handle = null;
      const finish = code => { if (!settled) { settled = true; if (handle) clearTimeout(handle); resolve(code); } };
      let killer;
      try { killer = spawn('taskkill.exe', ['/PID', String(pid), '/T', '/F'], {stdio:'ignore', windowsHide:true}); }
      catch { finish(null); return; }
      killer.once('error', () => finish(null));
      killer.once('exit', code => finish(code));
      handle = setTimeout(() => { if (!settled) { try { killer.kill?.(); } catch {} finish(null); } }, timeoutMs);
    });
  }
  async function terminateTree(child) {
    // Confirm the whole tree is gone; a nonzero or missing taskkill exit is not proof of termination.
    const pid = child.pid;
    if (!Number.isInteger(pid) || pid <= 0) { try { child.kill?.('SIGTERM'); } catch {} return { confirmed: false, attempts: [] }; }
    const timeoutMs = options.killTimeoutMs ?? 10000;
    const attempts = [];
    for (let attempt = 1; attempt <= 2; attempt++) {
      const code = await runTaskkill(pid, timeoutMs);
      attempts.push(code);
      if (code === 0) return { confirmed: true, attempts };
      if (attempt === 1) await new Promise(r => setTimeout(r, options.killRetryDelayMs ?? 1000));
    }
    try { child.kill?.('SIGTERM'); } catch {}
    return { confirmed: false, attempts };
  }
  async function waitExitBounded(exitPromise, ms) {
    let timer = null;
    const timeout = new Promise(resolve => { timer = setTimeout(() => resolve(false), ms); });
    const settled = await Promise.race([exitPromise.then(() => true, () => true), timeout]);
    if (timer) clearTimeout(timer);
    return settled;
  }
  async function defaultRunEngine(request, context) {
    const requestPath = path.join(jobsRoot, context.id + '.request.json');
    const resultPath = path.join(jobsRoot, context.id + '.result.json');
    await fs.writeFile(requestPath, JSON.stringify(request), { flag: 'wx' });
    const child = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
      path.join(root, 'helper', 'engine-worker.ps1'), '-RequestPath', requestPath,
      '-ResultPath', resultPath, '-StateRoot', stateRoot], { stdio: 'ignore', windowsHide: true });
    const exitPromise = new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('exit', code => resolve(code));
    });
    exitPromise.catch(() => {});
    // Race worker exit against a single deadline; the loser timer is always cleared.
    let deadlineHandle = null;
    const timedOut = await Promise.race([
      exitPromise.then(() => false, () => false),
      new Promise(resolve => { deadlineHandle = setTimeout(() => resolve(true), options.engineTimeoutMs ?? 240000); }),
    ]);
    if (deadlineHandle) clearTimeout(deadlineHandle);
    if (timedOut) {
      // Coordinate worker exit and taskkill completion before classifying or releasing the lock.
      const termination = await terminateTree(child);
      if (!termination.confirmed) {
        const error = new Error('engine_timeout_unconfirmed: 引擎超时且无法确认工作进程树已完全停止，写操作已锁定以保护主题库。该锁保存在皮肤廊本地服务进程内，仅关闭或重新打开窗口不会解除；请稍后重试，若持续锁定，请以受控方式重启皮肤廊本地服务后再试。');
        error.keepLock = true;
        error.terminationAttempts = termination.attempts;
        throw error;
      }
      await waitExitBounded(exitPromise, options.exitWaitMs ?? 5000);
      throw new Error('engine_timeout: worker process tree stopped after the execution deadline');
    }
    const exitCode = await exitPromise;
    const result = await optionalJson(resultPath, null);
    if (exitCode !== 0) throw new Error(result?.ok === false && result.message ? result.message : 'engine_exit_' + exitCode);
    if (!result) throw new Error('engine_result_missing');
    return result;
  }
  const runEngine = options.runEngine || defaultRunEngine;
  async function execute(job, body) {
    job.status = 'running';
    try {
      await fs.mkdir(jobsRoot, { recursive: true });
      let request;
      if (job.action === 'install') {
        job.phase = 'metadata'; job.message = '正在读取主题信息';
        const metadata = await remoteJson('/v1/themes/' + body.versionId);
        if (metadata?.id !== body.versionId) throw new Error('metadata_version_mismatch');
        const platforms = metadata.displayMeta?.platforms;
        if (!body.adaptWindows && (!Array.isArray(platforms) || !platforms.includes('windows'))) throw new Error('windows_platform_required');
        const expectedBytes = metadata.packageBytes;
        const expectedSha256 = metadata.packageSha256;
        if (!Number.isSafeInteger(expectedBytes) || expectedBytes < 1 || expectedBytes > 32 * 1024 * 1024) throw new Error('invalid_package_bytes');
        if (typeof expectedSha256 !== 'string' || !/^[a-fA-F0-9]{64}$/.test(expectedSha256)) throw new Error('invalid_package_sha256');
        job.phase = 'download'; job.message = '正在下载主题包';
        const archive = await requestBytes(new URL('/v1/themes/' + body.versionId + '/download', upstream), expectedBytes, 60000);
        job.phase = 'verify'; job.message = '正在校验主题包';
        if (archive.length !== expectedBytes) throw new Error('package_length_mismatch');
        if (crypto.createHash('sha256').update(archive).digest('hex') !== expectedSha256.toLowerCase()) throw new Error('package_sha256_mismatch');
        const archivePath = path.join(jobsRoot, job.id + '.zip');
        await fs.writeFile(archivePath, archive, { flag: 'wx' });
        request = { action: 'import', archivePath, expectedBytes, expectedSha256: expectedSha256.toLowerCase(), themeId: null, adaptWindows: body.adaptWindows };
      } else {
        await savedTheme(body.themeId);
        request = { action: 'apply', archivePath: null, expectedBytes: null, expectedSha256: null, themeId: body.themeId, adaptWindows: false };
      }
      job.phase = job.action === 'install' ? 'import' : 'apply';
      job.message = job.action === 'install' ? '正在保存主题' : '正在应用主题';
      const result = await runEngine(request, { id: job.id, root, stateRoot });
      if (!result || result.ok !== true) throw new Error(result?.message || 'engine_result_failed');
      if (!result.theme || !THEME_ID.test(result.theme.id)) throw new Error('engine_theme_missing');
      if (job.action === 'apply' && result.theme.id !== body.themeId) throw new Error('engine_theme_mismatch');
      const { theme } = await savedTheme(result.theme.id);
      if (job.action === 'install') {
        const mapping = await optionalJson(mappingPath, {});
        Object.defineProperty(mapping, theme.id, { value: { sourceVersion: body.versionId, adapted: body.adaptWindows }, enumerable: true, configurable: true, writable: true });
        const temporary = mappingPath + '.' + job.id + '.tmp';
        await fs.writeFile(temporary, JSON.stringify(mapping, null, 2));
        await fs.rename(temporary, mappingPath);
      }
      job.themeId = theme.id; job.result = { ...result, theme: { id: theme.id, name: theme.name } };
      job.status = 'success'; job.phase = 'done'; job.message = job.action === 'install' ? '主题已保存，可在「已保存」中应用' : '主题已应用，并已通过 Codex 显示验证';
    } catch (error) {
      job.status = 'error'; job.phase = 'error'; job.message = error.message || 'job_failed';
      if (error.keepLock === true) job.terminationUnconfirmed = true;
    } finally { if (!job.terminationUnconfirmed) { active = null; activeKey = null; } }
  }
  async function openBrowser(rawUrl, res) {
    let url;
    try { url = new URL(rawUrl); } catch { throw fail(400, 'bad_url'); }
    if (url.protocol !== 'https:' || !['dreamskin.cc', 'www.dreamskin.cc'].includes(url.hostname) || url.username || url.password || url.port) throw fail(403, 'host_not_allowed');
    await new Promise((resolve, reject) => {
      const child = spawn('rundll32.exe', ['url.dll,FileProtocolHandler', url.href], { detached: true, stdio: 'ignore', windowsHide: true });
      child.once('error', () => reject(fail(500, 'spawn_failed')));
      child.once('spawn', () => { child.unref(); resolve(); });
    });
    send(res, 200, { ok: true });
  }
  const server = http.createServer(async (req, res) => {
    try {
      const address = server.address();
      const hosts = ['127.0.0.1:' + address.port, 'localhost:' + address.port];
      if (!hosts.includes(req.headers.host) || (req.headers.origin !== undefined && req.headers.origin !== 'http://' + req.headers.host) || req.headers['sec-fetch-site'] === 'cross-site') throw fail(403, 'origin_not_allowed');
      if (!req.url.startsWith('/') || req.url.startsWith('//')) throw fail(400, 'bad_url');
      const url = new URL(req.url, 'http://' + req.headers.host);
      if (req.method === 'POST') {
        if (req.headers['x-gallery-token'] !== token) throw fail(403, 'token_required');
        if (!['/api/install', '/api/apply', '/api/maintenance'].includes(url.pathname)) throw fail(404, 'not_found');
        const body = await readBody(req);
        if (url.pathname === '/api/maintenance') {
          if (typeof body.enabled !== 'boolean') throw fail(400, 'invalid_maintenance');
          maintenance = body.enabled === true;
          send(res, 200, { ok: true, maintenance }); return;
        }
        if (maintenance) throw fail(503, 'maintenance_in_progress');
        const action = url.pathname === '/api/install' ? 'install' : 'apply';
        if (action === 'install') {
          if (typeof body.versionId !== 'string' || !VERSION_ID.test(body.versionId)) throw fail(400, 'invalid_version_id');
          if (body.adaptWindows !== undefined && typeof body.adaptWindows !== 'boolean') throw fail(400, 'invalid_adapt_windows');
          body.adaptWindows = body.adaptWindows === true;
          if (body.adaptWindows && body.versionId !== ADAPTABLE_VERSION) throw fail(400, 'adaptation_not_allowed');
        } else if (typeof body.themeId !== 'string' || !THEME_ID.test(body.themeId)) throw fail(400, 'invalid_theme_id');
        const key = action === 'install' ? action + ':' + body.versionId + ':' + body.adaptWindows : action + ':' + body.themeId;
        if (active) {
          if (key !== activeKey || active.terminationUnconfirmed === true) throw fail(409, 'job_in_progress');
          send(res, 202, active); return;
        }
        const job = { id: crypto.randomUUID(), action, status: 'queued', phase: 'queued', message: '任务已排队',
          ...(action === 'install' ? { versionId: body.versionId } : { themeId: body.themeId }) };
        active = latest = job; activeKey = key; jobs.set(job.id, job);
        if (jobs.size > 100) jobs.delete(jobs.keys().next().value);
        send(res, 202, job);
        setImmediate(() => { void execute(job, body); });
        return;
      }
      if (req.method !== 'GET') throw fail(405, 'method_not_allowed');
      if (url.pathname === '/api/health') { send(res, 200, { ok: true, version: 2, token }); return; }
      if (url.pathname === '/api/themes') { send(res, 200, await remoteJson(buildUpstreamPath(url.searchParams), url.searchParams.get('refresh') === '1')); return; }
      if (url.pathname === '/api/theme') {
        const id = url.searchParams.get('versionId');
        if (!VERSION_ID.test(id || '')) throw fail(400, 'invalid_version_id');
        send(res, 200, await remoteJson('/v1/themes/' + id, url.searchParams.get('refresh') === '1')); return;
      }
      if (url.pathname === '/api/saved') { send(res, 200, await savedList()); return; }
      if (url.pathname === '/api/jobs/latest') { send(res, 200, { job: latest }); return; }
      if (url.pathname.startsWith('/api/jobs/')) {
        const job = jobs.get(url.pathname.slice('/api/jobs/'.length));
        if (!job) throw fail(404, 'job_not_found');
        send(res, 200, job); return;
      }
      if (url.pathname === '/api/open') { await openBrowser(url.searchParams.get('url'), res); return; }
      if (url.pathname === '/preview') {
        const { theme, directory } = await savedTheme(url.searchParams.get('id') || '');
        if (typeof theme.image !== 'string') throw fail(404, 'preview_not_found');
        const file = await inside(directory, path.resolve(directory, theme.image));
        const types = { '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp', '.gif': 'image/gif' };
        const type = types[path.extname(file).toLowerCase()];
        if (!type) throw fail(404, 'preview_not_found');
        send(res, 200, await fs.readFile(file), type); return;
      }
      const statics = { '/': ['index.html', 'text/html; charset=utf-8'], '/app.js': ['app.js', 'text/javascript; charset=utf-8'], '/styles.css': ['styles.css', 'text/css; charset=utf-8'] };
      if (Object.hasOwn(statics, url.pathname)) {
        const [name, type] = statics[url.pathname];
        send(res, 200, await fs.readFile(path.join(root, 'app', name)), type); return;
      }
      throw fail(404, 'not_found');
    } catch (error) {
      const status = error.status || (error.code === 'ENOENT' ? 404 : 500);
      if (!res.headersSent) send(res, status, { error: status === 500 ? 'internal_error' : error.message });
      else res.destroy();
    }
  });
  server.requestTimeout = 15000;
  server.headersTimeout = 10000;
  // The listening socket keeps the helper alive. No fixed lifetime may interrupt jobs or gallery use.
  return server;
}

module.exports = { createGalleryServer };
if (require.main === module) {
  const server = createGalleryServer();
  server.on('error', error => { console.error(error.message); process.exitCode = error.code === 'EADDRINUSE' ? 0 : 1; });
  server.listen(PORT, '127.0.0.1', () => console.log('skin-gallery helper listening on http://127.0.0.1:' + PORT));
}
