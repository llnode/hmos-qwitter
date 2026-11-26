import { decodeDiscovery, DiscoverySection } from '../web/Discovery';
import { common } from '@kit.AbilityKit';
import { relationalStore as rdb } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { readSettingsSnapshot, SettingRow, SettingsPage, settingsRoute, SETTINGS_TITLE } from '../web/SettingsPage';
import { decodeSnapshot, normalizeVideoSources, Post, Profile, quoteStatusPath, Snapshot, Surface, validHandle, XRoute } from '../web/XPage';
import { decodeInbox, InboxPage, InboxRow } from '../web/InboxPage';

export const HOME_POST_LIMIT: number = 300;
const REPLY_LIMIT: number = 300;
const HOUR: number = 3600000;
const FEED: string = 'reader_feed';
const POSTS: string = 'reader_post';
const REPLIES: string = 'reader_reply';
const LIBRARY: string = 'reader_library';
// Posts this account opened in Qwitter. Local only, separate from X's likes and bookmarks.
const BROWSING: string = 'reader_browsing';
// X accounts that have been active in Qwitter on this device (for the account switcher). Not owner-scoped.
const ACCOUNTS: string = 'reader_account';

export class KnownAccount {
  handle: string = '';
  name: string = '';
  avatar: string = '';
  seen: number = 0;
}
const BROWSING_LIMIT: number = 500;
const DB_NAME: string = 'qyx-reader.db';

interface RecentThread {
  saved: number;
  snapshot: Snapshot;
}

export interface SidebarEntry {
  label: string;
  path: string;
  icon: Resource;
  primary: boolean;
}

const SIDEBAR_ENTRIES: SidebarEntry[] = [
  { label: '个人资料', path: 'profile', icon: $r('app.media.menu_profile'), primary: true },
  { label: '订阅', path: '/i/premium', icon: $r('app.media.menu_premium'), primary: true },
  { label: 'Money', path: '/i/money', icon: $r('app.media.menu_money'), primary: true },
  { label: '历史', path: '/i/history', icon: $r('app.media.menu_history'), primary: true },
  { label: '社群', path: '/i/communities', icon: $r('app.media.menu_people'), primary: true },
  { label: '列表', path: '/i/lists', icon: $r('app.media.menu_lists'), primary: true },
  { label: '空间', path: '/i/spaces', icon: $r('app.media.menu_space'), primary: true },
  { label: '创作者工作室', path: '/creators/studio', icon: $r('app.media.menu_studio'), primary: true },
  { label: '试用 Grok Bot', path: '/i/grok', icon: $r('app.media.grok_mark'), primary: false },
  { label: SETTINGS_TITLE, path: 'settings', icon: $r('app.media.menu_settings'), primary: false },
  { label: '帮助中心', path: 'https://help.x.com/zh-cn', icon: $r('app.media.menu_help'), primary: false }
];

export class ReaderStore {
  private db?: rdb.RdbStore;
  private owner: string = '';
  private revision: number = 0;
  private homeCount: number[] = [0, 0];
  private readonly recentThreads: Map<string, RecentThread> = new Map();
  private readonly recentPages: Map<string, Snapshot> = new Map();
  private readonly recentSettings: Map<string, SettingsPage> = new Map();
  private readonly homeUpdates: Map<number, Snapshot> = new Map();
  private readonly recentInbox: Map<string, InboxPage> = new Map();
  private writes: Promise<void> = Promise.resolve();

  sidebarEntries(): SidebarEntry[] {
    return SIDEBAR_ENTRIES;
  }

  async open(context: common.UIAbilityContext): Promise<void> {
    if (this.db) return;
    const db = await rdb.getRdbStore(context, {
      name: DB_NAME,
      securityLevel: rdb.SecurityLevel.S2,
      encrypt: true
    });
    await db.executeSql('CREATE TABLE IF NOT EXISTS reader_feed (' +
      'owner TEXT NOT NULL, tab INTEGER NOT NULL, position INTEGER NOT NULL, post TEXT NOT NULL, ' +
      'PRIMARY KEY(owner, tab, position))');
    await db.executeSql('CREATE TABLE IF NOT EXISTS reader_document (' +
      'owner TEXT NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL, saved INTEGER NOT NULL, payload TEXT NOT NULL, ' +
      'PRIMARY KEY(owner, kind, key))');
    await db.executeSql('CREATE TABLE IF NOT EXISTS reader_post (' +
      'owner TEXT NOT NULL, id TEXT NOT NULL, saved INTEGER NOT NULL, quality INTEGER NOT NULL, ' +
      'payload TEXT NOT NULL, PRIMARY KEY(owner, id))');
    await db.executeSql('CREATE INDEX IF NOT EXISTS reader_post_age ON reader_post(owner, saved DESC)');
    await db.executeSql('CREATE TRIGGER IF NOT EXISTS reader_keep_full_post BEFORE INSERT ON reader_post ' +
      'WHEN EXISTS (SELECT 1 FROM reader_post WHERE owner = NEW.owner AND id = NEW.id AND quality > NEW.quality ' +
      'AND saved >= NEW.saved - 43200000) BEGIN SELECT RAISE(IGNORE); END');
    await db.executeSql('CREATE TABLE IF NOT EXISTS reader_reply (' +
      'owner TEXT NOT NULL, root TEXT NOT NULL, position INTEGER NOT NULL, parent TEXT NOT NULL, post TEXT NOT NULL, ' +
      'PRIMARY KEY(owner, root, position))');
    await db.executeSql('CREATE TABLE IF NOT EXISTS reader_library (' +
      'owner TEXT NOT NULL, key TEXT NOT NULL, position INTEGER NOT NULL, post TEXT NOT NULL, ' +
      'PRIMARY KEY(owner, key, position))');
    await db.executeSql('CREATE TABLE IF NOT EXISTS reader_browsing (' +
      'owner TEXT NOT NULL, id TEXT NOT NULL, viewed INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(owner, id))');
    await db.executeSql('CREATE INDEX IF NOT EXISTS reader_browsing_age ON reader_browsing(owner, viewed DESC)');
    await db.executeSql('CREATE TABLE IF NOT EXISTS reader_account (' +
      'handle TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL, avatar TEXT NOT NULL, seen INTEGER NOT NULL)');
    this.db = db;
  }

