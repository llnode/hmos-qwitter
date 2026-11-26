export class DiscoveryRow {
  title: string = '';
  subtitle: string = '';
  query: string = '';
  path: string = '';
  avatar: string = '';
  verified: boolean = false;
}

export class DiscoverySection {
  kind: string = '';
  title: string = '';
  rows: DiscoveryRow[] = [];
}

function clipped(value: string, length: number): string {
  return typeof value === 'string' ? value.trim().slice(0, length) : '';
}

export function decodeDiscovery(sections: DiscoverySection[], rowLimit: number = 10): DiscoverySection[] {
  if (!Array.isArray(sections)) return [];
  const result: DiscoverySection[] = [];
  for (const section of sections.slice(0, 7)) {
    if (!section || !['trends', 'us', 'sports', 'people', 'other'].includes(section.kind) || !Array.isArray(section.rows)) continue;
    const title = clipped(section.title, 120);
    if (section.kind === 'other' && !title) continue;
    const rows: DiscoveryRow[] = [];
    for (const item of section.rows.slice(0, Math.min(100, Math.max(1, rowLimit)))) {
      if (!item) continue;
      const row = new DiscoveryRow();
      row.title = clipped(item.title, 160);
      row.subtitle = clipped(item.subtitle, 300);
      row.verified = item.verified === true;
      if (['trends', 'us', 'sports'].includes(section.kind)) row.query = clipped(item.query, 160);
      if (typeof item.path === 'string') {
        const profile = section.kind === 'people' && /^\/[A-Za-z0-9_]{1,15}$/.test(item.path);
        const other = (section.kind === 'other' || section.kind === 'sports') && /^\/(?:i\/(?:premium_sign_up|verified-choose|spaces\/[A-Za-z0-9_-]{1,64}|events\/\d{1,24}|topics\/\d{1,24})|premium|explore\/tabs\/[A-Za-z0-9_-]{1,64}|[A-Za-z0-9_]{1,15}\/status\/\d{1,24})$/.test(item.path);
        if (profile || other) row.path = item.path;
      }
      if (typeof item.avatar === 'string' &&
        /^https:\/\/pbs\.twimg\.com\/(?:profile_images|default_profile_images)\//.test(item.avatar)) {
        row.avatar = clipped(item.avatar, 600);
      }
      if (row.title && (row.query || row.path || section.kind === 'sports')) rows.push(row);
    }
    if (rows.length) result.push({ kind: section.kind, title, rows });
  }
  return result;
}
