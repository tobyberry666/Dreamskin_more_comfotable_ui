'use strict';
// Minimal fake gallery helper for maintenance-admission tests. Never touches real state.
// Usage: node fake-helper-server.js <port> <mode>
//   mode: idle | running | unconfirmed | jobsfail | old
const http = require('node:http');
const port = Number(process.argv[2]);
const mode = process.argv[3] || 'idle';

function send(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(body));
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  if (req.method === 'GET' && url.pathname === '/api/health') {
    if (mode === 'old') return send(res, 200, { ok: true });
    return send(res, 200, { ok: true, version: 2, token: 'testtoken' });
  }
  if (req.method === 'GET' && url.pathname === '/api/jobs/latest') {
    if (mode === 'old') return send(res, 404, { error: 'not_found' });
    if (mode === 'jobsfail') return send(res, 500, { error: 'internal_error' });
    if (mode === 'running') return send(res, 200, { job: { id: 'job-1', action: 'install', status: 'running' } });
    if (mode === 'unconfirmed') return send(res, 200, { job: { id: 'job-2', action: 'install', status: 'error', terminationUnconfirmed: true } });
    return send(res, 200, { job: null });
  }
  if (req.method === 'POST' && url.pathname === '/api/maintenance') {
    return send(res, 200, { ok: true, maintenance: true });
  }
  if (req.method === 'POST') return send(res, 202, { id: 'x', status: 'queued' });
  send(res, 404, { error: 'not_found' });
});
server.listen(port, '127.0.0.1', () => { console.log('fake helper ' + mode + ' on ' + port); });