  setAccount(handle: string): void {
    const owner = validHandle(handle) ? handle.toLowerCase() : '';
    if (owner === this.owner) return;
    this.owner = owner;
    this.revision++;
    this.homeCount = [0, 0];
    this.recentThreads.clear();
    this.recentPages.clear();
    this.recentSettings.clear();
    this.homeUpdates.clear();
    this.recentInbox.clear();
  }

  private write(task: (db: rdb.RdbStore, owner: string) => Promise<void>): Promise<void> {
    const owner = this.owner;
    const revision = this.revision;
    if (!owner || !this.db) return Promise.resolve();
    const operation = this.writes.then(async () => {
      if (this.db && this.revision === revision) await task(this.db, owner);
    });
    this.writes = operation.catch(() => {});
    return operation;
  }

  async clear(context: common.UIAbilityContext): Promise<void> {
    this.setAccount('');
    await this.writes;
    const db = this.db;
    if (!db) {
      await rdb.deleteRdbStore(context, DB_NAME);
      return;
    }
    const tx = await db.createTransaction();
    try {
      await tx.delete(new rdb.RdbPredicates(FEED));
      await tx.delete(new rdb.RdbPredicates('reader_document'));
      await tx.delete(new rdb.RdbPredicates(POSTS));
      await tx.delete(new rdb.RdbPredicates(REPLIES));
      await tx.delete(new rdb.RdbPredicates(LIBRARY));
      await tx.delete(new rdb.RdbPredicates(BROWSING));
      await tx.delete(new rdb.RdbPredicates(ACCOUNTS));
      await tx.commit();
    } catch (_) {
      await tx.rollback();
      throw new Error('Reader cache clear failed');
    }
  }

  async readHome(tab: number, anchor: string): Promise<Snapshot | undefined> {
    const db = this.db;
    const owner = this.owner;
    const revision = this.revision;
    if (!db || !owner) return undefined;
    const rs = await db.querySql(
      'SELECT m.saved, m.payload, f.post FROM reader_document m JOIN reader_feed f ON f.owner = m.owner ' +
      'AND f.tab = ? WHERE m.owner = ? AND m.kind = ? AND m.key = ? ORDER BY f.position LIMIT ?',
      [tab, owner, 'home', tab.toString(), HOME_POST_LIMIT]);
    try {
      if (!rs.goToFirstRow()) return undefined;
      const saved = rs.getLong(0);
      const snapshot = decodeSnapshot(rs.getString(1));
      if (!snapshot) return undefined;
      do {
        const post = JSON.parse(rs.getString(2)) as Post;
        if (post && validHandle(post.handle) && /^\d{1,24}$/.test(post.id)) snapshot.posts.push(post);
      } while (rs.goToNextRow());
      if (this.revision !== revision) return undefined;
      if (!snapshot.posts.length) return undefined;
      this.homeCount[tab] = snapshot.posts.length;
      return Date.now() - saved <= 12 * HOUR || snapshot.posts.some((post: Post) => post.id === anchor) ?
        snapshot : undefined;
    } finally {
      rs.close();
    }
  }

  async readHomeUpdates(tab: number, maxAge: number = 12 * HOUR): Promise<Post[]> {
    let staged = this.homeUpdates.get(tab);
    if (!staged) {
      const revision = this.revision;
      const stored = decodeSnapshot(await this.readDocument('home_updates', tab.toString(), 12 * HOUR));
      if (this.revision !== revision) return [];
      staged = this.homeUpdates.get(tab) || stored || new Snapshot();
      this.homeUpdates.set(tab, staged);
    }
    return Date.now() - staged.cachedAt <= maxAge ? staged.posts : [];
  }

  async stageHomeUpdates(tab: number, incoming: Post[]): Promise<boolean> {
    const revision = this.revision;
    if (!this.db || !this.owner || !incoming.length) return false;
    const snapshot = new Snapshot();
    snapshot.cachedAt = Date.now();
    snapshot.path = '/home';
    snapshot.authenticated = true;
    snapshot.posts = incoming.slice(0, 32);
    await this.saveDocument('home_updates', tab.toString(), JSON.stringify(snapshot), 2);
    if (revision !== this.revision) return false;
    this.homeUpdates.set(tab, snapshot);
    return true;
  }

