/* Persistent, synthetic UI review. No app-server, host bridge or provider requests. */
(() => {
'use strict';
const { components, coverage } = window.CODEX_UI_LAB;
const KEY = 'floatyterm.codex-ui-review.v1';
const $ = id => document.getElementById(id);
const h = (tag, props = {}, ...children) => {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (key === 'text') el.textContent = value;
    else if (key === 'class') el.className = value;
    else if (key.startsWith('on')) el.addEventListener(key.slice(2), value);
    else if (key === 'disabled') el.disabled = value;
    else el.setAttribute(key, value);
  }
  for (const child of children.flat(Infinity)) if (child != null) el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  return el;
};
let storageAvailable = true, stored = {};
try { stored = JSON.parse(localStorage.getItem(KEY) || '{}'); if (!stored || typeof stored !== 'object' || Array.isArray(stored)) stored = {}; } catch { storageAvailable = false; }
const validStates = ['running','done','failed','waiting'];
const knownId = id => components.some(c => c.id === id);
let selected = knownId(location.hash.slice(1)) ? location.hash.slice(1) : knownId(stored.selected) ? stored.selected : components[0].id;
let reviews = stored.reviews && typeof stored.reviews === 'object' ? stored.reviews : {};
let width = ['full','700','390'].includes(stored.width) ? stored.width : '700';
let timer = null, playing = false, toastTimer = null;
const current = () => components.find(c => c.id === selected);
const review = id => reviews[id] || { decision: 'unreviewed', notes: '', scenario: components.find(c => c.id === id).initial };
const save = () => {
  try { localStorage.setItem(KEY, JSON.stringify({version:1, selected, width, reviews})); storageAvailable = true; }
  catch { storageAvailable = false; }
  $('save-status').textContent = storageAvailable ? 'Saved in this browser · export for a portable copy' : 'Browser storage unavailable · export to keep your review';
  updateProgress();
};
const toast = message => { $('toast').textContent = message; $('toast').classList.add('visible'); clearTimeout(toastTimer); toastTimer = setTimeout(() => $('toast').classList.remove('visible'),3500); };
const feedback = text => { $('action-feedback').textContent = text; toast(text); };
const record = (field,value) => { reviews[selected] = {...review(selected),[field]:value,updatedAt:new Date().toISOString()}; save(); if (field === 'decision') renderNav(); };
const badge = (state,text) => h('span',{class:'ui-badge','data-state':state,text:text || ({running:'Running',done:'Completed',failed:'Failed',waiting:'Waiting for you'})[state]});
const inline = (...children) => h('div',{class:'ui-inline'},...children);
const stack = (...children) => h('div',{class:'ui-stack'},...children);
const muted = text => h('span',{class:'ui-muted',text});
const pre = text => h('pre',{class:'ui-code',text});
const fold = (title,body,open=false) => h('details',open ? {open:''} : {},h('summary',{text:title}),body);
const row = (title,state,subtitle) => h('div',{class:'ui-inline ui-between'},inline(h('span',{class:'ui-dot','data-state':state}),h('span',{class:'ui-title',text:title})),badge(state),subtitle ? muted(subtitle) : null);
const action = (title,callback,primary=false) => h('button',{type:'button',class:primary?'primary':'',text:title,onclick:callback});
const actions = (...buttons) => h('div',{class:'ui-actions'},...buttons);
const surface = (...children) => h('div',{class:'ui-surface ui-stack'},...children);
const result = (state,working,done,failed,waiting) => ({running:working,done,failed,waiting:waiting || 'Waiting for your response.'})[state];
const diff = 'diff --git a/src/events.ts b/src/events.ts\n--- a/src/events.ts\n+++ b/src/events.ts\n@@ -12,2 +12,3 @@\n-  output += delta;\n+  streams.get(itemId).append(delta);\n+  paintOutput(itemId);';
function diffDOM() { return h('pre',{class:'ui-code'},diff.split('\n').map(line => h('span',{class:'ui-diff-line '+(line.startsWith('+')?'add':line.startsWith('-')?'del':line.startsWith('@@')?'hunk':''),text:line+'\n'}))); }
function localDecision(container,label) {
  container.replaceChildren(surface(badge('done',label),muted('Synthetic response recorded. Reset interaction to try another choice.')));
  feedback(label+' · local simulation only');
}
function showArtifact() {
  const dialog = h('dialog',{class:'artifact-dialog','aria-label':'Synthetic artifact viewer'});
  const close = action('Close',()=>dialog.close());
  dialog.append(inline(h('strong',{text:'Generated header · synthetic placeholder'}),close),h('div',{class:'ui-media',role:'img','aria-label':'Synthetic amber and blue artifact'},h('span',{text:'Synthetic artifact preview'})),muted('artifacts/preview.png · local CSS placeholder'));
  dialog.addEventListener('close',()=>dialog.remove());document.body.append(dialog);dialog.showModal();close.focus();
}
function renderComponent(c,state) {
  const root = h('div',{class:'ui-stack','data-component':c.id,'data-state':state});
  const completed = state === 'done', failed = state === 'failed';
  const statusText = result(state,'Working on this item…','Completed successfully.','The operation failed. Details are available below.');
  switch(c.id) {
    case 'assistant': {
      root.append(h('div',{class:'ui-rail',text:'Make command output appear while the command is still running.'}));
      const md = h('div',{class:'ui-markdown sk-doc'});
      SkimRender.render(md,result(state,'The command stream is now attached to its item. Output appears in the existing row as each chunk arrives…','Command output now updates its owning tool row.\n\n- **Changed** output deltas append to the matching item.\n- **Preserved** final snapshots replace the accumulated output.\n\n```ts\npaintOutput(itemId);\n```','The update could not be completed because the file was unavailable.\n\n> [!CAUTION]\n> The previous output remains available.','I need the target file path before making this change.'),{streaming:!completed,interactive:false});
      root.append(md,inline(badge(state),muted(completed?'Final snapshot · item-4':'Message stream · item-4'))); break;
    }
    case 'thinking': root.append(fold(result(state,'Thinking · checking event ownership · 8s','Thought for 12s','Reasoning interrupted · 8s','Thinking paused · awaiting input'),stack(muted('Summary'),h('p',{text:'Trace the output stream to its owning item before updating the DOM. Keep a final snapshot separate from incremental chunks.'}),fold('Supplied raw reasoning',pre('Raw reasoning, when supplied by the protocol, is stored separately from the summary.'))))); break;
    case 'command': root.append(row('Build preview',state),fold('npm run build · /workspace/floatyterm',stack(pre('> build\nAnalyzing source files…\n'+result(state,'Bundling component preview…','✓ 28 components bundled\nBuild completed in 1.8s','Error: src/events.ts:24 — missing item identity','Build paused: additional permissions required')),inline(muted(completed?'Exit 0 · 1.8s':failed?'Exit 1 · 1.2s':'stdout · live output'),badge(state))),true)); break;
    case 'file': root.append(row('File changes',state),fold('src/events.ts · +2 −1',diffDOM(),true),fold('Patch application log',pre(result(state,'Applying patch…','Patch applied successfully.','Patch failed: context did not match.','Waiting for file-change approval.')))); break;
    case 'turn-diff': root.append(fold('Changes · 2 files · +8 −3',stack(inline(muted('Turn 12 · latest aggregate snapshot'),badge(state)),fold('src/events.ts · +2 −1',diffDOM(),true),fold('src/output.ts · +6 −2',pre('@@ -4,1 +4,2 @@\n- renderAll();\n+ renderItem(itemId);\n+ preserveScroll();')),action('Copy diff',async () => { try { await navigator.clipboard.writeText(diff); feedback('Synthetic diff copied'); } catch { feedback('Clipboard unavailable; select the diff text to copy.'); } })),true)); break;
    case 'plan': {
      const steps = completed ? ['completed','completed','completed'] : failed ? ['completed','failed','pending'] : ['completed',state==='waiting'?'pending':'inProgress','pending'];
      root.append(inline(h('span',{class:'ui-title',text:'Plan · '+(completed?'3/3':'1/3')}),badge(state)),h('progress',{class:'ui-progress',value:completed?3:1,max:3,'aria-label':'Plan completion'}),fold('Route output to its owning item',h('ul',{class:'ui-list'},['Inspect event ownership','Add live output rendering','Review narrow layout'].map((text,i) => h('li',{},inline(h('span',{class:'ui-mono',text:steps[i]==='completed'?'✓':steps[i]==='inProgress'?'◉':steps[i]==='failed'?'!':'○'}),text,muted(steps[i]))))),true)); break;
    }
    case 'approval': {
      const box=surface(row('Run command?',state),muted('Codex’s reason · Build the updated interface.'),pre('$ npm run build\ncwd: /workspace/floatyterm'),fold('Scope and offered decisions',muted('This command · allow once, allow for session, decline, or cancel. File approvals would show the matching patch here.')));
      if (state==='waiting') box.append(actions(...['Allow once','Allow for session','Decline','Cancel'].map((text,i) => action(text,() => localDecision(root,text),i===0))));
      else box.append(muted(result(state,'Decision submitted · awaiting resolution','Allowed once · resolved','Approval expired; no decision was sent.')));root.append(box); break;
    }
    case 'questions': {
      const box=surface(row('Choose the Changes placement',state),muted('Question 1 of 1 · blocks this turn'));
      const form=h('form',{});const list=h('ul',{class:'ui-list'});
      ['Below the reply','Inside the tool tray','Use my answer below'].forEach((text,i) => list.append(h('li',{},h('label',{},h('input',{type:'radio',name:'layout',value:text,...(i===0?{checked:''}:{})}),text))));
      const free=h('textarea',{rows:'2',placeholder:'Optional custom answer','aria-label':'Custom answer'});form.append(list,h('label',{class:'ui-field'},'Your answer',free));
      form.append(actions(h('button',{type:'submit',class:'primary',text:'Send answer'})));form.addEventListener('submit',e => {e.preventDefault();const answer=free.value.trim() || new FormData(form).get('layout');localDecision(root,'Answer: '+answer);});
      if(state==='waiting')box.append(form);else box.append(muted(result(state,'Question being prepared…','Answer sent · Below the reply','Question is no longer active.')));root.append(box);break;
    }
    case 'elicitation': {
      const box=surface(row('Docs server needs a workspace',state),muted('Only the requested workspace name is sent to docs-server.'));
      if(state==='waiting') {
        const form=h('form');const input=h('input',{required:'',placeholder:'e.g. engineering','aria-label':'Workspace name'});form.append(h('label',{},'Workspace',input),actions(h('button',{type:'submit',class:'primary',text:'Submit'}),action('Decline',()=>localDecision(root,'Elicitation declined'))));
        form.addEventListener('submit',e=>{e.preventDefault();localDecision(root,'Workspace: '+input.value);});box.append(form,fold('Alternative URL mode',stack(muted('A URL request uses an explicit action instead of a form.'),action('Open synthetic sign-in action',()=>feedback('URL mode demonstrated · no external sign-in opened')))));
      } else box.append(muted(result(state,'Awaiting form request…','Workspace submitted to docs-server.','The request expired.')));root.append(box);break;
    }
    case 'permissions': {
      const box=surface(row('Grant file access?',state),muted('Write generated assets to the preview folder.'),pre('Write: /workspace/preview\nNetwork: not requested'));
      if(state==='waiting') {const scope=h('select',{'aria-label':'Permission duration'},h('option',{value:'turn',text:'This turn'}),h('option',{value:'session',text:'This session'}));box.append(h('label',{},'Grant duration',scope),actions(action('Grant requested access',()=>localDecision(root,'Access granted for '+scope.value),true),action('Decline',()=>localDecision(root,'Permission request declined'))));}
      else box.append(muted(result(state,'Grant submitted · awaiting resolution','Granted for this turn','Permission request expired.')));root.append(box);break;
    }
    case 'approval-review': root.append(surface(row('Automatic review · npm run build',state),h('p',{text:result(state,'Reviewing requested action and permission scope…','Action allowed by automatic review.','Action rejected; inspect the review before continuing.','Strict review required before this action can continue.')}),fold('Decision evidence',pre('Review ID: review-2\nTarget item: item-4\nDecision source: automatic\nScope: workspace build command'))));break;
    case 'agent': root.append(row('Explorer · output rendering',state),muted('Child thread · child-thread · 3 tools · 8.4k tokens'),fold('Open agent transcript',stack(h('div',{class:'ui-rail',text:'Inspect stream ownership and report the best insertion point.'}),h('div',{class:'ui-transcript'},stack(muted('Thought for 4s'),fold('Read src/events.ts',pre('Identified command outputDelta handler and reducer state.'),true),h('p',{text:result(state,'Inspecting paintTool and final snapshots…','Keep the output buffer keyed by item ID; update the existing row.','The child thread disconnected. Its last output is preserved.','Awaiting access to the source file.')})))),true));break;
    case 'image': root.append(row('Generated header',state),completed?h('div',{class:'ui-media',role:'img','aria-label':'Synthetic amber and blue image placeholder'},h('span',{text:'Synthetic artifact preview'})):surface(muted(result(state,'Generating image…','Result available','Image generation failed: output unavailable.','Waiting for image generation approval.'))),fold('Artifact details',pre('artifacts/preview.png\nRevised prompt: soft amber and blue abstract header\nTransparent background: false')),completed?actions(action('View artifact',showArtifact),action('Copy artifact path',async()=>{try{await navigator.clipboard.writeText('artifacts/preview.png');feedback('Artifact path copied');}catch{feedback('Clipboard unavailable');}})):null);break;
    case 'review': root.append(surface(row('Review · event rendering changes',state),muted('Scope: working tree changes'),completed?stack(h('p',{text:'1 finding · medium severity'}),h('div',{class:'ui-rail'},h('strong',{text:'Late output can reach the wrong turn'}),h('p',{text:'Route output by thread and turn identity before selecting the current DOM row.'}),h('code',{text:'src/events.ts:24'}))):h('p',{text:statusText})));break;
    case 'hook': root.append(row('Formatting check · post-tool hook',state),fold('Hook output · 240 ms',pre(result(state,'Checking src/events.ts…','Formatting passed.\nNo files changed.','Formatting failed in src/events.ts:24.','Hook paused until tool approval completes.')),true));break;
    case 'status': root.append(h('div',{class:'ui-statusbar ui-inline ui-between'},inline(h('span',{class:'ui-dot','data-state':state}),result(state,'Working · rendering command output','Ready','Connection interrupted','Waiting for you')),inline(muted('Codex · high'),h('span',{class:'ui-key',text:'32% context'}))),fold('Status priority',muted('Pending request → recovery/buffering → live tool → thinking → working → ready.')),surface(muted(result(state,'Safety buffering · response will appear when ready.','Buffering finished.','Provider auth recovery failed.','An approval card needs a decision.'))));break;
    case 'session': root.append(surface(row('Live event rendering',state),h('dl',{},h('dt',{class:'ui-muted',text:'Workspace'}),h('dd',{text:'/workspace/floatyterm'}),h('dt',{class:'ui-muted',text:'Project / thread'}),h('dd',{text:'FloatyTerm · demo-thread'}),h('dt',{class:'ui-muted',text:'Model / settings'}),h('dd',{text:'Configured Codex model · high effort · workspace write'})),fold('Attachments and lifecycle',muted('2 attached resources · '+result(state,'Active','Saved · idle','Thread deleted · composer unavailable','Archived · resume to continue'))),actions(action('Rename',()=>{const field=h('input',{value:'Live event rendering','aria-label':'Thread title'});root.append(h('label',{},'New title',field),action('Save title',()=>feedback('Synthetic title: '+field.value)));}),action('View sessions',()=>feedback('Synthetic session list · no live threads fetched')))));break;
    case 'goal': root.append(surface(row('Give every event a UI destination',state),inline(muted(completed?'28 / 28 components reviewed':'9 / 28 components reviewed'),muted('Budget · 12k / 30k tokens')),h('progress',{class:'ui-progress',max:28,value:completed?28:9,'aria-label':'Goal progress'}),fold('Goal details',pre('Objective: Review the proposed Codex UI\nStatus: '+state+'\nElapsed: 18m\nProgress derives from supplied goal state.'))));break;
    case 'queue': root.append(surface(row('Queued messages · 2',state),h('ol',{class:'ui-list'},['Show the narrow Changes layout','Review permission cards next'].map((text,i)=>h('li',{},inline(h('span',{class:'ui-key',text:String(i+1)}),text,action('Remove',e=>{e.currentTarget.closest('li').remove();root.querySelector('.ui-title').textContent='Queued messages · '+root.querySelectorAll('li').length;feedback('Synthetic queued message removed');}))))),actions(action('Send next now',()=>feedback('Synthetic next message selected · no turn started'))),muted('Queue updates fetch authoritative state; this preview uses local messages.')));break;
    case 'integrations': root.append(surface(row('Docs MCP server',state),muted(result(state,'Fetching documentation · 2 of 3 pages','Connected · 3 tools available','Startup failed: executable unavailable.','Sign-in required.')),fold('Tool progress',pre('docs/search\nQuery: app-server output events\nFetched 2 of 3 pages')),fold('Subscriptions and app catalog',pre('Subscription: docs-events-1\nLatest event: catalog updated\nApps: documentation workspace')),actions(action('View connection details',()=>{root.querySelectorAll('details').forEach(d=>d.open=true);feedback('Synthetic MCP connection details expanded');}),state==='waiting'?action('Sign in',()=>feedback('Synthetic sign-in action · no external request')):null)));break;
    case 'account': root.append(surface(row('Account usage',state),muted('Synthetic account · no account data loaded'),h('div',{},inline(h('span',{text:'5-hour window'}),muted('32% used')),h('progress',{class:'ui-progress',max:100,value:32,'aria-label':'5-hour usage: 32 percent'})),h('div',{},inline(h('span',{text:'Context'}),muted('38k / 128k tokens')),h('progress',{class:'ui-progress',max:128,value:38,'aria-label':'Context usage: 38 thousand of 128 thousand tokens'})),fold('Auth and recovery',muted(result(state,'Refreshing account credentials…','Connected · usage refreshed','Credential refresh failed; reconnect required.','Waiting for sign-in.'))),actions(action('Refresh credentials',()=>feedback('Synthetic managed credential refresh · credentials stay outside the preview')),action('Sign in with ChatGPT',()=>feedback('Synthetic sign-in · no browser opened')))));break;
    case 'environment': root.append(surface(row('Local Mac environment',state),muted('local-mac · /workspace/floatyterm'),h('ul',{class:'ui-list'},h('li',{text:result(state,'Connecting transport…','Transport connected','Transport disconnected','Waiting for environment setup')}),h('li',{text:'Remote control: disabled'}),h('li',{text:'Workspace write · network restricted'})),fold('Platform and host capabilities',pre('Platform: macOS\nAttestation: disabled\nWindows setup events, when supplied, appear here.'))));break;
    case 'process': {
      root.append(row('Build process · process-7',state),fold('stdout / stderr',pre(result(state,'stdout: Build started\nstdout: Bundling…','stdout: Build completed\nstderr: 1 warning\nExit 0','stdout: Build started\nstderr: Missing input file\nExit 1','stdout: Continue? [y/N]\nAwaiting stdin')),true));
      if(state==='waiting') {const form=h('form',{class:'ui-inline'});const input=h('input',{placeholder:'Type process input','aria-label':'Process stdin'});form.append(input,h('button',{type:'submit',text:'Send input'}));form.addEventListener('submit',e=>{e.preventDefault();feedback('Synthetic stdin recorded: '+input.value);input.value='';});root.append(form);}root.append(muted('Separate stream identity · incremental byte decoding · output cap indicator'));break;
    }
    case 'search': root.append(surface(row('Find “event”',state),h('input',{type:'search',value:'event','aria-label':'Synthetic file search',oninput:e=>{for(const item of root.querySelectorAll('[data-result]'))item.hidden=!item.textContent.toLowerCase().includes(e.target.value.toLowerCase());}}),...['src/events.ts','src/event-state.ts','docs/event-contract.md'].map(path=>h('div',{class:'ui-result','data-result':''},action(path,()=>feedback('Synthetic file selected: '+path)))),fold('Web search results',stack(h('div',{class:'ui-result'},h('a',{href:'https://learn.chatgpt.com/docs/app-server',target:'_blank',rel:'noreferrer',text:'Codex app-server documentation ↗'}),h('p',{class:'ui-muted',text:'Primary source · protocol event lifecycle'})),muted(result(state,'Searching…','Results complete','Search failed. Previous results remain available.','Waiting for query.'))))));break;
    case 'realtime': {
      root.append(surface(row('Voice session',state),h('div',{class:'ui-wave','aria-hidden':'true'},Array.from({length:28},(_,i)=>h('i',{style:'--bar:'+ (8+(i*17%31))+'px'}))),h('div',{class:'ui-rail',text:'You · Show me the changes from this turn.'}),h('p',{text:result(state,'Codex · The changes fold contains two files…','Codex · Both changes are now visible below the reply.','Audio connection lost. Transcript preserved.','Microphone paused.')}),actions(action('Mute',e=>{const muted=e.currentTarget.textContent==='Mute';e.currentTarget.textContent=muted?'Unmute':'Mute';feedback(muted?'Synthetic microphone muted':'Synthetic microphone unmuted');}),action('Play sample tone',()=>{try{const audio=new (window.AudioContext||window.webkitAudioContext)();const oscillator=audio.createOscillator();const gain=audio.createGain();gain.gain.value=.035;oscillator.frequency.value=440;oscillator.connect(gain).connect(audio.destination);oscillator.start();oscillator.stop(audio.currentTime+.2);oscillator.onended=()=>audio.close();feedback('Played a local sample tone; no microphone requested');}catch{feedback('Audio playback unavailable');}}),action('End session',()=>localDecision(root,'Voice session ended'))),muted('Audio controls are local simulation; no recording or SDP connection.')));break;
    }
    case 'notice': root.append(h('div',{class:'ui-notice','data-state':state},h('strong',{text:result(state,'Connection interrupted · retrying','Connection recovered','Request failed','Reconnect to continue')}),h('p',{class:'ui-muted',text:result(state,'Attempt 2 of 3. Your transcript is preserved.','The request resumed successfully.','The provider could not complete the request.','This turn is waiting for account authentication.')}),fold('Details',pre('Thread: demo-thread\nTurn: turn-12\nwillRetry: '+(state==='running')+'\nThe turn is finalized only by its completion event.'))));break;
    case 'footer': root.append(h('div',{class:'ui-inline ui-between'},muted(result(state,'Working · 8.4s','Completed · 8.4s · 3 tools','Failed · 8.4s · 3 tools','Stopped · 8.4s')),badge(state)),fold('Turn details',pre('Turn: turn-12\nDuration: 8.4s\nModel: configured Codex model\nStatus: '+state+'\nSupplied moderation / verification metadata appears here.')));break;
    case 'inspector': root.append(fold('Protocol details · 3 records',stack(muted('Bounded diagnostic log · secrets and transport data excluded'),pre(JSON.stringify({type:'host.time',threadId:'demo-thread',status:state,result:'2026-10-01T10:00:00Z'},null,2)),fold('Future event fallback',pre(JSON.stringify({method:'future/event',params:{threadId:'demo-thread',message:'Safe diagnostic payload'}},null,2)))),true));break;
  }
  root.append(h('p',{class:'ui-callout',text:'Synthetic proposal · '+c.dom}));
  return root;
}
function updateProgress() { const approved=components.filter(c=>review(c.id).decision==='approved').length;const touched=components.filter(c=>['approved','changes'].includes(review(c.id).decision)).length;$('progress').textContent=touched+'/28 reviewed · '+approved+' approved'; }
function renderNav() {
  const query=$('filter').value.toLowerCase();const nav=$('catalog');nav.replaceChildren();let lastGroup='';
  components.forEach((c,i)=>{if(!(c.title+' '+c.description+' '+c.group).toLowerCase().includes(query))return;
    if(c.group!==lastGroup) {nav.append(h('div',{class:'nav-group',text:c.group}));lastGroup=c.group;}
    nav.append(h('button',{type:'button','aria-current':c.id===selected?'page':'false',onclick:()=>choose(c.id)},h('span',{class:'nav-number',text:String(i+1).padStart(2,'0')}),c.title,h('span',{class:'review-dot','data-decision':review(c.id).decision,text:review(c.id).decision==='approved'?'✓':review(c.id).decision==='changes'?'!':'○'})));
  });updateProgress();
}
function paintDemo() {
  const c=current();const state=validStates.includes(review(c.id).scenario)?review(c.id).scenario:c.initial;
  $('scenario').value=state;$('demo').style.maxWidth=width==='full'?'860px':width+'px';$('demo').replaceChildren(renderComponent(c,state));
  const fixture=JSON.parse(JSON.stringify(c.fixture));
  $('payload').textContent=JSON.stringify({note:'Representative synthetic payload, not full-schema validation. The UI object and scenario state below are proposed.',native:fixture,ui:{v:1,agent:'codex',type:coverage.find(r=>r.name===c.method)?.shared||'item.dispatch',id:'demo-thread:turn-12:item-4',scenario:state,destination:c.dom}},null,2);
}
function paintSelected() {
  const c=current();$('implemented-preview').hidden=false;$('implemented-preview').href=c.id==='turn-diff'?'../codex-turn-diff.html':'../codex-event-surfaces.html';$('component-group').textContent=c.group+' / '+String(components.indexOf(c)+1).padStart(2,'0')+' OF 28';$('component-title').textContent=c.title;$('component-description').textContent=c.description;
  $('destination').textContent='DOM: '+c.dom;$('update-rule').textContent=c.rule;$('decision').value=review(c.id).decision||'unreviewed';$('notes').value=review(c.id).notes||'';$('width').value=width;
  const routes=coverage.filter(r=>r.component===c.id);$('route-count').textContent=routes.length+' native routes assigned here';$('routes').replaceChildren(...routes.map(r=>h('li',{},h('code',{text:r.name}),muted(' · '+r.kind))));
  paintDemo();renderNav();save();$('action-feedback').textContent='Interactions stay in this preview.';
}
function stopReplay() { clearTimeout(timer);timer=null;playing=false;$('replay').textContent='Replay lifecycle'; }
function choose(id) { stopReplay();selected=id;history.replaceState(null,'','#'+id);setView('component');paintSelected(); }
function setView(view) {
  document.querySelectorAll('[data-view]').forEach(button=>{const active=button.dataset.view===view;button.setAttribute('aria-selected',String(active));$(button.dataset.view+'-view').hidden=!active;});
  if(view==='gallery')renderGallery();if(view==='events')renderEvents();if(view==='renderer'&&$('renderer-frame').getAttribute('src')==='about:blank')$('renderer-frame').src='../codex-replay.html';
}
function renderGallery() {
 $('gallery').replaceChildren(...components.map(c=>h('article',{class:'gallery-item'},h('header',{},h('h3',{text:c.title}),action('Review',()=>choose(c.id))),h('div',{class:'gallery-demo'},renderComponent(c,c.initial)),h('footer',{text:review(c.id).decision.replace('unreviewed','Unreviewed')+' · '+coverage.filter(r=>r.component===c.id).length+' routes'}))));
}
function renderEvents() {
  const q=$('event-filter').value.toLowerCase();$('event-rows').replaceChildren(...coverage.filter(r=>(r.name+' '+r.kind+' '+r.current).toLowerCase().includes(q)).map(r=>h('tr',{},h('td',{},h('span',{class:'kind',text:r.kind}),r.name),h('td',{text:r.current}),h('td',{},action(components.find(c=>c.id===r.component).title,()=>choose(r.component))))));
}
$('scenario').append(...validStates.map(value=>h('option',{value,text:({running:'Running / streaming',done:'Completed / resolved',failed:'Failed / unavailable',waiting:'Waiting / blocked'})[value]})));
$('scenario').addEventListener('change',()=>{stopReplay();record('scenario',$('scenario').value);paintDemo();});
$('width').addEventListener('change',()=>{width=$('width').value;save();paintDemo();});
$('decision').addEventListener('change',()=>record('decision',$('decision').value));$('notes').addEventListener('input',()=>record('notes',$('notes').value));
$('filter').addEventListener('input',renderNav);$('event-filter').addEventListener('input',renderEvents);
$('previous').addEventListener('click',()=>choose(components[(components.indexOf(current())+components.length-1)%components.length].id));$('next').addEventListener('click',()=>choose(components[(components.indexOf(current())+1)%components.length].id));
$('reset-demo').addEventListener('click',()=>{stopReplay();record('scenario',current().initial);paintDemo();feedback('Interaction reset; review notes preserved');});
$('replay').addEventListener('click',()=>{
 if(playing){stopReplay();return;}playing=true;$('replay').textContent='Stop replay';const states=['running','waiting','done'];let index=0;
 function step(){if(!playing)return;record('scenario',states[index++]);paintDemo();$('action-feedback').textContent='Synthetic lifecycle: '+$('scenario').selectedOptions[0].textContent;if(index<states.length)timer=setTimeout(step,1400);else stopReplay();}step();
});
document.querySelectorAll('[data-view]').forEach(b=>b.addEventListener('click',()=>{stopReplay();setView(b.dataset.view);}));
$('import-trigger').addEventListener('click',()=>$('import').click());
$('export').addEventListener('click',()=>{
 const report={version:1,protocol:'0.159.2',exportedAt:new Date().toISOString(),selected,width,reviews,components:components.map(({id,title})=>({id,title}))};const url=URL.createObjectURL(new Blob([JSON.stringify(report,null,2)],{type:'application/json'}));const link=h('a',{href:url,download:'codex-ui-review-'+new Date().toISOString().slice(0,10)+'.json'});document.body.append(link);link.click();link.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);toast('Review exported with notes and decisions');
});
$('import').addEventListener('change',async e=>{
 const file=e.target.files[0];if(!file)return;
 try {
  if(file.size>2*1024*1024)throw Error('Review file is larger than 2 MB');
  const data=JSON.parse(await file.text());if(data.version!==1||!data.reviews||typeof data.reviews!=='object')throw Error('Expected a v1 Codex UI review export');
  for(const c of components){const item=data.reviews[c.id];if(!item)continue;if(!['unreviewed','approved','changes'].includes(item.decision)||typeof item.notes!=='string')throw Error('Invalid review for '+c.id);}
  for(const c of components){const item=data.reviews[c.id];if(item)reviews[c.id]={decision:item.decision,notes:item.notes,scenario:validStates.includes(item.scenario)?item.scenario:c.initial,updatedAt:typeof item.updatedAt==='string'?item.updatedAt:new Date().toISOString()};}
  if(knownId(data.selected))selected=data.selected;if(['full','700','390'].includes(data.width))width=data.width;stopReplay();history.replaceState(null,'','#'+selected);paintSelected();renderGallery();toast('Imported review merged by component ID');
 }catch(error){toast('Could not import: '+error.message);}finally{e.target.value='';}
});
window.addEventListener('hashchange',()=>{const id=location.hash.slice(1);if(knownId(id))choose(id);});
// Exposed read-only inventory makes future extensions and manual inspection straightforward.
window.CodexUIPreview={version:1,components:components.map(c=>c.id),coverageCount:coverage.length};
paintSelected();
})();
