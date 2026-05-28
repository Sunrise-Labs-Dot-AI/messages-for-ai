// ────────────────────────────────────────────────────────────
// Texting Wrapped — card components + carousel
// ────────────────────────────────────────────────────────────
// From a Claude Design handoff (claude.ai/design). The original prototype
// hard-coded a DATA object; this version reads window.WRAPPED_DATA so the
// texting-analytics skill can inject a real analysis.json via build_wrapped.py.
// When window.WRAPPED_DATA is absent (opening index.html directly), it falls
// back to the design's sample data so the prototype still renders standalone.

const { useState, useEffect, useRef, useMemo, useCallback } = React;

// ── Data ────────────────────────────────────────────────────
// Injected by build_wrapped.py as window.WRAPPED_DATA; sample fallback below.
const DATA = (typeof window !== 'undefined' && window.WRAPPED_DATA) || {
  year: 2026,
  totalSent: 12400,
  topPeople: [
    { name: 'Maya Chen',     count: 2847, tag: 'best friend' },
    { name: 'Daniel Park',   count: 1962, tag: 'partner' },
    { name: 'Jordan Reyes',  count: 1403, tag: 'sibling' },
    { name: 'Sophie Liu',    count: 982,  tag: 'co-founder' },
    { name: 'Alex Whitman',  count: 711,  tag: 'mom' },
  ],
  median: 8.6,           // min
  mean: 85.5,            // min
  fastPct: 47,           // % within 5 min
  ballInCourt: 93,       // % active threads waiting on you
  groupContribPct: 0.7,
  silentGroups: 12,
  totalGroups: 15,
  worstGhost: { messages: 1589, name: 'kayak crew 🚣' },
  archetype: {
    name: 'The Group Chat Ghost',
    verdict: 'present in name, absent in spirit.',
    why: 'fast 1:1 replies, silent in 12 of 15 groups, 93% of threads waiting on you.',
  },
  // cards: ordered list of card keys to render. Absent → full 7-card arc.
};

// Full card arc — used to keep each card's designed palette even when some
// cards are omitted (build_wrapped drops cards the analysis can't populate).
const FULL_ARC = ['cover', 'volume', 'people', 'latency', 'groups', 'archetype', 'share'];

// ── Hooks ───────────────────────────────────────────────────

// Count-up animation, eased
function useCountUp(target, durationMs = 1100, active = true, startDelay = 200) {
  const [val, setVal] = useState(active ? 0 : target);
  const wasActive = useRef(active);
  useEffect(() => {
    if (!active) {
      // Reset only if we were previously active
      if (wasActive.current) setVal(0);
      wasActive.current = false;
      return;
    }
    wasActive.current = true;
    let raf = 0;
    let startedAt = null;
    let cancelled = false;
    const tick = (t) => {
      if (cancelled) return;
      if (startedAt === null) startedAt = t;
      const k = Math.min(1, (t - startedAt) / durationMs);
      const eased = 1 - Math.pow(1 - k, 3);
      setVal(target * eased);
      if (k < 1) raf = requestAnimationFrame(tick);
    };
    const delayTimer = setTimeout(() => {
      raf = requestAnimationFrame(tick);
    }, startDelay);
    return () => {
      cancelled = true;
      clearTimeout(delayTimer);
      if (raf) cancelAnimationFrame(raf);
    };
  }, [target, durationMs, active, startDelay]);
  return val;
}

function fmt(n, decimals = 0) {
  if (decimals > 0) return n.toFixed(decimals);
  return Math.round(n).toLocaleString('en-US');
}

// short archetype tag for the recap tile (last word, or explicit .short)
function archetypeShort() {
  if (DATA.archetype && DATA.archetype.short) return DATA.archetype.short;
  const name = (DATA.archetype && DATA.archetype.name) || '';
  const parts = name.replace(/^The\s+/i, '').split(' ');
  return parts[parts.length - 1] || '—';
}

// ── Card shell ──────────────────────────────────────────────