  async saveHome(tab: number, name: string, avatar: string, posts: Post[], previousCount: number, clearUpdates: boolean = false): Promise<boolean> {
    const snapshot = posts.slice(0, HOME_POST_LIMIT);
    const revision = this.revision;
    let committed = false;
    await this.write(async (db, owner) => {
      const first = this.homeCount[tab] === previousCount ? previousCount : 0;
      const rows: rdb.ValuesBucket[] = snapshot.slice(first).map((post: Post, index: number): rdb.ValuesBucket => ({
        owner, tab, position: first + index, post: JSON.stringify(post)
      }));
      const metadata = new Snapshot();
      metadata.path = '/home';
      metadata.authenticated = true;
      metadata.ownHandle = owner;
      metadata.ownName = name;
      metadata.ownAvatar = avatar;
      metadata.homeTab = tab;
      const tx = await db.createTransaction();
      try {
        if (first === 0) await tx.delete(new rdb.RdbPredicates(FEED).equalTo('owner', owner).equalTo('tab', tab));
        if (rows.length) await tx.batchInsertWithConflictResolution(FEED, rows, rdb.ConflictResolution.ON_CONFLICT_REPLACE);
        await this.writePosts(tx, owner, snapshot.slice(first));
        await tx.execute('INSERT OR REPLACE INTO reader_document VALUES (?, ?, ?, ?, ?)',
          [owner, 'home', tab.toString(), Date.now(), JSON.stringify(metadata)]);
        if (clearUpdates) {
          await tx.execute('DELETE FROM reader_document WHERE owner = ? AND kind = ? AND key = ?',
            [owner, 'home_updates', tab.toString()]);
        }
        await tx.commit();
        committed = true;
        if (this.revision === revision) {
          this.homeCount[tab] = snapshot.length;
          if (clearUpdates) this.homeUpdates.set(tab, new Snapshot());
        }
      } catch (_) {
        await tx.rollback();
        throw new Error('Timeline cache write failed');
      }
    });
    return committed;
  }

  private async writePosts(tx: rdb.Transaction, owner: string, posts: Post[]): Promise<void> {
    if (!posts.length) return;
    const now = Date.now();
    const rows = posts.map((post: Post): rdb.ValuesBucket => ({
      owner, id: post.id, saved: now,
      quality: (post.body ? 8 : 0) + (post.name ? 1 : 0) + (post.avatar ? 1 : 0) +
        Math.min(4, post.photos.length) + (post.videoSources.length ? 4 : 0) + (post.quotedPost?.path ? 2 : 0),
      payload: JSON.stringify(post)
    }));
    await tx.batchInsertWithConflictResolution(POSTS, rows, rdb.ConflictResolution.ON_CONFLICT_REPLACE);
    await tx.execute('DELETE FROM reader_post WHERE owner = ? AND id IN (' +
      'SELECT id FROM reader_post WHERE owner = ? ORDER BY saved DESC, id LIMIT -1 OFFSET 960)', [owner, owner]);
  }

  savePost(post: Post): Promise<void> {
    return this.write(async (db, owner) => {
      const tx = await db.createTransaction();
      try {
        await this.writePosts(tx, owner, [post]);
        await tx.commit();
      } catch (_) {
        await tx.rollback();
        throw new Error('Post cache write failed');
      }
    });
  }

  // Remembers an account that was active in Qwitter, keeping a known name or avatar when the new one is empty.
  async rememberKnownAccount(handle: string, name: string, avatar: string): Promise<void> {
    const db = this.db;
    if (!db || !validHandle(handle)) return;
    const key = handle.toLowerCase();
    const picture = /^https:\/\/pbs\.twimg\.com\/profile_images\//.test(avatar) ? avatar : '';
    await db.executeSql('INSERT INTO reader_account VALUES (?, ?, ?, ?) ON CONFLICT(handle) DO UPDATE SET ' +
      "name = CASE WHEN excluded.name <> '' THEN excluded.name ELSE name END, " +
      "avatar = CASE WHEN excluded.avatar <> '' THEN excluded.avatar ELSE avatar END, seen = excluded.seen",
      [key, name.slice(0, 80), picture, Date.now()]);
  }

  async readKnownAccounts(): Promise<KnownAccount[]> {
    const db = this.db;
    if (!db) return [];
    const rs = await db.querySql('SELECT handle, name, avatar, seen FROM reader_account ORDER BY seen DESC LIMIT 8');
    const accounts: KnownAccount[] = [];
    try {
      while (rs.goToNextRow()) {
        const account = new KnownAccount();
        account.handle = rs.getString(0);
        account.name = rs.getString(1);
        account.avatar = rs.getString(2);
        account.seen = rs.getLong(3);
        if (validHandle(account.handle)) accounts.push(account);
      }
    } finally {
      rs.close();
    }
    return accounts;
  }

  async forgetKnownAccount(handle: string): Promise<void> {
    const db = this.db;
    if (!db) return;
    await db.delete(new rdb.RdbPredicates(ACCOUNTS).equalTo('handle', handle.toLowerCase()));
  }

