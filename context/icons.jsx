/* icons.jsx — Simple geometric icon set + file/folder glyphs.
   All stroke-based, 16px grid. Exports Icon + FileGlyph to window. */

function Icon({ name, size = 16, stroke = 1.6, color = 'currentColor', style }) {
  const p = {
    width: size, height: size, viewBox: '0 0 24 24', fill: 'none',
    stroke: color, strokeWidth: stroke, strokeLinecap: 'round',
    strokeLinejoin: 'round', style,
  };
  switch (name) {
    case 'back':    return <svg {...p}><path d="M15 5l-7 7 7 7" /></svg>;
    case 'forward': return <svg {...p}><path d="M9 5l7 7-7 7" /></svg>;
    case 'up':      return <svg {...p}><path d="M12 19V6M6 12l6-6 6 6" /></svg>;
    case 'refresh': return <svg {...p}><path d="M20 11a8 8 0 10-1.6 5M20 5v6h-6" /></svg>;
    case 'chevron-right': return <svg {...p}><path d="M9 6l6 6-6 6" /></svg>;
    case 'chevron-down':  return <svg {...p}><path d="M6 9l6 6 6-6" /></svg>;
    case 'search':  return <svg {...p}><circle cx="11" cy="11" r="7" /><path d="M21 21l-4-4" /></svg>;
    case 'close':   return <svg {...p}><path d="M6 6l12 12M18 6L6 18" /></svg>;
    case 'plus':    return <svg {...p}><path d="M12 5v14M5 12h14" /></svg>;
    case 'details': return <svg {...p}><path d="M8 6h13M8 12h13M8 18h13M3.5 6h.01M3.5 12h.01M3.5 18h.01" /></svg>;
    case 'list':    return <svg {...p}><path d="M4 6h16M4 12h16M4 18h16" /></svg>;
    case 'grid':    return <svg {...p}><rect x="4" y="4" width="6" height="6" rx="1.4" /><rect x="14" y="4" width="6" height="6" rx="1.4" /><rect x="4" y="14" width="6" height="6" rx="1.4" /><rect x="14" y="14" width="6" height="6" rx="1.4" /></svg>;
    case 'columns': return <svg {...p}><rect x="3" y="4" width="18" height="16" rx="2" /><path d="M9 4v16M15 4v16" /></svg>;
    case 'split':   return <svg {...p}><rect x="3" y="4" width="18" height="16" rx="2" /><path d="M12 4v16" /></svg>;
    case 'star':    return <svg {...p}><path d="M12 3l2.6 5.6 6 .7-4.4 4.1 1.2 6L12 16.8 6.6 19.4l1.2-6L3.4 9.3l6-.7z" /></svg>;
    case 'star-fill': return <svg {...p} fill={color}><path d="M12 3l2.6 5.6 6 .7-4.4 4.1 1.2 6L12 16.8 6.6 19.4l1.2-6L3.4 9.3l6-.7z" /></svg>;
    case 'tag':     return <svg {...p}><path d="M3 12V5a2 2 0 012-2h7l9 9-9 9z" /><circle cx="8" cy="8" r="1.4" /></svg>;
    case 'copy':    return <svg {...p}><rect x="9" y="9" width="11" height="11" rx="2" /><path d="M5 15V5a2 2 0 012-2h8" /></svg>;
    case 'cut':     return <svg {...p}><circle cx="6" cy="6" r="2.5" /><circle cx="6" cy="18" r="2.5" /><path d="M8 7.5L20 18M8 16.5L20 6" /></svg>;
    case 'paste':   return <svg {...p}><rect x="6" y="4" width="12" height="17" rx="2" /><path d="M9 4V3h6v1" /><path d="M9 11h6M9 15h6" /></svg>;
    case 'rename':  return <svg {...p}><path d="M12 20h9" /><path d="M16.5 3.5a2.1 2.1 0 013 3L7 19l-4 1 1-4z" /></svg>;
    case 'trash':   return <svg {...p}><path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13" /></svg>;
    case 'new-folder': return <svg {...p}><path d="M3 7a2 2 0 012-2h4l2 2h8a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2z" /><path d="M12 11v4M10 13h4" /></svg>;
    case 'info':    return <svg {...p}><circle cx="12" cy="12" r="9" /><path d="M12 11v5M12 8h.01" /></svg>;
    case 'sun':     return <svg {...p}><circle cx="12" cy="12" r="4" /><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4" /></svg>;
    case 'moon':    return <svg {...p}><path d="M21 12.8A9 9 0 1111.2 3a7 7 0 009.8 9.8z" /></svg>;
    case 'sort-asc':  return <svg {...p}><path d="M12 19V6M7 11l5-5 5 5" /></svg>;
    case 'sort-desc': return <svg {...p}><path d="M12 5v13M7 13l5 5 5-5" /></svg>;
    case 'filter':  return <svg {...p}><path d="M3 5h18l-7 8v6l-4 2v-8z" /></svg>;
    case 'eye':     return <svg {...p}><path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7-10-7-10-7z" /><circle cx="12" cy="12" r="3" /></svg>;
    case 'sidebar': return <svg {...p}><rect x="3" y="4" width="18" height="16" rx="2" /><path d="M9 4v16" /></svg>;
    case 'panel-right': return <svg {...p}><rect x="3" y="4" width="18" height="16" rx="2" /><path d="M15 4v16" /></svg>;
    case 'drive':   return <svg {...p}><rect x="3" y="6" width="18" height="12" rx="2" /><path d="M7 12h.01" /><circle cx="16" cy="12" r="1.3" /></svg>;
    case 'cloud':   return <svg {...p}><path d="M7 18a4 4 0 010-8 5 5 0 019.6-1.2A3.5 3.5 0 0117 18z" /></svg>;
    case 'home':    return <svg {...p}><path d="M4 11l8-7 8 7M6 10v9h12v-9" /></svg>;
    case 'check':   return <svg {...p}><path d="M5 13l4 4L19 7" /></svg>;
    case 'dots':    return <svg {...p}><circle cx="5" cy="12" r="1.4" fill={color} stroke="none" /><circle cx="12" cy="12" r="1.4" fill={color} stroke="none" /><circle cx="19" cy="12" r="1.4" fill={color} stroke="none" /></svg>;
    case 'open':    return <svg {...p}><path d="M14 4h6v6M20 4l-9 9M19 14v5a1 1 0 01-1 1H5a1 1 0 01-1-1V6a1 1 0 011-1h5" /></svg>;
    case 'share':   return <svg {...p}><path d="M12 14V4M8 8l4-4 4 4" /><path d="M5 12v7a1 1 0 001 1h12a1 1 0 001-1v-7" /></svg>;
    case 'compress': return <svg {...p}><rect x="4" y="3" width="16" height="18" rx="2" /><path d="M10 3v4h4M12 11v6M10 13l2 2 2-2" /></svg>;
    case 'arrow-right': return <svg {...p}><path d="M5 12h14M13 6l6 6-6 6" /></svg>;
    case 'clock':   return <svg {...p}><circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" /></svg>;
    case 'pin':     return <svg {...p}><path d="M9 4h6l-1 6 3 3H7l3-3z" /><path d="M12 16v4" /></svg>;
    case 'server':  return <svg {...p}><rect x="3" y="4" width="18" height="6" rx="1.6" /><rect x="3" y="14" width="18" height="6" rx="1.6" /><path d="M7 7h.01M7 17h.01" /></svg>;
    case 'eye-off': return <svg {...p}><path d="M3 3l18 18" /><path d="M10.6 5.1A10.6 10.6 0 0112 5c6 0 10 7 10 7a15.6 15.6 0 01-3.2 3.9M6.6 6.6C4.5 8 3 10 2 12c0 0 4 7 10 7 1.4 0 2.7-.3 3.9-.8" /><path d="M9.9 9.9a3 3 0 004.2 4.2" /></svg>;
    default: return <svg {...p}><circle cx="12" cy="12" r="8" /></svg>;
  }
}

