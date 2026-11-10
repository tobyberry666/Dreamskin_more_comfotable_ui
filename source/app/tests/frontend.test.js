'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const context = { module: { exports: {} }, URL, AbortController, setTimeout, clearTimeout };
const source = path.join(__dirname, '../app.js');
vm.runInNewContext(fs.existsSync(source) ? fs.readFileSync(source, 'utf8') : '', context);
const api = context.module.exports;
const target = 'ver_636b0ac227d23f7bf741';
test('only canonical website version links are parsed locally', () => {
  assert.equal(typeof api.parseThemeLink, 'function');
  assert.equal(api.parseThemeLink('https://dreamskin.cc/themes/' + target), target);
  for (const value of ['https://evil.test/themes/' + target, 'https://dreamskin.cc.evil.test/themes/' + target, 'http://dreamskin.cc/themes/' + target, target, 'https://dreamskin.cc/themes/' + target + '?x=1', 'https://user@dreamskin.cc/themes/' + target, 'https://dreamskin.cc/themes/../themes/' + target]) assert.equal(api.parseThemeLink(value), null, value);
});
test('Windows compatibility is explicit and target adaptation never becomes a generic bypass', () => {
  assert.equal(typeof api.compatibility, 'function');
  assert.equal(api.compatibility({id: target, displayMeta:{platforms:['windows','macos']}}).kind, 'windows');
  assert.equal(api.compatibility({id: target, displayMeta:{platforms:['macos']}}).kind, 'adapt');
  assert.equal(api.compatibility({id: 'ver_other1234', displayMeta:{platforms:['macos']}}).kind, 'incompatible');
  assert.equal(api.compatibility({id: target, applyCompatible:true}).kind, 'unknown');
  assert.equal(api.compatibility({id: target, displayMeta:{platforms:[]}}).kind, 'unknown');
});
function deferred() { let resolve, reject; const promise = new Promise((a,b) => {resolve=a;reject=b;}); return {promise,resolve,reject}; }
test('late old search completion cannot overwrite newer sort results', async () => {
  assert.equal(typeof api.createCatalog, 'function');
  const pending = [];
  const model = api.createCatalog((url, options) => { const d=deferred(); pending.push({url, options, ...d}); return d.promise; });
  const old = model.load({q:'old',sort:'latest'}, true);
  const latest = model.load({q:'new',sort:'popular'}, true);
  assert.equal(pending[0].options.signal.aborted,true);
  pending[1].resolve({items:[{id:'new'}]}); await latest;
  pending[0].resolve({items:[{id:'old'}]}); await old;
  assert.equal(model.state.items[0].id,'new');
  assert.equal(model.state.loading,false);
});
test('stale rejection cannot clear active loading and pagination failure preserves cards and offset', async () => {
  const pending=[]; const model=api.createCatalog(() => {const d=deferred();pending.push(d);return d.promise;});
  const old=model.load({},true); const current=model.load({},true);
  pending[0].reject(new Error('old')); await old; assert.equal(model.state.loading,true);
  pending[1].resolve({items:Array.from({length:12},(_,i)=>({id:String(i)}))}); await current;
  const more=model.load({}); pending[2].reject(new Error('offline')); await more;
  assert.equal(model.state.items.length,12); assert.equal(model.state.offset,12); assert.equal(model.state.done,false);
  assert.match(model.state.error,/offline/);
});
test('invalidated catalog blocks pagination until a replacement query resets the offset', async () => {
  const urls=[]; const model=api.createCatalog(async url => {urls.push(url);return {items:Array.from({length:12},(_,i)=>({id:String(i)}))};});
  await model.load({q:'old'},true); model.invalidate(); await model.load({q:'new'});
  assert.equal(urls.length,1); await model.load({q:'new'},true);
  assert.match(urls[1],/offset=0/);
});
test('job result failure cannot be displayed as success', () => {
  assert.equal(api.jobOutcome({status:'success',result:{ok:false}}),'error');
  assert.equal(api.jobOutcome({status:'error'}),'error');
  assert.equal(api.jobOutcome({status:'running'}),'busy');
  assert.equal(api.jobOutcome({status:'success',result:{ok:true}}),'success');
});
test('client deadline aborts hung transport and cancellation remains distinguishable', async () => {
  const transport=(_url,options)=>new Promise((_,reject)=>options.signal.addEventListener('abort',()=>reject(new Error('aborted')),{once:true}));
  await assert.rejects(api.requestJSON(transport,'/api/themes',{},5),/超时/);
  const controller=new AbortController(); const pending=api.requestJSON(transport,'/api/themes',{signal:controller.signal});controller.abort();
  await assert.rejects(pending,/aborted/);
});
test('cancelled lookup gate rejects stale results even when transport ignores abort', () => {
  assert.equal(typeof api.createGate,'function'); const gate=api.createGate(); const a=gate.next(); const b=gate.next();
  assert.equal(a.signal.aborted,true); assert.equal(a.current(),false); assert.equal(b.current(),true);
});
