(function () {
  'use strict';
  const ADAPT_ID = 'ver_636b0ac227d23f7bf741';
  const VERSION = /^ver_[a-z0-9]{8,64}$/;
  function parseThemeLink(value) {
    const match = /^https:\/\/dreamskin\.cc\/themes\/(ver_[a-z0-9]{8,64})\/?$/.exec(String(value).trim());
    return match ? match[1] : null;
  }
  function compatibility(theme) {
    const platforms = theme.displayMeta && theme.displayMeta.platforms;
    if (!Array.isArray(platforms) || !platforms.length) return {kind:'unknown', label:'平台未注明', allowed:false};
    if (platforms.includes('windows')) return {kind:'windows', label:'支持 Windows', allowed:VERSION.test(theme.id)};
    if (theme.id === ADAPT_ID && platforms.includes('macos')) return {kind:'adapt', label:'macOS · 可本地适配', allowed:true};
    return {kind:'incompatible', label:'不支持 Windows', allowed:false};
  }
  function createGate() {
    let generation = 0, controller;
    return {next() {
      if (controller) controller.abort();
      controller = new AbortController(); const signal = controller.signal, id = ++generation;
      return {signal, current:() => generation === id && !signal.aborted};
    }};
  }
  function createCatalog(request, changed = () => {}) {
    const gate = createGate();
    const state = {items:[], offset:0, done:false, loading:false, dirty:false, error:'', total:null};
    return {state, invalidate() {gate.next(); state.loading=false; state.dirty=true; changed();}, async load(query, reset = false) {
      if (!reset && (state.loading || state.done || state.dirty)) return;
      const ticket = gate.next();
      if (reset) Object.assign(state,{items:[],offset:0,done:false,total:null});
      state.loading=true; state.dirty=false; state.error=''; changed();
      const url='/api/themes?limit=12&offset='+state.offset+'&sort='+encodeURIComponent(query.sort || 'latest')+'&q='+encodeURIComponent(query.q || '')+(query.refresh ? '&refresh=1' : '');
      try {
        const data=await request(url,{signal:ticket.signal});
        if (!ticket.current()) return;
        if (!data || !Array.isArray(data.items)) throw new Error('主题列表格式无效');
        state.items=state.items.concat(data.items); state.offset+=data.items.length;
        state.total=typeof data.total === 'number' ? data.total : null;
        state.done=data.items.length < 12 || (state.total !== null && state.offset >= state.total);
      } catch (error) {if(ticket.current()) state.error=error.message;}
      finally {if(ticket.current()) {state.loading=false;changed();}}
    }};
  }
  function jobOutcome(job) {
    if (job.status === 'error' || (job.status === 'success' && job.result && job.result.ok === false)) return 'error';
    if (job.status === 'success') return 'success';
    return job.status === 'queued' || job.status === 'running' ? 'busy' : 'error';
  }
  async function requestJSON(fetcher, url, options = {}, timeout = 15000) {
    const controller=new AbortController();
    const abort=() => controller.abort();
    if(options.signal) {if(options.signal.aborted) abort(); else options.signal.addEventListener('abort',abort,{once:true});}
    const timer=setTimeout(abort,timeout);
    try {
      const response=await fetcher(url,{...options,signal:controller.signal,cache:'no-store'});
      let body; try {body=await response.json();} catch {throw new Error('服务返回了无效数据');}
      if(!response.ok) {const error=new Error(body.message || body.error || '请求失败（'+response.status+'）');error.status=response.status;throw error;}
      return body;
    } catch(error) {
      if(controller.signal.aborted && !(options.signal && options.signal.aborted)) throw new Error('请求超时，请检查服务后重试');
      throw error;
    } finally {clearTimeout(timer);if(options.signal) options.signal.removeEventListener('abort',abort);}
  }
  const utilities={parseThemeLink,compatibility,createGate,createCatalog,jobOutcome,requestJSON};
  if(typeof module !== 'undefined' && module.exports) module.exports=utilities;
  if(typeof document === 'undefined') return;
  const $=id => document.getElementById(id);
  const request=(url,options) => requestJSON(window.fetch.bind(window),url,options);
  const state={tab:'online',saved:[],savedLoaded:false,savedLoading:false,savedError:'',current:null,paused:false,connected:false,token:'',recovering:true,busy:false,submitting:false,job:null,linked:null,lookupLoading:false,confirming:false};
  let healthPending=false, pollTimer, searchTimer, completedId='', gridSignature='', linkSignature='';
  const lookupGate=createGate(), savedGate=createGate(), taskGate=createGate();
  const catalog=createCatalog(request,render);
  function node(tag, cls, text) {const n=document.createElement(tag);if(cls)n.className=cls;if(text!==undefined)n.textContent=text;return n;}
  function note(message) {$('notice').textContent=message;$('notice').hidden=!message;}
  function locked() {return state.busy || state.submitting || state.recovering || state.confirming || !state.connected;}
  function dialog(title,message,label) {
    if(state.confirming) return Promise.resolve(false);
    state.confirming=true;render();
    $('confirm-title').textContent=title;$('confirm-message').textContent=message;$('confirm-ok').textContent=label;
    const modal=$('confirm-dialog');modal.returnValue='';modal.showModal();
    return new Promise(resolve => modal.addEventListener('close',() => {state.confirming=false;render();resolve(modal.returnValue==='confirm');},{once:true}));
  }
  function savedFor(theme) {return state.saved.find(item => item.sourceVersion === theme.id);}
  function card(theme,local) {
    const article=node('article','card'), preview=node('div','preview');
    const image=node('img');image.alt=(theme.name || '主题')+'预览';image.loading='lazy';
    if(local && typeof theme.imageUrl === 'string' && theme.imageUrl.startsWith('/preview?')) image.src=theme.imageUrl;
    else if(!local && VERSION.test(theme.id)) image.src='https://api.dreamskin.cc/v1/themes/'+encodeURIComponent(theme.id)+'/preview/thumbnail';
    image.addEventListener('error',() => image.remove());if(image.getAttribute('src'))preview.append(image);
    article.append(preview);const body=node('div','card-body');body.append(node('h3','',theme.name || '未命名主题'));
    const meta=node('div','meta');meta.append(node('span','',local ? '本地收藏' : theme.authorDisplayName || '佚名'));
    const appearance=local ? theme.appearance : theme.displayMeta && theme.displayMeta.appearance;
    if(appearance)meta.append(node('span','',appearance==='light'?'浅色':appearance==='dark'?'深色':'自定配色'));
    if(!local && theme.version)meta.append(node('span','','v'+theme.version));body.append(meta);
    const acts=node('div','actions');
    if(local) {
      const current=theme.current || (state.current && state.current.id===theme.id);
      body.append(node('span','badge',current ? (state.paused?'当前主题 · 已暂停':'当前使用') : theme.adapted?'Windows 本地适配':'已保存'));
      if(theme.adapted)body.append(node('p','card-note','本地 Windows 适配版，保留原作者来源。'));
      const button=node('button','primary',current && !state.paused ? '正在使用' : '应用主题');button.disabled=locked() || (current && !state.paused);button.onclick=() => applyTheme(theme);acts.append(button);
    } else {
      const compat=compatibility(theme), saved=savedFor(theme);
      body.append(node('span','badge'+(compat.kind==='windows'?'':' warn'),compat.label));
      if(compat.kind==='adapt')body.append(node('p','card-note','雨过青瓷原包仅供 macOS。可另存为 Windows 本地适配版。'));
      else if(!compat.allowed)body.append(node('p','card-note',compat.kind==='unknown'?'作者未注明 Windows 支持，暂不提供保存。':'此原包不能在 Windows 上直接安装。'));
      const button=node('button',compat.allowed?'primary':'',saved?'已保存 · 去查看':compat.kind==='adapt'?'适配并保存':compat.allowed?'下载并保存':'暂不可保存');
      button.disabled=saved ? false : locked() || !compat.allowed;
      button.onclick=() => saved ? switchTab('saved') : saveTheme(theme);acts.append(button);
      if(VERSION.test(theme.id)) {const detail=node('a','','详情 ↗');detail.href='https://dreamskin.cc/themes/'+theme.id;detail.target='_blank';detail.rel='noopener noreferrer';acts.append(detail);}
    }
    body.append(acts);article.append(body);return article;
  }
  function renderTask() {
    const job=state.job;$('task-panel').hidden=!job && !state.submitting;
    if(!job && !state.submitting)return;
    const outcome=job ? jobOutcome(job):'busy';
    $('task-title').textContent=job && job.action==='apply'?'应用主题':'下载并保存';
    $('task-state').textContent=state.submitting?'正在提交':outcome==='busy'?'进行中':outcome==='success'?'已完成':'未完成';
    $('task-state').className='badge'+(outcome==='error'?' bad':'');
    $('task-message').textContent=state.submitting?'正在提交请求，请稍候…':(job.result && job.result.ok===false && job.result.message) || job.message || (outcome==='success'?'任务已完成':'正在处理主题…');
    $('task-phase').textContent=state.recovering?'正在核对服务端任务状态，请勿重复操作':!state.connected?'连接中断，恢复后继续核对进度':job ? '阶段：'+(job.phase || job.status):'';
    const progress=$('task-progress');if(outcome==='busy')progress.removeAttribute('value');else {progress.max=1;progress.value=outcome==='success'?1:0;}
    $('retry-task').hidden=!job || outcome!=='error';$('retry-task').disabled=locked();
  }
  function render() {
    $('service').textContent=state.connected?'本地服务已连接':'本地服务未连接 · 自动重连中';$('service').className='service'+(state.connected?' connected':'');
    $('current-name').textContent=state.current ? state.current.name || state.current.id : state.savedLoaded?'尚未应用主题':'尚未读取主题';
    $('current-note').textContent=state.paused?'主题已暂停；应用后恢复':state.current?'本地主题库 · 当前配色':'从已保存主题中选择应用';
    $('saved-count').textContent=state.savedLoaded?String(state.saved.length):'—';
    const local=state.tab==='saved';
    for(const tab of ['online','saved']) {const nav=$('nav-'+tab);nav.classList.toggle('active',state.tab===tab);if(state.tab===tab)nav.setAttribute('aria-current','page');else nav.removeAttribute('aria-current');}
    $('online-tools').hidden=local;$('intro').hidden=local;
    $('page-title').textContent=local?'喜欢的配色，都在这里。':'让工作台，清新一点。';
    $('page-description').textContent=local?'直接读取本地收藏，无需等待在线主题库。':'挑选喜欢的配色，慢慢收进你的 Codex。';
    $('collection-title').textContent=local?'已保存主题':'发现主题';
    const model=local?{items:state.saved,loading:state.savedLoading,error:state.savedError}:catalog.state;
    const grid=$('grid');grid.setAttribute('aria-busy',String(model.loading));
    const signature=JSON.stringify([local,model.items,model.loading,model.error,locked(),state.saved,state.current,state.paused]);
    if(signature!==gridSignature) {
      gridSignature=signature;grid.replaceChildren();
      model.items.forEach(theme => grid.append(card(theme,local)));
      if(!model.items.length)grid.append(node('div','empty',model.loading?'正在读取主题…':model.error?'暂时无法读取。请重试，或切换到已保存主题。':local?'还没有收藏。去在线主题中保存第一份配色吧。':'没有匹配的主题，换个关键词试试。'));
    }
    $('collection-status').textContent=model.loading?'正在读取…':model.error?'读取失败 · '+model.error:local?state.saved.length+' 套本地主题':model.items.length+' 套主题'+(model.total!==null?' / 共 '+model.total+' 套':'');
    $('load-more').hidden=local || catalog.state.done || !catalog.state.items.length;$('load-more').disabled=catalog.state.loading || catalog.state.dirty;$('load-more').textContent=catalog.state.error?'重试加载更多':'加载更多主题';
    $('retry-list').hidden=!model.error || (!local && !!model.items.length);$('retry-list').disabled=model.loading;
    $('lookup').disabled=state.lookupLoading;
    const linked=JSON.stringify([state.linked,locked(),state.saved]);
    if(linked!==linkSignature) {linkSignature=linked;$('link-result').replaceChildren();if(state.linked)$('link-result').append(card(state.linked,false));}
    renderTask();
  }
  async function loadSaved() {
    const ticket=savedGate.next();state.savedLoading=true;render();
    try {const data=await request('/api/saved',{signal:ticket.signal});if(!ticket.current())return;
      if(!Array.isArray(data.items))throw new Error('本地主题列表格式无效');
      state.saved=data.items;state.current=data.current;state.paused=!!data.paused;state.savedLoaded=true;state.savedError='';
    } catch(error) {if(ticket.current())state.savedError=error.message;} finally {if(ticket.current()){state.savedLoading=false;render();}}
  }
  function query(refresh=false) {return {q:$('search').value.trim(),sort:$('sort').value,refresh};}
  function switchTab(tab) {
    state.tab=tab;clearTimeout(searchTimer);
    if(tab==='saved') {catalog.invalidate();loadSaved();}
    else if(!catalog.state.items.length || catalog.state.dirty)catalog.load(query(),true);
    render();
  }
  async function lookup() {
    const ticket=lookupGate.next();state.linked=null;
    const versionId=parseThemeLink($('theme-link').value);state.lookupLoading=false;
    if(!versionId){$('link-message').textContent='请输入完整官方版本链接：https://dreamskin.cc/themes/ver_…（不带查询参数）。';render();return;}
    state.lookupLoading=true;$('link-message').textContent='正在读取主题信息…';render();
    try {const data=await request('/api/theme?versionId='+encodeURIComponent(versionId),{signal:ticket.signal});if(!ticket.current())return;
      const theme=data.theme || data;if(theme.id!==versionId)throw new Error('主题版本与链接不一致');state.linked=theme;$('link-message').textContent='已读取主题，请核对平台说明后保存。';
    }catch(error){if(ticket.current())$('link-message').textContent='读取失败：'+error.message;}
    finally{if(ticket.current()){state.lookupLoading=false;render();}}
  }
  async function saveTheme(theme) {
    if(locked())return;const compat=compatibility(theme);if(!compat.allowed)return;
    if(compat.kind==='adapt') {
      const yes=await dialog('适配并保存雨过青瓷？','此主题原包仅支持 macOS。将创建独立的「雨过青瓷 · Windows 本地适配」主题，保留作者与来源。\n这属于本地适配，不代表作者提供官方 Windows 支持。仅保存，不会重启 Codex。','适配并保存');if(!yes)return;
    }
    await start('/api/install',{versionId:theme.id,adaptWindows:compat.kind==='adapt'});
  }
  async function applyTheme(theme) {
    if(locked())return;
    if(await dialog('应用「'+(theme.name || theme.id)+'」？','应用主题可能重启 Codex。请先保存正在进行的工作。\n已下载的主题会保留在本地收藏中。','确认应用'))await start('/api/apply',{themeId:theme.id});
  }
  async function post(url,body) {
    let response;
    try {response=await request(url,{method:'POST',headers:{'Content-Type':'application/json','X-Gallery-Token':state.token},body:JSON.stringify(body)});}
    catch(error) {
      if(error.status!==403 && error.status!==401)throw error;
      const health=await request('/api/health');if(health.version!==2 || !health.token)throw new Error('本地服务版本不兼容');state.token=health.token;
      response=await request(url,{method:'POST',headers:{'Content-Type':'application/json','X-Gallery-Token':state.token},body:JSON.stringify(body)});
    }
    return response;
  }
  async function start(url,body) {
    if(locked())return;taskGate.next();state.submitting=true;note('');render();
    try {const job=await post(url,body);acceptJob(job);}
    catch(error) {note('请求未能确认：'+error.message+'。正在核对服务端任务，请勿重复提交。');state.recovering=true;await recover();}
    finally {state.submitting=false;render();}
  }
  function acceptJob(job) {
    if(!job || typeof job.id!=='string')throw new Error('服务未返回有效任务');
    taskGate.next();state.job=job;state.busy=jobOutcome(job)==='busy';render();clearTimeout(pollTimer);
    if(state.busy)pollTimer=setTimeout(pollJob,900);
    else if(completedId!==job.id) {completedId=job.id;loadSaved();}
  }
  async function pollJob() {
    if(!state.job || !state.busy)return;
    const ticket=taskGate.next();
    try {const job=await request('/api/jobs/'+encodeURIComponent(state.job.id),{signal:ticket.signal});if(ticket.current())acceptJob(job);}
    catch(error) {if(!ticket.current())return;state.recovering=true;note('任务进度暂不可读取：'+error.message+'。恢复连接后会继续核对。');render();}
  }
  async function recover() {
    const ticket=taskGate.next();
    try {const latest=await request('/api/jobs/latest',{signal:ticket.signal});if(!ticket.current())return;if(latest.job)acceptJob(latest.job);else {state.busy=false;state.job=null;clearTimeout(pollTimer);}state.recovering=false;render();}
    catch {if(ticket.current()){state.recovering=true;render();}}
  }
  async function checkHealth() {
    if(healthPending)return;healthPending=true;
    try {const health=await request('/api/health');if(health.version!==2 || !health.token || health.ok===false)throw new Error('请使用第二版本地服务');
      const changed=!state.connected || state.token!==health.token;state.connected=true;state.token=health.token;
      if((changed || state.recovering) && !state.submitting) {await recover();loadSaved();}
    }catch(error){state.connected=false;state.token='';state.recovering=true;}
    finally {healthPending=false;render();}
  }
  async function retryTask() {
    if(locked() || !state.job)return;const job=state.job;
    if(job.action==='apply' && job.themeId) return applyTheme(state.saved.find(item=>item.id===job.themeId) || {id:job.themeId,name:job.themeId});
    if(job.versionId) {
      state.submitting=true;render();
      try {const data=await request('/api/theme?versionId='+encodeURIComponent(job.versionId));const theme=data.theme || data;if(theme.id!==job.versionId)throw new Error('主题版本不一致');state.submitting=false;await saveTheme(theme);}
      catch(error){note('无法重试：'+error.message);}finally{state.submitting=false;render();}
    } else note('任务缺少来源信息，请重新选择主题。');
  }
  $('nav-online').onclick=()=>switchTab('online');$('nav-saved').onclick=()=>switchTab('saved');
  $('load-more').onclick=()=>catalog.load(query());$('refresh').onclick=()=>catalog.load(query(true),true);
  $('retry-list').onclick=()=>state.tab==='saved'?loadSaved():catalog.load(query(),true);
  $('sort').onchange=()=>{clearTimeout(searchTimer);catalog.load(query(),true);};
  $('search').addEventListener('input',()=>{catalog.invalidate();clearTimeout(searchTimer);searchTimer=setTimeout(()=>catalog.load(query(),true),300);});
  $('link-form').onsubmit=event=>{event.preventDefault();lookup();};
  $('theme-link').addEventListener('input',()=>{lookupGate.next();state.linked=null;state.lookupLoading=false;$('link-message').textContent='';render();});
  $('reconnect').onclick=()=>{checkHealth();loadSaved();};$('retry-task').onclick=retryTask;
  window.addEventListener('online',checkHealth);window.addEventListener('focus',checkHealth);
  setInterval(checkHealth,5000);
  loadSaved();checkHealth();catalog.load(query(),true);render();
})();