// Folder + file glyphs used inside file rows / grid cells.
// Geometric only: folder = body + tab; file = page + folded corner + ext badge.
function FileGlyph({ node, size = 18 }) {
  const FS = window.FS;
  const kindInfo = FS.KINDS[node.kind] || FS.KINDS.txt;
  if (node.dir) {
    const open = false;
    return (
      <svg width={size} height={size} viewBox="0 0 24 24" fill="none" style={{ flexShrink: 0 }}>
        <path d="M2.5 7.5a2 2 0 012-2h4.2a2 2 0 011.5.7l1 1.2h8.3a2 2 0 012 2V18a2 2 0 01-2 2H4.5a2 2 0 01-2-2z"
              fill={kindInfo.color} opacity="0.18" />
        <path d="M2.5 9.4h19V18a2 2 0 01-2 2H4.5a2 2 0 01-2-2z" fill={kindInfo.color} opacity="0.85" />
        <path d="M2.5 7.5a2 2 0 012-2h4.2a2 2 0 011.5.7l1 1.2h8.3a2 2 0 012 2v.4h-19z"
              fill={kindInfo.color} />
      </svg>
    );
  }
  const ext = (node.name.match(/\.([a-z0-9]+)$/i) || [, ''])[1].toUpperCase().slice(0, 4);
  const c = kindInfo.color;
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" style={{ flexShrink: 0 }}>
      <path d="M5 3h9l5 5v12.5A1.5 1.5 0 0117.5 22h-12A1.5 1.5 0 014 20.5v-16A1.5 1.5 0 015.5 3z"
            fill="var(--glyph-page)" stroke="var(--glyph-edge)" strokeWidth="1" />
      <path d="M14 3l5 5h-3.5A1.5 1.5 0 0114 6.5z" fill="var(--glyph-fold)" />
      <rect x="3.2" y="13" width="15" height="7.6" rx="1.6" fill={c} />
      <text x="10.7" y="18.6" textAnchor="middle" fontSize="5.2" fontWeight="700"
            fill="#fff" fontFamily="'Public Sans', sans-serif" letterSpacing="0.2">{ext}</text>
    </svg>
  );
}

Object.assign(window, { Icon, FileGlyph });