function CardShell({ tone, treatment, label, children, footer, onTap }) {
  const titleFamily =
    treatment.titleFont === 'serif' ? treatment.serif :
    treatment.titleFont === 'mono'  ? treatment.mono  : treatment.sans;
  const bodyFamily =
    treatment.bodyFont === 'serif' ? treatment.serif :
    treatment.bodyFont === 'mono'  ? treatment.mono  : treatment.sans;
  return (
    <div
      onClick={onTap}
      style={{
        position: 'absolute', inset: 0,
        background: tone.bg,
        color: tone.ink,
        padding: '78px 30px 62px',
        display: 'flex', flexDirection: 'column',
        fontFamily: bodyFamily,
        overflow: 'hidden',
      }}>
      {/* Grain texture overlay */}
      {treatment.grain > 0 && (
        <div style={{
          position: 'absolute', inset: 0, pointerEvents: 'none',
          opacity: treatment.grain,
          backgroundImage: 'url("data:image/svg+xml;utf8,<svg xmlns=\\"http://www.w3.org/2000/svg\\" width=\\"160\\" height=\\"160\\"><filter id=\\"n\\"><feTurbulence type=\\"fractalNoise\\" baseFrequency=\\"0.9\\" numOctaves=\\"2\\" seed=\\"3\\"/><feColorMatrix values=\\"0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 1 0\\"/></filter><rect width=\\"160\\" height=\\"160\\" filter=\\"url(%23n)\\"/></svg>")',
          mixBlendMode: 'overlay',
        }}/>
      )}

      {/* Top label */}
      {label && (
        <div style={{
          fontFamily: treatment.mono, fontSize: 11, letterSpacing: '0.12em',
          textTransform: 'uppercase', color: tone.soft, fontWeight: 500,
        }}>{label}</div>
      )}

      <div style={{ position: 'relative', flex: 1, display: 'flex', flexDirection: 'column', minHeight: 0 }}>
        {children}
      </div>

      {footer && (
        <div style={{
          fontFamily: treatment.mono, fontSize: 10.5, letterSpacing: '0.12em',
          textTransform: 'uppercase', color: tone.soft, fontWeight: 500,
        }}>{footer}</div>
      )}
    </div>
  );
}

// ── Cards ───────────────────────────────────────────────────

// Card 1: Cover
function CoverCard({ tone, treatment, active }) {
  const titleFamily =
    treatment.titleFont === 'serif' ? treatment.serif : treatment.sans;
  const isSerif = treatment.titleFont === 'serif';
  return (
    <CardShell
      tone={tone} treatment={treatment}
      label={`Annual report · ${DATA.year}`}
      footer="swipe to begin →">
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'flex-end', paddingBottom: 12 }}>
        <div style={{
          fontFamily: titleFamily,
          fontStyle: isSerif ? 'italic' : 'normal',
          fontWeight: isSerif ? 400 : 700,
          fontSize: 76, lineHeight: 0.92,
          letterSpacing: isSerif ? '-0.02em' : '-0.04em',
          textWrap: 'balance',
        }}>
          <div style={{ opacity: active ? 1 : 0, transform: active ? 'translateY(0)' : 'translateY(20px)', transition: 'all 700ms cubic-bezier(.2,.7,.2,1) 100ms' }}>Your</div>
          <div style={{ opacity: active ? 1 : 0, transform: active ? 'translateY(0)' : 'translateY(20px)', transition: 'all 700ms cubic-bezier(.2,.7,.2,1) 220ms' }}>Texting</div>
          <div style={{ opacity: active ? 1 : 0, transform: active ? 'translateY(0)' : 'translateY(20px)', transition: 'all 700ms cubic-bezier(.2,.7,.2,1) 340ms' }}>Wrapped</div>
          <div style={{
            opacity: active ? 1 : 0, transform: active ? 'translateY(0)' : 'translateY(20px)',
            transition: 'all 700ms cubic-bezier(.2,.7,.2,1) 460ms',
            fontFamily: treatment.mono, fontSize: 22, letterSpacing: '0.05em', marginTop: 18, fontWeight: 500, fontStyle: 'normal',
          }}>{DATA.year}</div>
        </div>
      </div>
    </CardShell>
  );
}

