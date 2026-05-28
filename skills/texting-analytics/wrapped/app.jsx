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
const FULL_ARC = ['cover', 'volume', 'people', 'latency', 'ballincourt', 'groups', 'emoji', 'age', 'archetype', 'share'];

// ── Hooks ───────────────────────────────────────────────────

// Count-up animation, eased
function useCountUp(target, durationMs = 1100, active = true, startDelay = 200, instant = false) {
  const [val, setVal] = useState(active ? 0 : target);
  const wasActive = useRef(active);
  useEffect(() => {
    if (instant) { setVal(target); return; }  // capture mode: jump to final value
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
  }, [target, durationMs, active, startDelay, instant]);
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
function VolumeCard({ tone, treatment, active, instant }) {
  const n = useCountUp(DATA.totalSent, 1400, active, 150, instant);
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

// Reply-time distribution — a right-skewed (lognormal-ish) curve: a tall spike
// near the median, a long tail out past the mean. Median + mean drawn as lines.
function LatencyCurve({ median, mean }) {
  const W = 320, H = 108, base = H - 2, top = 16;
  const med = Math.max(median, 0.1);
  // Crop the x-axis to the BODY of the distribution (a few medians wide) so the
  // bell sits in frame. The long outlier tail is trimmed; if the outlier-dragged
  // mean falls off-frame, we pin its marker at the right edge with an arrow.
  const xmax = Math.max(med * 6, 8);
  const xOf = (v) => Math.min(v / xmax, 1) * W;
  const sigma = 0.85;
  const f = (v) => Math.exp(-Math.pow(Math.log(v + 1) - Math.log(med + 1), 2) / (2 * sigma * sigma));
  const N = 80;
  let peak = 0;
  const ys = [];
  for (let i = 0; i <= N; i++) { const y = f((i / N) * xmax); ys.push(y); if (y > peak) peak = y; }
  const yOf = (y) => base - (y / peak) * (base - top);
  let d = `M0 ${base}`;
  for (let i = 0; i <= N; i++) d += ` L${((i / N) * W).toFixed(1)} ${yOf(ys[i]).toFixed(1)}`;
  d += ` L${W} ${base} Z`;
  const meanOff = mean > xmax;
  const xMean = meanOff ? W - 1.5 : xOf(mean);
  return (
    <svg viewBox={`0 0 ${W} ${H}`} width="100%" style={{ display: 'block', overflow: 'visible' }}>
      <path d={d} fill="currentColor" fillOpacity="0.16" stroke="currentColor" strokeOpacity="0.5" strokeWidth="1.5" />
      <line x1={xOf(median)} y1={top - 8} x2={xOf(median)} y2={base} stroke="currentColor" strokeWidth="2.5" />
      <line x1={xMean} y1={top - 8} x2={xMean} y2={base} stroke="currentColor" strokeOpacity="0.65" strokeWidth="1.5" strokeDasharray="3 3" />
      {meanOff && <path d={`M${W - 7} ${top - 4} L${W - 1} ${top} L${W - 7} ${top + 4} Z`} fill="currentColor" fillOpacity="0.65" />}
    </svg>
  );
}

// Card 4: Reply latency — distribution curve + plain-language mean vs median
function LatencyCard({ tone, treatment, active }) {
  const isSerif = treatment.numberFont === 'serif';
  const med = DATA.median, mean = DATA.mean;
  const skew = mean > med * 1.5;
  return (
    <CardShell
      tone={tone} treatment={treatment}
      label="03 · the latency"
      footer="fast on the first reply. slow on the follow-through.">
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 20 }}>
        <div style={{ fontFamily: treatment.mono, fontSize: 12, letterSpacing: '0.12em', textTransform: 'uppercase', color: tone.soft }}>
          How fast you reply
        </div>

        <div style={{ opacity: active ? 1 : 0, transform: active ? 'translateY(0)' : 'translateY(10px)', transition: 'all 700ms ease 200ms' }}>
          <LatencyCurve median={med} mean={mean} />
          <div style={{ display: 'flex', gap: 20, marginTop: 10, fontFamily: treatment.mono, fontSize: 11, letterSpacing: '0.04em', color: tone.soft }}>
            <span><b style={{ color: tone.ink }}>│</b> median {fmt(med, 1)} min</span>
            <span>┊ mean {fmt(mean, 1)} min{mean > med * 6 ? ' →' : ''}</span>
          </div>
        </div>

        <div style={{
          fontFamily: isSerif ? treatment.serif : treatment.sans,
          fontStyle: isSerif ? 'italic' : 'normal',
          fontWeight: isSerif ? 400 : 600,
          fontSize: 24, lineHeight: 1.22, letterSpacing: '-0.01em', textWrap: 'balance',
        }}>
          {skew
            ? <>Half your replies land within <span style={{ textDecoration: 'underline', textUnderlineOffset: 5 }}>{fmt(med, 1)} minutes</span>. But your average is {fmt(mean, 1)} — a handful of slow ones drag the tail way out.</>
            : <>Half your replies land within <span style={{ textDecoration: 'underline', textUnderlineOffset: 5 }}>{fmt(med, 1)} minutes</span>, and your average ({fmt(mean, 1)}) isn't far off. You reply at a steady clip.</>}
        </div>
      </div>
    </CardShell>
  );
}

// Card 5: Ball in your court — its own frame. A gauge with a clear midpoint line.
function BallInCourtCard({ tone, treatment, active, instant }) {
  const pct = useCountUp(DATA.ballInCourt, 1200, active, 200, instant);
  const isSerif = treatment.numberFont === 'serif';
  const italic = isSerif && treatment.italicNumbers;
  const heavy = DATA.ballInCourt >= 50;
  return (
    <CardShell
      tone={tone} treatment={treatment}
      label="04 · ball in your court"
      footer="the ball doesn't move itself.">
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 26 }}>
        <div style={{ fontFamily: treatment.mono, fontSize: 12, letterSpacing: '0.12em', textTransform: 'uppercase', color: tone.soft }}>
          Active threads waiting on you
        </div>

        <div style={{ display: 'flex', alignItems: 'baseline', gap: 6, whiteSpace: 'nowrap' }}>
          <div style={{
            fontFamily: isSerif ? treatment.serif : treatment.sans,
            fontStyle: italic ? 'italic' : 'normal',
            fontWeight: isSerif ? 400 : 700,
            fontSize: 132, lineHeight: 0.85,
            letterSpacing: isSerif ? '-0.045em' : '-0.07em',
          }}>{fmt(pct)}</div>
          <div style={{
            fontFamily: isSerif ? treatment.serif : treatment.sans,
            fontStyle: italic ? 'italic' : 'normal',
            fontWeight: isSerif ? 400 : 600, fontSize: 52, letterSpacing: '-0.04em',
          }}>%</div>
        </div>

        {/* Gauge: fill to the user's %, with a clear midpoint (50%) reference line. */}
        <div style={{ position: 'relative', marginTop: 18 }}>
          <div style={{ position: 'relative', height: 14, borderRadius: 8, background: 'currentColor', opacity: 0.18, overflow: 'hidden' }}>
            <div style={{
              position: 'absolute', left: 0, top: 0, bottom: 0,
              width: active ? `${Math.min(DATA.ballInCourt, 100)}%` : 0,
              background: 'currentColor', borderRadius: 8,
              transition: 'width 1000ms cubic-bezier(.2,.7,.2,1) 200ms',
            }}/>
          </div>
          <div style={{ position: 'absolute', left: '50%', top: -7, bottom: -7, width: 2, background: tone.ink, opacity: 0.85 }} />
          <div style={{ position: 'absolute', left: '50%', top: -24, transform: 'translateX(-50%)', fontFamily: treatment.mono, fontSize: 9.5, letterSpacing: '0.1em', textTransform: 'uppercase', color: tone.soft }}>even</div>
          <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 10, fontFamily: treatment.mono, fontSize: 10, letterSpacing: '0.06em', color: tone.soft }}>
            <span>caught up</span><span>behind</span>
          </div>
        </div>

        <div style={{
          fontFamily: isSerif ? treatment.serif : treatment.sans,
          fontStyle: isSerif ? 'italic' : 'normal',
          fontWeight: isSerif ? 400 : 600,
          fontSize: 26, lineHeight: 1.18, letterSpacing: '-0.02em', textWrap: 'balance',
        }}>
          {heavy
            ? 'More than half your live threads are waiting on you to reply.'
            : "You're keeping up — most of your threads aren't waiting on you."}
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
function GroupsCard({ tone, treatment, active, instant }) {
  const pct = useCountUp(DATA.groupContribPct, 1100, active, 180, instant);
  const isSerif = treatment.numberFont === 'serif';
  const italic = isSerif && treatment.italicNumbers;
  return (
    <CardShell
      tone={tone} treatment={treatment}
      label="05 · the ghost data"
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
      label="08 · your archetype"
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

// Card 7: Share — pure creative. The share CTA lives in the page chrome
// (App's control bar), not on the card, so the shared image stays clean.
function ShareCard({ tone, treatment, active }) {
  const isSerif = treatment.titleFont === 'serif';
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

        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
          {recap.map((r, i) => (
            <RecapTile key={i} treatment={treatment} tone={tone} stat={r.stat} label={r.label} />
          ))}
        </div>
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

// Card 6: Emoji — aggregate emoji usage (from the emoji_stats pass). Omitted
// unless analysis.json carries an `emoji` block.
function EmojiCard({ tone, treatment, active, instant }) {
  const e = DATA.emoji || { pct_messages_with_emoji: 0, top: [] };
  const pct = useCountUp(e.pct_messages_with_emoji, 1100, active, 180, instant);
  const top = (e.top || []).slice(0, 5);
  const isSerif = treatment.numberFont === 'serif';
  const italic = isSerif && treatment.italicNumbers;
  return (
    <CardShell
      tone={tone} treatment={treatment}
      label="06 · your emoji"
      footer="a picture's worth a thousand texts.">
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 20 }}>
        <div style={{ fontFamily: treatment.mono, fontSize: 12, letterSpacing: '0.12em', textTransform: 'uppercase', color: tone.soft }}>
          You drop an emoji in
        </div>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 6 }}>
          <div style={{
            fontFamily: isSerif ? treatment.serif : treatment.sans,
            fontStyle: italic ? 'italic' : 'normal', fontWeight: isSerif ? 400 : 700,
            fontSize: 116, lineHeight: 0.85, letterSpacing: isSerif ? '-0.045em' : '-0.07em',
          }}>{fmt(pct, pct % 1 ? 1 : 0)}</div>
          <div style={{
            fontFamily: isSerif ? treatment.serif : treatment.sans,
            fontStyle: italic ? 'italic' : 'normal', fontWeight: isSerif ? 400 : 600,
            fontSize: 44, letterSpacing: '-0.04em',
          }}>%</div>
        </div>
        <div style={{ fontFamily: treatment.mono, fontSize: 13, color: tone.soft, letterSpacing: '0.04em', marginTop: -6 }}>
          of your texts.
        </div>

        {top.length > 0 && (
          <div style={{ display: 'flex', gap: 16, alignItems: 'flex-end', marginTop: 6 }}>
            {top.map((t, i) => (
              <div key={i} style={{
                textAlign: 'center',
                opacity: active ? 1 : 0, transform: active ? 'translateY(0)' : 'translateY(10px)',
                transition: `all 500ms cubic-bezier(.2,.7,.2,1) ${250 + i * 80}ms`,
              }}>
                <div style={{ fontSize: i === 0 ? 52 : 36, lineHeight: 1 }}>{t.emoji}</div>
                <div style={{ fontFamily: treatment.mono, fontSize: 11, color: tone.soft, marginTop: 7 }}>{t.count.toLocaleString()}</div>
              </div>
            ))}
          </div>
        )}

        <div style={{
          marginTop: 8,
          fontFamily: isSerif ? treatment.serif : treatment.sans,
          fontStyle: isSerif ? 'italic' : 'normal', fontWeight: isSerif ? 400 : 600,
          fontSize: 24, lineHeight: 1.2, letterSpacing: '-0.01em', textWrap: 'balance',
        }}>
          {top[0] ? <>{top[0].emoji} is doing the heavy lifting.</> : 'A words-only minimalist.'}
        </div>
      </div>
    </CardShell>
  );
}

