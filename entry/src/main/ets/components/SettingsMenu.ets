import { ui, xLanguage } from '../i18n/LanguageSettings';
import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { configureXWeb, isXLoginUrl, X_CONNECTIVITY, X_ORIGIN } from '../web/XPage';
import { readSettingsSnapshot, SettingAction, SettingEdit, SettingRow, SettingsPage, settingsRoute,
  SETTINGS_ROOT, SETTINGS_TITLE } from '../web/SettingsPage';
import { SettingsPageView } from './SettingsPageView';
import { PAPER } from './PostCard';
import { ReaderStore, settingsCachePath } from '../data/ReaderStore';
import { isLocalSettingsRoute } from '../data/AppearancePreferences';

const READ_WAIT: number = 15000;
const WRITE_WAIT: number = 14000;
const VERIFY_SETTLE: number = 1400;
const CACHE_FRESH_MS: number = 24 * 60 * 60 * 1000;
const WARM_GAP_MS: number = 1800;

class SettingsWarmPage {
  readonly controller: webview.WebviewController = new webview.WebviewController();
  readonly route: string;
  readonly handle: string;
  readonly locale: string;

  constructor(route: string, handle: string, locale: string) {
    this.route = route;
    this.handle = handle;
    this.locale = locale;
  }
}
const SAVED_NOTICE: RegExp = /saved|updated|applied|已保存|已儲存|已更新|已套用/i;
const SAVE_LABEL: RegExp = /^(?:save(?: changes)?|apply(?: changes)?|update|done|保存(?:更改)?|儲存(?:變更)?|套用|更新|完成)$/i;

class SettingsWrite {
  readonly action: SettingAction;
  readonly previous: SettingsPage | undefined;
  readonly deferred: boolean;
  readonly verify: SettingAction[];
  readonly started: number = Date.now();
  dispatched: boolean = false;
  verifying: boolean = false;
  confirmedAt: number = 0;

  constructor(action: SettingAction, previous: SettingsPage | undefined, deferred: boolean, verify: SettingAction[]) {
    this.action = action;
    this.previous = previous;
    this.deferred = deferred;
    this.verify = verify;
  }
}

@Component
export struct SettingsMenu {
  @StorageProp('qyxLocale') @Watch('localeChanged') private locale: string = 'zh-Hans';
  @Prop handle: string = '';
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;
  @Prop entryRoute: string = SETTINGS_ROOT;
  @Prop entryTitle: string = SETTINGS_TITLE;
  paths: NavPathStack = new NavPathStack();
  store: ReaderStore = new ReaderStore();
  canPersist: () => boolean = () => false;
  onClose: () => void = () => {};
  onLogout: () => void = () => {};
  @State private activeRoute: string = '';
  @State private pages: SettingsPage[] = [];
  @State private edits: SettingEdit[] = [];
  @State private waiting: boolean = true;
  @State private livePage: boolean = false;
  @State private cachedPage: boolean = false;
  @State private working: boolean = false;
  @State private failure: string = '';
  @State private controlRevision: number = 0;
  @State private warmPage: SettingsWarmPage | null = null;
  private titles: Map<string, string> = new Map();
  private parents: Map<string, string> = new Map();
  private controller: webview.WebviewController = new webview.WebviewController();
  private script: string = '';
  private attached: boolean = false;
  private ready: boolean = false;
  private liveRequested: boolean = false;
  private liveSiteRoute: string = '';
  private recoveredThroughParent: boolean = false;
  private routingParent: string = '';
  private routingSteps: string[] = [];
  private routingClickPending: boolean = false;
  private timer: number = -1;
  private deadline: number = 0;
  private revision: number = 0;
  private readingRevision: number = -1;
  private write: SettingsWrite | undefined;
  private lastSnapshot: string = '';
  private blockedDocument: string = '';
  private deferredActions: SettingAction[] = [];
  private queuedAction?: SettingAction;
  private warmQueue: string[] = [];
  private readonly warmedRoutes: Set<string> = new Set();
  private warmTimer: number = -1;
  private warmScheduled: boolean = false;
  private warmRequests: number = 0;