// Card 2: Hero number — total texts
function VolumeCard({ tone, treatment, active }) {
  const n = useCountUp(DATA.totalSent, 1400, active, 150);
  const isSerif = treatment.numberFont === 'serif';
  const italic = isSerif && treatment.italicNumbers;
  const perDay = DATA.totalSent ? Math.round(DATA.totalSent / 365) : null;
  return (
    <CardShell
      tone={tone} treatment={treatment}
      label="01 · the volume"
      footer={perDay ? `that's ~${perDay} a day, every day.` : 'across every thread on your phone.'}>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center' }}>
        <div style={{ fontSize: 14, letterSpacing: '0.12em', textTransform: 'uppercase', fontFamily: treatment.mono, color: tone.soft, marginBottom: 14 }}>
          You sent
        </div>
        <div style={{
          fontFamily: isSerif ? treatment.serif : treatment.sans,
          fontStyle: italic ? 'italic' : 'normal',
          fontWeight: isSerif ? 400 : 700,
          fontSize: 108, lineHeight: 0.88,
          letterSpacing: isSerif ? '-0.045em' : '-0.06em',
          marginBottom: 12,
          whiteSpace: 'nowrap',
        }}>
          {fmt(n)}
        </div>
        <div style={{
          fontFamily: isSerif ? treatment.serif : treatment.sans,
          fontStyle: italic ? 'italic' : 'normal',
          fontWeight: isSerif ? 400 : 600,
          fontSize: 38, lineHeight: 1.0,
          letterSpacing: isSerif ? '-0.02em' : '-0.03em',
        }}>
          texts.
        </div>
        <div style={{ marginTop: 24, fontFamily: treatment.mono, fontSize: 13, color: tone.soft, letterSpacing: '0.04em' }}>
          across iMessage + WhatsApp
        </div>
      </div>
    </CardShell>
  );
}