// Card 7: Texting age — playful, probabilistic (from age_estimate.py via the
// research rubric). Omitted unless analysis.json carries an `age` block.
function AgeCard({ tone, treatment, active }) {
  const a = DATA.age || { range_label: '—', approx_age: '', drivers: [] };
  const isSerif = treatment.titleFont === 'serif';
  const drivers = (a.drivers || []).slice(0, 3);
  return (
    <CardShell
      tone={tone} treatment={treatment}
      label="07 · your texting age"
      footer="probabilistic & for fun — not a background check.">
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 16 }}>
        <div style={{ fontFamily: treatment.mono, fontSize: 12, letterSpacing: '0.12em', textTransform: 'uppercase', color: tone.soft }}>
          You text like a
        </div>
        <div style={{
          fontFamily: isSerif ? treatment.serif : treatment.sans,
          fontStyle: isSerif ? 'italic' : 'normal', fontWeight: isSerif ? 400 : 800,
          fontSize: 60, lineHeight: 0.9, letterSpacing: isSerif ? '-0.03em' : '-0.05em',
          textWrap: 'balance',
        }}>{a.range_label}</div>
        {a.approx_age && (
          <div style={{ fontFamily: treatment.mono, fontSize: 13, color: tone.soft, letterSpacing: '0.06em' }}>
            roughly age {a.approx_age}
          </div>
        )}
        {drivers.length > 0 && (
          <div style={{ marginTop: 8, paddingTop: 16, borderTop: `1px solid ${tone.ink}` }}>
            <div style={{ fontFamily: treatment.mono, fontSize: 11, letterSpacing: '0.1em', textTransform: 'uppercase', color: tone.soft, marginBottom: 10 }}>
              Strongest tells
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 7 }}>
              {drivers.map((d, i) => (
                <div key={i} style={{
                  fontFamily: isSerif ? treatment.serif : treatment.sans,
                  fontStyle: isSerif ? 'italic' : 'normal', fontWeight: isSerif ? 400 : 600,
                  fontSize: 19, lineHeight: 1.15, letterSpacing: '-0.01em',
                  opacity: active ? 1 : 0, transform: active ? 'translateX(0)' : 'translateX(-10px)',
                  transition: `all 500ms cubic-bezier(.2,.7,.2,1) ${200 + i * 90}ms`,
                }}>{d}</div>
              ))}
            </div>
          </div>
        )}
      </div>
    </CardShell>
  );
}