  async aboutToAppear(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      this.script = util.TextDecoder.create('utf-8').decodeToString(
        await context.resourceManager.getRawFileContent('read-settings.js'));
      this.read();
    } catch (_) {
      this.waiting = false;
      this.failure = ui('无法初始化 X 设置', this.locale);
    }
  }

  aboutToDisappear(): void {
    clearInterval(this.timer);
    this.stopWarmPage();
    this.revision++;
    this.edits = [];
    this.write = undefined;
    this.queuedAction = undefined;
    this.attached = false;
  }

  private localeChanged(): void {
    if (this.attached && this.activeRoute) {
      this.stopWarmPage();
      this.warmQueue = [];
      this.warmedRoutes.clear();
      this.warmRequests = 0;
      this.pages = [];
      this.activate(this.activeRoute, true);
    }
  }

  private activate(route: string, reload: boolean = false, loaded: boolean = false): void {
    if (!this.attached || !route || (!reload && route === this.activeRoute)) return;
    this.stopWarmPage();
    if (this.blockedDocument) {
      this.pages = this.pages.filter((page: SettingsPage) => page.route !== this.activeRoute);
    }
    this.revision++;
    this.activeRoute = route;
    this.edits = [];
    this.waiting = true;
    this.livePage = false;
    this.cachedPage = false;
    this.working = false;
    this.failure = '';
    this.deadline = Date.now() + READ_WAIT;
    this.write = undefined;
    this.lastSnapshot = '';
    this.blockedDocument = '';
    this.deferredActions = [];
    this.queuedAction = undefined;
    this.liveRequested = loaded;
    this.liveSiteRoute = '';
    this.recoveredThroughParent = false;
    this.routingParent = '';
    this.routingSteps = [];
    this.routingClickPending = false;
    this.ready = loaded;
    if (isLocalSettingsRoute(route)) {
      this.waiting = false;
      this.liveRequested = false;
      try { this.controller.stop(); } catch (_) {}
      return;
    }
    if (loaded) this.read();
    else this.openCachedPage(route, this.revision, reload);
  }

  private async openCachedPage(route: string, revision: number, reload: boolean): Promise<void> {
    const current = this.snapshot(route);
    const page = current || await this.store.readSettings(this.handle, this.locale, route).catch(() => undefined);
    if (revision !== this.revision || !this.attached) return;
    if (page && !current) {
      this.pages = [...this.pages, page];
    }
    if (!reload && page?.cachedAt && Date.now() - page.cachedAt < CACHE_FRESH_MS) {
      this.cachedPage = true;
      this.waiting = false;
      hilog.info(0x0000, 'QwitterSettings', 'settings opened from cache');
      this.queueSettingChildren(page, true);
      return;
    }
    this.loadSite();
  }

  private loadSite(): void {
    this.stopWarmPage();
    this.waiting = true;
    this.ready = false;
    this.liveRequested = true;
    this.routingParent = '';
    this.routingSteps = [];
    this.routingClickPending = false;
    this.deadline = Date.now() + READ_WAIT;
    try {
      this.controller.loadUrl(this.activeRoute, [{ headerKey: 'Accept-Language', headerValue: xLanguage(this.locale) }]);
    } catch (_) {
      this.failed(ui('暂时无法读取 X 设置', this.locale));
    }
  }

  private sameRoute(left: string, right: string): boolean {
    const a = settingsRoute(left);
    const b = settingsRoute(right);
    return !!a && (a === b || (!!settingsCachePath(a) && settingsCachePath(a) === settingsCachePath(b)));
  }

  private recoverThroughParent(): boolean {
    if (this.working || this.recoveredThroughParent || !this.activeRoute.startsWith(X_ORIGIN + '/settings/') ||
      this.activeRoute === SETTINGS_ROOT) return false;
    const steps: string[] = [this.activeRoute];
    let parent = this.parents.get(this.activeRoute);
    while (parent && !this.sameRoute(parent, SETTINGS_ROOT) && steps.length < 8 && !steps.includes(parent)) {
      steps.unshift(parent);
      parent = this.parents.get(parent);
    }
    this.recoveredThroughParent = true;
    this.routingParent = SETTINGS_ROOT;
    this.routingSteps = steps;
    this.routingClickPending = false;
    this.deadline = Date.now() + 8500;
    try {
      this.controller.loadUrl(SETTINGS_ROOT, [{ headerKey: 'Accept-Language', headerValue: xLanguage(this.locale) }]);
      return true;
    } catch (_) {
      this.routingParent = '';
      return false;
    }
  }

  private async followParentLink(address: string): Promise<void> {
    if (!this.sameRoute(address, this.routingParent) || this.routingClickPending) return;
    const revision = this.revision;
    const destination = this.routingSteps[0] || this.activeRoute;
    this.routingClickPending = true;
    try {
      const raw = await this.controller.runJavaScript(
        '(() => { const qyxSettingsDestination = ' + JSON.stringify(destination) + '; return ' + this.script + '; })()');
      if (revision === this.revision && raw !== 'true') this.routingClickPending = false;
    } catch (_) {
      if (revision === this.revision) this.routingClickPending = false;
    }
  }

  private cachePage(page: SettingsPage): void {
    if (!this.canPersist() || this.write || this.blockedDocument === page.documentId ||
      page.busy || page.error || page.dialog || page.signedOut) return;
    page.cachedAt = Date.now();
    this.queueSettingChildren(page, true);
    this.store.saveSettings(this.handle, this.locale, this.activeRoute, page)
      .catch(() => hilog.warn(0x0000, 'QwitterSettings', 'settings cache write failed'));
  }

  private queueSettingChildren(page: SettingsPage, prioritize: boolean = false): void {
    const links = page.rows.filter((row: SettingRow) => row.kind === 'link')
      .map((row: SettingRow) => settingsCachePath(row.path))
      .filter((route: string) => !!route && route !== settingsCachePath(this.activeRoute) && !this.warmedRoutes.has(route));
    const next = prioritize ? [...links, ...this.warmQueue] : [...this.warmQueue, ...links];
    this.warmQueue = Array.from(new Set(next)).slice(0, 100);
    this.scheduleWarmPage();
  }

  private stopWarmPage(): void {
    clearTimeout(this.warmTimer);
    this.warmPage = null;
    this.warmScheduled = false;
  }

  private scheduleWarmPage(): void {
    if (!this.attached || !this.script || !this.canPersist() || this.working || this.waiting ||
      this.warmPage || this.warmScheduled || this.warmRequests >= 24 || !this.warmQueue.length) return;
    this.warmScheduled = true;
    this.warmTimer = setTimeout(() => this.selectWarmPage(), WARM_GAP_MS);
  }

  private async selectWarmPage(): Promise<void> {
    const revision = this.revision;
    const handle = this.handle;
    const locale = this.locale;
    while (this.attached && revision === this.revision && !this.working && !this.waiting && this.warmQueue.length) {
      const route = this.warmQueue.shift();
      if (!route || route === settingsCachePath(this.activeRoute) || this.warmedRoutes.has(route)) continue;
      const cached = await this.store.readSettings(handle, locale, route).catch(() => undefined);
      if (revision !== this.revision || !this.attached || this.working || this.waiting) {
        this.warmQueue.unshift(route);
        return;
      }
      this.warmedRoutes.add(route);
      if (cached?.cachedAt && Date.now() - cached.cachedAt < CACHE_FRESH_MS) {
        this.queueSettingChildren(cached);
        continue;
      }
      this.warmScheduled = false;
      this.warmRequests++;
      this.warmPage = new SettingsWarmPage(route, handle, locale);
      return;
    }
    this.warmScheduled = false;
  }

  private async readWarmPage(task: SettingsWarmPage): Promise<void> {
    try {
      configureXWeb(task.controller, true);
      task.controller.loadUrl(task.route, [{ headerKey: 'Accept-Language', headerValue: xLanguage(task.locale) }]);
      for (let attempt = 0; attempt < 14 && this.warmPage === task; attempt++) {
        await new Promise<void>((resolve) => { setTimeout(resolve, 600); });
        if (this.warmPage !== task || !this.canPersist() || task.handle !== this.handle || task.locale !== this.locale) return;
        const address = task.controller.getUrl();
        if (isXLoginUrl(address)) return;
        if (settingsCachePath(address) !== task.route) continue;
        const raw = await task.controller.runJavaScript(this.script).catch(() => '');
        if (this.warmPage !== task) return;
        const page = readSettingsSnapshot(raw);
        if (!page || settingsCachePath(page.route) !== task.route || page.busy || page.error || page.dialog ||
          page.signedOut || !page.rows.length) continue;
        await this.store.saveSettings(task.handle, task.locale, task.route, page);
        if (this.warmPage !== task) return;
        this.queueSettingChildren(page);
        hilog.info(0x0000, 'QwitterSettings', 'settings subpage preloaded');
        return;
      }
    } catch (_) {
      // User-initiated navigation can still load the page directly.
    } finally {
      if (this.warmPage === task) {
        this.warmPage = null;
        this.scheduleWarmPage();
      }
    }
  }

  private failed(message: string): void {
    this.waiting = false;
    this.livePage = false;
    this.queuedAction = undefined;
    this.working = false;
    this.failure = message;
  }

  private documentReady(url: string): void {
    try {
      const actual = this.controller.getUrl().split('#')[0];
      if (actual !== url.split('#')[0] && !this.sameRoute(actual, url)) return;
      this.ready = true;
      this.read();
    } catch (_) {}
  }

  private async read(): Promise<void> {
    if (!this.attached || !this.activeRoute || isLocalSettingsRoute(this.activeRoute)) return;
    this.scheduleWarmPage();
    if (this.write && Date.now() - this.write.started >= WRITE_WAIT) {
      this.finishWrite(ui('X 未确认已保存，已保留网页当前显示的设置', this.locale));
    }
    if (this.waiting && Date.now() >= this.deadline) {
      if (this.recoverThroughParent()) return;
      this.failed(ui('X 暂未返回此页的设置', this.locale));
      this.liveRequested = false;
    }
    if (!this.script || !this.liveRequested || this.readingRevision === this.revision) return;
    try {
      const actual = this.controller.getUrl();
      if (this.routingParent && !this.sameRoute(actual, this.activeRoute) && !isXLoginUrl(actual)) {
        if (this.routingSteps.length && this.sameRoute(actual, this.routingSteps[0])) {
          this.routingSteps.shift();
          this.routingParent = actual;
          this.routingClickPending = false;
          this.deadline = Date.now() + 6500;
        }
        if (!this.routingClickPending) {
          this.followParentLink(actual);
          return;
        }
        this.ready = true;
      }
      if (this.sameRoute(actual, this.activeRoute)) {
        this.routingParent = '';
        this.routingSteps = [];
        this.ready = true;
      }
    } catch (_) {}
    if (!this.ready) return;
    const revision = this.revision;
    this.readingRevision = revision;
    try {
      const raw = await this.controller.runJavaScript(this.script);
      if (revision !== this.revision || !this.attached) return;
      const page = readSettingsSnapshot(raw);
      if (!page) return;
      if (page.signedOut) {
        this.pages = [];
        this.edits = [];
        this.finishWrite();
        this.failed(ui('X 会话需要验证，请返回 Qwitter 首页后重新登录', this.locale));
        return;
      }
      const route = settingsRoute(page.route);
      const wantedTitle = this.titles.get(this.activeRoute) || '';
      const inPlaceChild = this.routingClickPending && this.routingSteps.length <= 1 &&
        this.sameRoute(route, this.routingParent) && !!wantedTitle &&
        wantedTitle.replace(/\s+/g, '').toLowerCase() === page.title.replace(/\s+/g, '').toLowerCase();
      if (!this.sameRoute(route, this.activeRoute) && !inPlaceChild) {
        if (route && this.write?.dispatched) {
          this.finishWrite();
          this.open(page.title, route, true);
        }
        return;
      }
      this.liveSiteRoute = route;
      page.route = this.activeRoute;
      if (!page.rows.length && !page.dialog && !page.notice && !page.error) return;
      const changed = raw !== this.lastSnapshot;
      if (changed) {
        const previous = this.snapshot(this.activeRoute);
        if (previous && previous.dialog !== page.dialog) this.edits = [];
        this.lastSnapshot = raw;
        this.pages = [...this.pages.filter((item: SettingsPage) => item.route !== this.activeRoute), page];
      }
      this.waiting = page.busy;
      this.livePage = !page.busy && !page.error;
      if (this.livePage) this.cachedPage = false;
      this.failure = '';
      this.observeWrite(page);
      if (changed) this.cachePage(page);
      this.scheduleWarmPage();
      if (this.livePage && this.queuedAction) {
        const queued = this.queuedAction;
        this.queuedAction = undefined;
        this.working = false;
        const row = page.rows.find((item: SettingRow) => item.key === queued.key && item.label === queued.label);
        if (row && !row.disabled &&
          (row.kind !== 'select' || row.options.some((item) => item.value === queued.value && !item.disabled))) {
          this.act(row, queued.value, queued.checked, queued.submit);
        } else {
          this.getUIContext().getPromptAction().showToast({ message: ui('X 未接受此项操作，请刷新后重试', this.locale) });
        }
      }
    } catch (_) {
      // The next tick can read after the website has committed the new document.
    } finally {
      if (this.readingRevision === revision) this.readingRevision = -1;
    }
  }

  private snapshot(route: string): SettingsPage | undefined {
    return this.pages.find((page: SettingsPage) => page.route === route);
  }

  private rows(route: string): SettingRow[] {
    return this.snapshot(route)?.rows || [];
  }

  private open(title: string, path: string, loaded: boolean = false): void {
    const route = isLocalSettingsRoute(path) ? path : settingsRoute(path);
    if (!route || route === this.activeRoute || this.paths.size() >= 16) return;
    if (title) this.titles.set(route, title);
    const ancestors = this.paths.getAllPathName();
    if (!loaded && !ancestors.includes(route) && route !== this.entryRoute) this.parents.set(route, this.activeRoute);
    if (route === this.entryRoute) {
      this.paths.clear(true);
    } else if (ancestors.includes(route)) {
      this.paths.popToName(route, true);
    } else {
      this.paths.pushPath({ name: route }, true);
    }
    this.activate(route, false, loaded);
  }

  private back(): void {
    const dialog = this.snapshot(this.activeRoute);
    if (dialog?.dialog) {
      const cancel = dialog.rows.find((row: SettingRow) => row.kind === 'button' &&
        /^(?:取消|關閉|关闭|返回|cancel|close|dismiss|back)$/i.test(row.label));
      if (cancel && !this.working) {
        this.act(cancel, '', false, false);
        return;
      }
      this.activate(this.activeRoute, true);
      return;
    }
    if (this.paths.size()) {
      this.paths.pop(true);
      const names = this.paths.getAllPathName();
      this.activate(names[names.length - 1] || this.entryRoute);
    } else {
      this.onClose();
    }
  }

  private edit(row: SettingRow, value: string): void {
    if (this.working || (!this.livePage && !this.cachedPage)) return;
    this.edits = [...this.edits.filter((item: SettingEdit) => item.key !== row.key), new SettingEdit(row, value)];
  }

  private async act(row: SettingRow, value: string, checked: boolean, submit: boolean): Promise<void> {
    if (this.working || row.disabled ||
      (row.kind === 'toggle' && row.checked === checked)) return;
    if (!this.livePage && this.cachedPage) {
      this.queuedAction = new SettingAction(this.activeRoute, row, value, checked, submit, []);
      this.working = true;
      this.loadSite();
      return;
    }
    if (!this.livePage || !this.script || !this.ready) return;
    this.stopWarmPage();
    const revision = this.revision;
    const editsForm = submit || (row.kind === 'button' &&
      !/^(?:取消|關閉|关闭|返回|cancel|close|dismiss|back)$/i.test(row.label));
    const action = new SettingAction(this.liveSiteRoute || this.activeRoute, row, value, checked, submit, editsForm ? this.edits : []);
    const verify = row.kind === 'button' && SAVE_LABEL.test(row.label) ? this.deferredActions.slice() : [];
    const pending = new SettingsWrite(action, this.snapshot(this.activeRoute), row.deferred, verify);
    this.blockedDocument = pending.previous?.documentId || '';
    this.write = pending;
    this.working = true;
    try {
      const raw = await this.controller.runJavaScript(
        '(() => { const qyxSettingAction = ' + JSON.stringify(action) + '; return ' + this.script + '; })()');
      if (revision !== this.revision || this.write !== pending) return;
      const result = readSettingsSnapshot(raw);
      this.edits = this.edits.filter((item: SettingEdit) => item.kind !== 'password');
      if (!result?.applied) {
        this.finishWrite(result?.error || ui('X 未接受此项操作，请刷新后重试', this.locale));
        return;
      }
      pending.dispatched = true;
      this.read();
    } catch (_) {
      if (revision === this.revision && this.write === pending) this.finishWrite(ui('操作失败，请重试', this.locale));
    }
  }

  private observeWrite(page: SettingsPage): void {
    const pending = this.write;
    if (!pending?.dispatched || page.busy) return;
    if (page.error && page.error !== pending.previous?.error) {
      this.finishWrite(page.error);
      return;
    }
    const action = pending.action;
    const isValue = ['toggle', 'choice', 'select', 'range'].includes(action.kind);
    const saved = !!page.notice && page.notice !== pending.previous?.notice && SAVED_NOTICE.test(page.notice);
    if (page.dialog !== !!pending.previous?.dialog) {
      this.finishWrite();
      return;
    }
    if (pending.verify.length) {
      if (saved || (pending.verifying && page.documentId !== pending.previous?.documentId &&
        pending.verify.every((item: SettingAction) => this.matchesSetting(page, item)))) {
        this.confirmWrite();
      } else if (pending.verifying && page.documentId !== pending.previous?.documentId) {
        this.deferredActions = [];
        this.finishWrite(ui('X 未确认已保存，已保留网页当前显示的设置', this.locale));
      } else if (!pending.verifying && Date.now() - pending.started >= VERIFY_SETTLE) {
        this.verifyWrite(pending);
      }
      return;
    }
    if (!isValue) {
      if (saved) {
        this.confirmWrite();
      } else if (page.notice && page.notice !== pending.previous?.notice) {
        this.edits = [];
        this.finishWrite(page.notice);
      } else if (page.rows.map((row: SettingRow) => row.key).join('|') !==
        pending.previous?.rows.map((row: SettingRow) => row.key).join('|')) {
        this.finishWrite();
      }
      return;
    }
    if (pending.verifying && page.documentId === pending.previous?.documentId) return;
    if (!this.matchesSetting(page, action)) {
      pending.confirmedAt = 0;
      return;
    }
    if (pending.verifying || saved) {
      this.confirmWrite();
    } else if (pending.deferred || page.dialog) {
      if (pending.deferred && !page.dialog) {
        this.deferredActions = [...this.deferredActions.filter((item: SettingAction) => item.key !== action.key), action];
      }
      this.finishWrite(ui('已更改，保存后同步到 X', this.locale));
    } else if (!pending.confirmedAt) {
      pending.confirmedAt = Date.now();
    } else if (Date.now() - pending.confirmedAt >= VERIFY_SETTLE) {
      this.verifyWrite(pending);
    }
  }

  private matchesSetting(page: SettingsPage, action: SettingAction): boolean {
    const item = page.rows.find((row: SettingRow) => row.key === action.key);
    if (!item) return false;
    if (action.kind === 'toggle' || action.kind === 'choice') return item.checked === action.checked;
    if (action.kind === 'range') return Number(item.value) === Number(action.value);
    return item.value === action.value;
  }

  private verifyWrite(pending: SettingsWrite): void {
    try {
      pending.verifying = true;
      this.ready = false;
      this.controller.refresh();
    } catch (_) {
      this.ready = true;
      this.finishWrite(ui('已提交给 X，暂时无法确认是否保存', this.locale));
    }
  }

  private confirmWrite(): void {
    webview.WebCookieManager.saveCookieAsync().catch(() => {});
    this.edits = [];
    this.deferredActions = [];
    this.blockedDocument = '';
    this.finishWrite(ui('已同步到 X', this.locale));
  }

  private finishWrite(message: string = ''): void {
    if (!this.write) return;
    this.write = undefined;
    this.working = false;
    this.controlRevision++;
    if (message) this.getUIContext().getPromptAction().showToast({ message });
  }

  @Builder
  page(route: string) {
    SettingsPageView({
      title: this.snapshot(route)?.dialog ? (this.snapshot(route)?.title || ui('确认操作', this.locale)) :
        (route === this.entryRoute ? this.entryTitle : this.titles.get(route) || this.snapshot(route)?.title || ui('设置', this.locale)),
      root: route === SETTINGS_ROOT,
      localRoute: isLocalSettingsRoute(route) ? route : '',
      handle: this.handle,
      rows: this.rows(route),
      edits: route === this.activeRoute ? this.edits : [],
      loading: route === this.activeRoute && this.waiting && !this.rows(route).length,
      failure: route === this.activeRoute ? this.failure : '',
      disabled: route !== this.activeRoute || (!this.livePage && !this.cachedPage) || this.working,
      syncing: route === this.activeRoute && this.working,
      controlRevision: this.controlRevision,
      topInset: this.topInset,
      bottomInset: this.bottomInset,
      onBack: () => this.back(),
      onRetry: () => this.activate(route, true),
      onOpen: (title: string, path: string) => this.open(title, path),
      onEdit: (row: SettingRow, value: string) => this.edit(row, value),
      onAction: (row: SettingRow, value: string, checked: boolean, submit: boolean) => this.act(row, value, checked, submit),
      onLogout: () => this.onLogout()
    })
  }

  @Builder
  destination(route: string) {
    NavDestination() {
      this.page(route)
    }.hideTitleBar(true).backgroundColor(PAPER)
      .systemTransition(NavigationSystemTransitionType.DEFAULT)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .onWillShow(() => this.activate(route))
      .onBackPressed(() => { this.back(); return true; })
  }

  build() {
    Stack() {
      if (this.warmPage) {
        ForEach([this.warmPage], (task: SettingsWarmPage) => {
          Web({ src: '', controller: task.controller }).width('100%').height('100%')
            .opacity(0).hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
            .javaScriptAccess(true).domStorageAccess(true).fileAccess(false).mixedMode(MixedMode.None)
            .runJavaScriptOnDocumentStart([{ script: X_CONNECTIVITY, scriptRules: [X_ORIGIN] }])
            .onControllerAttached(() => this.readWarmPage(task))
            .onLoadIntercept((event) => event.data.isMainFrame() && event.data.getRequestUrl() !== 'about:blank' &&
              settingsCachePath(event.data.getRequestUrl()) !== task.route && !isXLoginUrl(event.data.getRequestUrl()))
        }, (task: SettingsWarmPage) => task.route)
      }
      Web({ src: '', controller: this.controller }).width('100%').height('100%')
        .opacity(0).hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
        .javaScriptAccess(true).domStorageAccess(true).fileAccess(false).mixedMode(MixedMode.None)
        .runJavaScriptOnDocumentStart([{ script: X_CONNECTIVITY, scriptRules: [X_ORIGIN] }])
        .onControllerAttached(() => {
          configureXWeb(this.controller);
          this.attached = true;
          this.activate(this.entryRoute);
          this.timer = setInterval(() => this.read(), 650);
        })
        .onLoadIntercept((event) => {
          const url = event.data.getRequestUrl();
          return event.data.isMainFrame() && url !== 'about:blank' && !settingsRoute(url) && !isXLoginUrl(url);
        })
        .onNavigationEntryCommitted((event) => {
          if (event.isMainFrame) this.documentReady(event.url);
        })
        .onPageVisible((event) => this.documentReady(event.url))
        .onLoadFinished((event) => this.documentReady(event.url))
        .onPageEnd((event) => this.documentReady(event.url))
        .onErrorReceive((event) => {
          if (event.request.isMainFrame() && event.error.getErrorCode() !== -3 &&
            this.sameRoute(event.request.getRequestUrl(), this.activeRoute)) {
            if (this.recoverThroughParent()) return;
            this.finishWrite(ui('无法确认更改，暂时无法连接 X', this.locale));
            this.failed(ui('暂时无法连接 X', this.locale));
          }
        })
        .onHttpErrorReceive((event) => {
          if (event.request.isMainFrame() &&
            this.sameRoute(event.request.getRequestUrl(), this.activeRoute)) {
            if (this.recoverThroughParent()) return;
            this.finishWrite(ui('X 暂时无法确认此更改', this.locale));
            this.failed(ui('X 暂时无法打开此设置', this.locale));
          }
        })
      Navigation(this.paths) {
        this.page(this.entryRoute)
      }.mode(NavigationMode.Stack).hideTitleBar(true).navDestination(this.destination)
        .onNavBarStateChange((visible: boolean) => { if (visible && !this.paths.size()) this.activate(this.entryRoute); })
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
        .width('100%').height('100%')
    }.width('100%').height('100%').backgroundColor(PAPER)
  }
}