// Card 3: Top People
function PeopleCard({ tone, treatment, active }) {
  const people = DATA.topPeople || [];
  const max = people.length ? people[0].count : 1;
  const isSerif = treatment.titleFont === 'serif';
  return (
    <CardShell
      tone={tone} treatment={treatment}
      label="02 · your inner circle"
      footer="five names, half your year.">
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'flex-start', paddingTop: 8 }}>
        <div style={{
          fontFamily: isSerif ? treatment.serif : treatment.sans,
          fontStyle: isSerif ? 'italic' : 'normal',
          fontWeight: isSerif ? 400 : 700,
          fontSize: 44, lineHeight: 0.95,
          letterSpacing: isSerif ? '-0.025em' : '-0.04em',
          marginBottom: 22,
        }}>
          The top five.
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          {people.map((p, i) => {
            const pct = (p.count / max) * 100;
            return (
              <div key={p.name} style={{
                opacity: active ? 1 : 0, transform: active ? 'translateX(0)' : 'translateX(-12px)',
                transition: `all 500ms cubic-bezier(.2,.7,.2,1) ${200 + i * 90}ms`,
              }}>
                <div style={{ display: 'flex', alignItems: 'baseline', gap: 12, marginBottom: 6 }}>
                  <span style={{ fontFamily: treatment.mono, fontSize: 12, color: tone.soft, width: 18, fontWeight: 500, flexShrink: 0 }}>0{i + 1}</span>
                  <span style={{
                    fontFamily: isSerif ? treatment.serif : treatment.sans,
                    fontWeight: isSerif ? 500 : 600,
                    fontSize: 22, letterSpacing: '-0.01em',
                    flex: 1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
                  }}>{p.name}</span>
                  <span style={{ fontFamily: treatment.mono, fontSize: 12, color: tone.soft, fontWeight: 500, flexShrink: 0 }}>
                    {p.count.toLocaleString()}
                  </span>
                </div>
                <div style={{ position: 'relative', height: 4, background: 'currentColor', opacity: 0.32, marginLeft: 30, borderRadius: 2 }}>
                  <div style={{
                    position: 'absolute', left: 0, top: -2, bottom: -2,
                    width: active ? `${pct}%` : 0,
                    background: 'currentColor', opacity: 1, borderRadius: 2,
                    transition: `width 900ms cubic-bezier(.2,.7,.2,1) ${280 + i * 90}ms`,
                  }}/>
                </div>
                <div style={{ marginLeft: 30, marginTop: 5, fontFamily: treatment.mono, fontSize: 10, color: tone.soft, letterSpacing: '0.08em', textTransform: 'uppercase' }}>
                  {p.tag}
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </CardShell>
  );
}

// Card 4: Reply behavior
function LatencyCard({ tone, treatment, active }) {
  const med = useCountUp(DATA.median, 1100, active, 180);
  const ballPct = useCountUp(DATA.ballInCourt, 1200, active, 500);
  const isSerif = treatment.numberFont === 'serif';
  const italic = isSerif && treatment.italicNumbers;
  return (
    <CardShell
      tone={tone} treatment={treatment}
      label="03 · the latency"
      footer="fast on first reply. slow on follow-through.">
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 18 }}>
        <div>
          <div style={{ fontFamily: treatment.mono, fontSize: 12, letterSpacing: '0.12em', textTransform: 'uppercase', color: tone.soft, marginBottom: 8 }}>
            Your median reply
          </div>
          <div style={{ display: 'flex', alignItems: 'flex-end', gap: 0, flexWrap: 'nowrap' }}>
            <div style={{
              fontFamily: isSerif ? treatment.serif : treatment.sans,
              fontStyle: italic ? 'italic' : 'normal',
              fontWeight: isSerif ? 400 : 700,
              fontSize: 116, lineHeight: 0.88,
              letterSpacing: isSerif ? '-0.045em' : '-0.06em',
            }}>{fmt(med, 1)}</div>
          </div>
          <div style={{
            marginTop: 10,
            fontFamily: treatment.mono,
            fontWeight: 500,
            fontSize: 13, letterSpacing: '0.14em',
            textTransform: 'uppercase',
            color: tone.soft,
          }}>minutes</div>
        </div>

        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14, marginTop: 6 }}>
          <Stat treatment={treatment} tone={tone} value={`${fmt(DATA.mean, 1)}m`} label="mean reply" />
          <Stat treatment={treatment} tone={tone} value={`${DATA.fastPct}%`} label="within 5 min" />
        </div>

        <div style={{ marginTop: 18, paddingTop: 18, borderTop: `1px solid ${tone.ink}`, opacity: active ? 1 : 0, transition: 'opacity 700ms ease 600ms' }}>
          <div style={{
            fontFamily: isSerif ? treatment.serif : treatment.sans,
            fontStyle: italic ? 'italic' : 'normal',
            fontWeight: isSerif ? 400 : 700,
            fontSize: 64, lineHeight: 0.9,
            letterSpacing: isSerif ? '-0.03em' : '-0.05em',
          }}>{fmt(ballPct)}%</div>
          <div style={{ fontFamily: treatment.mono, fontSize: 12, letterSpacing: '0.06em', color: tone.soft, marginTop: 4 }}>
            of active threads waiting on you.
          </div>
        </div>
      </div>
    </CardShell>
  );
}

function Stat({ treatment, tone, value, label }) {
  return (
    <div style={{ paddingTop: 10, borderTop: `1px solid ${tone.ink}` }}>
      <div style={{
        fontFamily: treatment.numberFont === 'serif' ? treatment.serif : treatment.sans,
        fontWeight: treatment.numberFont === 'serif' ? 400 : 700,
        fontStyle: treatment.italicNumbers ? 'italic' : 'normal',
        fontSize: 36, lineHeight: 1, letterSpacing: '-0.03em',
      }}>{value}</div>
      <div style={{ marginTop: 4, fontFamily: treatment.mono, fontSize: 11, color: tone.soft, letterSpacing: '0.06em', textTransform: 'uppercase' }}>
        {label}
      </div>
    </div>
  );
}