  // Records that the current account opened a post. Re-opening moves it to the top.
  recordBrowsing(post: Post): Promise<void> {
    if (!validHandle(post.handle) || !/^\d{1,24}$/.test(post.id)) return Promise.resolve();
    const payload = JSON.stringify(post);
    if (payload.length > 60000) return Promise.resolve();
    return this.write(async (db, owner) => {
      const tx = await db.createTransaction();
      try {
        await tx.execute('INSERT OR REPLACE INTO reader_browsing VALUES (?, ?, ?, ?)', [owner, post.id, Date.now(), payload]);
        await tx.execute('DELETE FROM reader_browsing WHERE owner = ? AND id IN (' +
          'SELECT id FROM reader_browsing WHERE owner = ? ORDER BY viewed DESC, id LIMIT -1 OFFSET ?)',
          [owner, owner, BROWSING_LIMIT]);
        await tx.commit();
      } catch (_) {
        await tx.rollback();
        throw new Error('Browsing history write failed');
      }
    });
  }

  // Replaces the stored copy of an already-recorded post with a fuller one, without changing its position.
  updateBrowsing(post: Post): Promise<void> {
    if (!validHandle(post.handle) || !/^\d{1,24}$/.test(post.id)) return Promise.resolve();
    const payload = JSON.stringify(post);
    if (payload.length > 60000) return Promise.resolve();
    return this.write(async (db, owner) => {
      await db.executeSql('UPDATE reader_browsing SET payload = ? WHERE owner = ? AND id = ?', [payload, owner, post.id]);
    });
  }

  async readBrowsing(limit: number = 300): Promise<Post[]> {
    // A post opened just before showing the list may still be queued for writing.
    await this.writes.catch(() => {});
    const db = this.db;
    const owner = this.owner;
    const revision = this.revision;
    if (!db || !owner) return [];
    const rs = await db.querySql('SELECT payload FROM reader_browsing WHERE owner = ? ORDER BY viewed DESC LIMIT ?',
      [owner, Math.max(1, Math.min(limit, BROWSING_LIMIT))]);
    const posts: Post[] = [];
    try {
      while (rs.goToNextRow()) {
        try {
          const post = JSON.parse(rs.getString(0)) as Post;
          if (post && validHandle(post.handle) && /^\d{1,24}$/.test(post.id)) posts.push(post);
        } catch (_) {}
      }
    } finally {
      rs.close();
    }
    return revision === this.revision ? posts : [];
  }

  clearBrowsing(): Promise<void> {
    return this.write(async (db, owner) => {
      await db.delete(new rdb.RdbPredicates(BROWSING).equalTo('owner', owner));
    });
  }

  async readPost(id: string): Promise<Post | undefined> {
    const db = this.db;
    const revision = this.revision;
    if (!db || !this.owner || !/^\d{1,24}$/.test(id)) return undefined;
    const result = await db.querySql('SELECT payload FROM reader_post WHERE owner = ? AND id = ? AND saved >= ?',
      [this.owner, id, Date.now() - 12 * HOUR]);
    try {
      return revision === this.revision && result.goToFirstRow() ? JSON.parse(result.getString(0)) as Post : undefined;
    } finally {
      result.close();
    }
  }

  private saveDocument(kind: string, key: string, payload: string, limit: number, posts: Post[] = []): Promise<void> {
    if (payload.length > 450000) return Promise.resolve();
    return this.write(async (db, owner) => {
      const tx = await db.createTransaction();
      try {
        await this.writePosts(tx, owner, posts);
        await tx.execute('INSERT OR REPLACE INTO reader_document VALUES (?, ?, ?, ?, ?)',
          [owner, kind, key, Date.now(), payload]);
        await tx.execute('DELETE FROM reader_document WHERE owner = ? AND kind = ? AND key IN (' +
          'SELECT key FROM reader_document WHERE owner = ? AND kind = ? ORDER BY saved DESC, key LIMIT -1 OFFSET ?)',
          [owner, kind, owner, kind, limit]);
        await tx.commit();
      } catch (_) {
        await tx.rollback();
        throw new Error('Reader document write failed');
      }
    });
  }

  private async readDocument(kind: string, key: string, maxAge: number): Promise<string> {
    const db = this.db;
    const revision = this.revision;
    if (!db || !this.owner) return '';
    const rs = await db.querySql('SELECT payload FROM reader_document WHERE owner = ? AND kind = ? AND key = ? AND saved >= ?',
      [this.owner, kind, key, Date.now() - maxAge]);
    try {
      return this.revision === revision && rs.goToFirstRow() ? rs.getString(0) : '';
    } finally {
      rs.close();
    }
  }

  saveTranslation(post: Post): Promise<void> {
    if (!/^\d{1,24}$/.test(post.id) || !/^[A-Za-z0-9-]{2,24}$/.test(post.translationLanguage) ||
      !post.body || !post.translation || post.translation === post.body) return Promise.resolve();
    return this.saveDocument('translation', post.translationLanguage + ':' + post.id,
      JSON.stringify({ body: post.body, translation: post.translation }), 1200);
  }

