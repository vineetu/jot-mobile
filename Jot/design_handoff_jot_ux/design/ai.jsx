// AI settings sub-page (rev 2) + Rewrite prompt editor (rev 2).
// New IA: prompts are the protagonist. Model is one thin strip.

const CORAL = "#FF6B57";
const CORAL_DEEP = "#E0533F";
const ACTION_GRADIENT = `linear-gradient(180deg, ${CORAL}, ${CORAL_DEEP})`;
const ACTION_SHADOW = `${CORAL}66`;

// Shared sub-page header — back button + centered title + optional trailing
const SubPageHeader = ({ title, trailing }) => (
  <div style={{
    display: "grid", gridTemplateColumns: "1fr auto 1fr",
    alignItems: "center", padding: "8px 18px 12px"
  }}>
    <div style={{ display: "flex" }}>
      <div style={{
        width: 36, height: 36, borderRadius: 18,
        background: "rgba(255,255,255,0.7)",
        backdropFilter: "blur(20px)",
        WebkitBackdropFilter: "blur(20px)",
        border: "0.5px solid rgba(0,0,0,0.06)",
        display: "flex", alignItems: "center", justifyContent: "center"
      }}>
        <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
          <path d="M9 1.5L3.5 7 9 12.5" stroke="#15171C" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
        </svg>
      </div>
    </div>
    <div style={{ fontSize: 17, fontWeight: 600, color: "#15171C", letterSpacing: -0.3 }}>{title}</div>
    <div style={{ display: "flex", justifyContent: "flex-end" }}>{trailing}</div>
  </div>
);

const PillButton = ({ children, color = "#15171C", bg = "rgba(255,255,255,0.7)" }) => (
  <div style={{
    padding: "7px 14px", borderRadius: 999,
    background: bg,
    backdropFilter: "blur(20px)",
    WebkitBackdropFilter: "blur(20px)",
    border: "0.5px solid rgba(0,0,0,0.06)",
    fontSize: 13, fontWeight: 600, color
  }}>{children}</div>
);

// ─────────────────────────────────────────────────────────────
// Compact model strip — ONE place that says model status
// ─────────────────────────────────────────────────────────────
const ModelStrip = ({ state = "ready" }) => {
  const dot = state === "ready" ? "#34C759" : CORAL;
  return (
    <div style={{
      margin: "0 14px 18px",
      padding: "11px 14px 11px 12px",
      background: "rgba(255,255,255,0.55)",
      backdropFilter: "blur(28px) saturate(200%)",
      WebkitBackdropFilter: "blur(28px) saturate(200%)",
      border: "0.5px solid rgba(0,0,0,0.05)",
      borderRadius: 14,
      display: "flex", alignItems: "center", gap: 12,
      boxShadow: "0 1px 0 rgba(255,255,255,0.7) inset"
    }}>
      <window.IconTile color="#7C5CFF" size={28}>
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M14 6l4 4-10 10H4v-4L14 6z"/>
          <path d="M17 3v3M21 5h-3M19 9v2"/>
        </svg>
      </window.IconTile>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 13.5, color: "#15171C", fontWeight: 600, letterSpacing: -0.2 }}>
          Phi-4 mini
          <span style={{ color: "rgba(60,60,67,0.45)", fontWeight: 500, marginLeft: 6 }}>· 2.4 GB · on-device</span>
        </div>
        <div style={{
          display: "flex", alignItems: "center", gap: 6, marginTop: 2,
          fontSize: 11.5, color: "rgba(60,60,67,0.65)"
        }}>
          <span style={{ width: 6, height: 6, borderRadius: 3, background: dot, boxShadow: `0 0 0 2.5px ${dot}33` }} />
          {state === "ready" ? "Ready · audio never leaves your iPhone" : "Downloading…"}
        </div>
      </div>
      <div style={{ fontSize: 13, color: CORAL, fontWeight: 600 }}>Change</div>
    </div>
  );
};