// Card 5: Group chat reveal
function GroupsCard({ tone, treatment, active }) {
  const pct = useCountUp(DATA.groupContribPct, 1100, active, 180);
  const isSerif = treatment.numberFont === 'serif';
  const italic = isSerif && treatment.italicNumbers;
  return (
    <CardShell
      tone={tone} treatment={treatment}
      label="04 · the ghost data"
      footer="the receipts don't lie.">
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 22 }}>
        <div>
          <div style={{ fontFamily: treatment.mono, fontSize: 12, letterSpacing: '0.12em', textTransform: 'uppercase', color: tone.soft, marginBottom: 8 }}>
            Your share of every group thread
          </div>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 6, flexWrap: 'nowrap', whiteSpace: 'nowrap' }}>
            <div style={{
              fontFamily: isSerif ? treatment.serif : treatment.sans,
              fontStyle: italic ? 'italic' : 'normal',
              fontWeight: isSerif ? 400 : 700,
              fontSize: 132, lineHeight: 0.85,
              letterSpacing: isSerif ? '-0.045em' : '-0.07em',
              paddingRight: isSerif ? 14 : 0,
            }}>{pct.toFixed(1)}</div>
            <div style={{
              fontFamily: isSerif ? treatment.serif : treatment.sans,
              fontStyle: italic ? 'italic' : 'normal',
              fontWeight: isSerif ? 400 : 600,
              fontSize: 52, letterSpacing: '-0.04em',
            }}>%</div>
          </div>
        </div>

        <div style={{
          paddingTop: 16, borderTop: `1px solid ${tone.ink}`,
          fontFamily: isSerif ? treatment.serif : treatment.sans,
          fontStyle: isSerif ? 'italic' : 'normal',
          fontWeight: isSerif ? 400 : 600,
          fontSize: 30, lineHeight: 1.1, letterSpacing: '-0.02em',
          textWrap: 'balance',
        }}>
          Silent in <span style={{ textDecoration: 'underline', textUnderlineOffset: 6 }}>{DATA.silentGroups} of {DATA.totalGroups}</span> groups.
        </div>

        {DATA.worstGhost && (
          <div style={{
            padding: '14px 16px',
            border: `1px solid ${tone.ink}`,
            opacity: active ? 1 : 0, transform: active ? 'translateY(0)' : 'translateY(8px)',
            transition: 'all 600ms ease 700ms',
          }}>
            <div style={{ fontFamily: treatment.mono, fontSize: 10.5, letterSpacing: '0.08em', textTransform: 'uppercase', color: tone.soft, marginBottom: 4 }}>
              Top offender · "{DATA.worstGhost.name}"
            </div>
            <div style={{ fontFamily: treatment.mono, fontSize: 14, fontWeight: 500 }}>
              {DATA.worstGhost.messages.toLocaleString()} messages. You sent {DATA.worstGhost.userSent != null ? DATA.worstGhost.userSent : 0}.
            </div>
          </div>
        )}
      </div>
    </CardShell>
  );
}

// Card 6: Archetype
function ArchetypeCard({ tone, treatment, active }) {
  const isSerif = treatment.titleFont === 'serif';
  const italic = isSerif && treatment.italicNumbers;
  const lines = DATA.archetype.name.split(' ');
  return (
    <CardShell
      tone={tone} treatment={treatment}
      label="05 · your archetype"
      footer={`fits ${DATA.archetype.why}`}>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center' }}>
        <div style={{ fontFamily: treatment.mono, fontSize: 12, letterSpacing: '0.12em', textTransform: 'uppercase', color: tone.soft, marginBottom: 14 }}>
          You are
        </div>
        <div style={{
          fontFamily: isSerif ? treatment.serif : treatment.sans,
          fontStyle: italic ? 'italic' : 'normal',
          fontWeight: isSerif ? 400 : 800,
          fontSize: 86, lineHeight: 0.86,
          letterSpacing: isSerif ? '-0.04em' : '-0.06em',
        }}>
          {lines.map((w, i) => (
            <div key={i} style={{
              opacity: active ? 1 : 0,
              transform: active ? 'translateY(0)' : 'translateY(18px)',
              transition: `all 700ms cubic-bezier(.2,.7,.2,1) ${300 + i * 160}ms`,
            }}>{w}</div>
          ))}
        </div>
        <div style={{
          marginTop: 28, paddingTop: 18, borderTop: `1px solid ${tone.ink}`,
          fontFamily: isSerif ? treatment.serif : treatment.sans,
          fontStyle: isSerif ? 'italic' : 'normal',
          fontWeight: isSerif ? 400 : 500,
          fontSize: 22, lineHeight: 1.2, letterSpacing: '-0.01em',
          opacity: active ? 1 : 0, transition: 'opacity 800ms ease 900ms',
        }}>
          {DATA.archetype.verdict}
        </div>
      </div>
    </CardShell>
  );
}

