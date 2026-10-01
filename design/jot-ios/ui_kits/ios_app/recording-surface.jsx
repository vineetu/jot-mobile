/* recording-surface.jsx — Jot cold-start recording view + the swipe-back cue.
   The §2.9 moment: Jot was forced foreground only to grab the mic. The top copy
   reassures; the bottom silently demos the iOS "swipe right to your last app"
   gesture. No live transcript yet (it appears ~10s later, once the cue is gone).
   Exposes RecordingSurface + SwipeCue + StatusBar to window. */

const Gl = {
  chevL:`<svg width="22" height="22" viewBox="0 0 24 24" fill="none"><path d="M15 5l-7 7 7 7" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/></svg>`,
  pause:`<svg width="19" height="19" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="5" width="4" height="14" rx="1.5"/><rect x="14" y="5" width="4" height="14" rx="1.5"/></svg>`,
  trash:`<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M9 7V5h6v2M6 7l1 13h10l1-13M10 11v6M14 11v6"/></svg>`,
  signal:`<svg class="ico" width="18" height="12" viewBox="0 0 18 12" fill="currentColor"><rect x="0" y="8" width="3" height="4" rx="1"/><rect x="5" y="5.5" width="3" height="6.5" rx="1"/><rect x="10" y="3" width="3" height="9" rx="1"/><rect x="15" y="0.5" width="3" height="11.5" rx="1"/></svg>`,
  wifi:`<svg class="ico" width="17" height="12" viewBox="0 0 17 12" fill="currentColor"><path d="M8.5 2.4c2.7 0 5.2 1 7 2.8l-1.6 1.7A7.6 7.6 0 0 0 8.5 4.7 7.6 7.6 0 0 0 3.1 6.9L1.5 5.2A9.9 9.9 0 0 1 8.5 2.4z"/><path d="M8.5 6.6c1.5 0 2.9.6 4 1.6L8.5 12 4.5 8.2a5.7 5.7 0 0 1 4-1.6z"/></svg>`,
  battery:`<span style="display:inline-flex;align-items:center;gap:2px"><span style="width:25px;height:12.5px;border-radius:3.5px;border:1px solid currentColor;opacity:0.5;padding:1.6px;display:block"><span style="display:block;width:72%;height:100%;border-radius:1.5px;background:currentColor"></span></span><span style="width:1.5px;height:4.5px;border-radius:1px;background:currentColor;opacity:0.5;display:block"></span></span>`,
};
const H = (s) => ({ dangerouslySetInnerHTML:{ __html:s } });

function StatusBar(){
  return (
    <div className="sb">
      <span className="t">9:41</span>
      <div className="island"></div>
      <div className="rt">
        <span {...H(Gl.signal)} />
        <span {...H(Gl.wifi)} />
        <span {...H(Gl.battery)} />
      </div>
    </div>
  );
}

/* ---- the looping app-switch cue ----
   Exactly the iOS gesture: as a finger drags right along the home bar, the Jot
   screen shrinks into a card and slides right while the previous app's card
   follows in from the left — both tracking the finger together. No text. */
function SwipeCue(){
  return (
    <div className="cue cueB">
      <div className="stage">
        {/* the app you came from — slides in from the left */}
        <div className="appcard prev">
          <div className="ac-bar">
            <span className="ac-ic ac-grey"></span>
            <span className="ac-name"></span>
          </div>
          <span className="ac-row"></span>
          <span className="ac-row"></span>
          <span className="ac-row s"></span>
        </div>
        {/* Jot — the current app, shrinks to a card and exits right */}
        <div className="appcard jot">
          <div className="ac-bar">
            <span className="ac-ic ac-j">j</span>
            <span className="ac-name jot"></span>
          </div>
          <span className="ac-head"></span>
          <span className="ac-row"></span>
          <span className="ac-row s"></span>
        </div>
      </div>
      <div className="home"></div>
      <div className="touch"></div>
    </div>
  );
}

/* ---- full cold-start recording surface ---- */
function RecordingSurface({ theme }){
  return (
    <div className={`screen ${theme}`}>
      <StatusBar />
      <div className="rec">
        <div className="back" {...H(Gl.chevL)} />
        <div className="reassure">
          <h1>Keep talking — Jot’s still listening.</h1>
          <p>You don’t have to stay here. Head back to your app; we’ll tidy up the text once you stop.</p>
        </div>
        <div className="spacer"></div>
        <div className="lctrls">
          <div className="cbtn trash" {...H(Gl.trash)} />
          <div className="cbtn" {...H(Gl.pause)} />
          <div className="stoppill"><span className="sq"></span> <span className="tm">0:08</span></div>
        </div>
        <SwipeCue />
      </div>
    </div>
  );
}

Object.assign(window, { RecordingSurface, SwipeCue, StatusBar });