// ── Carousel ────────────────────────────────────────────────

const CARDS_BY_KEY = {
  cover: CoverCard, volume: VolumeCard, people: PeopleCard, latency: LatencyCard,
  ballincourt: BallInCourtCard, groups: GroupsCard, emoji: EmojiCard,
  age: AgeCard, archetype: ArchetypeCard, share: ShareCard,
};

// Palette is decoupled from card order so adding/omitting cards never recolors
// the others. Each key maps to an index into the treatment's palette array;
// emoji + age reuse earlier slots (people/volume) to avoid extra palettes.
const PALETTE_OF = {
  cover: 0, volume: 1, people: 2, latency: 3, ballincourt: 4,
  groups: 5, archetype: 6, share: 7, emoji: 2, age: 1,
};

// Active cards: from DATA.cards if provided, else the full arc.
const CARD_KEYS = (DATA.cards && DATA.cards.length ? DATA.cards : FULL_ARC)
  .filter((k) => CARDS_BY_KEY[k]);
const CARDS = CARD_KEYS.map((k) => ({ Comp: CARDS_BY_KEY[k], paletteIdx: PALETTE_OF[k] != null ? PALETTE_OF[k] : 0 }));

// Controlled: idx + go come from App, so navigation controls can live in the
// page chrome (off the creative). captureRef points at the active card so App's
// Share can snapshot just the card art.
function Carousel({ treatment, idx, go, captureRef, instant }) {
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
      {/* Card stack — each card is PURE creative (no controls baked in). The
          active card's wrapper is the capture target for sharing. */}
      {CARDS.map(({ Comp, paletteIdx }, i) => {
        const offset = i - idx;
        const dragOffset = (drag && i === idx) ? drag.dx : 0;
        const isActive = i === idx;
        const visible = Math.abs(offset) <= 1 || drag;
        return (
          <div key={i}
            ref={isActive ? (el) => { if (captureRef) captureRef.current = el; } : undefined}
            style={{
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
              instant={instant}
              onTap={onCardTap}
            />
          </div>
        );
      })}

      {/* Top story-segment progress — subtle phone status, not a CTA. Excluded
          from the shared image (capture targets the card, not this overlay). */}
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
              width: i <= idx ? '100%' : '0%',
              background: 'rgba(255,255,255,0.95)',
              transition: 'width 360ms ease',
            }}/>
          </div>
        ))}
      </div>
    </div>
  );
}