// Card 7: Share
function ShareCard({ tone, treatment, active, onShare, shareState }) {
  const isSerif = treatment.titleFont === 'serif';
  const accent = tone.accent || tone.ink;
  const recap = [
    DATA.totalSent ? { stat: fmt(DATA.totalSent), label: 'texts' }
                   : { stat: `${fmt(DATA.median, 1)}m`, label: 'median reply' },
    { stat: `${DATA.ballInCourt}%`, label: 'ball in court' },
    { stat: `${Number(DATA.groupContribPct).toFixed(1)}%`, label: 'group share' },
    { stat: archetypeShort(), label: 'archetype' },
  ];
  return (
    <CardShell
      tone={tone} treatment={treatment}
      label={`Wrapped · ${DATA.year}`}
      footer="sunriselabs.ai · messagesfor.ai">
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column' }}>
        <div style={{
          fontFamily: isSerif ? treatment.serif : treatment.sans,
          fontStyle: isSerif ? 'italic' : 'normal',
          fontWeight: isSerif ? 400 : 700,
          fontSize: 50, lineHeight: 0.92,
          letterSpacing: isSerif ? '-0.025em' : '-0.04em',
          marginBottom: 22,
          textWrap: 'balance',
        }}>
          Your year, on the record.
        </div>

        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 22 }}>
          {recap.map((r, i) => (
            <RecapTile key={i} treatment={treatment} tone={tone} stat={r.stat} label={r.label} />
          ))}
        </div>

        <button
          onClick={(e) => { e.stopPropagation(); onShare(); }}
          style={{
            marginTop: 'auto',
            width: '100%',
            padding: '18px 20px',
            border: 'none',
            background: tone.ink,
            color: tone.bg && tone.bg.startsWith('#') ? tone.bg : '#fff',
            fontFamily: treatment.mono,
            fontSize: 13, letterSpacing: '0.18em', textTransform: 'uppercase', fontWeight: 600,
            cursor: 'pointer',
            transition: 'transform 120ms ease',
          }}
          onMouseDown={(e) => e.currentTarget.style.transform = 'scale(0.98)'}
          onMouseUp={(e) => e.currentTarget.style.transform = 'scale(1)'}
          onMouseLeave={(e) => e.currentTarget.style.transform = 'scale(1)'}>
          {shareState === 'shared' ? '✓ Copied to share' : 'Share your Wrapped'}
        </button>
      </div>
    </CardShell>
  );
}

function RecapTile({ treatment, tone, stat, label }) {
  const isSerif = treatment.numberFont === 'serif';
  return (
    <div style={{
      padding: '14px 14px 12px',
      border: `1px solid ${tone.ink}`,
    }}>
      <div style={{
        fontFamily: isSerif ? treatment.serif : treatment.sans,
        fontStyle: treatment.italicNumbers ? 'italic' : 'normal',
        fontWeight: isSerif ? 400 : 700,
        fontSize: 28, lineHeight: 1, letterSpacing: '-0.03em',
      }}>{stat}</div>
      <div style={{ marginTop: 4, fontFamily: treatment.mono, fontSize: 10, color: tone.soft, letterSpacing: '0.08em', textTransform: 'uppercase' }}>
        {label}
      </div>
    </div>
  );
}

// ── Carousel ────────────────────────────────────────────────

const CARDS_BY_KEY = {
  cover: CoverCard, volume: VolumeCard, people: PeopleCard, latency: LatencyCard,
  groups: GroupsCard, archetype: ArchetypeCard, share: ShareCard,
};

// Active cards: from DATA.cards if provided, else the full arc. Each card keeps
// its designed palette via its index in FULL_ARC (so omitting a card doesn't
// recolor the survivors).
const CARD_KEYS = (DATA.cards && DATA.cards.length ? DATA.cards : FULL_ARC)
  .filter((k) => CARDS_BY_KEY[k]);
const CARDS = CARD_KEYS.map((k) => ({ Comp: CARDS_BY_KEY[k], paletteIdx: FULL_ARC.indexOf(k) }));

