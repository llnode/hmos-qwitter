export class InboxRow {
  id: string = '';
  title: string = '';
  text: string = '';
  time: string = '';
  avatar: string = '';
  path: string = '';
  kind: string = '';
  unread: boolean = false;
  outgoing: boolean = false;
}

export class InboxPage {
  rows: InboxRow[] = [];
  messages: InboxRow[] = [];
  conversation: string = '';
  title: string = '';
  locked: boolean = false;
  empty: boolean = false;
  opened: boolean = false;
  embeddedChat: boolean = false;
}

function limited(value: string, max: number): string {
  return typeof value === 'string' ? value.slice(0, max) : '';
}

function clean(rows: InboxRow[]): InboxRow[] {
  if (!Array.isArray(rows)) return [];
  return rows.filter((row: InboxRow) => row && typeof row.id === 'string' && /^[A-Za-z0-9:_-]{1,200}$/.test(row.id))
    .slice(0, 200).map((row: InboxRow): InboxRow => {
      const entry = new InboxRow();
      entry.id = row.id;
      entry.title = limited(row.title, 160);
      entry.text = limited(row.text, 4000);
      entry.time = limited(row.time, 80);
      entry.kind = limited(row.kind, 32);
      entry.avatar = typeof row.avatar === 'string' && /^https:\/\/pbs\.twimg\.com\/(?:profile_images|default_profile_images)\//.test(row.avatar) ?
        limited(row.avatar, 600) : '';
      entry.path = typeof row.path === 'string' &&
        /^\/(?:[A-Za-z0-9_]{1,15}(?:\/status\/\d{1,24})?|i\/web\/status\/\d{1,24}|(?:i\/chat|messages)\/[A-Za-z0-9_-]{1,128})$/
          .test(row.path) ? row.path : chatConversationUrl(row.path);
      entry.unread = row.unread === true;
      entry.outgoing = row.outgoing === true;
      return entry;
    });
}

export function chatConversationUrl(path: string): string {
  if (typeof path !== 'string') return '';
  if (/^\/(?:i\/chat|messages)\/[A-Za-z0-9_-]{1,128}$/.test(path)) return 'https://x.com' + path;
  return /^https:\/\/chat\.x\.com\/(?:i\/chat\/|messages\/|chat\/|conversation\/)?[A-Za-z0-9_-]{1,128}$/.test(path) ?
    path : '';
}

export function decodeInbox(page: InboxPage | null): InboxPage | null {
  if (!page || typeof page !== 'object') return null;
  page.rows = clean(page.rows);
  page.messages = clean(page.messages);
  page.title = limited(page.title, 160);
  page.conversation = typeof page.conversation === 'string' && /^[A-Za-z0-9:_-]{1,200}$/.test(page.conversation) ?
    page.conversation : '';
  page.locked = page.locked === true;
  page.empty = page.empty === true;
  page.opened = page.opened === true;
  page.embeddedChat = page.embeddedChat === true;
  return page;
}
