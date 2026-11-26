import { preferences } from '@kit.ArkData';
import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { HOME_POST_LIMIT } from '../data/ReaderStore';
import { decodeSnapshot, Post, Snapshot } from './XPage';

const RESET: string = 'resetPending';
const KNOWN_SESSION: string = 'knownSession';
const KNOWN_ACCOUNT: string = 'knownAccount';
const HOME_TAB: string = 'homeTab';
const MAX_HOME_BYTES: number = 8 * 1024 * 1024;
const HOME_MAX_AGE_MS: number = 12 * 60 * 60 * 1000;


class RecentHome {
  format: number = 1;
  savedAt: number = 0;
  snapshot: string = '';
}

export class HomePosition {
  postId: string = '';
  offset: number = 0;
  headerHidden: boolean = false;
}

export class SessionReset {
  private store?: preferences.Preferences;
  private homePath: string = '';

  async open(context: common.UIAbilityContext): Promise<boolean> {
    this.store = await preferences.getPreferences(context, 'qyx_session');
    this.homePath = context.cacheDir + '/qyx-recent-home.json';
    return await this.store.get(RESET, false) === true;
  }

  readHome(tab: number): Snapshot | undefined {
    const position = this.readHomePosition(tab);
    return this.readHomeFile(this.homePath + '.' + tab.toString(), position) ||
      (tab === 0 ? this.readHomeFile(this.homePath, position) : undefined);
  }

  private readHomeFile(path: string, position?: HomePosition): Snapshot | undefined {
    try {
      if (fileIo.statSync(path).size > MAX_HOME_BYTES) return undefined;
      const saved = JSON.parse(fileIo.readTextSync(path)) as RecentHome;
      if (!saved || saved.format !== 1 || !Number.isFinite(saved.savedAt)) return undefined;
      const snapshot = decodeSnapshot(saved.snapshot, HOME_POST_LIMIT, MAX_HOME_BYTES);
      if (!snapshot?.authenticated || snapshot.path !== '/home' || !snapshot.posts.length) return undefined;
      const resumable = position && snapshot.posts.some((post: Post) => post.id === position.postId);
      return resumable || Date.now() - saved.savedAt <= HOME_MAX_AGE_MS ? snapshot : undefined;
    } catch (_) {
      return undefined;
    }
  }

  removeLegacyHome(tab: number): void {
    const paths = [this.homePath + '.' + tab.toString()];
    if (tab === 0) paths.push(this.homePath);
    for (const path of paths) {
      if (fileIo.accessSync(path)) fileIo.unlinkSync(path);
      if (fileIo.accessSync(path + '.tmp')) fileIo.unlinkSync(path + '.tmp');
    }
  }

  forgetHome(tab: number = -1): void {
    const paths = [this.homePath];
    if (tab <= 0) paths.push(this.homePath + '.0');
    if (tab !== 0) paths.push(this.homePath + '.1');
    for (const path of paths) {
      if (fileIo.accessSync(path)) fileIo.unlinkSync(path);
      if (fileIo.accessSync(path + '.tmp')) fileIo.unlinkSync(path + '.tmp');
    }
    const store = this.store;
    if (store) {
      if (tab < 0) store.deleteSync(HOME_TAB);
      if (tab <= 0) store.deleteSync('homePosition0');
      if (tab !== 0) store.deleteSync('homePosition1');
      store.flushSync();
    }
  }

  readHomeTab(): number {
    return this.store?.getSync(HOME_TAB, 0) === 1 ? 1 : 0;
  }

  async saveHomeTab(tab: number): Promise<void> {
    const store = this.store;
    if (!store || this.readHomeTab() === tab) return;
    store.putSync(HOME_TAB, tab);
    await store.flush();
  }

  readHomePosition(tab: number): HomePosition | undefined {
    try {
      const raw = this.store?.getSync('homePosition' + tab.toString(), '');
      if (typeof raw !== 'string' || !raw) return undefined;
      const position = JSON.parse(raw) as HomePosition;
      if (typeof position.postId === 'string' && /^\d{1,24}$/.test(position.postId) &&
        Number.isFinite(position.offset) && typeof position.headerHidden === 'boolean') {
        return position;
      }
    } catch (_) {}
    return undefined;
  }

  async saveHomePosition(tab: number, position: HomePosition): Promise<void> {
    const store = this.store;
    if (!store) return;
    const key = 'homePosition' + tab.toString();
    const value = position.postId ? JSON.stringify(position) : '';
    if (store.getSync(key, '') === value) return;
    store.putSync(key, value);
    await store.flush();
  }

  hasKnownSession(): boolean {
    return this.store?.getSync(KNOWN_SESSION, false) === true;
  }

  knownAccount(): string {
    const value = this.store?.getSync(KNOWN_ACCOUNT, '');
    return typeof value === 'string' ? value : '';
  }

  async rememberAccount(handle: string): Promise<void> {
    if (!this.store || this.knownAccount() === handle) return;
    this.store.putSync(KNOWN_ACCOUNT, handle);
    await this.store.flush();
  }

  async rememberSession(known: boolean): Promise<void> {
    const store = this.store;
    if (!store) return;
    store.putSync(KNOWN_SESSION, known);
    if (!known) store.deleteSync(KNOWN_ACCOUNT);
    await store.flush();
  }

  async markPending(): Promise<void> {
    const store = this.store;
    if (!store) throw new Error('Session storage unavailable');
    store.putSync(RESET, true);
    store.deleteSync(KNOWN_SESSION);
    store.deleteSync(KNOWN_ACCOUNT);
    await store.flush();
  }

  async clear(controller: webview.WebviewController): Promise<void> {
    const store = this.store;
    if (!store) throw new Error('Session storage unavailable');
    await webview.WebCookieManager.clearAllCookies();
    webview.WebStorage.deleteAllData();
    controller.removeCache(true);
    controller.clearHistory();
    await webview.WebCookieManager.saveCookieAsync();
    this.forgetHome();
    await store.delete(RESET);
    await store.flush();
  }
}