// Chrome nav button (page chrome, off the creative)
function ChromeBtn({ children, onClick, disabled, aria }) {
  return (
    <button onClick={onClick} disabled={disabled} aria-label={aria} style={{
      width: 44, height: 44, borderRadius: 9999,
      border: '1px solid rgba(255,255,255,0.25)',
      background: 'rgba(255,255,255,0.08)', color: '#fff',
      fontSize: 22, lineHeight: 1, cursor: disabled ? 'default' : 'pointer',
      opacity: disabled ? 0.3 : 1,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      backdropFilter: 'blur(8px)', WebkitBackdropFilter: 'blur(8px)',
    }}>{children}</button>
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

  // Navigation + share state live here so the controls render in the page
  // chrome (off the creative), not on the cards.
  const [idx, setIdx] = useState(0);
  const [shareState, setShareState] = useState('idle');
  const captureRef = useRef(null);
  const go = useCallback((n) => setIdx(() => Math.max(0, Math.min(CARDS.length - 1, n))), []);

  // Share ALL cards as one composite image. Walks every card (so each renders
  // in its active, final state — `capturing` makes count-ups jump to final),
  // snapshots each, tiles them into a grid, then shares/saves the one image.
  const [capturing, setCapturing] = useState(false);
  const [shareAllState, setShareAllState] = useState('');
  const handleShareAll = useCallback(async () => {
    if (!window.html2canvas || capturing) return;
    const startIdx = idx;
    setCapturing(true);
    try {
      const shots = [];
      for (let i = 0; i < CARDS.length; i++) {
        setIdx(i);
        setShareAllState(`${i + 1}/${CARDS.length}`);
        await new Promise((r) => setTimeout(r, 800));  // let the reveal settle
        const el = captureRef.current;
        if (el) shots.push(await window.html2canvas(el, { scale: 2, backgroundColor: null, useCORS: true, logging: false }));
      }
      if (!shots.length) return;
      const cols = shots.length <= 4 ? 2 : 3;
      const rows = Math.ceil(shots.length / cols);
      const scale = 360 / shots[0].width;
      const sw = Math.round(shots[0].width * scale), sh = Math.round(shots[0].height * scale);
      const gap = 18, pad = 28;
      const cvs = document.createElement('canvas');
      cvs.width = pad * 2 + cols * sw + (cols - 1) * gap;
      cvs.height = pad * 2 + rows * sh + (rows - 1) * gap;
      const ctx = cvs.getContext('2d');
      ctx.fillStyle = '#0a0a0c'; ctx.fillRect(0, 0, cvs.width, cvs.height);
      shots.forEach((c, i) => ctx.drawImage(c, pad + (i % cols) * (sw + gap), pad + Math.floor(i / cols) * (sh + gap), sw, sh));
      const blob = await new Promise((res) => cvs.toBlob(res, 'image/png'));
      const file = new File([blob], `texting-wrapped-${DATA.year}-all.png`, { type: 'image/png' });
      if (navigator.canShare && navigator.canShare({ files: [file] })) {
        await navigator.share({ files: [file], title: 'My Texting Wrapped', text: 'My full Texting Wrapped · messagesfor.ai' });
      } else {
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url; a.download = file.name; document.body.appendChild(a); a.click(); a.remove();
        URL.revokeObjectURL(url);
      }
      setShareAllState('done');
    } catch (e) {
      setShareAllState('');
    } finally {
      setCapturing(false);
      setIdx(startIdx);
      setTimeout(() => setShareAllState(''), 2500);
    }
  }, [idx, capturing]);

  // Capture the CURRENT card → native share sheet (Safari bridges Web Share to
  // the macOS share sheet); otherwise save a PNG. The card is the only thing
  // captured, so the shared image is clean creative.
  const handleShare = useCallback(async () => {
    const el = captureRef.current;
    if (!el || !window.html2canvas) return;
    try {
      setShareState('working');
      const canvas = await window.html2canvas(el, {
        scale: 3, backgroundColor: null, useCORS: true, logging: false,
      });
      const blob = await new Promise((res) => canvas.toBlob(res, 'image/png'));
      if (!blob) { setShareState('idle'); return; }
      const file = new File([blob], `texting-wrapped-${DATA.year}.png`, { type: 'image/png' });
      if (navigator.canShare && navigator.canShare({ files: [file] })) {
        await navigator.share({ files: [file], title: 'My Texting Wrapped',
          text: 'My Texting Wrapped · messagesfor.ai' });
        setShareState('shared');
      } else {
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url; a.download = file.name;
        document.body.appendChild(a); a.click(); a.remove();
        URL.revokeObjectURL(url);
        setShareState('saved');
      }
    } catch (e) {
      setShareState('idle');  // includes user-cancelled share (AbortError)
    } finally {
      setTimeout(() => setShareState('idle'), 2200);
    }
  }, []);

  // Scale the device to fit viewport (height-driven)
  const [scale, setScale] = useState(1);
  useEffect(() => {
    const compute = () => {
      const PHONE_H = 874, PHONE_W = 402;
      // Reserve vertical room for the control bar that sits BELOW the frame.
      const sH = (window.innerHeight - 150) / PHONE_H;
      const sW = (window.innerWidth - 80) / PHONE_W;
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
      display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 20,
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

      {/* The phone — a sized box (scaled dims) so the control bar flows BELOW
          the frame instead of overlapping it. The iPhone is dedicated to the
          creative; nothing interactive sits on it. */}
      <div style={{ position: 'relative', zIndex: 1, width: 402 * scale, height: 874 * scale }}>
        <div style={{ width: 402, height: 874, transform: `scale(${scale})`, transformOrigin: 'top left' }}>
          <IOSDevice width={402} height={874} dark={true}>
            <div style={{ position: 'absolute', inset: 0 }}>
              <Carousel treatment={treatment} idx={idx} go={go} captureRef={captureRef} instant={capturing} />
            </div>
          </IOSDevice>
        </div>
      </div>

      {/* Controls — OUTSIDE the iPhone frame entirely, in the page chrome.
          Prev / Share / Next. Share captures the CURRENT card and opens the
          native share sheet (Safari → macOS share sheet via Web Share);
          otherwise saves a PNG. */}
      <div style={{
        zIndex: 6,
        display: 'flex', justifyContent: 'center', alignItems: 'center', gap: 12,
      }}>
        <ChromeBtn disabled={idx === 0 || capturing} onClick={() => go(idx - 1)} aria="Previous card">‹</ChromeBtn>
        <button
          onClick={handleShare}
          disabled={shareState === 'working' || capturing}
          style={{
            height: 44, padding: '0 22px', borderRadius: 9999, border: 'none',
            background: '#fff', color: '#111',
            fontFamily: 'ui-monospace, "JetBrains Mono", monospace',
            fontSize: 12, fontWeight: 600, letterSpacing: '0.12em', textTransform: 'uppercase',
            cursor: (shareState === 'working' || capturing) ? 'default' : 'pointer',
            boxShadow: '0 6px 20px rgba(0,0,0,0.35)',
          }}>
          {shareState === 'working' ? 'Rendering…'
            : shareState === 'shared' ? '✓ Shared'
            : shareState === 'saved' ? '✓ Saved PNG'
            : 'Share this card'}
        </button>
        <ChromeBtn disabled={idx === CARDS.length - 1 || capturing} onClick={() => go(idx + 1)} aria="Next card">›</ChromeBtn>
      </div>

      {/* On the final card: share the WHOLE set as one composite image. Still in
          the page chrome, off the creative. */}
      {idx === CARDS.length - 1 && (
        <button
          onClick={handleShareAll}
          disabled={capturing}
          style={{
            height: 40, padding: '0 20px', borderRadius: 9999,
            border: '1px solid rgba(255,255,255,0.25)', background: 'rgba(255,255,255,0.08)',
            color: '#fff', backdropFilter: 'blur(8px)', WebkitBackdropFilter: 'blur(8px)',
            fontFamily: 'ui-monospace, "JetBrains Mono", monospace',
            fontSize: 11.5, fontWeight: 600, letterSpacing: '0.12em', textTransform: 'uppercase',
            cursor: capturing ? 'default' : 'pointer',
          }}>
          {shareAllState === 'done' ? '✓ Shared all cards'
            : shareAllState ? `Rendering ${shareAllState}…`
            : '⧉ Share all cards'}
        </button>
      )}

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
