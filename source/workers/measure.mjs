const base = process.argv[2] || 'http://127.0.0.1:9336';
for (const route of ['/api/health', '/api/themes?limit=12&offset=0&sort=latest', '/api/themes?limit=12&offset=0&sort=latest', '/api/saved']) {
  const started = performance.now();
  try {
    const response = await fetch(base + route, {signal: AbortSignal.timeout(20000)});
    const body = await response.json();
    console.log(JSON.stringify({route,status:response.status,ms:Math.round(performance.now()-started),items:body.items?.length,version:body.version}));
  } catch (error) { console.log(JSON.stringify({route,ms:Math.round(performance.now()-started),error:error.message})); }
}
