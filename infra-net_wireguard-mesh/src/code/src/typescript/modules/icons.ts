// Inline SVG icon library — wireguard-mesh
const ICONS: Record<string, string> = {
  'overview':  '<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',
  'topology':  '<circle cx="12" cy="5" r="2"/><circle cx="5" cy="19" r="2"/><circle cx="19" cy="19" r="2"/><path d="M12 7v3M12 14l-7 5M12 14l7 5"/>',
  'nodes':     '<rect x="3" y="4" width="18" height="6" rx="1.5"/><rect x="3" y="14" width="18" height="6" rx="1.5"/><circle cx="7" cy="7" r="1" fill="currentColor"/><circle cx="7" cy="17" r="1" fill="currentColor"/>',
  'peers':     '<circle cx="9" cy="8" r="3"/><circle cx="17" cy="11" r="2.5"/><path d="M3 21c0-3 3-6 6-6s6 3 6 6"/><path d="M14 19c0-2 1.5-4 3-4s3 2 3 4"/>',
  'transports':'<path d="M3 12h18"/><path d="M7 8l-4 4 4 4"/><path d="M17 8l4 4-4 4"/>',
  'routes':    '<path d="M5 12h4l2-3 4 6 2-3h2"/><circle cx="5" cy="12" r="1.6" fill="currentColor"/><circle cx="19" cy="12" r="1.6" fill="currentColor"/>',
  'health':    '<path d="M12 21s-7-4.5-9.5-9A4.8 4.8 0 0 1 7 5c2 0 3.5 1.5 5 3 1.5-1.5 3-3 5-3a4.8 4.8 0 0 1 4.5 7C19 16.5 12 21 12 21Z"/>',
  'shield':    '<path d="M12 3 4 6v6c0 5 3.5 8.5 8 9 4.5-.5 8-4 8-9V6l-8-3Z"/>',
  'lock':      '<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>',
  'refresh':   '<path d="M21 12a9 9 0 0 1-15.5 6.3L3 16"/><path d="M3 12a9 9 0 0 1 15.5-6.3L21 8"/><path d="M3 4v4h4"/><path d="M21 20v-4h-4"/>',
  'external':  '<path d="M14 4h6v6"/><path d="M10 14 20 4"/><path d="M19 14v5a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h5"/>',
};

export function svgIcon(name: string, size: number = 18): string {
  const body = ICONS[name] ?? ICONS.shield;
  return `<svg viewBox="0 0 24 24" width="${size}" height="${size}" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;
}