// ─────────────────────────────────────────────────────────────
// Prompt card — rich, with before/after sample
// ─────────────────────────────────────────────────────────────
const PromptCard = ({ icon, iconColor, name, description, beforeText, afterContent, builtin, isLast }) => (
  <div style={{
    padding: "18px 18px 16px",
    borderBottom: isLast ? "none" : "0.5px solid rgba(60,60,67,0.10)",
    display: "grid", gridTemplateColumns: "auto 1fr auto", columnGap: 14
  }}>
    <window.IconTile color={iconColor} size={36}>{icon}</window.IconTile>
    <div style={{ minWidth: 0 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
        <span style={{
          fontSize: 16, fontWeight: 600, color: "#15171C", letterSpacing: -0.3,
          fontFamily: '"New York", "Iowan Old Style", Georgia, serif'
        }}>{name}</span>
        {builtin && (
          <span style={{
            fontSize: 9.5, fontWeight: 700, letterSpacing: 0.8, textTransform: "uppercase",
            padding: "2px 6px", borderRadius: 4,
            background: "rgba(60,60,67,0.08)", color: "rgba(60,60,67,0.65)"
          }}>Default</span>
        )}
      </div>
      <div style={{
        fontSize: 12.5, color: "rgba(60,60,67,0.65)", marginTop: 3, letterSpacing: -0.05
      }}>{description}</div>

      {/* Sample */}
      <div style={{ marginTop: 12 }}>
        <div style={{
          fontSize: 12.5, lineHeight: 1.45, color: "rgba(60,60,67,0.55)",
          fontStyle: "italic", letterSpacing: -0.1,
          display: "-webkit-box", WebkitLineClamp: 2, WebkitBoxOrient: "vertical", overflow: "hidden",
          textWrap: "pretty"
        }}>"{beforeText}"</div>
        <div style={{
          display: "flex", alignItems: "center", gap: 6,
          padding: "5px 0 5px 2px"
        }}>
          <svg width="11" height="11" viewBox="0 0 11 11" fill="none">
            <path d="M5.5 1.5v8M2.5 6.5l3 3 3-3" stroke={CORAL} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
          <span style={{ fontSize: 10, fontWeight: 700, letterSpacing: 1.2, color: CORAL, textTransform: "uppercase" }}>{name}</span>
        </div>
        <div style={{
          fontSize: 13, lineHeight: 1.45, color: "#15171C", letterSpacing: -0.1, textWrap: "pretty"
        }}>{afterContent}</div>
      </div>
    </div>
    {/* Drag handle */}
    <div style={{ display: "flex", alignItems: "flex-start", paddingTop: 8, color: "rgba(60,60,67,0.30)" }}>
      <svg width="14" height="18" viewBox="0 0 14 18" fill="currentColor">
        <circle cx="4" cy="3" r="1.4"/><circle cx="10" cy="3" r="1.4"/>
        <circle cx="4" cy="9" r="1.4"/><circle cx="10" cy="9" r="1.4"/>
        <circle cx="4" cy="15" r="1.4"/><circle cx="10" cy="15" r="1.4"/>
      </svg>
    </div>
  </div>
);

const AISettingsScreen = () => {
  const Wallpaper = window.Wallpaper;
  return (
    <div style={{ position: "absolute", inset: 0, overflow: "hidden", display: "flex", flexDirection: "column" }}>
      <Wallpaper dark={false} />
      <div style={{ position: "relative", zIndex: 1, display: "flex", flexDirection: "column", height: "100%", overflow: "hidden" }}>
        <div style={{ height: 54 }} />
        <SubPageHeader title="AI" trailing={<PillButton>Edit</PillButton>} />

        {/* Italic serif hero — gives the page weight */}
        <div style={{ padding: "8px 22px 18px" }}>
          <div style={{
            display: "flex", alignItems: "center", gap: 10
          }}>
            <div style={{
              fontSize: 44, fontWeight: 400, letterSpacing: -1.6, color: "#15171C",
              fontFamily: '"New York", "Iowan Old Style", Georgia, serif',
              lineHeight: 1.0, fontStyle: "italic"
            }}>AI.</div>
            <span style={{
              fontSize: 10, fontWeight: 700, letterSpacing: 1.2,
              padding: "3px 7px", borderRadius: 6,
              background: "rgba(255,107,87,0.14)", color: CORAL_DEEP,
              textTransform: "uppercase"
            }}>Experimental</span>
          </div>
          <div style={{
            fontSize: 14, color: "rgba(60,60,67,0.65)", marginTop: 8, letterSpacing: -0.1,
            textWrap: "pretty", maxWidth: 320
          }}>
            One-tap text transforms. Tap the wand in any transcript to run a prompt on selected text.
          </div>
        </div>

        <div style={{ flex: 1, overflow: "hidden" }}>
          {/* Single, compact model strip */}
          <ModelStrip state="ready" />

          {/* Prompts — the protagonist */}
          <div style={{ padding: "0 22px 8px", display: "flex", alignItems: "center", justifyContent: "space-between" }}>
            <div style={{
              fontSize: 11, fontWeight: 700, letterSpacing: 1.5,
              color: "rgba(60,60,67,0.55)", textTransform: "uppercase"
            }}>Your prompts · 2</div>
            <div style={{
              fontSize: 12.5, color: CORAL, fontWeight: 600, letterSpacing: -0.05
            }}>Drag to reorder</div>
          </div>

          <div style={{ padding: "0 14px 14px" }}>
            <div style={{
              background: "rgba(255,255,255,0.62)",
              backdropFilter: "blur(28px) saturate(200%)",
              WebkitBackdropFilter: "blur(28px) saturate(200%)",
              border: "0.5px solid rgba(0,0,0,0.05)",
              borderRadius: 20,
              overflow: "hidden",
              boxShadow: "0 1px 0 rgba(255,255,255,0.7) inset, 0 14px 36px -28px rgba(15,17,28,0.30)"
            }}>
              <PromptCard
                icon={<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M14 6l4 4-10 10H4v-4L14 6z"/><path d="M17 3v3M21 5h-3M19 9v2"/></svg>}
                iconColor={CORAL}
                name="Rewrite"
                description="Polish without shortening · sentence-by-sentence"
                beforeText="yo can you hear me testing the new mic gating on the keyboard"
                afterContent={<>Yo, can you hear me? Testing the new mic gating on the keyboard.</>}
                builtin
              />
              <PromptCard
                icon={<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="2" strokeLinecap="round"><circle cx="5" cy="6.5" r="1.2" fill="#fff"/><circle cx="5" cy="12" r="1.2" fill="#fff"/><circle cx="5" cy="17.5" r="1.2" fill="#fff"/><path d="M10 6.5h11M10 12h11M10 17.5h11"/></svg>}
                iconColor="#7C5CFF"
                name="Bullet points"
                description="Reformat into a clean list · keep voice"
                beforeText="three things today shipped the chrome change talked to priya about onboarding drafted the ai sheet copy"
                afterContent={
                  <div style={{ display: "flex", flexDirection: "column", gap: 1 }}>
                    <span>• Shipped the chrome change</span>
                    <span>• Talked to Priya about onboarding</span>
                    <span>• Drafted the AI sheet copy</span>
                  </div>
                }
                isLast
              />
            </div>
          </div>

          {/* Add prompt — primary CTA card */}
          <div style={{ padding: "0 14px 12px" }}>
            <div style={{
              background: "rgba(255,107,87,0.08)",
              border: `1px dashed rgba(255,107,87,0.45)`,
              borderRadius: 18,
              padding: "16px 18px",
              display: "flex", alignItems: "center", justifyContent: "center", gap: 8,
              color: CORAL, fontSize: 15, fontWeight: 600, letterSpacing: -0.1
            }}>
              <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
                <path d="M8 2v12M2 8h12" stroke={CORAL} strokeWidth="2" strokeLinecap="round"/>
              </svg>
              New prompt
            </div>
          </div>

          {/* Footer caption */}
          <div style={{
            padding: "12px 22px 0",
            fontSize: 12.5, color: "rgba(60,60,67,0.55)", letterSpacing: -0.05,
            lineHeight: 1.45, textWrap: "pretty"
          }}>
            Titles and tags use the system's built-in AI automatically. They don't need a custom prompt.
          </div>
        </div>

        <div style={{
          position: "absolute", bottom: 8, left: "50%", transform: "translateX(-50%)",
          width: 134, height: 5, borderRadius: 3, background: "rgba(0,0,0,0.4)"
        }} />
      </div>
    </div>
  );
};

// ─────────────────────────────────────────────────────────────
// Rewrite prompt editor — simplified
// System prompt is the hero. "Try it" is a slim footer pill.
// ─────────────────────────────────────────────────────────────

const SYSTEM_PROMPT = `Polish the selected text without shortening it.

Rewrite sentence by sentence. Keep the same language, meaning, voice, tone, perspective, nuance, uncertainty, emphasis, paragraph breaks, and roughly the same length as the original.

Preserve every meaningful detail, claim, qualifier, example, condition, contrast, and causal relationship.

Do not summarize, condense, or interpret. Do not add commentary or new information. Maintain the speaker's first-person voice and any technical vocabulary verbatim.`;

const RewritePromptScreen = () => {
  const Wallpaper = window.Wallpaper;
  const { IconTile } = window;

  return (
    <div style={{ position: "absolute", inset: 0, overflow: "hidden", display: "flex", flexDirection: "column" }}>
      <Wallpaper dark={false} />
      <div style={{ position: "relative", zIndex: 1, display: "flex", flexDirection: "column", height: "100%", overflow: "hidden" }}>
        <div style={{ height: 54 }} />

        {/* Sheet handle */}
        <div style={{ display: "flex", justifyContent: "center", padding: "4px 0 8px" }}>
          <div style={{ width: 36, height: 5, borderRadius: 3, background: "rgba(60,60,67,0.30)" }}/>
        </div>

        {/* Header: Cancel · title · Save */}
        <div style={{
          display: "grid", gridTemplateColumns: "1fr auto 1fr",
          alignItems: "center", padding: "4px 18px 16px"
        }}>
          <div style={{ display: "flex" }}><PillButton>Cancel</PillButton></div>
          <div style={{ fontSize: 17, fontWeight: 600, letterSpacing: -0.3, color: "#15171C" }}>Edit prompt</div>
          <div style={{ display: "flex", justifyContent: "flex-end" }}>
            <PillButton color="#fff" bg={ACTION_GRADIENT}>Save</PillButton>
          </div>
        </div>

        <div style={{ flex: 1, overflow: "hidden", padding: "0 14px 110px", display: "flex", flexDirection: "column", gap: 12 }}>
          {/* Compact header: icon + editable name + description */}
          <div style={{
            background: "rgba(255,255,255,0.62)",
            backdropFilter: "blur(28px) saturate(200%)",
            WebkitBackdropFilter: "blur(28px) saturate(200%)",
            border: "0.5px solid rgba(0,0,0,0.05)",
            borderRadius: 18,
            padding: "14px 16px",
            display: "grid", gridTemplateColumns: "auto 1fr", columnGap: 12, alignItems: "center"
          }}>
            <IconTile color={CORAL} size={40}>
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <path d="M14 6l4 4-10 10H4v-4L14 6z"/>
                <path d="M17 3v3M21 5h-3M19 9v2"/>
              </svg>
            </IconTile>
            <div>
              <div style={{
                fontSize: 19, fontWeight: 500, color: "#15171C", letterSpacing: -0.3,
                fontFamily: '"New York", "Iowan Old Style", Georgia, serif'
              }}>Rewrite</div>
              <div style={{ fontSize: 12.5, color: "rgba(60,60,67,0.65)", marginTop: 2 }}>Polish without shortening · sentence-by-sentence</div>
            </div>
          </div>

          {/* System prompt — the hero. Full-bleed editor. */}
          <div style={{
            flex: 1,
            background: "rgba(255,255,255,0.62)",
            backdropFilter: "blur(28px) saturate(200%)",
            WebkitBackdropFilter: "blur(28px) saturate(200%)",
            border: "0.5px solid rgba(0,0,0,0.05)",
            borderRadius: 18,
            display: "flex", flexDirection: "column", overflow: "hidden",
            boxShadow: "0 1px 0 rgba(255,255,255,0.7) inset, 0 14px 36px -28px rgba(15,17,28,0.30)"
          }}>
            <div style={{
              padding: "12px 16px 8px",
              display: "flex", alignItems: "center", justifyContent: "space-between",
              borderBottom: "0.5px solid rgba(60,60,67,0.10)"
            }}>
              <span style={{
                fontSize: 10.5, fontWeight: 700, letterSpacing: 1.5, color: "rgba(60,60,67,0.55)",
                textTransform: "uppercase"
              }}>System prompt</span>
              <div style={{ display: "flex", alignItems: "center", gap: 4 }}>
                <span style={{ fontSize: 11, color: "rgba(60,60,67,0.50)" }}>432 chars</span>
                <span style={{ color: "rgba(60,60,67,0.30)" }}>·</span>
                <span style={{ fontSize: 11, color: CORAL, fontWeight: 600 }}>Expand</span>
              </div>
            </div>
            <div style={{
              flex: 1, padding: "14px 16px", overflow: "hidden", position: "relative"
            }}>
              <pre style={{
                margin: 0,
                fontFamily: '"SF Mono", ui-monospace, Menlo, monospace',
                fontSize: 12.5, lineHeight: 1.6, color: "#15171C",
                whiteSpace: "pre-wrap", letterSpacing: -0.1
              }}>{SYSTEM_PROMPT}<span style={{
                display: "inline-block", width: 8, height: 14, background: CORAL,
                verticalAlign: "text-bottom", marginLeft: 1, animation: "blink 1s steps(2) infinite"
              }} /></pre>
            </div>
          </div>
        </div>

        {/* Slim "Try it" footer pill — replaces the giant Test card */}
        <div style={{
          position: "absolute", left: 14, right: 14, bottom: 26,
          background: "rgba(255,255,255,0.78)",
          backdropFilter: "blur(28px) saturate(200%)",
          WebkitBackdropFilter: "blur(28px) saturate(200%)",
          border: "0.5px solid rgba(0,0,0,0.06)",
          borderRadius: 16,
          padding: "12px 14px",
          display: "grid", gridTemplateColumns: "auto 1fr auto", alignItems: "center", columnGap: 10,
          boxShadow: "0 14px 36px -22px rgba(15,17,28,0.35)"
        }}>
          <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
            <path d="M3.5 2.5v11l9-5.5z" fill={CORAL}/>
          </svg>
          <div style={{ minWidth: 0 }}>
            <div style={{ fontSize: 13, color: "#15171C", fontWeight: 600, letterSpacing: -0.1 }}>Try this prompt</div>
            <div style={{
              fontSize: 11, color: "rgba(60,60,67,0.55)", marginTop: 1,
              overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap"
            }}>on your latest recording — "Three things today, shipped the chrome…"</div>
          </div>
          <div style={{
            padding: "7px 12px", borderRadius: 999,
            background: ACTION_GRADIENT,
            color: "#fff", fontSize: 12.5, fontWeight: 600,
            boxShadow: `0 4px 12px -2px ${ACTION_SHADOW}`
          }}>Run</div>
        </div>

        <div style={{
          position: "absolute", bottom: 8, left: "50%", transform: "translateX(-50%)",
          width: 134, height: 5, borderRadius: 3, background: "rgba(0,0,0,0.4)"
        }} />
      </div>
    </div>
  );
};

window.AISettingsScreen = AISettingsScreen;
window.RewritePromptScreen = RewritePromptScreen;

// ─────────────────────────────────────────────────────────────
// New prompt — blank canvas, with icon picker and templates
// ─────────────────────────────────────────────────────────────

const ICON_PALETTE = [
  { color: "#FF6B57", glyph: <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M14 6l4 4-10 10H4v-4L14 6z"/><path d="M17 3v3M21 5h-3M19 9v2"/></svg> },
  { color: "#7C5CFF", glyph: <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="2" strokeLinecap="round"><circle cx="5" cy="6.5" r="1.2" fill="#fff"/><circle cx="5" cy="12" r="1.2" fill="#fff"/><circle cx="5" cy="17.5" r="1.2" fill="#fff"/><path d="M10 6.5h11M10 12h11M10 17.5h11"/></svg> },
  { color: "#1FCED1", glyph: <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M4 5a2 2 0 012-2h12v16H6a2 2 0 00-2 2V5z"/><path d="M8 7h7M8 11h7"/></svg> },
  { color: "#1A8CFF", glyph: <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="2" strokeLinecap="round"><path d="M4 12v0M8 8v8M12 5v14M16 9v6M20 11v2"/></svg> },
  { color: "#34C759", glyph: <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="2" strokeLinejoin="round"><path d="M12 3l2 5 5 2-5 2-2 5-2-5-5-2 5-2 2-5z"/></svg> },
  { color: "#FF9A33", glyph: <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="12" r="9"/><path d="M9 12l2 2 4-4"/></svg> },
  { color: "#FF4F6B", glyph: <svg width="16" height="16" viewBox="0 0 24 24" fill="#fff"><path d="M12 21s-7-4.5-9.5-9.2C.8 7.7 3.3 4 7 4c2 0 3.5 1 5 2.5C13.5 5 15 4 17 4c3.7 0 6.2 3.7 4.5 7.8C19 16.5 12 21 12 21z"/></svg> },
  { color: "#8B8E96", glyph: <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="2.4" strokeLinecap="round"><path d="M5 9h14M5 15h14"/></svg> },
];

const TEMPLATES = [
  { name: "Translate to…", icon: 2 },
  { name: "Make it shorter", icon: 5 },
  { name: "More formal", icon: 0 },
  { name: "Action items", icon: 1 },
];

const NewPromptScreen = () => {
  const Wallpaper = window.Wallpaper;
  const { IconTile } = window;
  const selected = 0; // coral wand selected by default
  const sel = ICON_PALETTE[selected];

  return (
    <div style={{ position: "absolute", inset: 0, overflow: "hidden", display: "flex", flexDirection: "column" }}>
      <Wallpaper dark={false} />
      <div style={{ position: "relative", zIndex: 1, display: "flex", flexDirection: "column", height: "100%", overflow: "hidden" }}>
        <div style={{ height: 54 }} />

        {/* Sheet handle */}
        <div style={{ display: "flex", justifyContent: "center", padding: "4px 0 8px" }}>
          <div style={{ width: 36, height: 5, borderRadius: 3, background: "rgba(60,60,67,0.30)" }}/>
        </div>

        {/* Header: Cancel · title · Save (disabled until name + prompt) */}
        <div style={{
          display: "grid", gridTemplateColumns: "1fr auto 1fr",
          alignItems: "center", padding: "4px 18px 16px"
        }}>
          <div style={{ display: "flex" }}><PillButton>Cancel</PillButton></div>
          <div style={{ fontSize: 17, fontWeight: 600, letterSpacing: -0.3, color: "#15171C" }}>New prompt</div>
          <div style={{ display: "flex", justifyContent: "flex-end" }}>
            <div style={{
              padding: "7px 14px", borderRadius: 999,
              background: "rgba(255,107,87,0.18)",
              border: "0.5px solid rgba(255,107,87,0.20)",
              fontSize: 13, fontWeight: 600, color: "rgba(255,107,87,0.60)"
            }}>Save</div>
          </div>
        </div>

        <div style={{ flex: 1, overflow: "hidden", padding: "0 14px 110px", display: "flex", flexDirection: "column", gap: 14 }}>
          {/* Name + icon row */}
          <div style={{
            background: "rgba(255,255,255,0.62)",
            backdropFilter: "blur(28px) saturate(200%)",
            WebkitBackdropFilter: "blur(28px) saturate(200%)",
            border: "0.5px solid rgba(0,0,0,0.05)",
            borderRadius: 18,
            padding: "14px 16px",
            display: "grid", gridTemplateColumns: "auto 1fr", columnGap: 14, alignItems: "center"
          }}>
            <IconTile color={sel.color} size={44}>{React.cloneElement(sel.glyph, { width: 22, height: 22 })}</IconTile>
            <div>
              <div style={{
                fontSize: 19, fontWeight: 500, letterSpacing: -0.3,
                color: "rgba(60,60,67,0.40)", fontStyle: "italic",
                fontFamily: '"New York", "Iowan Old Style", Georgia, serif'
              }}>Name your prompt</div>
              <div style={{
                fontSize: 12, color: "rgba(60,60,67,0.45)", marginTop: 3, letterSpacing: -0.05
              }}>e.g. "Translate to Spanish"</div>
            </div>
          </div>

          {/* Icon picker — 8 colors */}
          <div>
            <div style={{
              padding: "0 8px 8px",
              fontSize: 10.5, fontWeight: 700, letterSpacing: 1.5,
              color: "rgba(60,60,67,0.55)", textTransform: "uppercase"
            }}>Icon</div>
            <div style={{
              background: "rgba(255,255,255,0.62)",
              backdropFilter: "blur(28px) saturate(200%)",
              WebkitBackdropFilter: "blur(28px) saturate(200%)",
              border: "0.5px solid rgba(0,0,0,0.05)",
              borderRadius: 18,
              padding: "14px 12px",
              display: "grid", gridTemplateColumns: "repeat(8, 1fr)", gap: 8
            }}>
              {ICON_PALETTE.map((p, i) => (
                <div key={i} style={{
                  display: "flex", justifyContent: "center", padding: i === selected ? 0 : 2
                }}>
                  <div style={{
                    width: i === selected ? 38 : 34,
                    height: i === selected ? 38 : 34,
                    borderRadius: i === selected ? 11 : 9,
                    background: `linear-gradient(180deg, ${p.color} 0%, ${shadeHex(p.color, -0.18)} 100%)`,
                    boxShadow: i === selected
                      ? `0 0 0 2px #fff, 0 0 0 4px ${p.color}, 0 4px 10px -2px ${p.color}66`
                      : "0 1px 0 rgba(255,255,255,0.35) inset, 0 1px 2px rgba(0,0,0,0.08)",
                    display: "flex", alignItems: "center", justifyContent: "center",
                    color: "#fff"
                  }}>{React.cloneElement(p.glyph, { width: i === selected ? 16 : 14, height: i === selected ? 16 : 14 })}</div>
                </div>
              ))}
            </div>
          </div>

          {/* System prompt — empty with helpful placeholder */}
          <div style={{
            flex: 1,
            background: "rgba(255,255,255,0.62)",
            backdropFilter: "blur(28px) saturate(200%)",
            WebkitBackdropFilter: "blur(28px) saturate(200%)",
            border: "0.5px solid rgba(0,0,0,0.05)",
            borderRadius: 18,
            display: "flex", flexDirection: "column", overflow: "hidden",
            boxShadow: "0 1px 0 rgba(255,255,255,0.7) inset, 0 14px 36px -28px rgba(15,17,28,0.30)"
          }}>
            <div style={{
              padding: "12px 16px 8px",
              display: "flex", alignItems: "center", justifyContent: "space-between",
              borderBottom: "0.5px solid rgba(60,60,67,0.10)"
            }}>
              <span style={{
                fontSize: 10.5, fontWeight: 700, letterSpacing: 1.5, color: "rgba(60,60,67,0.55)",
                textTransform: "uppercase"
              }}>System prompt</span>
              <span style={{ fontSize: 11, color: "rgba(60,60,67,0.40)" }}>0 chars</span>
            </div>
            <div style={{ flex: 1, padding: "14px 16px", overflow: "hidden", position: "relative" }}>
              <div style={{
                fontFamily: '"SF Mono", ui-monospace, Menlo, monospace',
                fontSize: 12.5, lineHeight: 1.6, color: "rgba(60,60,67,0.45)",
                letterSpacing: -0.1, textWrap: "pretty"
              }}>
                Describe how Jot should transform the selected text.{"\n\n"}
                <span style={{ color: "rgba(60,60,67,0.35)" }}>Tip: be specific about voice, length, and what to preserve. Test on a recording before saving.</span>
                <span style={{
                  display: "inline-block", width: 8, height: 14, background: CORAL,
                  verticalAlign: "text-bottom", marginLeft: 1, animation: "blink 1s steps(2) infinite"
                }} />
              </div>
            </div>
          </div>
        </div>

        {/* Start-from-template footer pill — replaces the "Try this prompt" since there's nothing to try yet */}
        <div style={{
          position: "absolute", left: 14, right: 14, bottom: 26,
          background: "rgba(255,255,255,0.78)",
          backdropFilter: "blur(28px) saturate(200%)",
          WebkitBackdropFilter: "blur(28px) saturate(200%)",
          border: "0.5px solid rgba(0,0,0,0.06)",
          borderRadius: 16,
          padding: "12px 14px",
          boxShadow: "0 14px 36px -22px rgba(15,17,28,0.35)"
        }}>
          <div style={{
            display: "flex", alignItems: "center", justifyContent: "space-between",
            marginBottom: 10
          }}>
            <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
              <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
                <path d="M2 4l3 3 7-7M2 10l3 3 7-7" stroke={CORAL} strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" opacity="0.5"/>
              </svg>
              <span style={{ fontSize: 12.5, color: "#15171C", fontWeight: 600, letterSpacing: -0.1 }}>Start from a template</span>
            </div>
            <span style={{ fontSize: 11, color: "rgba(60,60,67,0.50)" }}>Optional</span>
          </div>
          <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
            {TEMPLATES.map((t, i) => {
              const ic = ICON_PALETTE[t.icon];
              return (
                <div key={i} style={{
                  display: "inline-flex", alignItems: "center", gap: 6,
                  padding: "5px 10px 5px 5px", borderRadius: 999,
                  background: "rgba(60,60,67,0.06)",
                  border: "0.5px solid rgba(60,60,67,0.08)"
                }}>
                  <div style={{
                    width: 18, height: 18, borderRadius: 5,
                    background: `linear-gradient(180deg, ${ic.color}, ${shadeHex(ic.color, -0.18)})`,
                    display: "flex", alignItems: "center", justifyContent: "center"
                  }}>{React.cloneElement(ic.glyph, { width: 10, height: 10 })}</div>
                  <span style={{ fontSize: 12, fontWeight: 500, color: "#15171C", letterSpacing: -0.1 }}>{t.name}</span>
                </div>
              );
            })}
          </div>
        </div>

        <div style={{
          position: "absolute", bottom: 8, left: "50%", transform: "translateX(-50%)",
          width: 134, height: 5, borderRadius: 3, background: "rgba(0,0,0,0.4)"
        }} />
      </div>
    </div>
  );
};

function shadeHex(hex, amt) {
  const h = hex.replace("#", "");
  const r = parseInt(h.substr(0,2),16), g = parseInt(h.substr(2,2),16), b = parseInt(h.substr(4,2),16);
  const f = (v) => Math.max(0, Math.min(255, Math.round(v + v * amt)));
  return `#${[f(r),f(g),f(b)].map(v=>v.toString(16).padStart(2,"0")).join("")}`;
}

window.NewPromptScreen = NewPromptScreen;

// ─────────────────────────────────────────────────────────────
// "Try this prompt" — expanded result state
// Same screen as RewritePromptScreen, but the slim footer pill has
// expanded into a result panel showing before → after.
// ─────────────────────────────────────────────────────────────
const BEFORE_TEXT = "three things today shipped the chrome change talked to priya about onboarding and drafted the ai sheet copy the wizard read is sharper now and vocab help is actually pulling its weight";
const AFTER_TEXT  = "Three things today: shipped the chrome change, talked to Priya about onboarding, and drafted the AI sheet copy. The wizard read is sharper now, and vocab help is actually pulling its weight.";

const RewritePromptResultScreen = () => {
  const Wallpaper = window.Wallpaper;
  const { IconTile } = window;

  return (
    <div style={{ position: "absolute", inset: 0, overflow: "hidden", display: "flex", flexDirection: "column" }}>
      <Wallpaper dark={false} />
      <div style={{ position: "relative", zIndex: 1, display: "flex", flexDirection: "column", height: "100%", overflow: "hidden" }}>
        <div style={{ height: 54 }} />

        {/* Sheet handle */}
        <div style={{ display: "flex", justifyContent: "center", padding: "4px 0 8px" }}>
          <div style={{ width: 36, height: 5, borderRadius: 3, background: "rgba(60,60,67,0.30)" }}/>
        </div>

        {/* Header: Cancel · title · Save */}
        <div style={{
          display: "grid", gridTemplateColumns: "1fr auto 1fr",
          alignItems: "center", padding: "4px 18px 16px"
        }}>
          <div style={{ display: "flex" }}><PillButton>Cancel</PillButton></div>
          <div style={{ fontSize: 17, fontWeight: 600, letterSpacing: -0.3, color: "#15171C" }}>Edit prompt</div>
          <div style={{ display: "flex", justifyContent: "flex-end" }}>
            <PillButton color="#fff" bg={`linear-gradient(180deg, ${CORAL}, ${CORAL_DEEP})`}>Save</PillButton>
          </div>
        </div>

        {/* Compact header card (same as edit screen) */}
        <div style={{ padding: "0 14px" }}>
          <div style={{
            background: "rgba(255,255,255,0.62)",
            backdropFilter: "blur(28px) saturate(200%)",
            WebkitBackdropFilter: "blur(28px) saturate(200%)",
            border: "0.5px solid rgba(0,0,0,0.05)",
            borderRadius: 18,
            padding: "12px 16px",
            display: "grid", gridTemplateColumns: "auto 1fr auto", columnGap: 12, alignItems: "center"
          }}>
            <IconTile color={CORAL} size={36}>
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <path d="M14 6l4 4-10 10H4v-4L14 6z"/>
                <path d="M17 3v3M21 5h-3M19 9v2"/>
              </svg>
            </IconTile>
            <div>
              <div style={{
                fontSize: 17, fontWeight: 500, color: "#15171C", letterSpacing: -0.3,
                fontFamily: '"New York", "Iowan Old Style", Georgia, serif'
              }}>Rewrite</div>
              <div style={{ fontSize: 11.5, color: "rgba(60,60,67,0.65)", marginTop: 1 }}>Polish without shortening</div>
            </div>
            <span style={{
              fontSize: 11, color: "rgba(60,60,67,0.55)", fontWeight: 600,
              padding: "4px 8px", borderRadius: 6, background: "rgba(60,60,67,0.06)"
            }}>432 chars</span>
          </div>
        </div>

        {/* Result panel — replaces the slim try-this-prompt footer */}
        <div style={{ padding: "14px 14px 0", flex: 1, overflow: "hidden", display: "flex", flexDirection: "column" }}>
          <div style={{
            flex: 1,
            background: "rgba(255,255,255,0.66)",
            backdropFilter: "blur(28px) saturate(200%)",
            WebkitBackdropFilter: "blur(28px) saturate(200%)",
            border: `1px solid rgba(255,107,87,0.45)`,
            borderRadius: 20,
            boxShadow: `0 1px 0 rgba(255,255,255,0.7) inset, 0 20px 50px -28px rgba(15,17,28,0.35), 0 0 0 4px rgba(255,107,87,0.08)`,
            display: "flex", flexDirection: "column", overflow: "hidden"
          }}>
            {/* Panel header */}
            <div style={{
              padding: "12px 16px",
              display: "flex", alignItems: "center", justifyContent: "space-between",
              borderBottom: "0.5px solid rgba(60,60,67,0.10)"
            }}>
              <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                <span style={{
                  fontSize: 10.5, fontWeight: 700, letterSpacing: 1.5, color: CORAL,
                  textTransform: "uppercase"
                }}>Try this prompt</span>
                <span style={{ color: "rgba(60,60,67,0.30)" }}>·</span>
                <span style={{ fontSize: 12, color: "rgba(60,60,67,0.55)" }}>Latest recording, 5:48 PM</span>
              </div>
              <div style={{ display: "flex", alignItems: "center", gap: 4, color: "rgba(60,60,67,0.55)" }}>
                <svg width="11" height="11" viewBox="0 0 11 11" fill="none">
                  <path d="M2.5 2.5l6 6M8.5 2.5l-6 6" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"/>
                </svg>
              </div>
            </div>

            {/* Body — Before / arrow / After */}
            <div style={{ flex: 1, overflow: "hidden", padding: "16px 18px", display: "flex", flexDirection: "column", gap: 12 }}>
              {/* Before */}
              <div>
                <div style={{
                  fontSize: 10, fontWeight: 700, letterSpacing: 1.4, color: "rgba(60,60,67,0.55)",
                  textTransform: "uppercase", marginBottom: 6
                }}>Before</div>
                <div style={{
                  fontSize: 14, lineHeight: 1.5, letterSpacing: -0.1,
                  color: "rgba(60,60,67,0.65)", fontStyle: "italic", textWrap: "pretty",
                  display: "-webkit-box", WebkitLineClamp: 3, WebkitBoxOrient: "vertical", overflow: "hidden"
                }}>"{BEFORE_TEXT}"</div>
              </div>

              {/* Arrow + label */}
              <div style={{
                display: "flex", alignItems: "center", gap: 8,
                paddingLeft: 2
              }}>
                <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
                  <path d="M7 1v12M3 9l4 4 4-4" stroke={CORAL} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
                </svg>
                <span style={{ fontSize: 10.5, fontWeight: 700, letterSpacing: 1.6, color: CORAL, textTransform: "uppercase" }}>Rewrite</span>
                <span style={{ height: 1, flex: 1, background: "rgba(255,107,87,0.18)" }}/>
                <span style={{ fontSize: 11, color: "rgba(60,60,67,0.55)" }}>1.8s</span>
              </div>

              {/* After */}
              <div style={{ flex: 1, overflow: "hidden" }}>
                <div style={{
                  fontSize: 10, fontWeight: 700, letterSpacing: 1.4, color: "rgba(60,60,67,0.55)",
                  textTransform: "uppercase", marginBottom: 6
                }}>After</div>
                <div style={{
                  fontSize: 15, lineHeight: 1.5, letterSpacing: -0.15, color: "#15171C",
                  fontFamily: '"New York", "Iowan Old Style", Georgia, serif',
                  textWrap: "pretty"
                }}>"{AFTER_TEXT}"</div>
              </div>
            </div>

            {/* Action footer */}
            <div style={{
              padding: "12px 14px",
              borderTop: "0.5px solid rgba(60,60,67,0.10)",
              display: "flex", alignItems: "center", justifyContent: "space-between",
              gap: 10
            }}>
              <span style={{
                fontSize: 11.5, color: "rgba(60,60,67,0.55)", letterSpacing: -0.05,
                whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", minWidth: 0
              }}>Phi-4 mini</span>
              <div style={{ display: "flex", gap: 8, flexShrink: 0 }}>
                <div style={{
                  padding: "7px 14px", borderRadius: 999,
                  background: "rgba(255,255,255,0.7)",
                  border: "0.5px solid rgba(0,0,0,0.06)",
                  fontSize: 12.5, fontWeight: 600, color: "#15171C",
                  display: "flex", alignItems: "center", gap: 6,
                  whiteSpace: "nowrap"
                }}>
                  <svg width="11" height="11" viewBox="0 0 11 11" fill="none">
                    <rect x="2.5" y="2.5" width="6" height="7" rx="1.2" stroke="#15171C" strokeWidth="1.4"/>
                    <path d="M1 7.5V1.5C1 1 1.5.5 2 .5h5" stroke="#15171C" strokeWidth="1.4" strokeLinecap="round"/>
                  </svg>
                  Copy
                </div>
                <div style={{
                  padding: "7px 14px", borderRadius: 999,
                  background: ACTION_GRADIENT,
                  color: "#fff", fontSize: 12.5, fontWeight: 600,
                  display: "flex", alignItems: "center", gap: 6,
                  whiteSpace: "nowrap",
                  boxShadow: `0 4px 12px -2px ${ACTION_SHADOW}`
                }}>
                  <svg width="11" height="11" viewBox="0 0 11 11" fill="none">
                    <path d="M2 5.5a3.5 3.5 0 015.8-2.6M9 5.5a3.5 3.5 0 01-5.8 2.6M8.5 1v2.5H6M2.5 10V7.5H5"
                      stroke="#fff" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"/>
                  </svg>
                  Run again
                </div>
              </div>
            </div>
          </div>
        </div>

        {/* spacer for home indicator */}
        <div style={{ height: 26 }} />

        <div style={{
          position: "absolute", bottom: 8, left: "50%", transform: "translateX(-50%)",
          width: 134, height: 5, borderRadius: 3, background: "rgba(0,0,0,0.4)"
        }} />
      </div>
    </div>
  );
};

window.RewritePromptResultScreen = RewritePromptResultScreen;