  async readTranslations(posts: Post[], target: string): Promise<Post[]> {
    const db = this.db;
    const owner = this.owner;
    const revision = this.revision;
    if (!db || !owner || !/^[A-Za-z0-9-]{2,24}$/.test(target)) return [];
    const byKey = new Map<string, Post>();
    for (const post of posts.slice(0, 24)) {
      if (/^\d{1,24}$/.test(post.id) && post.body) byKey.set(target + ':' + post.id, post);
    }
    const keys = Array.from(byKey.keys());
    if (!keys.length) return [];
    const rs = await db.querySql('SELECT key, payload FROM reader_document WHERE owner = ? AND kind = ? AND saved >= ? ' +
      'AND key IN (' + keys.map(() => '?').join(',') + ')', [owner, 'translation', Date.now() - 14 * 24 * HOUR, ...keys]);
    const translated: Post[] = [];
    try {
      if (revision !== this.revision || !rs.goToFirstRow()) return [];
      do {
        const original = byKey.get(rs.getString(0));
        try {
          const cached = JSON.parse(rs.getString(1)) as Post;
          if (!original || cached.body !== original.body || typeof cached.translation !== 'string' ||
            !cached.translation || cached.translation === cached.body) continue;
          const post = new Post();
          post.id = original.id;
          post.body = cached.body;
          post.translation = cached.translation;
          post.translationLanguage = target;
          translated.push(post);
        } catch (_) {}
      } while (rs.goToNextRow());
      return translated;
    } finally {
      rs.close();
    }
  }

  saveQuotePath(outerId: string, path: string): Promise<void> {
    const canonical = quoteStatusPath(path, outerId);
    return canonical && /^\d{1,24}$/.test(outerId) ?
      this.saveDocument('quote_path', outerId, canonical, 300) : Promise.resolve();
  }

  async readQuotePath(outerId: string): Promise<string> {
    return quoteStatusPath(await this.readDocument('quote_path', outerId, 12 * HOUR), outerId);
  }

  async cacheConfirmedReply(parent: Post, reply: Post): Promise<void> {
    const owner = this.owner;
    if (!owner || reply.replyToId !== parent.id) return;
    const cached = await this.readThread(parent.id);
    if (this.owner !== owner) return;
    const replies = (cached?.posts || []).filter((post: Post) => post.id !== parent.id && post.id !== reply.id);
    this.publishThread(cached?.posts[0] || parent, [reply, ...replies]);
  }

  publishThread(post: Post, replies: Post[], empty: boolean = false, complete: boolean = false,
    persist: boolean = true): Snapshot {
    const snapshot = new Snapshot();
    snapshot.path = '/' + post.handle + '/status/' + post.id;
    snapshot.authenticated = true;
    snapshot.empty = empty && !replies.length;
    snapshot.threadComplete = complete || snapshot.empty;
    snapshot.posts = [post, ...replies.slice(0, REPLY_LIMIT)];
    for (const reply of snapshot.posts.slice(1)) {
      if (!reply.replyToId) reply.replyToId = post.id;
    }
    if (!persist || !this.owner || (!replies.length && !empty)) return snapshot;
    this.recentThreads.delete(post.id);
    if (this.recentThreads.size >= 24) this.recentThreads.delete(Array.from(this.recentThreads.keys())[0]);
    this.recentThreads.set(post.id, { saved: Date.now(), snapshot });
    this.writeThread(post, snapshot).catch(() => hilog.warn(0x0000, 'QwitterReader', 'thread cache write failed'));
    return snapshot;
  }

  private writeThread(post: Post, snapshot: Snapshot): Promise<void> {
    const replies = snapshot.posts.slice(1);
    const metadata = new Snapshot();
    metadata.path = snapshot.path;
    metadata.authenticated = true;
    metadata.empty = snapshot.empty;
    metadata.threadComplete = snapshot.threadComplete;
    metadata.posts = [post];
    const payload = JSON.stringify(metadata);
    return this.write(async (db, owner) => {
      const rows = replies.map((reply: Post, index: number): rdb.ValuesBucket => ({
        owner, root: post.id, position: index, parent: reply.replyToId || post.id, post: JSON.stringify(reply)
      }));
      const tx = await db.createTransaction();
      try {
        await this.writePosts(tx, owner, snapshot.posts);
        await tx.execute('INSERT OR REPLACE INTO reader_document VALUES (?, ?, ?, ?, ?)',
          [owner, 'thread', post.id, Date.now(), payload]);
        await tx.delete(new rdb.RdbPredicates(REPLIES).equalTo('owner', owner).equalTo('root', post.id));
        if (rows.length) await tx.batchInsert(REPLIES, rows);
        await tx.execute('DELETE FROM reader_document WHERE owner = ? AND kind = ? AND key IN (' +
          'SELECT key FROM reader_document WHERE owner = ? AND kind = ? ORDER BY saved DESC, key LIMIT -1 OFFSET 64)',
          [owner, 'thread', owner, 'thread']);
        await tx.execute('DELETE FROM reader_reply WHERE owner = ? AND root NOT IN (' +
          'SELECT key FROM reader_document WHERE owner = ? AND kind = ?)', [owner, owner, 'thread']);
        await tx.commit();
      } catch (_) {
        await tx.rollback();
        throw new Error('Thread cache write failed');
      }
    });
  }

