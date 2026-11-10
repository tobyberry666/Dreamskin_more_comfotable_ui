'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const source=fs.readFileSync(path.join(__dirname,'../app.js'),'utf8');
class Element {
  constructor(tag='div') {this.tag=tag;this.children=[];this.attributes={};this.events={};this.value='';this.hidden=false;this.disabled=false;this.classList={toggle(){}};}
  set disabled(value){this._disabled=!!value;}
  get disabled(){return this._disabled;}
  append(...children){this.children.push(...children);}
  replaceChildren(...children){this.children=children;}
  setAttribute(k,v){this.attributes[k]=v;}
  getAttribute(k){return this.attributes[k] || (k==='src'?this.src:null);}
  removeAttribute(k){delete this.attributes[k];}
  addEventListener(k,fn,options={}){(this.events[k] ||= []).push({fn,options});}
  emit(k){const listeners=this.events[k] || [];this.events[k]=listeners.filter(x=>!x.options.once);for(const listener of listeners)listener.fn({target:this});}
  showModal(){this.open=true;}
  remove(){}
}
async function flush(){for(let i=0;i<40;i++)await Promise.resolve();}
function harness(handler) {
  const elements=Object.fromEntries([...html.matchAll(/id="([^"]+)"/g)].map(m=>[m[1],new Element()]));
  elements.sort.value='latest';
  const timers=new Map(),intervals=[],calls=[];let next=0;
  const window={fetch:async(url,options)=>{calls.push({url,options});const body=await handler(url,options);return {ok:!body.$status,status:body.$status || 200,json:async()=>body};},addEventListener(){}};
  vm.runInNewContext(source,{document:{getElementById:id=>elements[id],createElement:tag=>new Element(tag)},window,URL,AbortController,setTimeout:(fn,ms)=>{timers.set(++next,{fn,ms});return next;},clearTimeout:id=>timers.delete(id),setInterval:fn=>intervals.push(fn)});
  return {elements,calls,timers,intervals,async tick(ms){const entry=[...timers].find(([,t])=>t.ms===ms);assert.ok(entry,'expected scheduled timer '+ms);timers.delete(entry[0]);await entry[1].fn();await flush();}};
}
const theme={id:'ver_windows1234',name:'测试青瓷',displayMeta:{platforms:['windows'],appearance:'light'}};
function findButton(root,label){if(root.tag==='button' && root.textContent===label)return root;for(const child of root.children || []){const result=findButton(child,label);if(result)return result;}}
function basics(url){if(url==='/api/health')return {ok:true,version:2,token:'fresh-token'};if(url==='/api/saved')return {items:[],current:null,paused:false};if(url.startsWith('/api/themes?'))return {items:[theme]};if(url==='/api/jobs/latest')return {job:null};throw new Error('unhandled '+url);}
test('page boots with same-origin calls and saves without applying, then honors failed job result',async()=>{
  let savedReads=0;
  const app=harness((url,options)=>{
    if(url==='/api/saved'){savedReads++;return {items:[],current:null};}
    if(url==='/api/install'){assert.equal(options.headers['X-Gallery-Token'],'fresh-token');assert.deepEqual(JSON.parse(options.body),{versionId:theme.id,adaptWindows:false});return {id:'job-save',action:'install',status:'queued',phase:'queued',message:'排队'};}
    if(url==='/api/jobs/job-save')return {id:'job-save',action:'install',status:'success',result:{ok:false,message:'真实导入失败'},versionId:theme.id};
    return basics(url);
  });
  await flush();const save=findButton(app.elements.grid,'下载并保存');assert.ok(save);assert.equal(save.disabled,false);
  await save.onclick();await flush();assert.equal(findButton(app.elements.grid,'下载并保存').disabled,true);
  assert.ok(!app.calls.some(call=>call.url==='/api/apply'));
  await app.tick(900);assert.equal(app.elements['task-state'].textContent,'未完成');assert.equal(app.elements['task-message'].textContent,'真实导入失败');assert.equal(app.elements['retry-task'].hidden,false);assert.ok(savedReads>=2);
  assert.ok(app.calls.every(call=>call.url.startsWith('/')));
});
test('expired mutation token refreshes health and retries once with the new token',async()=>{
  let healthReads=0,posts=0;
  const app=harness((url,options)=>{
    if(url==='/api/health')return {ok:true,version:2,token:++healthReads===1?'old-token':'new-token'};
    if(url==='/api/install') {posts++;if(posts===1)return {$status:403,message:'令牌过期'};assert.equal(options.headers['X-Gallery-Token'],'new-token');return {id:'saved',action:'install',status:'success'};}
    return basics(url);
  });await flush();await findButton(app.elements.grid,'下载并保存').onclick();await flush();assert.equal(posts,2);assert.equal(app.elements['task-state'].textContent,'已完成');
});
test('target macOS adaptation requires explanation and explicit confirmation before install',async()=>{
  const target={id:'ver_636b0ac227d23f7bf741',name:'雨过青瓷',displayMeta:{platforms:['macos']}};
  const app=harness((url,options)=>{
    if(url.startsWith('/api/themes?'))return {items:[target]};
    if(url==='/api/install'){assert.equal(JSON.parse(options.body).adaptWindows,true);return {id:'adapted',action:'install',status:'success'};}
    return basics(url);
  });await flush();const pending=findButton(app.elements.grid,'适配并保存').onclick();await flush();
  assert.match(app.elements['confirm-message'].textContent,/Windows 本地适配/);assert.equal(app.calls.some(c=>c.url==='/api/install'),false);
  app.elements['confirm-dialog'].returnValue='confirm';app.elements['confirm-dialog'].emit('close');await pending;await flush();assert.equal(app.calls.filter(c=>c.url==='/api/install').length,1);
});
test('healthy heartbeat preserves existing card nodes and keyboard focus',async()=>{
  const app=harness(basics);await flush();const first=app.elements.grid.children[0];
  await app.intervals[0]();await flush();assert.equal(app.elements.grid.children[0],first);
});
test('old job poll cannot replace a new task after reconnect recovery',async()=>{
  let token='first',latestStatus='running',resolvePoll;
  const app=harness(url=>{
    if(url==='/api/health')return {ok:true,version:2,token};
    if(url==='/api/jobs/latest')return {job:{id:'old',action:'install',status:latestStatus}};
    if(url==='/api/jobs/old')return new Promise(resolve=>{resolvePoll=resolve;});
    if(url==='/api/install')return {id:'new',action:'install',status:'queued'};
    return basics(url);
  });
  await flush();const polling=app.tick(900);await flush();token='second';latestStatus='success';await app.intervals[0]();await flush();
  await findButton(app.elements.grid,'下载并保存').onclick();await flush();
  resolvePoll({id:'old',action:'install',status:'running',message:'STALE'});await polling;await flush();
  assert.notEqual(app.elements['task-message'].textContent,'STALE');
});
test('reload restores running task, saved navigation works while online catalog hangs, apply requires confirmation',async()=>{
  let phase='running';
  const saved={id:'local-celadon',name:'本地青瓷',adapted:true};
  const app=harness((url,options)=>{
    if(url.startsWith('/api/themes?'))return new Promise(()=>{});
    if(url==='/api/saved')return {items:[saved],current:null};
    if(url==='/api/jobs/latest')return {job:{id:'restored',action:'install',status:phase,versionId:theme.id,message:'恢复任务'}};
    if(url==='/api/jobs/restored'){phase='success';return {id:'restored',action:'install',status:'success'};}
    if(url==='/api/apply'){assert.equal(JSON.parse(options.body).themeId,saved.id);return {id:'applied',action:'apply',status:'success',message:'已应用'};}
    return basics(url);
  });
  await flush();app.elements['nav-saved'].onclick();await flush();assert.ok(findButton(app.elements.grid,'应用主题'));assert.equal(findButton(app.elements.grid,'应用主题').disabled,true);
  await app.tick(900);const apply=findButton(app.elements.grid,'应用主题');assert.equal(apply.disabled,false);
  const pending=apply.onclick();await flush();assert.equal(app.elements['confirm-dialog'].open,true);assert.match(app.elements['confirm-message'].textContent,/重启 Codex/);assert.equal(app.calls.some(c=>c.url==='/api/apply'),false);
  app.elements['confirm-dialog'].returnValue='confirm';app.elements['confirm-dialog'].emit('close');await pending;await flush();assert.equal(app.elements['task-state'].textContent,'已完成');
});
function findTag(root,tag){if(root.tag===tag)return root;for(const child of root.children || []){const result=findTag(child,tag);if(result)return result;}}
test('online thumbnails use official API while saved imports use local imageUrl',async()=>{
 const local={id:'guiming.ink.rainwashed-celadon-windows-local',name:'local',sourceVersion:theme.id,imageUrl:'/preview?id=guiming.ink.rainwashed-celadon-windows-local'};
 const app=harness(url=>url==='/api/saved'?{items:[local],current:null}:basics(url));await flush();
 assert.equal(findTag(app.elements.grid,'img').src,'https://api.dreamskin.cc/v1/themes/'+theme.id+'/preview/thumbnail');
 app.elements['nav-saved'].onclick();await flush();
 assert.equal(findTag(app.elements.grid,'img').src,local.imageUrl);
});