function Carousel({ treatment, onPaletteChange }) {
  const [idx, setIdx] = useState(0);
  const [shareState, setShareState] = useState('idle');
  const [drag, setDrag] = useState(null); // {startX, dx}
  const [w, setW] = useState(402);
  const ref = useRef(null);

  // Measure carousel width so we can translate in pixels (avoids calc bugs)
  useEffect(() => {
    const measure = () => { if (ref.current) setW(ref.current.offsetWidth); };
    measure();
    const ro = new ResizeObserver(measure);
    if (ref.current) ro.observe(ref.current);
    return () => ro.disconnect();
  }, []);

  const total = CARDS.length;

  const go = useCallback((next) => {
    setIdx((i) => Math.max(0, Math.min(total - 1, next)));
  }, [total]);

  // keyboard
  useEffect(() => {
    const onKey = (e) => {
      if (e.key === 'ArrowRight') go(idx + 1);
      else if (e.key === 'ArrowLeft') go(idx - 1);
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [idx, go]);

  // Pointer drag
  const onPointerDown = (e) => {
    setDrag({ startX: e.clientX, dx: 0 });
    e.currentTarget.setPointerCapture(e.pointerId);
  };
  const onPointerMove = (e) => {
    if (!drag) return;
    setDrag({ ...drag, dx: e.clientX - drag.startX });
  };
  const onPointerUp = () => {
    if (!drag) return;
    const { dx } = drag;
    if (Math.abs(dx) > 50) {
      if (dx < 0) go(idx + 1); else go(idx - 1);
    }
    setDrag(null);
  };

  const handleShare = () => {
    setShareState('shared');
    setTimeout(() => setShareState('idle'), 1800);
  };

  // tap zones
  const onCardTap = (e) => {
    const rect = ref.current.getBoundingClientRect();
    const x = e.clientX - rect.left;
    if (x < rect.width * 0.35) go(idx - 1);
    else if (x > rect.width * 0.65) go(idx + 1);
  };

  return (
    <div
      ref={ref}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
      onPointerCancel={onPointerUp}
      style={{
        position: 'absolute', inset: 0,
        overflow: 'hidden',
        touchAction: 'pan-y',
        userSelect: 'none',
        cursor: drag ? 'grabbing' : 'default',
      }}>
      {/* Card stack */}
      {CARDS.map(({ Comp, paletteIdx }, i) => {
        const offset = i - idx;
        const dragOffset = (drag && i === idx) ? drag.dx : 0;
        const isActive = i === idx;
        const visible = Math.abs(offset) <= 1 || drag;
        return (
          <div key={i} style={{
            position: 'absolute', inset: 0,
            transform: `translate3d(${offset * w + dragOffset}px, 0, 0)`,
            transition: drag ? 'none' : 'transform 520ms cubic-bezier(.22,.61,.36,1), opacity 520ms ease',
            opacity: visible ? 1 : 0,
            pointerEvents: isActive ? 'auto' : 'none',
          }}>
            <Comp
              tone={treatment.cards[paletteIdx]}
              treatment={treatment}
              active={isActive}
              onTap={onCardTap}
              onShare={handleShare}
              shareState={shareState}
            />
          </div>
        );
      })}

      {/* Top story-segment indicators — sit below dynamic island */}
      <div style={{
        position: 'absolute', top: 58, left: 16, right: 16,
        display: 'flex', gap: 4, pointerEvents: 'none', zIndex: 10,
      }}>
        {CARDS.map((_, i) => (
          <div key={i} style={{
            flex: 1, height: 2.5, borderRadius: 2,
            background: 'rgba(0,0,0,0.18)',
            overflow: 'hidden',
            mixBlendMode: 'difference',
          }}>
            <div style={{
              height: '100%',
              width: i < idx ? '100%' : i === idx ? '100%' : '0%',
              background: 'rgba(255,255,255,0.95)',
              transition: 'width 360ms ease',
            }}/>
          </div>
        ))}
      </div>

      {/* Bottom dots — above home indicator */}
      <div style={{
        position: 'absolute', bottom: 44, left: 0, right: 0,
        display: 'flex', justifyContent: 'center', gap: 6,
        pointerEvents: 'none', zIndex: 10,
      }}>
        {CARDS.map((_, i) => (
          <div key={i} style={{
            width: i === idx ? 16 : 5, height: 5, borderRadius: 3,
            background: i === idx ? 'currentColor' : 'rgba(127,127,127,0.4)',
            mixBlendMode: 'difference',
            transition: 'all 280ms ease',
          }}/>
        ))}
      </div>
    </div>
  );
}

// ── App ─────────────────────────────────────────────────────

const DEFAULTS = {
  treatment: (typeof window !== 'undefined' && window.WRAPPED_TREATMENT) || 'sunrise',
};

function App() {
  const [tweaks, setTweak] = window.useTweaks
    ? window.useTweaks(DEFAULTS)
    : [DEFAULTS, () => {}];
  const treatmentId = tweaks.treatment in TREATMENTS ? tweaks.treatment : 'sunrise';
  const treatment = TREATMENTS[treatmentId];

  // Scale the device to fit viewport (height-driven)
  const [scale, setScale] = useState(1);
  useEffect(() => {
    const compute = () => {
      const PHONE_H = 874, PHONE_W = 402;
      const margin = 80;
      const sH = (window.innerHeight - margin) / PHONE_H;
      const sW = (window.innerWidth - margin) / PHONE_W;
      setScale(Math.min(1, sH, sW));
    };
    compute();
    window.addEventListener('resize', compute);
    return () => window.removeEventListener('resize', compute);
  }, []);

  return (
    <div style={{
      position: 'fixed', inset: 0,
      background: '#1c1a1f',
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      overflow: 'hidden',
      fontFamily: '"Inter", system-ui, sans-serif',
    }}>
      {/* Stage backdrop hue based on treatment */}
      <div style={{
        position: 'absolute', inset: 0,
        background:
          treatmentId === 'sunrise' ? 'radial-gradient(60% 50% at 50% 40%, rgba(255,140,90,0.20), transparent 70%), #1a1116' :
          treatmentId === 'receipt' ? 'radial-gradient(60% 50% at 50% 40%, rgba(245,236,217,0.10), transparent 70%), #161310' :
          'radial-gradient(60% 50% at 50% 40%, rgba(198,255,77,0.10), transparent 70%), #07070c',
        transition: 'background 600ms ease',
      }}/>

      {/* Brand mark — bottom-left */}
      <div style={{
        position: 'absolute', bottom: 22, left: 24,
        color: 'rgba(255,255,255,0.5)',
        fontFamily: 'ui-monospace, "JetBrains Mono", monospace',
        fontSize: 11, letterSpacing: '0.14em', textTransform: 'uppercase',
        zIndex: 5,
      }}>
        messages for ai · annual report {DATA.year}
      </div>

      <div style={{
        position: 'absolute', bottom: 22, right: 24,
        color: 'rgba(255,255,255,0.5)',
        fontFamily: 'ui-monospace, "JetBrains Mono", monospace',
        fontSize: 11, letterSpacing: '0.14em', textTransform: 'uppercase',
        zIndex: 5,
      }}>
        ← → · drag · tap edges
      </div>

      {/* The phone */}
      <div style={{ position: 'relative', zIndex: 1, transform: `scale(${scale})`, transformOrigin: 'center center' }}>
        <IOSDevice width={402} height={874} dark={true}>
          <div style={{ position: 'absolute', inset: 0 }}>
            <Carousel treatment={treatment} ref={null} />
          </div>
        </IOSDevice>
      </div>

      {/* Tweaks panel — present only in the interactive dev prototype (index.html).
          The shipped wrapped.html generated by build_wrapped.py omits it. */}
      {window.TweaksPanel && (
        <window.TweaksPanel title="Tweaks">
          <window.TweakSection title="Visual treatment">
            <window.TweakRadio
              value={treatmentId}
              onChange={(v) => setTweak('treatment', v)}
              options={[
                { value: 'sunrise', label: 'Sunrise' },
                { value: 'receipt', label: 'Receipt' },
                { value: 'pager',   label: 'Pager' },
              ]}
            />
          </window.TweakSection>
        </window.TweaksPanel>
      )}
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
