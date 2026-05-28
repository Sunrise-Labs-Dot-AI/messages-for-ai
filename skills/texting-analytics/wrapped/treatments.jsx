// ────────────────────────────────────────────────────────────
// Treatments — three distinct visual systems
// Each declares: name, fonts, ink, background renderer per card
// ────────────────────────────────────────────────────────────

const TREATMENTS = {
  // ── 1. Sunrise — warm editorial gradients, Instrument Serif display
  sunrise: {
    id: 'sunrise',
    name: 'Sunrise',
    serif: '"Instrument Serif", "Cormorant Garamond", Georgia, serif',
    sans: '"Inter", -apple-system, system-ui, sans-serif',
    mono: '"JetBrains Mono", ui-monospace, monospace',
    titleFont: 'serif',           // which family the big headlines use
    numberFont: 'serif',
    bodyFont: 'sans',
    italicNumbers: true,
    grain: 0.06,
    cards: [
      // 1 cover — soft peach to coral
      { bg: 'linear-gradient(160deg, #ffd9b3 0%, #ff8b6b 45%, #d94a6f 100%)', ink: '#1a0d1a', soft: '#1a0d1a' },
      // 2 hero number — molten orange
      { bg: 'linear-gradient(180deg, #ffb37a 0%, #ff5e3a 60%, #b21d4d 100%)', ink: '#1a0a14', soft: '#3a1020' },
      // 3 top people — magenta dusk
      { bg: 'linear-gradient(170deg, #ffa1c4 0%, #c84d96 55%, #5a1b6f 100%)', ink: '#fff4ee', soft: 'rgba(255,244,238,0.85)' },
      // 4 reply behavior — violet twilight
      { bg: 'linear-gradient(190deg, #ffb29c 0%, #b95aa3 50%, #2e1859 100%)', ink: '#fff', soft: 'rgba(255,255,255,0.78)' },
      // 5 ball in court — plum
      { bg: 'linear-gradient(195deg, #d98fbf 0%, #8a3f86 50%, #241455 100%)', ink: '#fff', soft: 'rgba(255,255,255,0.78)' },
      // 6 group chat — indigo night
      { bg: 'linear-gradient(200deg, #ff7a8a 0%, #6a3a9a 50%, #0e0a3a 100%)', ink: '#fff', soft: 'rgba(255,255,255,0.74)' },
      // 6 archetype — ink with peach flare
      { bg: 'radial-gradient(120% 90% at 80% 10%, #ff7a4a 0%, #c41f55 35%, #2a0a2a 75%, #0a0612 100%)', ink: '#fff1e6', soft: 'rgba(255,241,230,0.78)' },
      // 7 share — cream
      { bg: 'linear-gradient(180deg, #fff3e0 0%, #ffd6c2 100%)', ink: '#231016', soft: '#5a2a3a' },
    ],
  },

  // ── 2. Receipt — cream paper + bold serif + monospace stats
  receipt: {
    id: 'receipt',
    name: 'Receipt',
    serif: '"Instrument Serif", "Cormorant Garamond", Georgia, serif',
    sans: '"Inter", -apple-system, system-ui, sans-serif',
    mono: '"JetBrains Mono", "IBM Plex Mono", ui-monospace, monospace',
    titleFont: 'serif',
    numberFont: 'serif',
    bodyFont: 'mono',
    italicNumbers: false,
    grain: 0.10,
    cards: [
      { bg: '#f5ecd9', ink: '#1a1612', soft: '#6b5e48', accent: '#c8341d' },
      { bg: '#1a1612', ink: '#f5ecd9', soft: '#a89978', accent: '#e7c45a' },
      { bg: '#e8d9bd', ink: '#1a1612', soft: '#6b5e48', accent: '#1d4ec8' },
      { bg: '#f5ecd9', ink: '#1a1612', soft: '#6b5e48', accent: '#c8341d' },
      { bg: '#e8d9bd', ink: '#1a1612', soft: '#6b5e48', accent: '#1d9ec8' },
      { bg: '#1a1612', ink: '#f5ecd9', soft: '#a89978', accent: '#5acdb3' },
      { bg: '#c8341d', ink: '#fff3e0', soft: 'rgba(255,243,224,0.78)', accent: '#1a1612' },
      { bg: '#f5ecd9', ink: '#1a1612', soft: '#6b5e48', accent: '#c8341d' },
    ],
  },

  // ── 3. Pager — midnight + electric accents, chunky grotesk
  pager: {
    id: 'pager',
    name: 'Pager',
    serif: '"Instrument Serif", Georgia, serif',
    sans: '"Space Grotesk", "Inter", system-ui, sans-serif',
    mono: '"JetBrains Mono", ui-monospace, monospace',
    titleFont: 'sans',
    numberFont: 'sans',
    bodyFont: 'mono',
    italicNumbers: false,
    grain: 0.0,
    cards: [
      { bg: '#0a0a12', ink: '#f4f0e8', soft: '#7a7686', accent: '#c6ff4d' },
      { bg: '#c6ff4d', ink: '#0a0a12', soft: '#1a1a22', accent: '#0a0a12' },
      { bg: '#0a0a12', ink: '#f4f0e8', soft: '#7a7686', accent: '#ff5cab' },
      { bg: '#0a0a12', ink: '#f4f0e8', soft: '#7a7686', accent: '#6cd5ff' },
      { bg: '#0a0a12', ink: '#f4f0e8', soft: '#7a7686', accent: '#ffb14d' },
      { bg: '#ff5cab', ink: '#0a0a12', soft: '#22000f', accent: '#0a0a12' },
      { bg: '#0a0a12', ink: '#f4f0e8', soft: '#7a7686', accent: '#c6ff4d' },
      { bg: '#0a0a12', ink: '#f4f0e8', soft: '#7a7686', accent: '#c6ff4d' },
    ],
  },
};

window.TREATMENTS = TREATMENTS;