  async readThread(id: string): Promise<Snapshot | undefined> {
    const entry = this.recentThreads.get(id);
    if (entry && Date.now() - entry.saved <= 2 * HOUR) return entry.snapshot;
    const db = this.db;
    const revision = this.revision;
    if (!db || !this.owner) return undefined;
    const rs = await db.querySql(
      'SELECT m.payload, r.parent, r.post FROM reader_document m LEFT JOIN reader_reply r ON r.owner = m.owner ' +
      'AND r.root = m.key WHERE m.owner = ? AND m.kind = ? AND m.key = ? AND m.saved >= ? ORDER BY r.position',
      [this.owner, 'thread', id, Date.now() - 2 * HOUR]);
    try {
      if (revision !== this.revision || !rs.goToFirstRow()) return undefined;
      const snapshot = decodeSnapshot(rs.getString(0));
      if (!snapshot?.posts.length) return undefined;
      do {
        if (rs.isColumnNull(2)) break;
        const post = JSON.parse(rs.getString(2)) as Post;
        post.replyToId = rs.getString(1);
        snapshot.posts.push(post);
      } while (rs.goToNextRow());
      return snapshot;
    } finally {
      rs.close();
    }
  }

  saveVideo(id: string, sources: string[]): Promise<void> {
    const candidates = normalizeVideoSources(sources);
    return candidates.length ? this.saveDocument('video', id, JSON.stringify(candidates), 120) : Promise.resolve();
  }

  async readVideo(id: string): Promise<string[]> {
    const payload = await this.readDocument('video', id, HOUR / 2);
    return payload ? normalizeVideoSources(JSON.parse(payload) as string[]) : [];
  }

  async readInbox(key: string): Promise<InboxPage | null> {
    if (!this.owner) return null;
    const recent = this.recentInbox.get(key);
    if (recent) return recent;
    const db = this.db;
    const revision = this.revision;
    if (!db) return null;
    const rs = await db.querySql(
      "SELECT m.payload, l.post FROM reader_document m LEFT JOIN reader_library l ON l.owner = m.owner " +
      "AND l.key = 'inbox:' || m.key WHERE m.owner = ? AND m.kind = ? AND m.key = ? ORDER BY l.position",
      [this.owner, 'inbox', key]);
    try {
      if (revision !== this.revision || !rs.goToFirstRow()) return null;
      const page = JSON.parse(rs.getString(0)) as InboxPage;
      do {
        if (rs.isColumnNull(1)) break;
        page.rows.push(JSON.parse(rs.getString(1)) as InboxRow);
      } while (rs.goToNextRow());
      const decoded = decodeInbox(page);
      if (decoded && !this.recentInbox.has(key)) this.rememberInbox(key, decoded);
      return this.recentInbox.get(key) || decoded;
    } finally {
      rs.close();
    }
  }

  publishInbox(key: string, rows: InboxRow[], empty: boolean, title: string, persist: boolean): InboxPage {
    const page = new InboxPage();
    page.title = title;
    page.rows = rows.slice(0, 160);
    page.empty = empty && !page.rows.length;
    if (!persist || !this.owner || (!page.rows.length && !page.empty)) return page;
    const previous = this.recentInbox.get(key);
    if (previous && previous.title === title && previous.empty === page.empty &&
      JSON.stringify(previous.rows) === JSON.stringify(page.rows)) return previous;
    this.rememberInbox(key, page);
    this.writeInbox(key, page).catch(() => {
      if (this.recentInbox.get(key) === page) this.recentInbox.delete(key);
      hilog.warn(0x0000, 'QwitterReader', 'inbox cache write failed');
    });
    return page;
  }

  private rememberInbox(key: string, page: InboxPage): void {
    this.recentInbox.delete(key);
    if (this.recentInbox.size >= 16) this.recentInbox.delete(Array.from(this.recentInbox.keys())[0]);
    this.recentInbox.set(key, page);
  }

  private writeInbox(key: string, page: InboxPage): Promise<void> {
    const rowKey = 'inbox:' + key;
    const metadata = new InboxPage();
    metadata.title = page.title;
    metadata.empty = page.empty;
    return this.write(async (db, owner) => {
      const rows = page.rows.map((row: InboxRow, index: number): rdb.ValuesBucket => ({
        owner, key: rowKey, position: index, post: JSON.stringify(row)
      }));
      const tx = await db.createTransaction();
      try {
        await tx.execute('INSERT OR REPLACE INTO reader_document VALUES (?, ?, ?, ?, ?)',
          [owner, 'inbox', key, Date.now(), JSON.stringify(metadata)]);
        await tx.delete(new rdb.RdbPredicates(LIBRARY).equalTo('owner', owner).equalTo('key', rowKey));
        if (rows.length) await tx.batchInsert(LIBRARY, rows);
        await tx.execute("DELETE FROM reader_document WHERE owner = ? AND kind = ? AND key IN (" +
          "SELECT key FROM reader_document WHERE owner = ? AND kind = ? AND key LIKE 'chat:%' " +
          'ORDER BY saved DESC, key LIMIT -1 OFFSET 96)',
          [owner, 'inbox', owner, 'inbox']);
        await tx.execute("DELETE FROM reader_library WHERE owner = ? AND key LIKE 'inbox:%' AND key NOT IN (" +
          "SELECT 'inbox:' || key FROM reader_document WHERE owner = ? AND kind = ?)", [owner, owner, 'inbox']);
        await tx.commit();
        hilog.info(0x0000, 'QwitterReader', 'inbox saved to RDB, rows %{public}d', page.rows.length);
      } catch (_) {
        await tx.rollback();
        throw new Error('Inbox cache write failed');
      }
    });
  }

