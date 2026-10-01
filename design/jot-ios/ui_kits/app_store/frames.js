/* ===========================================================================
   Jot — App Store gallery builder
   Frames are generated once (static marketing compositions). Edit COPY in the
   IPHONE / WATCH data arrays; edit screen markup in the screen builders.
   =========================================================================== */
(function(){
'use strict';

/* ---------- glyphs ---------- */
const G = {
  signal:`<svg class="ico" width="18" height="12" viewBox="0 0 18 12" fill="currentColor"><rect x="0" y="8" width="3" height="4" rx="1"/><rect x="5" y="5.5" width="3" height="6.5" rx="1"/><rect x="10" y="3" width="3" height="9" rx="1"/><rect x="15" y="0.5" width="3" height="11.5" rx="1"/></svg>`,
  wifi:`<svg class="ico" width="17" height="12" viewBox="0 0 17 12" fill="currentColor"><path d="M8.5 2.4c2.7 0 5.2 1 7 2.8l-1.6 1.7A7.6 7.6 0 0 0 8.5 4.7 7.6 7.6 0 0 0 3.1 6.9L1.5 5.2A9.9 9.9 0 0 1 8.5 2.4z"/><path d="M8.5 6.6c1.5 0 2.9.6 4 1.6L8.5 12 4.5 8.2a5.7 5.7 0 0 1 4-1.6z"/></svg>`,
  battery:`<span style="display:inline-flex;align-items:center;gap:2px"><span style="width:25px;height:12.5px;border-radius:3.5px;border:1px solid currentColor;opacity:0.5;padding:1.6px;display:block"><span style="display:block;width:78%;height:100%;border-radius:1.5px;background:currentColor"></span></span><span style="width:1.5px;height:4.5px;border-radius:1px;background:currentColor;opacity:0.5;display:block"></span></span>`,
  mic:`<svg viewBox="0 0 24 24" fill="none"><rect x="9" y="2.5" width="6" height="11.5" rx="3" fill="#fff"/><path d="M5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v3.2M8.5 21.5h7" stroke="#fff" stroke-width="2" stroke-linecap="round"/></svg>`,
  sparkle:`<svg width="22" height="22" viewBox="0 0 24 24" fill="none"><path d="M12 2.5c.7 4.2 1.9 6.9 3.9 8.6 1.8 1.4 4.4 2.2 6.6 2-4.2.7-6.9 1.9-8.6 3.9-1.4 1.8-2.2 4.4-2 6.5-.7-4.2-1.9-6.9-3.9-8.5-1.8-1.4-4.4-2.2-6.5-2 4.2-.7 6.9-1.9 8.5-3.9C11.4 6.9 12.2 4.6 12 2.5z" fill="${'#1A8CFF'}"/></svg>`,
  sync:`<svg viewBox="0 0 24 24" fill="none"><path d="M20 11a8 8 0 0 0-14-4.5M4 5v3.5h3.5M4 13a8 8 0 0 0 14 4.5M20 19v-3.5h-3.5" stroke="#F6A93B" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"/></svg>`,
  chevR:`<svg width="16" height="16" viewBox="0 0 24 24" fill="none"><path d="M9 5l7 7-7 7" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></svg>`,
};

function statusBar(o){
  o = o || {};
  return `<div class="sb">
    <span class="t">${o.time||'9:41'}</span>
    <div class="island"></div>
    <div class="rt">
      ${o.mic?'<span class="dot"></span>':''}
      ${G.signal}${G.wifi}${G.battery}
    </div>
  </div>`;
}

/* ====================================================================== */
/*  SCREEN BUILDERS — authored in iPhone-logical px (393×852)             */
/* ====================================================================== */

function trow(sn,mt){ return `<div class="trow"><span class="sn">${sn}</span><span class="mt">${mt}</span></div>`; }
function homeScreen(theme){ theme=theme||'dark';
  return `<div class="screen ${theme}">${statusBar({})}<div class="lib">
    <div class="top">
      <div class="jotw"><span class="badge">J</span><b>Jot</b></div>
      <div class="acts"><span class="iconbtn">${G.help}</span><span class="iconbtn">${G.gear}</span></div>
    </div>
    <div class="head">Speak it straight<br>into your app.</div>
    <div class="date">Wednesday, June 3</div>
    <div class="srch"><div class="searchbar">${G.search} Search transcripts</div><div class="sparkbtn">${G.sparkle}</div></div>
    <div class="tlist">
      <div class="grp-cap">Today</div>
      <div class="trow latest"><div class="lhdr"><span class="ltag">LATEST</span><span class="mt">11:58 AM · 0:58</span></div><span class="sn">“Can you hear me? This is how it looks right now…”</span></div>
      ${trow('So, researchers at September University did this, okay? And on…','11:55 AM · 20:32')}
      ${trow('So this is what Google Earth has looked like for the last decade. Aw…','11:20 AM · 6:01')}
      ${trow('Absolutely not. None of this works without the rules changing fir…','11:03 AM · 0:04')}
      ${trow('Buy it at that price — the price is nuts. And if you can’t sell it to…','10:59 AM · 0:42')}
      ${trow('I’m about to describe to you what I worked on this morning, so…','9:54 AM · 10:34')}
      <div class="grp-cap">Yesterday</div>
      ${trow('Standup — channel config, service hub vs. a dedicated slotting…','4:55 PM · 1:12')}
      <div class="fade"></div>
    </div>
    <div class="fab">${G.mic} Dictate</div>
  </div></div>`;
}

/* extra glyphs + helpers */
Object.assign(G,{
  chevL:`<svg width="22" height="22" viewBox="0 0 24 24" fill="none"><path d="M15 5l-7 7 7 7" stroke="#1A8CFF" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/></svg>`,
  globe:`<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.7"><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c3 3.2 3 14.8 0 18M12 3c-3 3.2-3 14.8 0 18"/></svg>`,
  search:`<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="7"/><path d="M21 21l-4-4" stroke-linecap="round"/></svg>`,
  doc:`<svg width="16" height="16" viewBox="0 0 24 24" fill="none"><path d="M7 3h7l4 4v14H7z" stroke="#1A8CFF" stroke-width="1.8" stroke-linejoin="round"/><path d="M14 3v4h4" stroke="#1A8CFF" stroke-width="1.8" stroke-linejoin="round"/></svg>`,
  xmk:`<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.4" stroke-linecap="round"><path d="M6 6l12 12M18 6L6 18"/></svg>`,
  book:`<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M12 6.5C10.5 5 8.5 4.4 5 4.4V18c3.5 0 5.5.6 7 2 1.5-1.4 3.5-2 7-2V4.4c-3.5 0-5.5.6-7 2.1z"/><path d="M12 6.5V20"/></svg>`,
  help:`<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="9.2"/><path d="M9.3 9.3a2.8 2.8 0 1 1 4.2 2.6c-.9.6-1.5 1.1-1.5 2.2" stroke-linecap="round"/><circle cx="12" cy="16.8" r="0.6" fill="currentColor" stroke="none"/></svg>`,
  gear:`<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><circle cx="12" cy="12" r="3.1"/><path d="M12 2.6v2.5M12 18.9v2.5M21.4 12h-2.5M5.1 12H2.6M18.6 5.4l-1.8 1.8M7.2 16.8l-1.8 1.8M18.6 18.6l-1.8-1.8M7.2 7.2 5.4 5.4" stroke-linecap="round"/></svg>`,
  plus:`<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M12 5v14M5 12h14"/></svg>`,
  micsm:`<svg width="20" height="20" viewBox="0 0 24 24" fill="none"><rect x="9.5" y="3" width="5" height="10" rx="2.5" fill="currentColor"/><path d="M6 11a6 6 0 0 0 12 0M12 17v3.2M9 20.6h6" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>`,
  ret:`<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 7l-5 5 5 5M4 12h11a4 4 0 0 0 4-4V6"/></svg>`,
  pause:`<svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="5" width="4" height="14" rx="1.5"/><rect x="14" y="5" width="4" height="14" rx="1.5"/></svg>`,
  trash:`<svg width="21" height="21" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M9 7V5h6v2M6 7l1 13h10l1-13M10 11v6M14 11v6"/></svg>`,
  check:`<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7"/></svg>`,
  chevW:`<svg width="22" height="22" viewBox="0 0 24 24" fill="none"><path d="M15 5l-7 7 7 7" stroke="#fff" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/></svg>`,
  micAmber:`<svg width="20" height="24" viewBox="0 0 24 24" fill="none"><rect x="9.5" y="3" width="5" height="10" rx="2.5" fill="#F6A93B"/><path d="M6 11a6 6 0 0 0 12 0M12 17v3M9 20h6" stroke="#F6A93B" stroke-width="1.9" stroke-linecap="round"/></svg>`,
});
function jotmark(h,c){ c=c||'#1A8CFF'; const w=Math.round(h*0.486);
  return `<svg viewBox="22 6 72 148" width="${w}" height="${h}"><g stroke="${c}" stroke-width="15" stroke-linecap="round" stroke-linejoin="round" fill="none"><path d="M58 52 L58 116 Q58 138 34 138"/><line x1="47" y1="19" x2="47" y2="29" stroke-width="5.4"/><line x1="58" y1="15" x2="58" y2="33" stroke-width="5.4"/><line x1="69" y1="19" x2="69" y2="29" stroke-width="5.4"/></g></svg>`; }
function waveBars(count, maxH, w, cls){
  let s='';
  for(let i=0;i<count;i++){
    const x=count>1?i/(count-1):0.5;
    const env=Math.sin(Math.PI*x);
    const noise=0.5+0.5*Math.abs(Math.sin(i*1.7)+Math.cos(i*0.9))/2 + 0.25*Math.abs(Math.sin(i*0.5));
    let h=Math.max(maxH*0.16, maxH*env*Math.min(1, noise*1.1+0.18));
    s+=`<i style="height:${Math.round(h)}px;width:${w}px"></i>`;
  }
  return `<div class="wv${cls?' '+cls:''}">${s}</div>`;
}

/* ---- Screen: keyboard dictating into Messages ---- */
function kbScreen(theme){ theme=theme||'dark';
  return `<div class="screen ${theme}">${statusBar({})}<div class="imsg">
    <div class="msgspace"></div>
    <div class="composer"><span class="plus">${G.plus}</span><div class="field">iMessage</div><span class="micsm">${G.micsm}</span></div>
    <div class="jotkb">
      <div class="hint"><span class="bd"></span> We tidy this up when you stop <span class="wd">${waveBars(7,13,2.5)}</span></div>
      <div class="pv"><p>can you hear me this is how it looks right now i think it’s cool it’s continue with this<span class="car"></span></p><span class="scroll"></span></div>
      <div class="ctrls">
        <div class="cc trash">${G.trash}</div>
        <div class="cc">${G.pause}</div>
        <div class="recpill"><span class="sq"></span> 00:13 <span class="rpt"></span></div>
        <div class="cc ret">${G.ret}</div>
      </div>
      <div class="botrow">${G.globe}${G.micsm}</div>
    </div>
  </div></div>`;
}

/* ---- Screen: live transcription (no waveform) ---- */
function recScreen(theme){ theme=theme||'dark';
  return `<div class="screen ${theme}">${statusBar({mic:true})}<div class="lv">
    <div class="back">${G.chevL}</div>
    <div class="lcard"><p>Capture this before it slips — the home screen should open straight into the library, and the dictate button stays<span class="tail"> pinned at the bottom</span><span class="car"></span></p></div>
    <div class="lctrls">
      <div class="cbtn">${G.pause}</div>
      <div class="stoppill"><span class="sq"></span> 0:08</div>
      <div class="cbtn trash">${G.trash}</div>
    </div>
  </div></div>`;
}

/* ---- Screen 4: all notes ---- */
function nrow(ti,me){ return `<div class="nrow"><span class="glyph">${G.doc}</span><div class="col"><div class="ti">${ti}</div><div class="me">${me}</div></div></div>`; }
function notesScreen(){
  return `<div class="screen dark">${statusBar({})}<div class="notes">
    <div class="ntop"><h1>All notes</h1><div class="search">${G.search} Search transcripts</div></div>
    <div class="grplbl">Today</div>
    <div class="ngrp">
      ${nrow('Let’s ship the editorial header on home, then revisit the recents list spacing.','9:04 AM · 0:38')}
      ${nrow('Grocery: oat milk, lemons, the good bread, and more of that coffee.','8:12 AM · 0:11')}
      ${nrow('Idea — let people ask Jot across every note, not just one.','7:40 AM · 0:22')}
    </div>
    <div class="grplbl">Yesterday</div>
    <div class="ngrp">
      ${nrow('Standup: channel config — service hub vs. a dedicated slotting layer.','4:55 PM · 1:12')}
      ${nrow('Call Mom back about the weekend.','9:30 AM · 0:06')}
    </div>
  </div></div>`;
}

/* ---- Screen 5: Ask Jot (light) ---- */
function askScreen(theme){ theme=theme||'dark';
  return `<div class="screen ${theme}">${statusBar({})}<div class="ask2">
    <div class="topbar">
      <div class="hd">
        <span class="done">Done</span>
        <div class="ttl"><b>Ask Jot</b><span>BETA</span></div>
        <span style="width:74px"></span>
      </div>
    </div>
    <div class="qh">
      <div class="ql"><div class="cap">You asked</div><div class="q">What happened on May 29?</div></div>
      <span class="another">Ask another</span>
    </div>
    <div class="body">
      <p>On May 29 you worked through how to model channels in the configuration. You decided to skip a dedicated slotting layer and treat the channel as a service hub, with a second channel acting as a store. <span class="chip">${G.doc} May 29</span></p>
      <p>From a configuration view that means three setups — email service, store, and channel cube — but underneath, only two real capabilities. <span class="chip">${G.doc} May 28</span></p>
    </div>
    <div class="srcs">
      <div class="sh"><b>SOURCES</b><span class="ln"></span></div>
      <div class="srow"><span class="tile2">${G.doc}</span><div class="c"><div class="d">May 29</div><div class="s">Standup — channel config, service hub vs. slotting layer</div></div><span class="chv">${G.chevR}</span></div>
      <div class="srow" style="border-bottom:none"><span class="tile2">${G.doc}</span><div class="c"><div class="d">May 28</div><div class="s">Email &amp; direct capabilities; three configurations</div></div><span class="chv">${G.chevR}</span></div>
      <div class="attr">Answered with Apple Intelligence · 9 notes · on-device</div>
    </div>
  </div></div>`;
}

/* ---- Screen: donations (exact app copy, honest small amounts) ---- */
function drow(mono,name,sub){
  return `<div class="drow"><span class="mono">${mono}</span><div class="dn"><b>${name}</b>${sub?`<span>${sub}</span>`:''}</div><span class="chv">${G.chevR}</span></div>`;
}
function donScreen(theme){ theme=theme||'dark';
  return `<div class="screen ${theme}">${statusBar({})}<div class="don">
    <div class="back">${G.chevL}</div>
    <div class="dttl">Donations.</div>
    <div class="lead">Jot is free, and always will be.</div>
    <div class="body">The time and clarity it gives back — speaking instead of typing, thinking out loud, catching what would’ve slipped — isn’t something everyone has access to.</div>
    <div class="saved2">Jot has saved you about 27h so far.</div>
    <div class="body2">If it’s helped, consider passing some of that forward.</div>
    <div class="csearch">${G.search} Search charities</div>
    <div class="clist2">
      ${drow('KA','Khan Academy','$20 raised · 2 donations')}
      ${drow('C','CAMFED','')}
      ${drow('PU','Pratham USA','$10 raised · 1 donation')}
      ${drow('SR','Sudan Relief Fund','')}
      ${drow('D','DonorsChoose','$10 raised · 1 donation')}
      ${drow('FL','Foster Love','')}
      <div class="fade"></div>
    </div>
  </div></div>`;
}

/* ---- Watch screens (410×502) ---- */
function whomeScreen(){
  return `<div class="wt-s"><div class="whome">
    <div class="wh-top"><div class="wh-time">6:02</div><div class="wh-jot">Jot</div></div>
    <div class="wdict">${G.mic}<span>Dictate</span></div>
    <div class="wsync"><span class="wpend">${G.sync}1 pending sync</span><span class="wstuck">· Sync stuck? ›</span></div>
    <div class="wrec-lbl">RECENT</div>
    <div class="wcard">
      <div class="wnote"><div class="ti">There.</div><div class="me">Jun 1 at 9:05 AM</div></div>
      <div class="wnote"><div class="ti">Also, the home screen…</div><div class="me">Jun 1 at 9:04 AM</div></div>
    </div>
  </div></div>`;
}
function wrecScreen(){
  return `<div class="wt-s"><div class="wrec">
    <div class="wtop"><span class="wx">${G.xmk}</span><span class="wmic">${G.micAmber}<span class="tm">6:02</span></span></div>
    <div class="wmid">
      <div class="wtimer"><span class="rd"></span><b>00:01</b></div>
      <div class="wwave">${waveBars(13,82,7,'coral')}</div>
    </div>
    <div class="wstop"><span class="sq"></span> Stop</div>
  </div></div>`;
}
function wdiagScreen(){
  return `<div class="wt-s"><div class="wdiag">
    <div class="wd-top"><span class="wx">${G.chevW}</span><span class="wd-ttl">Diagnostics</span></div>
    <div class="wd-card"><div class="wd-conn"><span class="ck">${G.check}</span>Connected</div><div class="wd-wait">2 waiting to sync</div></div>
    <div class="wd-reset">Reset sync</div>
  </div></div>`;
}

/* ====================================================================== */
/*  FRAME DATA                                                            */
/* ====================================================================== */
const IPHONE = [
  { headline:'Dictate into mail, notes,<br>messages — anywhere<br>a keyboard goes.', hsize:60, screen:homeScreen() },
  { headline:'Every word,<br>as it’s said.', sub:'Real-time transcription — nothing leaves the phone.', screen:recScreen() },
  { headline:'Dictate in<br>any app.', sub:'A keyboard that turns speech into text, anywhere.', screen:kbScreen() },
  { headline:'Ask across<br>every note.', sub:'Grounded answers, with sources, on device.', screen:askScreen() },
  { headline:'Free, and<br>always will be.', sub:'No subscription. Optional giving to charity.', screen:donScreen() },
];

const IPHONE_LIGHT = [
  { lite:true, headline:'Dictate into mail, notes,<br>messages — anywhere<br>a keyboard goes.', hsize:60, screen:homeScreen('light') },
  { lite:true, headline:'Every word,<br>as it’s said.', sub:'Real-time transcription — nothing leaves the phone.', screen:recScreen('light') },
  { lite:true, headline:'Dictate in<br>any app.', sub:'A keyboard that turns speech into text, anywhere.', screen:kbScreen('light') },
  { lite:true, headline:'Ask across<br>every note.', sub:'Grounded answers, with sources, on device.', screen:askScreen('light') },
  { lite:true, headline:'Free, and<br>always will be.', sub:'No subscription. Optional giving to charity.', screen:donScreen('light') },
];

const IPHONE_DUAL = [
  { dual:true, headline:'Light or dark,<br>right at home.', sub:'Jot follows your system — easy on the eyes, morning to midnight.',
    light:homeScreen('light'), dark:homeScreen('dark') },
];

const WATCH = [
  { cap:'Capture from your wrist', screen:whomeScreen() },
  { cap:'Recording', screen:wrecScreen() },
  { cap:'Diagnostics', screen:wdiagScreen() },
];

/* ====================================================================== */
/*  RENDER                                                                */
/* ====================================================================== */
function ipFrame(d){
  if(d.dual){
    return `<div class="frame ip lite dual2">
      <div class="headline"><h3 style="font-size:92px;letter-spacing:-2px">${d.headline}</h3>${d.sub?`<p>${d.sub}</p>`:''}</div>
      <div class="dwrap">
        <div class="mphone dark-ph"><div class="glass">${d.dark}</div></div>
        <div class="mphone light-ph"><div class="glass">${d.light}</div></div>
        <div class="modetag light-tag">☀︎ Light</div>
        <div class="modetag dark-tag">☾ Dark</div>
      </div>
    </div>`;
  }
  return `<div class="frame ip${d.lite?' lite':''}">
    <div class="headline"><h3${d.hsize?` style="font-size:${d.hsize}px;letter-spacing:-1px"`:''}>${d.headline}</h3>${d.sub?`<p>${d.sub}</p>`:''}</div>
    <div class="device"><div class="glass">${d.screen}</div></div>
  </div>`;
}
function wtFrame(d){
  return `<div class="frame wt" style="width:410px;height:502px;background:#000">${d.screen}</div>`;
}

function tile(kind, inner, capB, capS){
  return `<div class="tile">
    <div class="scaler" data-zoom><div class="wrap ${kind}">${inner}</div></div>
    <div class="cap"><b>${capB}</b><span>${capS}</span></div>
  </div>`;
}

const ipRail = document.getElementById('iphone');
const wtRail = document.getElementById('watch');
ipRail.innerHTML = IPHONE.map((d,i)=>tile('ip', ipFrame(d), String(i+1).padStart(2,'0'), d.headline.replace(/<br>/g,' ').replace(/<[^>]+>/g,''))).join('');
wtRail.innerHTML = WATCH.map((d,i)=>tile('wt', wtFrame(d), String(i+1).padStart(2,'0'), d.cap)).join('');

const ipLightRail = document.getElementById('iphonelight');
if(ipLightRail){
  const lightSet = IPHONE_LIGHT.concat(IPHONE_DUAL);
  ipLightRail.innerHTML = lightSet.map((d,i)=>tile('ip', ipFrame(d), String(i+1).padStart(2,'0'), d.headline.replace(/<br>/g,' ').replace(/<[^>]+>/g,''))).join('');
}

/* ---------- focus zoom ---------- */
const focus = document.getElementById('focus');
const finner = focus.querySelector('.focus-inner');
document.querySelectorAll('[data-zoom]').forEach(el=>{
  el.addEventListener('click', ()=>{
    const src = el.querySelector('.frame');
    const isIp = src.classList.contains('ip');
    const W = isIp?1290:410, H = isIp?2796:502;
    finner.innerHTML = src.outerHTML;
    const f = finner.querySelector('.frame');
    const s = Math.min(window.innerHeight*0.94/H, window.innerWidth*0.94/W);
    finner.style.width = (W*s)+'px';
    finner.style.height = (H*s)+'px';
    f.style.transform = `scale(${s})`;
    f.style.position = 'absolute';
    f.style.top = '0'; f.style.left = '0';
    f.style.transformOrigin = 'top left';
    focus.classList.add('on');
  });
});
focus.addEventListener('click', ()=> focus.classList.remove('on'));

/* ---------- full-size export helper (for PNG capture) ---------- */
window.__sets = { ip:IPHONE, ipl:IPHONE_LIGHT, ipd:IPHONE_DUAL, wt:WATCH };
window.__frameHTML = function(kind, i){
  const isWt = kind==='wt';
  const d = window.__sets[kind][i];
  return isWt?wtFrame(d):ipFrame(d);
};
window.__exportFrame = function(kind, i){
  const isWt = kind==='wt';
  const d = window.__sets[kind][i];
  const W = isWt?410:1290, H = isWt?502:2796;
  const html = isWt?wtFrame(d):ipFrame(d);
  document.body.style.cssText = 'margin:0;padding:0;background:#000;overflow:hidden';
  document.body.innerHTML = `<div id="__exp" style="position:fixed;top:0;left:0;width:${W}px;height:${H}px;overflow:hidden;transform-origin:top left">${html}</div>`;
  window.scrollTo(0,0);
  return {W,H};
};
/* pan the current export frame so tile (x,y) sits at viewport top-left */
window.__tile = function(x,y){
  const el = document.getElementById('__exp');
  if(el){ el.style.transform = `translate(${-x}px,${-y}px)`; }
};

})();