  saveRoute(route: XRoute, locale: string, posts: Post[], profile: Profile | null, empty: boolean,
    discovery: DiscoverySection[] = []): Promise<void> {
    const key = this.routeKey(route, locale);
    if (!this.owner || !key || (!posts.length && !empty && !discovery.some((section: DiscoverySection) => section.rows.length))) return Promise.resolve();
    const snapshot = new Snapshot();
    snapshot.authenticated = true;
    snapshot.cachedAt = Date.now();
    snapshot.path = route.path;
    snapshot.query = route.query;
    snapshot.latestSearch = route.latestSearch;
    snapshot.searchMode = route.searchMode;
    snapshot.discovery = discovery;
    const library = this.isLibrary(route);
    snapshot.posts = posts.slice(0, library ? HOME_POST_LIMIT : 32);
    snapshot.profile = profile;
    snapshot.empty = empty;
    if (!this.isOwnProfileLibraryTab(route)) this.rememberPage(key, snapshot);
    if (!library) return this.saveDocument('page', key, JSON.stringify(snapshot), 72, snapshot.posts);
    const revision = this.revision;
    const metadata = new Snapshot();
    metadata.authenticated = true;
    metadata.cachedAt = snapshot.cachedAt;
    metadata.path = snapshot.path;
    metadata.profile = profile;
    metadata.empty = empty;
    return this.write(async (db, owner) => {
      const rows = snapshot.posts.map((post: Post, index: number): rdb.ValuesBucket => ({
        owner, key, position: index, post: JSON.stringify(post)
      }));
      const tx = await db.createTransaction();
      try {
        await this.writePosts(tx, owner, snapshot.posts);
        await tx.execute('INSERT OR REPLACE INTO reader_document VALUES (?, ?, ?, ?, ?)',
          [owner, 'library', key, Date.now(), JSON.stringify(metadata)]);
        await tx.delete(new rdb.RdbPredicates(LIBRARY).equalTo('owner', owner).equalTo('key', key));
        if (rows.length) await tx.batchInsert(LIBRARY, rows);
        await tx.commit();
        if (this.revision === revision) this.rememberPage(key, snapshot);
      } catch (_) {
        await tx.rollback();
        throw new Error('Library cache write failed');
      }
    });
  }

  private rememberPage(key: string, snapshot: Snapshot): void {
    this.recentPages.delete(key);
    if (this.recentPages.size >= 24) this.recentPages.delete(Array.from(this.recentPages.keys())[0]);
    this.recentPages.set(key, snapshot);
  }

  isOwnProfileLibraryTab(route: XRoute): boolean {
    return route.surface === Surface.Profile && this.isLibrary(route) && /\/(?:likes|media(?:\/grid)?)$/i.test(route.path);
  }

  async commitProfileLibrary(route: XRoute, locale: string, posts: Post[], profile: Profile | null,
    empty: boolean): Promise<Snapshot | undefined> {
    if (!this.isOwnProfileLibraryTab(route)) return undefined;
    const revision = this.revision;
    await this.saveRoute(route, locale, posts, profile, empty);
    if (revision !== this.revision) return undefined;
    return this.readLibrary(this.routeKey(route, locale));
  }

  async readRoute(route: XRoute, locale: string): Promise<Snapshot | undefined> {
    const key = this.routeKey(route, locale);
    if (!key) return undefined;
    const recent = this.recentPages.get(key);
    if (recent && Date.now() - recent.cachedAt < 2 * HOUR) return recent;
    const library = this.isLibrary(route);
    if (library) {
      const saved = await this.readLibrary(key);
      if (saved) return saved;
    }
    const age = library ? Number.MAX_SAFE_INTEGER : 2 * HOUR;
    const cached = decodeSnapshot(await this.readDocument('page', library ? locale + ':' + route.url().toLowerCase() : key, age));
    if (cached) {
      if (library && (cached.posts.length || cached.empty)) {
        this.saveRoute(route, locale, cached.posts, cached.profile, cached.empty).catch(() => {});
      }
      return cached;
    }
    if (route.surface !== Surface.Profile) return undefined;
    const previousKey = locale + ':' + route.url();
    return previousKey !== key ? decodeSnapshot(await this.readDocument('page', previousKey, age)) : undefined;
  }

  private isLibrary(route: XRoute): boolean {
    return route.surface === Surface.Bookmarks ||
      (route.surface === Surface.Profile && route.path.split('/')[1].toLowerCase() === this.owner);
  }

  private async readLibrary(key: string): Promise<Snapshot | undefined> {
    const db = this.db;
    const revision = this.revision;
    if (!db || !this.owner) return undefined;
    const rs = await db.querySql(
      'SELECT m.payload, l.post FROM reader_document m LEFT JOIN reader_library l ON l.owner = m.owner AND l.key = m.key ' +
      'WHERE m.owner = ? AND m.kind = ? AND m.key = ? ORDER BY l.position', [this.owner, 'library', key]);
    try {
      if (this.revision !== revision || !rs.goToFirstRow()) return undefined;
      const snapshot = decodeSnapshot(rs.getString(0));
      if (!snapshot) return undefined;
      do {
        if (rs.isColumnNull(1)) break;
        snapshot.posts.push(JSON.parse(rs.getString(1)) as Post);
      } while (rs.goToNextRow());
      return snapshot;
    } finally {
      rs.close();
    }
  }

  saveDiscovery(locale: string, sections: DiscoverySection[]): Promise<void> {
    return this.saveDocument('discovery', locale, JSON.stringify(sections), 24);
  }

  async readDiscovery(locale: string): Promise<DiscoverySection[]> {
    const payload = await this.readDocument('discovery', locale, 7 * 24 * HOUR);
    return payload ? decodeDiscovery(JSON.parse(payload) as DiscoverySection[]) : [];
  }

  saveProfile(locale: string, profile: Profile): Promise<void> {
    if (!validHandle(profile.handle)) return Promise.resolve();
    const snapshot = new Snapshot();
    snapshot.path = '/' + profile.handle;
    snapshot.authenticated = true;
    snapshot.profile = profile;
    return this.saveDocument('profile', locale + ':' + profile.handle.toLowerCase(), JSON.stringify(snapshot), 72);
  }

  async readProfile(locale: string, handle: string): Promise<Profile | null> {
    if (!validHandle(handle)) return null;
    const key = locale + ':' + handle.toLowerCase();
    const snapshot = decodeSnapshot(await this.readDocument('profile', key, 24 * HOUR));
    return snapshot?.profile || null;
  }

  private routeKey(route: XRoute, locale: string): string {
    if (this.isLibrary(route)) return route.url().toLowerCase().replace(/\/media\/grid$/, '/media');
    if (route.surface === Surface.Profile) return locale + ':' + route.url().toLowerCase();
    if (route.surface === Surface.Bookmarks ||
      (route.surface === Surface.Search && route.query)) {
      return locale + ':' + route.url();
    }
    return '';
  }

  saveSettings(handle: string, locale: string, route: string, page: SettingsPage): Promise<void> {
    const key = settingsCachePath(route);
    if (this.owner !== handle.toLowerCase() || !key ||
      page.busy || page.signedOut || page.error || page.dialog) return Promise.resolve();
    const cached = new SettingsPage();
    cached.route = route;
    cached.title = page.title;
    cached.cachedAt = Date.now();
    const sensitive = page.rows.some((row: SettingRow) => row.kind === 'password' ||
      ['email', 'tel', 'file'].includes(row.inputType));
    cached.rows = page.rows.filter((row: SettingRow) => row.kind === 'link' ||
      (!sensitive && (['heading', 'text', 'button', 'toggle', 'select', 'choice', 'range'].includes(row.kind) ||
      (row.kind === 'input' && row.inputType === 'number')))).map((row: SettingRow) => {
      if (row.kind !== 'link') return row;
      const copy = new SettingRow();
      copy.kind = row.kind;
      copy.label = row.label;
      copy.path = settingsCachePath(row.path) || settingsRoute(row.path.split(/[?#]/)[0]);
      copy.key = 'link:' + copy.path;
      copy.disabled = row.disabled;
      return copy;
    }).filter((row: SettingRow) => row.kind !== 'link' || !!row.path);
    if (!cached.rows.length) return Promise.resolve();
    const cacheKey = locale + ':' + key;
    this.recentSettings.delete(cacheKey);
    if (this.recentSettings.size >= 80) this.recentSettings.delete(Array.from(this.recentSettings.keys())[0]);
    this.recentSettings.set(cacheKey, cached);
    return this.saveDocument('settings', cacheKey, JSON.stringify(cached), 180);
  }

  async readSettings(handle: string, locale: string, route: string): Promise<SettingsPage | undefined> {
    const path = settingsCachePath(route);
    if (this.owner !== handle.toLowerCase() || !path) return undefined;
    const key = locale + ':' + path;
    const page = this.recentSettings.get(key) ||
      readSettingsSnapshot(await this.readDocument('settings', key, 30 * 24 * HOUR));
    if (!page) return undefined;
    if (page.route === route) return page;
    const view = new SettingsPage();
    view.route = route;
    view.title = page.title;
    view.rows = page.rows;
    view.cachedAt = page.cachedAt;
    return view;
  }
}

export function settingsCachePath(route: string): string {
  const path = settingsRoute(route).split('?')[0];
  if (!/^https:\/\/x\.com\/settings(?:\/[a-z0-9_/-]+)?$/i.test(path) ||
    /(?:password|login|security_keys?|two.factor|sessions?|connected_apps|account_information|your_twitter_data|download|deactivat|payment|billing|email_address|phone_number|verification_code)/i
      .test(path)) return '';
  const query = route.split('?')[1] || '';
  const safe = query.split('&').filter((parameter: string) => /^(?:lang|tab|section)=[a-z0-9_-]+$/i.test(parameter));
  return path.toLowerCase() + (safe.length ? '?' + safe.join('&') : '');
}
