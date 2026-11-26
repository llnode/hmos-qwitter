import { fileIo } from '@kit.CoreFileKit';
import { submitWebReply } from '../web/ReplySubmission';
import { DiscoveryRow, DiscoverySection } from '../web/Discovery';
import { accentForeground, DEFAULT_ACCENT } from '../data/AppearancePreferences';
import { ComposeFloatingButton } from '../components/ComposeFloatingButton';
import { LAUNCHER_ICON_STORAGE_KEY, launcherIconImage } from '../data/LauncherIconChoices';
import { common } from '@kit.AbilityKit';
import { display, FrameCallback, KeyboardAvoidMode, LengthMetrics, uiMaterial, window } from '@kit.ArkUI';
import { deviceInfo, pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { url as arkUrl, util } from '@kit.ArkTS';
import { webview } from '@kit.ArkWeb';
import { systemShare } from '@kit.ShareKit';
import { Avatar, hasPostTranslation, INK, MUTED, PAPER, RULE, SOFT, PostCard } from '../components/PostCard';
import { AccountMenu } from '../components/AccountMenu';
import { ProfileHeader } from '../components/ProfileHeader';
import { PostVideoPlayer } from '../components/PostVideoPlayer';
import { InlineReplies, ReplyGroup, ReplyThread } from '../components/ReplyThread';
import { SettingsMenu } from '../components/SettingsMenu';
import { InboxList } from '../components/InboxList';
import { XWebPage } from '../components/XWebPage';
import { ZoomablePhoto } from '../components/ZoomablePhoto';
import { NewPostsButton } from '../components/NewPostsButton';
import { GlassButton } from '../components/GlassButton';
import { createMediaSaveTarget, MediaSaveTarget, saveVideo, savePhoto } from '../web/MediaDownload';
import { DownloadBackgroundTask } from '../web/DownloadBackgroundTask';
import { isAudioVideoSource, videoSourceOrder } from '../web/VideoQuality';
import { PostAttachment, PostMediaBridge, PostUpload, selectPostAttachments } from '../web/PostComposerMedia';
import { settingsRoute, SETTINGS_ROOT, SETTINGS_TITLE } from '../web/SettingsPage';
import { HomePosition, SessionReset } from '../web/SessionReset';
import { HOME_POST_LIMIT, KnownAccount, ReaderStore } from '../data/ReaderStore';
import { PageScripts } from '../web/PageScripts';
import { MediaLookahead } from '../data/MediaLookahead';
import { DEFAULT_TAB_HEIGHT, DEFAULT_TAB_MATERIAL, TAB_MATERIAL_STYLES } from '../data/AppearancePreferences';
import { chatConversationUrl, decodeInbox, InboxPage, InboxRow } from '../web/InboxPage';
import { ui, xLanguage } from '../i18n/LanguageSettings';
import { VIDEO_TRANSPORT_SCRIPT, VideoWebSource } from '../web/VideoWebSource';
import { VideoStartupCache } from '../web/VideoStartupCache';
import {
  ADVANCE_PAGE, ADVANCE_REPLIES, ADVANCE_VIDEO_FEED, BLANK, configureXWeb, decodeSnapshot, imageAtSize, isPostWebLink, isXChatUrl, isXLoginUrl, isXUrl, matchesVideoAsset, normalizeVideoSources, Post, Profile, quoteStatusPath,
  PostLikeState, QuotedPost, Snapshot, Surface, validHandle, videoPosterKey,
  X_CONNECTIVITY, X_LOGIN, X_ORIGIN, XRoute, PageTab, searchModeFilter
} from '../web/XPage';

enum Session {
  Starting,
  SignedOut,
  SigningIn,
  Active,
  Clearing,
  ResetFailed
}

enum Content {
  Loading,
  Ready,
  Empty,
  Failed
}

const WAIT_MS: number = 22000;
const START_WAIT_MS: number = 12000;
const REPLY_WAIT_MS: number = 5500;
const PROFILE_WAIT_MS: number = 10500;
const SIGN_OUT_CONFIRM_MS: number = 3000;
const COOKIE_SAVE_INTERVAL_MS: number = 60000;
const PAGE_LIMIT: number = HOME_POST_LIMIT;
const INITIAL_HIGH_QUALITY_POSTS: number = 10;
const MEDIA_LOOKAHEAD: number = 5;
const HOME_HEADER_HEIGHT: number = 92;
const HOME_PULL_REFRESH_DISTANCE: number = 64;
const THREAD_CACHE_LIMIT: number = 24;
const HOME_CHECK_MS: number = 120000;
const HOME_STAGE_MAX_AGE: number = 120000;
const POST_PREVIEW_INTERVAL: number = 8000;
// Gap between translation jobs. The translation view stays loaded, so jobs no longer need the preview interval.
const TRANSLATION_GAP_MS: number = 600;
// The X editor page is loaded only after Send is tapped, so allow for a cold page load before giving up.
const COMPOSER_PREPARE_MS: number = 30000;
const COMPOSER_VERIFY_MS: number = 15000;
// X can re-draw its editor or enable Post a moment after the text lands. Keep retrying the submit step this long.
const COMPOSER_SUBMIT_MS: number = 8000;
const ACCOUNT_SWITCH_TIMEOUT_MS: number = 15000;
// On X's /account/switch page, taps the row that shows @handle. Returns true once it has tapped.
function accountSwitchScript(handle: string): string {
  return '(() => { if (location.origin !== "https://x.com" || !/^\\/account\\/switch/.test(location.pathname)) return false;' +
    'const target = ' + JSON.stringify('@' + handle.toLowerCase()) + ';' +
    'const scope = document.querySelector("main, [role=\\"main\\"]") || document.body;' +
    'for (const node of scope.querySelectorAll("span, div")) {' +
    'if (node.childElementCount || (node.textContent || "").trim().toLowerCase() !== target) continue;' +
    'const row = node.closest("[role=\\"button\\"], button, a[href], [data-testid=\\"UserCell\\"], [role=\\"listitem\\"], li");' +
    'if (row) { row.click(); return true; } } return false; })()';
}
// Moves a loaded x.com page to another post in place, the way X's own links do, instead of reloading the app.
function softNavigateScript(path: string): string {
  return '(() => { if (location.origin !== "https://x.com") return false; const path = ' + JSON.stringify(path) + ';' +
    'if (location.pathname !== path) history.pushState(null, "", path);' +
    'window.dispatchEvent(new PopStateEvent("popstate", { state: history.state })); return true; })()';
}
const PROFILE_LIBRARY_FRESH_MS: number = 15 * 60 * 1000;
const READER_PAUSE_WEB_VIDEO: string = `(() => {
  if (location.origin !== 'https://x.com' || location.pathname === '/login' ||
    location.pathname.startsWith('/i/flow/') || location.pathname.startsWith('/i/jf/')) return;
  document.addEventListener('play', (event) => {
    if (event.target instanceof HTMLVideoElement) event.target.pause();
  }, true);
})()`;
const VIDEO_FEED_PAUSE_WHILE_IDLE: string = `document.addEventListener('play', (event) => {
  if (window.__qyxVideoFeedIdle && event.target instanceof HTMLVideoElement) event.target.pause();
}, true)`;
const LOGIN_PASSWORD_TRACE: string = `(() => {
  if (window !== window.top || location.origin !== 'https://x.com') return;
  let until = 0;
  let pendingUntil = 0;
  let clickForm = null;
  let lastAction = '';
  let lastActionAt = 0;
  const cooldownKey = 'qwitter.login.cooldown';
  let cooldownUntil = 0;
  try { cooldownUntil = Number(sessionStorage.getItem(cooldownKey)) || 0; } catch (_) {}
  const report = (event) => console.info('qwitter-login-trace:' + event);
  const active = () => Date.now() < until;
  // ArkWeb has no working passkey support: X's passkey request fails with a TypeError and its
  // "Use password" step then never shows the password field. Report passkeys as unavailable, as a
  // browser without them would, so X goes straight to its plain password step.
  try {
    if (window.PublicKeyCredential) {
      delete window.PublicKeyCredential;
      if (window.PublicKeyCredential) {
        Object.defineProperty(window, 'PublicKeyCredential', { value: undefined, configurable: true, writable: true });
      }
      report('passkeys-hidden');
    }
  } catch (_) {}
  const onLoginPage = () => /^\\/(?:i\\/flow\\/login|i\\/jf\\/onboarding|login)(?:\\/|$)/.test(location.pathname);
  const cancel = (event) => {
    event.preventDefault();
    event.stopImmediatePropagation();
  };
  const begin = (event, action) => {
    const now = Date.now();
    if (now < cooldownUntil || now < pendingUntil || (action === lastAction && now - lastActionAt < 900)) {
      cancel(event);
      if (now < cooldownUntil) report('cooldown');
      return false;
    }
    lastAction = action;
    lastActionAt = now;
    pendingUntil = now + 10000;
    until = now + 15000;
    return true;
  };
  document.addEventListener('click', (event) => {
    if (!onLoginPage()) return;
    const button = event.target instanceof Element && event.target.closest('button,[role="button"],a');
    if (!button) return;
    const label = (button.innerText || button.textContent || '').trim();
    const next = /^(?:继续|繼續|下一步|Continue|Next)$/i.test(label);
    const password = /^(?:使用密[码碼]|Use (?:a |your )?password)$/i.test(label);
    if ((!next && !password) || button.matches(':disabled,[aria-disabled="true"]') ||
      !begin(event, next ? 'next' : 'password')) return;
    // A submit event can follow this very click. Let that event pass once.
    clickForm = button instanceof HTMLButtonElement && button.type === 'submit' ? button.form : null;
    setTimeout(() => { clickForm = null; }, 0);
    if (next) {
      report('continue-button');
      return;
    }
    report(button instanceof HTMLButtonElement && button.form && button.type === 'submit' ?
      'form-submit-button' : 'password-button');
    setTimeout(() => {
      report(document.querySelector('input[type="password"]') ? 'password-field' : 'no-password-field');
      // Field types and frame count only, never values, so a stuck step shows what X put on screen instead.
      const shown = Array.from(document.querySelectorAll('input')).filter((input) => input.getClientRects().length)
        .map((input) => (input.type || 'text').toLowerCase().replace(/[^a-z]/g, '')).slice(0, 6).join(',');
      report('after-password:' + shown + ':frames=' + Math.min(document.querySelectorAll('iframe').length, 9));
    }, 2500);
  }, true);
  document.addEventListener('invalid', (event) => {
    if (active() && event.target instanceof HTMLInputElement) {
      pendingUntil = 0;
      report(event.target.type === 'tel' ? 'phone-invalid' : 'field-invalid');
    }
  }, true);
  document.addEventListener('submit', (event) => {
    if (!onLoginPage()) return;
    if (event.target === clickForm) clickForm = null;
    else if (!begin(event, 'submit')) return;
    report('form-submitted');
  }, true);
  if (typeof PerformanceObserver === 'function') {
    try {
      const observer = new PerformanceObserver((list) => {
        if (!active()) return;
        for (const entry of list.getEntries()) {
          if (entry.initiatorType !== 'fetch' && entry.initiatorType !== 'xmlhttprequest') continue;
          const url = new URL(entry.name);
          if ((url.origin !== 'https://x.com' && url.origin !== 'https://api.x.com') ||
            !url.pathname.includes('/onboarding/')) continue;
          const status = entry.responseStatus || 0;
          if (status < 200) continue;
          pendingUntil = 0;
          if (status === 429) {
            // More attempts after HTTP 429 only extend X's block, so hold further submits for 5 minutes.
            cooldownUntil = Date.now() + 300000;
            try { sessionStorage.setItem(cooldownKey, String(cooldownUntil)); } catch (_) {}
          }
          report('onboarding-response-' + status);
        }
      });
      observer.observe({ entryTypes: ['resource'] });
    } catch (_) {}
  }
  window.addEventListener('error', () => { if (active()) report('script-error'); });
  window.addEventListener('unhandledrejection', () => { if (active()) report('script-rejection'); });
  // Name the next step X asks for (its subtask ids only; nothing typed is read) and any passkey request.
  const isOnboarding = (value) => {
    try {
      const url = new URL(String(value), location.href);
      return (url.origin === 'https://x.com' || url.origin === 'https://api.x.com') && url.pathname.includes('/onboarding/');
    } catch (_) { return false; }
  };
  const reportSubtasks = (body) => {
    try {
      const data = typeof body === 'string' ? JSON.parse(body) : body;
      const ids = (data && Array.isArray(data.subtasks) ? data.subtasks : [])
        .map((task) => task && task.subtask_id).filter((id) => /^[A-Za-z]{1,60}$/.test(id || '')).slice(0, 4);
      if (ids.length) report('subtask-' + ids.join('-'));
    } catch (_) {}
  };
  const nativeFetch = window.fetch;
  if (typeof nativeFetch === 'function') {
    window.fetch = function (input, options) {
      const pending = nativeFetch.apply(this, arguments);
      if (isOnboarding(typeof input === 'string' ? input : input && input.url)) {
        pending.then((response) => response.clone().text()).then(reportSubtasks).catch(() => {});
      }
      return pending;
    };
  }
  const nativeOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    if (isOnboarding(url)) {
      this.addEventListener('load', () => {
        try { reportSubtasks(this.responseType === 'json' ? this.response : this.responseText); } catch (_) {}
      });
    }
    return nativeOpen.apply(this, arguments);
  };
  if (navigator.credentials && typeof navigator.credentials.get === 'function') {
    const nativeGet = navigator.credentials.get.bind(navigator.credentials);
    navigator.credentials.get = (options) => {
      const login = onLoginPage();
      if (options && options.publicKey) {
        // Answer as a declined passkey prompt, which X handles by staying on the password path.
        if (login) report('webauthn-blocked');
        return Promise.reject(new DOMException('Passkeys are not available here.', 'NotAllowedError'));
      }
      if (login) report('webauthn-' + (options && options.mediation === 'conditional' ? 'conditional' : 'request'));
      return nativeGet(options).then((result) => {
        if (login) report('webauthn-done');
        return result;
      }, (error) => {
        if (login) report('webauthn-error-' + (/^[A-Za-z]{1,40}$/.test(error && error.name || '') ? error.name : 'unknown'));
        throw error;
      });
    };
  }
  // A value filled in without a keystroke (restored field, IME commit, autofill) does not reach X's form state,
  // so X keeps Continue disabled. Tell X about the value the field already shows. Nothing is read or sent here.
  let synced = false;
  const syncFields = () => {
    if (!onLoginPage()) return;
    for (const input of document.querySelectorAll('input:not([type="hidden"]):not([type="checkbox"])')) {
      const tracker = input._valueTracker;
      if (!input.value || !tracker || tracker.getValue() === input.value) continue;
      tracker.setValue('');
      input.dispatchEvent(new Event('input', { bubbles: true }));
      if (!synced) {
        synced = true;
        report('field-synced');
      }
    }
  };
  document.addEventListener('focusout', syncFields, true);
  document.addEventListener('compositionend', () => setTimeout(syncFields, 0), true);
  setInterval(syncFields, 800);
})();`;
const CHAT_HIDE_SITE_TABS: string = `(() => {
  if (location.origin !== 'https://chat.x.com' && !/^[/](?:i[/]chat|messages)(?:[/]|$)/.test(location.pathname)) return;
  const style = document.createElement('style');
  style.textContent = '[data-testid="BottomBar"], nav:has(a[href^="/home"]):has(a[href^="/notifications"]), ' +
    '[role="navigation"]:has(a[href^="/home"]):has(a[href^="/notifications"]) { display: none !important; }';
  document.documentElement.appendChild(style);
})()`;
// Runs in the dedicated chat page. X Chat is a single-page app whose message list can live inside open shadow roots,
// so observe the document and the open shadow roots found so far, and log a throttled signal when anything changes. Qyx then reads
// the inbox right away instead of waiting for the next poll. The page can only nudge Qyx; it cannot pass data this way.
const CHAT_CHANGE_SIGNAL: string = `(() => {
  if (window !== window.top || window.__qyxChatSignal) return;
  if (location.origin !== 'https://chat.x.com' && location.origin !== 'https://x.com') return;
  window.__qyxChatSignal = true;
  let timer = 0;
  let last = 0;
  const signal = () => {
    if (timer) return;
    timer = setTimeout(() => {
      timer = 0;
      last = Date.now();
      console.info('qyx-chat-change');
    }, Math.max(0, 120 - (Date.now() - last)));
  };
  const seen = new WeakSet();
  const observe = (root) => {
    if (!root || seen.has(root)) return;
    seen.add(root);
    try { new MutationObserver(signal).observe(root, { childList: true, subtree: true, characterData: true }); } catch (_) {}
  };
  // Open shadow roots are not covered by the document observer. Qyx calls this after reads to pick up new ones.
  window.__qyxChatObserve = () => {
    const roots = [document];
    for (let index = 0; index < roots.length && index < 32; index++) {
      for (const node of roots[index].querySelectorAll('*')) {
        if (!node.shadowRoot) continue;
        observe(node.shadowRoot);
        if (roots.length < 32) roots.push(node.shadowRoot);
      }
    }
  };
  if (document.documentElement) observe(document.documentElement);
  else document.addEventListener('DOMContentLoaded', () => observe(document.documentElement), { once: true });
})();`;
const CHAT_SIGNAL_GAP_MS: number = 500;
// X's History hub, and Qwitter's local list of posts this account opened. The local list never goes to X.
const HISTORY_PATH: string = '/i/history';
const LOCAL_BROWSING_PATH: string = '/qwitter/browsing-history';
const HOME_DOUBLE_TAP_MS: number = 360;
const INLINE_REPLY_BATCH: number = 10;
// Read the first replies quickly and scroll X's page until this many direct replies are rendered.
const DETAIL_REPLY_TARGET: number = 10;
const DETAIL_FILL_ROUNDS: number = 8;
const DETAIL_FILL_GAP_MS: number = 650;

function replyCountValue(value: string): number {
  const match = /^([\d.,]+)\s*([KkMm万萬千]?)/.exec((value || '').trim());
  if (!match) return -1;
  const base = Number(match[1].replace(/,/g, ''));
  if (!Number.isFinite(base)) return -1;
  const unit = match[2].toLowerCase();
  return Math.round(base * (unit === 'k' || unit === '千' ? 1000 : unit === 'm' ? 1000000 : unit === '万' || unit === '萬' ? 10000 : 1));
}

let probeSequence: number = 0;

class FeedPostsSource implements IDataSource {
  private posts: Post[] = [];
  private listeners: Set<DataChangeListener> = new Set();

  totalCount(): number { return this.posts.length; }

  getData(index: number): Post { return this.posts[index]; }

  registerDataChangeListener(listener: DataChangeListener): void { this.listeners.add(listener); }

  unregisterDataChangeListener(listener: DataChangeListener): void { this.listeners.delete(listener); }

  replace(posts: Post[]): void {
    this.posts = posts;
    this.listeners.forEach((listener: DataChangeListener) => listener.onDataReloaded());
  }
}

class ReaderProbe {
  readonly key: string = (++probeSequence).toString();
  readonly controller: webview.WebviewController = new webview.WebviewController();
  readonly route: XRoute;
  readonly post: Post | null;
  readonly existing: Post[];
  readonly preview: boolean;
  readonly warmHome: boolean;
  readonly resolveQuote: boolean;
  readonly replyLimit: number;
  readonly notificationPreview: boolean;

  constructor(route: XRoute, post: Post | null = null, existing: Post[] = [], preview: boolean = false,
    warmHome: boolean = false, resolveQuote: boolean = false, replyLimit: number = 0, notificationPreview: boolean = false) {
    this.route = route;
    this.post = post;
    this.existing = existing;
    this.preview = preview;
    this.warmHome = warmHome;
    this.resolveQuote = resolveQuote;
    this.replyLimit = replyLimit;
    this.notificationPreview = notificationPreview;
  }
}

interface ComposerRequest {
  key: number;
  step: string;
  text: string;
  target: string;
  mode: string;
  choices: string[];
  duration: number;
  uploads: PostUpload[];
  thread: string[];
  gif: string;
}

interface PostGif {
  url: string;
  label: string;
}

interface GifResponse {
  ready: boolean;
  selected: boolean;
  items: PostGif[];
}

interface GifRequest {
  step: string;
  query: string;
  url: string;
}

class PostActionOperation {
  readonly post: Post;
  readonly desired: boolean;
  readonly kind: string;
  readonly key: string;
  readonly token: number = ++probeSequence;
  readonly previous?: PostLikeState;
  readonly controller: webview.WebviewController = new webview.WebviewController();
  sent: boolean = false;

  constructor(post: Post, kind: string, desired: boolean, previous?: PostLikeState) {
    this.post = post;
    this.kind = kind;
    this.key = kind + ':' + post.id;
    this.desired = desired;
    this.previous = previous;
  }
}

class PostMenuOperation {
  readonly post: Post;
  readonly kind: string;
  readonly token: number = ++probeSequence;
  readonly controller: webview.WebviewController = new webview.WebviewController();

  constructor(post: Post, kind: string) {
    this.post = post;
    this.kind = kind;
  }
}

const POST_MENU_DONE: string[] = ['done', 'already'];
const POST_MENU_FINAL: string[] = ['done', 'already', 'not-applied', 'no-item', 'no-delete', 'no-menu', 'invalid'];
const POST_MENU_TIMEOUT_MS: number = 25000;
const DESTRUCTIVE: string = '#F4212E';

interface PostActionResult {
  status: string;
  liked?: boolean;
  count?: string;
}

interface ThreadSnapshot {
  post: Post;
  replies: Post[];
  content: Content;
  offset: number;
}

class RestoreThreadScroll extends FrameCallback {
  private readonly restore: () => void;

  constructor(restore: () => void) {
    super();
    this.restore = restore;
  }

  onIdle(_timeLeftInNano: number): void {
    this.restore();
  }
}

@Entry
@Component
struct Index {
  @StorageProp('qyxAccent') private accent: string = DEFAULT_ACCENT;
  @StorageProp('qyxAccentInk') private accentInk: string = DEFAULT_ACCENT;
  @StorageProp('qyxStatusInset') private statusInset: number = 36;
  @StorageProp('qyxLocale') private locale: string = 'zh-Hans';
  @StorageProp('qyxImageQuality') private imageQuality: string = 'orig';
  @StorageProp('qyxVideoQuality') private videoQuality: string = '';
  @StorageProp('qyxTabMaterial') private tabMaterial: number = DEFAULT_TAB_MATERIAL;
  @StorageProp('qyxTabHeight') private tabHeight: number = DEFAULT_TAB_HEIGHT;
  @StorageProp('qyxTabLabels') private tabLabels: boolean = false;
  @StorageProp(LAUNCHER_ICON_STORAGE_KEY) private launcherIconId: string = 'pending';
  @State private showStartupIcon: boolean = true;
  private startupIconTimer: number = -1;
  @StorageProp('qyxTranslationLanguage') @Watch('translationLanguageChanged') private translationLanguage: string = '';
  @State private translationProbe: ReaderProbe | null = null;
  // One hidden x.com view reused for every translation job (translationProbe is the job in progress).
  @State private translationHost: ReaderProbe | null = null;
  private translationHostAttached: boolean = false;
  private translationHostLanguage: string = '';
  @State private translatedPosts: Map<string, Post> = new Map();
  private translationQueue: Post[] = [];
  private attemptedTranslations: Set<string> = new Set();
  private readonly translationReads: Set<string> = new Set();
  private translationRevision: number = 0;
  @StorageProp('qyxKeyboardInset') private keyboardInset: number = 0;
  @StorageProp('qyxBottomInset') private bottomInset: number = 22;
  @StorageProp('qyxForeground') @Watch('foregroundChanged') private foreground: boolean = true;
  @State private session: Session = Session.Starting;
  @State private content: Content = Content.Loading;
  @State private surface: Surface = Surface.Home;
  @State private homeTab: number = 0;
  @State @Watch('syncRecommendedPosts') private recommendedPosts: Post[] = [];
  @State @Watch('syncFollowingPosts') private followingPosts: Post[] = [];
  private readonly recommendedSource: FeedPostsSource = new FeedPostsSource();
  private readonly followingSource: FeedPostsSource = new FeedPostsSource();
  private readonly routeFeedSource: FeedPostsSource = new FeedPostsSource();
  private retainedSearch: Snapshot | undefined;
  private homeSnapshotRevision: number[] = [0, 0];
  @State private recommendedHighQuality: number = INITIAL_HIGH_QUALITY_POSTS;
  @State private followingHighQuality: number = INITIAL_HIGH_QUALITY_POSTS;
  @State private routeHighQuality: number = INITIAL_HIGH_QUALITY_POSTS;
  @State private homeHeaderHidden: boolean = false;
  private homeScrollDelta: number = 0;
  @State private recommendedHasNew: boolean = false;
  @State private followingHasNew: boolean = false;
  private homeLoaded: boolean[] = [false, false];
  private homeFirstVisible: number[] = [-1, -1];
  private pendingHomePosition: (HomePosition | undefined)[] = [undefined, undefined];
  private homeHeaderPositions: boolean[] = [false, false];
  private homeScrollers: Scroller[] = [new Scroller(), new Scroller()];
  private readonly routeScroller: Scroller = new Scroller();
  private readonly feedFlinging: boolean[] = [false, false, false];
  private homeAnchors: (HomePosition | undefined)[] = [undefined, undefined];
  private homeRefreshRequested: boolean = false;
  private homeScrolled: boolean = false;
  private lastHomeTap: number = 0;
  private lastHomeCheck: number[] = [0, 0];
  @State private handle: string = '';
  @State private accountName: string = '';
  @State private avatar: string = '';
  @State @Watch('syncRouteFeed') private posts: Post[] = [];
  @State private inlineReplies: InlineReplies[] = [];
  @State private readerProbe: ReaderProbe | null = null;
  @State private libraryProbe: ReaderProbe | null = null;
  private librarySelecting: boolean = false;
  private readonly libraryAttempts: Map<string, number> = new Map();
  @State private detailPost: Post | null = null;
  @State private detailCachedOnly: boolean = false;
  @State private profile: Profile | null = null;
  private readonly profileCache: Map<string, Profile> = new Map();
  private profileRetryTimer: number = -1;
  private profileRetried: boolean = false;
  @State private profileTab: string = '';
  @State private wideTablet: boolean = false;
  @State private discoverySections: DiscoverySection[] = [];
  @State private discoveryProbe: ReaderProbe | null = null;
  @State private discoveryQuery: string = '';
  private discoveryKey: string = '';
  private discoveryRefreshAt: number = 0;
  @State private query: string = '';
  @State private submittedQuery: string = '';
  private searchDocumentTime: number = 0;
  private previousSearchDocumentTime: number = 0;
  @State private searchMode: string = 'top';
  @State private searchPeople: DiscoveryRow[] = [];
  @State private profileMediaFilter: number = 0;
  private searchScroller: Scroller = new Scroller();
  @State private settingsOpen: boolean = false;
  @State private settingsEntry: string = SETTINGS_ROOT;
  @State private settingsEntryTitle: string = SETTINGS_TITLE;
  @State private navIndex: number = 0;
  @State private drawerOpen: boolean = false;
  @State private drawerDrag: number = 0;
  @State private drawerWidth: number = 283;
  @State private ownProfile: Profile | null = null;
  @State private webUrl: string = '';
  @State private webTitle: string = '';
  @State private refreshing: boolean = false;
  @State private homePullOffset: number = 0;
  @State private fullPhotos: string[] = [];
  @State private photoIndex: number = 0;
  private readonly photoSwiper: SwiperController = new SwiperController();
  @State private photoSlide: number = 0;
  private photoHeight: number = 800;
  private photoClosing: boolean = false;
  @State private videoSlide: number = 0;
  @State private videoSlideTarget: Post | null = null;
  @State private videoSlideDirection: number = 1;
  private playerHeight: number = 800;
  @State private galleryTouchPost: string = '';
  @State private playerPost: Post | null = null;
  @State private notifications: InboxRow[] = [];
  @State private notificationPath: string = '/notifications';
  @State private selectedNotificationPath: string = '/notifications';
  @State private notificationPosts: Map<string, Post> = new Map();
  private notificationEnd: number = 0;
  private notificationReadAt: number = 0;
  private notificationSelecting: boolean = false;
  private readonly notificationAttempts: Map<string, number> = new Map();
  @State private chatWebVisible: boolean = false;
  // History hub: tabs X shows for this account (read from x.com/i/history) and the active library path.
  @State private historyTabsFromX: PageTab[] = [];
  // Accounts used in Qwitter on this device, and an in-progress switch through X's account switcher page.
  @State private knownAccounts: KnownAccount[] = [];
  @State private switchingAccount: string = '';
  @State private accountSwitchProbe: ReaderProbe | null = null;
  @State private libraryPath: string = '';
  private loggedPageTabs: string = '';
  // Dedicated hidden web view for X Chat. It stays on chat.x.com while the reader is open, so returning to Chat or
  // opening another conversation does not restart X's chat app and its key unlock.
  @State private chatEngine: ReaderProbe | null = null;
  private chatEngineAttached: boolean = false;
  @State private chatEngineReady: boolean = false;
  private chatEngineUrl: string = '';
  private chatEngineEpoch: number = 0;
  private chatEngineLoadAt: number = 0;
  // Whether the last read saw the conversation list. X Chat's phone layout hides the list while a conversation is open,
  // and clicking a hidden row does nothing.
  private chatEngineShowsList: boolean = false;
  private chatObserveAt: number = 0;
  private chatLastLog: string = '';
  // The last raw chat read. Most change signals (typing indicators, timestamps) leave the readable content unchanged.
  private chatLastRaw: string = '';
  private chatReading: boolean = false;
  private chatReadAgain: boolean = false;
  private chatLastRead: number = 0;
  private chatSignalTimer: number = -1;
  private chatOpenedByClick: boolean = false;
  private chatConversationSeen: string = '';
  // Messages shown immediately after Send, until X shows them in the conversation.
  @State private chatPending: InboxRow[] = [];
  private chatUnlockOffered: boolean = false;
  private chatHostTried: boolean = false;
  private pendingChatCache: Map<string, InboxPage> = new Map();
  private pendingChatOwner: string = '';
  @State private conversations: InboxRow[] = [];
  @State private chatMessages: InboxRow[] = [];
  @State private chatItem: InboxRow | null = null;
  @State private chatLocked: boolean = false;
  @State private chatWaiting: boolean = false;
  @State private chatDraft: string = '';
  @State private postDraft: string = '';
  @State private postAttachments: PostAttachment[] = [];
  @State private postPollChoices: string[] = [];
  @State private postPollDays: string = '1';
  @State private postPollHours: string = '0';
  @State private postPollMinutes: string = '0';
  @State private postThread: string[] = [];
  @State private postEmojiOpen: boolean = false;
  @State private postGifOpen: boolean = false;
  @State private postGifBusy: boolean = false;
  @State private postGifQuery: string = '';
  @State private postGifResults: PostGif[] = [];
  @State private postGif: PostGif | null = null;
  private postGifScript: string = '';
  private postGifRevision: number = 0;
  @State private pickingPostMedia: boolean = false;
  @State private composerBusy: boolean = false;
  @State private composerFeedback: string = '';
  @State private replyTarget: Post | null = null;
  @State private replyAttachments: PostAttachment[] = [];
  @State private replyEmojiOpen: boolean = false;
  @State private replyDraft: string = '';
  @State private postComposer: ReaderProbe | null = null;
  @State private postComposerWebRequested: boolean = false;
  private composerScript: string = '';
  private previousKeyboardMode: KeyboardAvoidMode | undefined;
  private readonly postMediaBridge: PostMediaBridge = new PostMediaBridge();
  private reloadPostComposer: boolean = false;
  private composerSubmitted: boolean = false;
  private chatScrollAfterSend: boolean = false;
  @State private chatFailure: string = '';
  private readonly inboxScroller: Scroller = new Scroller();
  private readonly notificationScrollers: Scroller[] = [new Scroller(), new Scroller(), new Scroller()];
  private readonly messageScroller: Scroller = new Scroller();
  private inboxScript: string = '';
  @State private inboxAccountProbe: ReaderProbe | null = null;
  private nextInboxAccountProbe: number = 0;
  private inboxAdvanceAt: number = 0;
  private inboxAdvancedCount: number = -1;
  private conversationOpenAt: number = 0;
  private conversationOpenSent: boolean = false;
  private messageAdvanceAt: number = 0;
  private messageAdvancedCount: number = -1;
  @State private videoRate: number = 1;
  @State private downloadVideoPost: Post | null = null;
  private downloadVideoResolve?: (sources: string[]) => void;
  private readonly downloadWebSource: VideoWebSource = new VideoWebSource();
  private readonly playbackWebSource: VideoWebSource = new VideoWebSource();
  private readonly videoStartup: VideoStartupCache = new VideoStartupCache(this.playbackWebSource);
  @State private warmupPost: Post | null = null;
  @State private preparedVideoSources: Map<string, string[]> = new Map();
  private warmupQueue: Post[] = [];
  private warmupTimer: number = -1;
  private warmupUntil: number = -1;
  private bufferingStartup: boolean = false;
  private warmupGeneration: number = 0;
  private readonly warmedAt: Map<string, number> = new Map();
  private readonly successfulVideoSources: Map<string, string> = new Map();
  @State private videoDurations: Map<string, string> = new Map();
  @State private postActionProbe: PostActionOperation | null = null;
  @State private postMenuOperation: PostMenuOperation | null = null;
  private postMenuScript: string = '';
  @State private postActionStates: Map<string, PostLikeState> = new Map();
  @State private pendingPostActions: string[] = [];
  private postActionQueue: PostActionOperation[] = [];
  private queuedPostActionIntents: Map<string, boolean[]> = new Map();
  private postActionOperation: PostActionOperation | null = null;
  private videoSwitchRevision: number = 0;
  private videoAnimating: boolean = false;
  private videoPlaybackReady: boolean = false;
  private videoPaging: string = '';
  @State private videoFeedProbe: ReaderProbe | null = null;
  private videoFeed: Post[] = [];
  private videoFeedExhausted: boolean = false;
  private videoRecommendationLabels: Map<string, string> = new Map();
  private videoWindow: window.Window | null = null;
  private videoPreviousOrientation: window.Orientation = window.Orientation.UNSPECIFIED;
  private videoPreviousBrightness: number = -1;
  @State private videoBrightness: number = 0.5;
  @State private videoVolume: number = 1;
  @State private paging: boolean = false;
  @State private pageNote: string = '';
  @State private problem: string = '';
  @State private loginProblem: string = '';
  @State private loginDocument: boolean = false;
  private tabletReaderUserAgent: string = '';
  @State private sessionKnown: boolean = false;
  @State private showingSavedHome: boolean = false;
  @State private expired: boolean = false;

  private controller: webview.WebviewController = new webview.WebviewController();
  private profileWeb: webview.WebviewController = new webview.WebviewController();
  private settingsPaths: NavPathStack = new NavPathStack();
  private reset: SessionReset = new SessionReset();
  private readonly store: ReaderStore = new ReaderStore();
  private readonly mediaLookahead: MediaLookahead = new MediaLookahead();
  private mediaLookaheadKey: string = '';
  @State private drawerProfileLoading: boolean = false;
  private verifiedReaderAccount: string = '';
  private homeRestoredFromDb: boolean[] = [false, false];
  private legacyHomePending: boolean[] = [false, false];
  private homeLastVisible: number[] = [0, 0];
  private homePrefetchAt: number[] = [-1, -1];
  private stagingHome: boolean[] = [false, false];
  private applyingHome: boolean[] = [false, false];
  private homeWarmAttempted: boolean[] = [false, false];
  private pageAdvanceRounds: number = 0;
  private detailFillRounds: number = 0;
  private detailFillAt: number = 0;
  private pageAdvanceAt: number = 0;
  private routeFirstVisible: number = 0;
  private routeLastVisible: number = 0;
  private routePrefetchAt: number = -1;
  private homeDocumentConfirmed: boolean = false;
  private recoveringHomePagination: boolean = false;
  private homeNeedsPageSource: boolean = false;
  private homeStagePending: boolean = false;
  private homeRefreshStartedAt: number = 0;
  private previewNextAt: number = 0;
  private translationNextAt: number = 0;
  private quoteRequest: ReaderProbe | null = null;
  private readonly resolvedQuotes: Map<string, string> = new Map();
  private readonly previewPosts: Map<string, Post> = new Map();
  private readonly quoteAttempts: Map<string, number> = new Map();
  private previewSelecting: boolean = false;
  private inlineOpenRevision: number = 0;
  private inlinePreviewTimer: number = -1;
  private inlinePreviewQueue: Post[] = [];
  private readonly commentAttempts: Map<string, number> = new Map();
  private readonly profileWarmAttempted: Set<string> = new Set();
  private profileWarmAt: number = 0;
  private profileWakeUsed: boolean = false;
  private routeCachedEmpty: boolean = false;
  @State private routeCachedOnly: boolean = false;
  private routeNeedsPaging: boolean = false;
  private routeRefreshRequested: boolean = false;
  private routeScrolled: boolean = false;
  private resumePreviewDetail: boolean = false;
  private route: XRoute = new XRoute(Surface.Home, '/home');
  private trail: XRoute[] = [];
  private threadCache: Map<string, ThreadSnapshot> = new Map();
  private authorAvatars: Map<string, string> = new Map();
  private detailScroller: Scroller = new Scroller();
  private detailNeedsPaging: boolean = false;
  private followingPostId: string = '';
  private followedPostStarted: boolean = false;
  private readerPages: NavPathStack = new NavPathStack();
  private script: string = '';
  private readonly pageScripts: PageScripts = new PageScripts();
  private timer: number = -1;
  private deadline: number = 0;
  private pageDeadline: number = 0;
  private lastRead: number = 0;
  private signedOutSince: number = -1;
  private lastCookieSave: number = -COOKIE_SAVE_INTERVAL_MS;
  private savingCookies: boolean = false;
  private epoch: number = 0;
  private reading: number = -1;
  private homeWebPaged: boolean = false;
  private ready: boolean = false;
  private detailConfirmed: boolean = false;
  private clearRunning: boolean = false;
  private awaitingBlank: boolean = false;
  private clearTimer: number = -1;
  private startRunning: boolean = false;
  private lastObservation: string = '';
  private startupRetryUsed: boolean = false;
  private startupRetryTimer: number = -1;
  @State private mediaBusy: boolean = false;

  aboutToDisappear(): void {
    clearTimeout(this.startupIconTimer);
    this.rememberHomePosition();
    this.stopPolling();
    clearTimeout(this.clearTimer);
    clearTimeout(this.startupRetryTimer);
    clearTimeout(this.profileRetryTimer);
    this.cancelProbe();
    this.stopInboxAccountProbe();
    this.mediaLookahead.stop();
    this.clearVideoWarmup();
    this.playbackWebSource.close();
    this.downloadWebSource.close();
    this.postActionOperation = null;
    this.epoch++;
  }

  private async start(): Promise<void> {
    if (this.startRunning) return;
    this.startRunning = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pending = await this.reset.open(context);
      this.verifiedReaderAccount = '';
      if (pending) await this.store.open(context);
      else await this.store.open(context).catch(() => this.observe('reader-db-open-failed'));
      this.sessionKnown = this.reset.hasKnownSession();
      const sources: Uint8Array[] = await Promise.all([
        context.resourceManager.getRawFileContent('read-page.js'),
        context.resourceManager.getRawFileContent('read-inbox.js'),
        context.resourceManager.getRawFileContent('write-composer.js'),
        context.resourceManager.getRawFileContent('read-post-gifs.js'),
        context.resourceManager.getRawFileContent('post-menu.js')
      ]);
      const decoder = util.TextDecoder.create('utf-8');
      const script = decoder.decodeToString(sources[0]);
      this.inboxScript = decoder.decodeToString(sources[1]);
      this.composerScript = decoder.decodeToString(sources[2]);
      this.postGifScript = decoder.decodeToString(sources[3]);
      this.postMenuScript = decoder.decodeToString(sources[4]).trim();
      this.pageScripts.configure(script, this.inboxScript, this.composerScript, this.postGifScript);
      // poll() treats a non-empty script as "adapters ready", so assign it after the cache is configured.
      this.script = script;
      if (pending) {
        await this.clearSession();
      } else {
        this.startupRetryUsed = false;
        this.session = Session.Starting;
        this.navigate(new XRoute(Surface.Home, '/home', '', this.sessionKnown ? this.reset.readHomeTab() : 0));
      }
    } catch (_) {
      this.session = Session.Starting;
      this.content = Content.Failed;
      this.problem = ui('启动失败，请重试。', this.locale);
    } finally {
      this.startRunning = false;
    }
  }

  private foregroundChanged(): void {
    this.signedOutSince = -1;
    if (this.foreground) {
      if (this.resumePreviewDetail) {
        this.resumePreviewDetail = false;
        if (this.surface === Surface.Detail) this.load(this.route.url());
      }
      this.lastRead = 0;
      if (this.content === Content.Loading && this.session !== Session.SigningIn) {
        this.deadline = Date.now() + (this.session === Session.Starting ? START_WAIT_MS : WAIT_MS);
      }
      this.resumePolling();
      this.poll();
    } else {
      this.rememberHomePosition();
      this.stopPolling();
      this.stopInboxAccountProbe();
      if (this.discoveryProbe) {
        this.discoveryProbe = null;
        this.discoveryRefreshAt = 0;
      }
      this.lastHomeTap = 0;
      this.resumePreviewDetail = this.readerProbe?.preview === true &&
        this.surface === Surface.Detail && this.readerProbe.post?.id === this.route.postId;
      this.cancelProbe();
      this.libraryProbe = null;
      this.translationProbe = null;
      this.clearVideoWarmup();
      this.mediaLookahead.stop();
      this.flushCookies(true);
    }
  }

  private resumePolling(): void {
    if (!this.foreground || this.detailCachedOnly || this.timer !== -1) return;
    this.timer = setInterval(() => this.poll(), this.surface === Surface.Detail ? 300 : 850);
  }

  private stopPolling(): void {
    clearInterval(this.timer);
    this.timer = -1;
  }

  private async flushCookies(force: boolean = false): Promise<void> {
    if (this.session !== Session.Active && this.session !== Session.SigningIn) return;
    const now = Date.now();
    if (this.savingCookies || (!force && now - this.lastCookieSave < COOKIE_SAVE_INTERVAL_MS)) return;
    this.savingCookies = true;
    this.lastCookieSave = now;
    try {
      await webview.WebCookieManager.saveCookieAsync();
      hilog.info(0x0000, 'QyxSession', 'session cookies saved');
    } catch (_) {
      hilog.warn(0x0000, 'QyxSession', 'session cookie save failed');
    } finally {
      this.savingCookies = false;
    }
  }

  private load(url: string, followPostId: string = ''): void {
    this.previousSearchDocumentTime = 0;
    this.epoch++;
    this.homeDocumentConfirmed = false;
    this.homeNeedsPageSource = false;
    this.homeStagePending = false;
    this.detailCachedOnly = false;
    this.followingPostId = followPostId;
    this.followedPostStarted = false;
    clearTimeout(this.startupRetryTimer);
    this.loginDocument = false;
    this.ready = false;
    this.lastRead = 0;
    this.lastObservation = '';
    this.signedOutSince = -1;
    try {
      if (this.surface === Surface.Search && this.route.query && this.currentSearchDocument()) {
        this.previousSearchDocumentTime = this.searchDocumentTime;
        this.controller.refresh();
      } else if (followPostId) this.followPostLink(url, followPostId, this.epoch);
      else if ((this.session === Session.Active || this.session === Session.Starting) && isXUrl(url)) {
        this.loadReadingPage(this.controller, url);
      }
      else this.controller.loadUrl(url);
      this.resumePolling();
    } catch (_) {
      this.fail(ui('无法加载 X，请重试。', this.locale));
    }
  }

  private currentSearchDocument(): boolean {
    try {
      const current = arkUrl.URL.parseURL(this.controller.getUrl());
      return current.origin === X_ORIGIN && current.pathname.replace(/\/$/, '') === '/search' &&
        current.searchParams.get('q') === this.route.requestQuery() &&
        (current.searchParams.get('f') || '') === searchModeFilter(this.route.searchMode);
    } catch (_) {
      return false;
    }
  }

  private loadReadingPage(controller: webview.WebviewController, url: string): void {
    if (this.translationLanguage) {
      controller.loadUrl(url, [{ headerKey: 'Accept-Language', headerValue: xLanguage(this.translationLanguage) }]);
    } else {
      controller.loadUrl(url);
    }
  }

  private resetTranslations(): void {
    const probe = this.translationProbe;
    this.translationProbe = null;
    try { probe?.controller.stop(); } catch (_) {}
    this.translationRevision++;
    this.translationHostLanguage = '';
    this.translationReads.clear();
    this.translationQueue = [];
    this.translatedPosts = new Map();
    this.attemptedTranslations.clear();
    this.translationNextAt = 0;
  }

  private translationLanguageChanged(): void {
    this.resetTranslations();
    if (this.session !== Session.Active) return;
    this.load(this.route.url());
    const posts = this.posts.slice(0, 8);
    if (this.detailPost) posts.unshift(this.detailPost);
    this.queueTranslations(posts, true);
  }

  private queueTranslation(post: Post): void {
    this.queueTranslations([post], true);
  }

  private canQueueTranslation(post: Post, target: string): boolean {
    if (!post.body || !validHandle(post.handle) || !/^\d{1,24}$/.test(post.id) ||
      this.translatedPosts.get(post.id)?.body === post.body || this.attemptedTranslations.has(post.id) ||
      this.translationReads.has(post.id) || this.translationProbe?.post?.id === post.id ||
      this.translationQueue.some((item: Post) => item.id === post.id)) return false;
    const source = post.sourceLanguage?.toLowerCase() || '';
    const language = xLanguage(target).toLowerCase();
    return !source || (source !== language && (language.startsWith('zh-') || source.split('-')[0] !== language.split('-')[0]));
  }

  private async queueTranslations(posts: Post[], priority: boolean = false): Promise<void> {
    const target = this.translationLanguage;
    const owner = this.verifiedReaderAccount;
    const revision = this.translationRevision;
    if (!target || !owner || this.session !== Session.Active) return;
    this.rememberTranslations(posts, target, true);
    const pending: Post[] = [];
    for (const post of posts.slice(0, 12)) {
      const quote = post.quotedPost ? this.quotedMediaPost(post.quotedPost) : null;
      for (const candidate of quote ? [post, quote] : [post]) {
        if (!this.canQueueTranslation(candidate, target)) continue;
        this.translationReads.add(candidate.id);
        pending.push(candidate);
      }
    }
    if (!pending.length) return;
    const cached = await this.store.readTranslations(pending, target).catch((): Post[] => []);
    if (revision !== this.translationRevision || owner !== this.verifiedReaderAccount || this.session !== Session.Active) return;
    this.rememberTranslations(cached, target, false);
    if (cached.length) hilog.info(0x0000, 'QyxTranslation', 'local translation hits %{public}d', cached.length);
    for (const post of pending) this.translationReads.delete(post.id);
    const missing = pending.filter((post: Post) => this.canQueueTranslation(post, target));
    this.translationQueue = (priority ? [...missing, ...this.translationQueue] :
      [...this.translationQueue, ...missing]).slice(0, 24);
    this.nextTranslation();
  }

  private rememberTranslations(posts: Post[], target: string, persist: boolean): void {
    let updated: Map<string, Post> | undefined;
    for (const post of posts) {
      if (!hasPostTranslation(post, target)) continue;
      const previous = (updated || this.translatedPosts).get(post.id);
      if (previous?.body === post.body && previous.translation === post.translation) continue;
      if (!updated) updated = new Map(this.translatedPosts);
      updated.delete(post.id);
      updated.set(post.id, post);
      if (persist) this.store.saveTranslation(post).catch(() => this.observe('translation-cache-write-failed'));
    }
    if (!updated) return;
    while (updated.size > 160) {
      const oldest = updated.keys().next();
      if (oldest.done) break;
      updated.delete(oldest.value);
    }
    this.translatedPosts = updated;
  }

  private nextTranslation(): void {
    if (this.postComposer || this.translationProbe || this.libraryProbe || this.librarySelecting || this.notificationSelecting ||
      this.playerPost || this.homeRefreshRequested ||
      this.routeRefreshRequested || Date.now() < this.translationNextAt || !this.foreground || this.settingsOpen ||
      this.session !== Session.Active || !this.verifiedReaderAccount) return;
    const index = this.translationQueue.findIndex((item: Post) =>
      this.translatedPosts.get(item.id)?.body !== item.body && !this.attemptedTranslations.has(item.id));
    const post = index >= 0 ? this.translationQueue[index] : undefined;
    this.translationQueue = index >= 0 ? this.translationQueue.slice(index + 1) : [];
    if (!post || !this.translationLanguage) return;
    this.translationNextAt = Date.now() + TRANSLATION_GAP_MS;
    const job = new ReaderProbe(new XRoute(Surface.Detail, '/' + post.handle + '/status/' + post.id, '', 0, post.id), post);
    this.translationProbe = job;
    if (!this.translationHost) {
      this.translationHostAttached = false;
      this.translationHostLanguage = '';
      this.translationHost = new ReaderProbe(job.route, post);
      return;
    }
    if (this.translationHostAttached) this.readTranslation(job);
  }

  private translationHostReady(host: ReaderProbe): void {
    if (this.translationHost !== host) return;
    configureXWeb(host.controller, true);
    this.translationHostAttached = true;
    const job = this.translationProbe;
    if (job) this.readTranslation(job);
  }

  private discardTranslationHost(): void {
    this.translationProbe = null;
    this.translationHost = null;
    this.translationHostAttached = false;
    this.translationHostLanguage = '';
  }

  private async readTranslation(probe: ReaderProbe): Promise<void> {
    const target = this.translationLanguage;
    const owner = this.verifiedReaderAccount;
    let documentLanguage = '';
    let success = false;
    const host = this.translationHost;
    if (!host || !this.translationHostAttached) return;
    const controller = host.controller;
    try {
      // In-place navigation keeps the page's language, so it is only used once the view was loaded for this target.
      let loaded = false;
      let soft = false;
      if (this.translationHostLanguage === target) {
        soft = await controller.runJavaScript(softNavigateScript(probe.route.path)).catch(() => 'false') === 'true';
      }
      if (!soft) {
        this.loadReadingPage(controller, probe.route.url());
        this.translationHostLanguage = target;
        loaded = true;
      }
      const softUntil = Date.now() + 3000;
      const until = Date.now() + 9500;
      while (this.translationProbe === probe && this.translationHost === host && this.foreground && Date.now() < until) {
        await this.waitForWeb(soft ? 400 : 650);
        if (this.translationProbe !== probe || this.translationLanguage !== target) return;
        try {
          if (!isXUrl(controller.getUrl())) continue;
          const snapshot = decodeSnapshot(await this.pageScripts.run(controller, this.readerScript(-1, false, true, probe.route.postId)));
          const onPost = snapshot?.path.match(/\/status\/(\d{1,24})\/?$/)?.[1] === probe.route.postId;
          if (!loaded && !onPost && Date.now() > softUntil) {
            this.loadReadingPage(controller, probe.route.url());
            loaded = true;
            continue;
          }
          if (!snapshot?.authenticated || this.translationProbe !== probe || this.translationLanguage !== target || !onPost) continue;
          if (owner !== this.verifiedReaderAccount || (snapshot.ownHandle && snapshot.ownHandle.toLowerCase() !== owner)) break;
          documentLanguage = snapshot.documentLanguage;
          const post = snapshot.posts.find((item: Post) => item.id === probe.route.postId && hasPostTranslation(item, target));
          if (post) {
            this.rememberTranslations(snapshot.posts, target, true);
            success = true;
            break;
          }
        } catch (_) {}
      }
    } catch (_) {
      // The visible card continues to display its source text.
    } finally {
      if (this.translationProbe === probe) {
        this.attemptedTranslations.add(probe.route.postId);
        if (this.attemptedTranslations.size > 240) {
          const oldest = this.attemptedTranslations.values().next();
          if (!oldest.done) this.attemptedTranslations.delete(oldest.value);
        }
        hilog.info(0x0000, 'QyxTranslation', 'target=%{public}s document=%{public}s translated=%{public}s',
          target, documentLanguage, success.toString());
        this.translationProbe = null;
        this.nextTranslation();
      }
    }
  }

  @Builder
  translationReader(probe: ReaderProbe) {
    Web({ src: '', controller: probe.controller })
      .width('100%').height('100%').opacity(0).hitTestBehavior(HitTestMode.None).focusable(false)
      .accessibilityLevel('no-hide-descendants').javaScriptAccess(true).domStorageAccess(true).fileAccess(false)
      .onlineImageAccess(false)
      .runJavaScriptOnDocumentStart([{ script: X_CONNECTIVITY, scriptRules: [X_ORIGIN] },
        { script: READER_PAUSE_WEB_VIDEO, scriptRules: [X_ORIGIN] }])
      .onLoadIntercept((event) => event.data.isMainFrame() &&
        event.data.getRequestUrl() !== BLANK && !isXUrl(event.data.getRequestUrl()))
      .onControllerAttached(() => this.translationHostReady(probe))
  }

  private readerScript(homeTab: number, discover: boolean, translate: boolean = true, translationId: string = '',
    includeNotifications: boolean = false): string {
    const target = translate ? this.translationLanguage : '';
    const inbox = !!this.inboxScript &&
      (includeNotifications || this.surface === Surface.Notifications || this.surface === Surface.Chat);
    const pages = this.pageScripts;
    const args = '{ qyxDiscoverAccount: ' + discover.toString() + ', qyxHomeTarget: ' + homeTab.toString() +
      ', qyxTranslationLocale: ' + JSON.stringify(target) +
      ', qyxTranslationLabel: ' + JSON.stringify(ui('翻译帖子', target)) +
      ', qyxTranslationPostId: ' + JSON.stringify(translationId) +
      ', qyxKnownTranslationIds: ' + JSON.stringify(target && !translationId ? Array.from(this.translatedPosts.keys()) : []) +
      (inbox ? ', qyxInboxResult: ' + pages.inbox.call() : '') + ' }';
    return pages.wrap(pages.read.call(args), inbox ? [pages.read, pages.inbox] : [pages.read]);
  }

  // Same as evaluating read-page.js with no arguments.
  private plainReaderScript(): string {
    return this.pageScripts.wrap(this.pageScripts.read.call(), [this.pageScripts.read]);
  }

  private mainWebOnX(): boolean {
    if (this.loginDocument) return false;
    try { return isXUrl(this.controller.getUrl()); } catch (_) { return false; }
  }

  private followPostLink(url: string, postId: string, generation: number): void {
    let pending = true;
    const fallback = (): void => {
      if (!pending || generation !== this.epoch) return;
      pending = false;
      try {
        const current = this.controller.getUrl();
        if (isXUrl(current) && current.split(/[?#]/)[0].replace(/\/$/, '').endsWith('/status/' + postId)) {
          this.pageEnded(current);
        } else if (!this.followedPostStarted) {
          this.loadReadingPage(this.controller, url);
        }
      } catch (_) {
        this.fail(ui('无法加载 X，请重试。', this.locale));
      }
    };
    const script = '(() => {' +
      'if (location.origin !== "https://x.com") return false;' +
      'const path = ' + JSON.stringify('/status/' + postId) + ';' +
      'const links = document.querySelectorAll("article a[href]");' +
      'for (const link of links) {' +
      'if (link.origin === location.origin && link.pathname.endsWith(path) &&' +
      '(!link.target || link.target === "_self") && !link.hasAttribute("download")) {' +
      'link.click(); return true;' +
      '}} return false;})()';
    const timer = setTimeout(fallback, 550);
    const path = url.replace(/^https:\/\/x\.com/, '').split(/[?#]/)[0];
    this.controller.runJavaScript(script).then(async (result: string) => {
      if (result === 'true') return;
      // The post is not linked on this page (History, notifications, search...): navigate in place, and load the
      // page normally if X has not shown the post shortly after.
      const soft = /^\/[A-Za-z0-9_]{1,15}\/status\/\d{1,24}$/.test(path) && generation === this.epoch ?
        await this.controller.runJavaScript(softNavigateScript(path)).catch(() => 'false') : 'false';
      if (soft !== 'true') {
        clearTimeout(timer);
        fallback();
        return;
      }
      setTimeout(() => {
        if (generation !== this.epoch || this.detailConfirmed || this.route.postId !== postId) return;
        hilog.info(0x0000, 'QyxDetail', 'in-place open timed out, loading page');
        this.followedPostStarted = true;
        this.loadReadingPage(this.controller, url);
      }, 3000);
    }).catch(() => {
      clearTimeout(timer);
      fallback();
    });
  }

  private navigate(route: XRoute, detailPost: Post | null = null,
    restoreDetail: boolean = true, refreshHome: boolean = false, retained: Snapshot | undefined = undefined): void {
    const isDetail = route.surface === Surface.Detail;
    const followLink = isDetail && detailPost && this.mainWebOnX() && !this.detailCachedOnly &&
      this.session === Session.Active && route.postId !== this.route.postId;
    const isReturnToThread = isDetail && !detailPost;
    const related = isDetail && detailPost && this.surface === Surface.Detail && route.postId !== this.route.postId ?
      this.threadReplies(route.postId) : [];
    this.rememberHomePosition();
    this.rememberThread();
    clearTimeout(this.inlinePreviewTimer);
    this.inlinePreviewQueue = [];
    this.mediaLookahead.stop();
    this.mediaLookaheadKey = '';
    const continuingPreview = isDetail && this.readerProbe?.preview && !this.readerProbe.resolveQuote && this.readerProbe.post?.id === route.postId;
    if (!continuingPreview) this.cancelProbe();
    this.lastHomeTap = 0;
    const cached = isDetail && restoreDetail && this.session === Session.Active ?
      this.threadCache.get(route.postId) : undefined;
    const isHome = route.surface === Surface.Home;
    this.homeStagePending = false;
    this.homeRefreshRequested = isHome && refreshHome;
    this.homeRefreshStartedAt = this.homeRefreshRequested ? Date.now() : 0;
    this.refreshing = this.homeRefreshRequested;
    this.homeScrolled = false;
    this.stopPolling();
    this.route = route;
    if (route.surface === Surface.Notifications) this.selectedNotificationPath = route.path;
    this.inboxAdvancedCount = -1;
    this.inboxAdvanceAt = 0;
    if (route.surface !== Surface.Chat) {
      this.chatWebVisible = false;
      this.chatUnlockOffered = false;
      this.clearOpenChat();
      this.pauseChatEngine();
    }
    this.routeCachedEmpty = false;
    this.routeCachedOnly = false;
    this.routeNeedsPaging = false;
    this.routeRefreshRequested = false;
    this.routeScrolled = false;
    this.surface = route.surface;
    clearTimeout(this.profileRetryTimer);
    this.profileRetryTimer = -1;
    this.profileRetried = false;
    this.profileWakeUsed = false;
    if (route.surface === Surface.Search) {
      this.submittedQuery = route.query;
      this.searchMode = route.searchMode;
    }
    this.routeHighQuality = INITIAL_HIGH_QUALITY_POSTS;
    if (isHome) {
      this.homeTab = route.homeTab;
      this.homePrefetchAt[this.homeTab] = -1;
      if (refreshHome) {
        this.scrollHomeToTop();
      }
      this.homeHeaderHidden = this.homeHeaderPositions[this.homeTab];
      this.homeScrollDelta = 0;
      if (this.verifiedReaderAccount) this.restoreNewHomeNotice(this.homeTab);
    }
    this.libraryPath = route.surface === Surface.Bookmarks ? route.path : '';
    this.detailPost = isDetail ? cached?.post || detailPost : null;
    this.detailConfirmed = false;
    this.detailNeedsPaging = false;
    this.showingSavedHome = false;
    if (route.surface === Surface.Profile) {
      const parts = route.path.split('/');
      this.profileTab = parts[2] || '';
      this.profileMediaFilter = 0;
      if (this.profile?.handle.toLowerCase() !== parts[1].toLowerCase()) {
        this.profile = this.profileCache.get(parts[1].toLowerCase()) || null;
      }
    } else {
      this.profile = null;
    }
    this.posts = isDetail ? cached?.replies || related : isHome ? this.timelinePosts(this.homeTab) : retained?.posts || [];
    this.searchPeople = route.surface === Surface.Search && route.searchMode === 'people' ?
      (retained?.discovery || []).filter((section: DiscoverySection) => section.kind === 'people')
        .flatMap((section: DiscoverySection) => section.rows) : [];
    this.paging = false;
    this.pageNote = '';
    this.problem = '';
    const hasTimeline = isHome && this.homeLoaded[this.homeTab] && !refreshHome && this.session === Session.Active;
    const hasInbox = route.surface === Surface.Chat && this.conversations.length > 0 ||
      route.surface === Surface.Notifications && this.notifications.length > 0;
    this.content = cached?.content ?? (hasInbox ? Content.Ready :
      hasTimeline || retained ? (this.feedItemCount() ? Content.Ready : Content.Empty) : Content.Loading);
    this.deadline = Date.now() + (this.session === Session.Starting ? START_WAIT_MS :
      route.surface === Surface.Profile ? PROFILE_WAIT_MS : WAIT_MS);
    this.homeWebPaged = false;
    this.pageAdvanceRounds = 0;
    this.detailFillRounds = 0;
    this.detailFillAt = 0;
    this.routeFirstVisible = 0;
    this.routeLastVisible = 0;
    this.routePrefetchAt = -1;
    const restoreHome = isHome && !this.homeLoaded[this.homeTab] && !refreshHome && this.sessionKnown;
    const page = route.surface === Surface.Detail ? 'post-detail' : route.surface === Surface.Profile ? 'profile' : '';
    const pages = this.readerPages.getAllPathName();
    if (page && !pages.length) {
      this.readerPages.pushPath({ name: page }, this.session === Session.Active);
    } else if (page && pages[0] !== page) {
      this.readerPages.replacePath({ name: page }, this.session === Session.Active);
    } else if (!page && pages.length) {
      this.readerPages.pop(this.session === Session.Active);
    }
    if (isHome) this.restoreHomePosition();
    if (isDetail) {
      this.getUIContext().postFrameCallback(new RestoreThreadScroll(() => {
        if (this.route === route) {
          this.detailScroller.scrollTo({ xOffset: 0, yOffset: isReturnToThread ? cached?.offset || 0 : 0 });
        }
      }));
    }
    if (isDetail && !this.posts.length) {
      this.restoreStoredThread(route);
      this.restoreStoredPost(route);
    }
    if (continuingPreview) {
      this.epoch++;
      this.ready = false;
      this.detailCachedOnly = true;
      return;
    }
    if (this.isLocalBrowsing(route)) {
      this.epoch++;
      this.ready = false;
      this.routeCachedOnly = true;
      this.showLocalBrowsing(route);
      return;
    }
    if (retained) {
      this.queueTranslations(retained.posts, true);
      if (route.surface === Surface.Search && route.query) {
        this.routeRefreshRequested = true;
        this.load(route.url());
      } else {
        this.epoch++;
        this.ready = false;
        this.routeCachedOnly = true;
        this.resumePolling();
      }
      return;
    }
    if (restoreHome) {
      this.restoreStoredHome(route).finally(() => {
        if (this.route === route && (this.session === Session.Active || this.session === Session.Starting)) this.load(route.url());
      }).catch(() => this.observe('home-cache-read-failed'));
    } else if (route.surface === Surface.Notifications || route.surface === Surface.Chat) {
      this.epoch++;
      this.ready = false;
      this.openInboxRoute(route);
    } else if (!isHome && !isDetail && restoreDetail && this.session === Session.Active) {
      this.epoch++;
      this.ready = false;
      this.openStoredRoute(route);
    } else {
      this.load(route.url(), followLink ? route.postId : '');
    }
  }

  private selectNotificationCategory(path: string): void {
    if (this.surface !== Surface.Notifications || this.route.path === path) return;
    this.notificationEnd = 0;
    this.inboxAdvanceAt = 0;
    this.inboxAdvancedCount = -1;
    this.navigate(new XRoute(Surface.Notifications, path));
  }

  private async openInboxRoute(route: XRoute): Promise<void> {
    const chat = route.surface === Surface.Chat;
    if (!chat && this.notificationPath !== route.path) {
      this.notifications = [];
      this.notificationPath = route.path;
      this.content = Content.Loading;
    }
    const existing = chat ? this.conversations : this.notifications;
    const data = existing.length ? null : await this.store.readInbox(chat ? 'chats' : 'v2:' + route.path.slice(1)).catch(() => null);
    if (this.route !== route || this.session !== Session.Active) return;
    if (data) {
      if (chat && !this.conversations.length) this.conversations = data.rows;
      if (!chat && !this.notifications.length) this.notifications = data.rows;
      this.content = data.rows.length ? Content.Ready : Content.Empty;
    }
    if ((chat ? this.conversations : this.notifications).length) this.content = Content.Ready;
    if (!chat) {
      this.loadNotificationCategory();
      return;
    }
    this.ensureChatEngine(route.url());
    this.resumePolling();
  }

  private ensureChatEngine(url: string, reload: boolean = false): void {
    if (this.session !== Session.Active) return;
    const engine = this.chatEngine;
    if (!engine) {
      this.chatEngineAttached = false;
      this.chatEngineReady = false;
      this.chatEngineUrl = url;
      this.chatHostTried = false;
      this.chatEngine = new ReaderProbe(new XRoute(Surface.Chat, '/i/chat'));
      return;
    }
    try { engine.controller.onActive(); } catch (_) {}
    let current = '';
    try { current = engine.controller.getUrl(); } catch (_) {}
    if (reload || !this.chatEngineAttached || (!isXChatUrl(current) && !current.startsWith('https://chat.x.com'))) {
      this.loadChatEngine(url);
      return;
    }
    this.chatLastRead = 0;
    this.chatLastRaw = '';
    if (this.chatEngineUsable()) this.readChat(true);
  }

  private loadChatEngine(url: string): void {
    this.chatEngineUrl = url;
    this.chatLastRaw = '';
    this.chatEngineEpoch++;
    this.chatEngineReady = false;
    this.chatLastRead = 0;
    this.chatOpenedByClick = false;
    this.chatEngineShowsList = false;
    const engine = this.chatEngine;
    if (!engine || !this.chatEngineAttached) return;
    this.chatEngineLoadAt = Date.now();
    this.logChat('load ' + this.chatHost(url));
    try { engine.controller.loadUrl(url); } catch (_) {}
  }

  // onPageEnd is not reliable for X pages, so also treat the engine as usable a short time after a load starts.
  // A read that returns a chat page marks it ready.
  private chatEngineUsable(): boolean {
    return this.chatEngineReady ||
      (this.chatEngineAttached && this.chatEngineLoadAt > 0 && Date.now() - this.chatEngineLoadAt > 2500);
  }

  private chatHost(url: string): string {
    return url.startsWith('https://chat.x.com') ? 'chat' : isXUrl(url) ? 'x' : url === BLANK ? 'blank' : 'other';
  }

  private logChat(message: string): void {
    if (message === this.chatLastLog) return;
    this.chatLastLog = message;
    hilog.info(0x0000, 'QwitterChat', 'engine %{public}s', message);
  }

  private attachChatEngine(engine: ReaderProbe): void {
    if (this.chatEngine !== engine) return;
    configureXWeb(engine.controller, true);
    this.chatEngineAttached = true;
    this.loadChatEngine(this.chatEngineUrl || engine.route.url());
  }

  private chatPageEnded(engine: ReaderProbe, url: string): void {
    if (this.chatEngine !== engine || (!isXUrl(url) && !isXChatUrl(url))) return;
    if (!this.chatEngineReady) this.logChat('ready ' + this.chatHost(url));
    this.chatEngineReady = true;
    this.flushCookies();
    this.readChat(true);
  }

  private pauseChatEngine(): void {
    clearTimeout(this.chatSignalTimer);
    this.chatSignalTimer = -1;
    try { this.chatEngine?.controller.onInactive(); } catch (_) {}
  }

  private discardChatEngine(): void {
    this.pauseChatEngine();
    this.chatEngine = null;
    this.chatEngineAttached = false;
    this.chatEngineReady = false;
    this.chatEngineUrl = '';
    this.chatEngineEpoch++;
    this.chatReading = false;
    this.chatReadAgain = false;
    this.chatOpenedByClick = false;
    this.chatConversationSeen = '';
    this.chatPending = [];
  }

  private chatSignal(engine: ReaderProbe): void {
    if (this.chatEngine !== engine || this.surface !== Surface.Chat || this.chatSignalTimer !== -1) return;
    const wait = Math.max(0, CHAT_SIGNAL_GAP_MS - (Date.now() - this.chatLastRead));
    this.chatSignalTimer = setTimeout(() => {
      this.chatSignalTimer = -1;
      this.readChat(true);
    }, wait);
  }

  // Reads the chat page in the engine. Called on page load, on the page's change signal, and as a slow fallback poll.
  private async readChat(force: boolean = false): Promise<void> {
    const engine = this.chatEngine;
    if (!engine || !this.chatEngineUsable() || this.surface !== Surface.Chat || !this.foreground ||
      this.session !== Session.Active || !this.inboxScript) return;
    if (this.chatReading) {
      this.chatReadAgain = true;
      return;
    }
    const waiting = this.chatWebVisible || this.content === Content.Loading || (!!this.chatItem && this.chatWaiting);
    const interval = waiting ? 0 : this.chatItem ? 2000 : 5000;
    if (!force && Date.now() - this.chatLastRead < interval) return;
    this.chatReading = true;
    this.chatLastRead = Date.now();
    const epoch = this.chatEngineEpoch;
    try {
      const url = engine.controller.getUrl();
      if (!isXUrl(url) && !isXChatUrl(url)) return;
      const pages = this.pageScripts;
      const raw = await pages.run(engine.controller, pages.wrap('JSON.stringify(' + pages.inbox.call() + ')', [pages.inbox]));
      if (this.chatEngine !== engine || epoch !== this.chatEngineEpoch || this.surface !== Surface.Chat ||
        this.session !== Session.Active) return;
      if (raw === this.chatLastRaw && this.chatEngineReady && !this.chatWebVisible) return;
      this.chatLastRaw = raw;
      const json = raw.startsWith('"') ? JSON.parse(raw) as string : raw;
      const page = json ? decodeInbox(JSON.parse(json) as InboxPage) : null;
      this.logChat('read ' + this.chatHost(url) + (page ? ' rows=' + page.rows.length.toString() +
        ' messages=' + page.messages.length.toString() + ' locked=' + page.locked.toString() +
        ' embedded=' + page.embeddedChat.toString() + ' conversation=' + (page.conversation ? (this.chatItem ?
        (page.conversation === this.chatItem.id ? 'open' : 'other') : 'listed') : 'none') : ' no-chat-page'));
      if (!page) return;
      if (!this.chatEngineReady) this.chatEngineReady = true;
      this.chatEngineShowsList = page.rows.length > 0;
      if (Date.now() - this.chatObserveAt > 4000) {
        this.chatObserveAt = Date.now();
        engine.controller.runJavaScript('(() => { if (typeof window.__qyxChatObserve === "function") window.__qyxChatObserve(); })()')
          .catch(() => {});
      }
      if (page.embeddedChat && !this.chatHostTried && !page.locked && !page.rows.length && !page.messages.length) {
        this.chatHostTried = true;
        this.deadline = Date.now() + WAIT_MS;
        this.loadChatEngine('https://chat.x.com/');
        return;
      }
      this.acceptInbox(page);
      // A click that left the page on another conversation: load the requested one directly.
      const item = this.chatItem;
      const address = item ? chatConversationUrl(item.path) : '';
      if (item && address && this.chatOpenedByClick && page.conversation && page.conversation !== item.id &&
        page.messages.length > 0 && Date.now() - this.conversationOpenAt > 1000) {
        this.logChat('open fallback load');
        this.conversationOpenSent = true;
        this.ensureChatEngine(address, true);
      }
    } catch (_) {
      // The chat app can replace its document while a read is running. The next signal or poll retries.
    } finally {
      this.chatReading = false;
      if (this.chatReadAgain) {
        this.chatReadAgain = false;
        setTimeout(() => this.readChat(true), 150);
      }
    }
  }

  private loadNotificationCategory(reload: boolean = false): void {
    try {
      if (!reload && /^https:\/\/x\.com\/notifications(?:[/?#]|$)/.test(this.controller.getUrl())) {
        this.ready = true;
        this.lastRead = 0;
        this.resumePolling();
        this.poll();
        return;
      }
    } catch (_) {}
    this.load(X_ORIGIN + '/notifications');
  }

  private mergeInbox(incoming: InboxRow[], existing: InboxRow[], append: boolean, keepTail: boolean = false): InboxRow[] {
    const entries = new Map<string, InboxRow>();
    for (const row of append ? existing : incoming) entries.set(row.id, row);
    for (const row of append ? incoming : existing) {
      if (!entries.has(row.id)) entries.set(row.id, row);
      else {
        const previous = entries.get(row.id);
        const latest = append ? row : previous;
        const fallback = append ? previous : row;
        if (latest?.kind === 'message' && !latest.avatar && fallback?.avatar) {
          const enriched: InboxRow = {
            id: latest.id, title: latest.title, text: latest.text, time: latest.time, avatar: fallback.avatar,
            path: latest.path, kind: latest.kind, unread: latest.unread, outgoing: latest.outgoing
          };
          entries.set(row.id, enriched);
        } else if (append) entries.set(row.id, row);
      }
    }
    const rows = Array.from(entries.values());
    return keepTail ? rows.slice(-160) : rows.slice(0, 160);
  }

  private acceptInbox(page: InboxPage): void {
    const chat = this.surface === Surface.Chat;
    this.verifyInboxAccount();
    if (chat) this.chatLocked = page.locked;
    if (page.locked) {
      this.chatWaiting = false;
      this.refreshing = false;
      this.content = Content.Ready;
      if (chat && !this.chatUnlockOffered && !this.conversations.length && !this.chatMessages.length) this.showChatWeb();
      return;
    }
    if (chat && (this.chatItem ? page.messages.length > 0 : page.rows.length > 0 || page.empty)) {
      const wasVisible = this.chatWebVisible;
      this.chatWebVisible = false;
      if (wasVisible) this.flushCookies(true);
    }
    const previous = chat ? this.conversations : this.notifications;
    if (page.rows.length || page.empty) {
      const rows = this.mergeInbox(page.rows, previous, !!this.inboxAdvanceAt);
      const cached = chat ? this.publishChatCache('chats', rows, page.empty, page.title) :
        this.store.publishInbox('v2:' + this.route.path.slice(1), rows, page.empty, page.title, !!this.verifiedReaderAccount);
      if (JSON.stringify(rows) !== JSON.stringify(previous) || (page.empty && this.content === Content.Loading)) {
        if (chat) this.conversations = cached.rows;
        else {
          this.notifications = cached.rows;
          this.warmNotifications();
        }
      }
      this.content = rows.length ? Content.Ready : Content.Empty;
      this.refreshing = false;
      if (rows.length > previous.length) this.inboxAdvanceAt = 0;
    }
    const item = this.chatItem;
    if (!chat) return;
    if (!item) {
      if (page.conversation && page.messages.length) {
        this.publishChatCache('chat:' + page.conversation, page.messages, false, page.title);
      }
      return;
    }
    if (page.conversation === item.id) {
      this.conversationOpenSent = true;
      this.chatConversationSeen = item.id;
      if (page.messages.length) {
        const previousMessages = this.chatMessages;
        const older = !!this.messageAdvanceAt;
        const rows = this.mergeInbox(page.messages, previousMessages, !older, !older);
        const cached = this.publishChatCache('chat:' + item.id, rows, false, item.title);
        if (JSON.stringify(rows) !== JSON.stringify(previousMessages)) {
          this.chatMessages = cached.rows;
          this.prunePendingChat(item);
          if (!previousMessages.length || this.chatScrollAfterSend) this.scrollMessagesToEnd(item);
          this.messageAdvanceAt = 0;
        }
        this.chatScrollAfterSend = false;
        this.chatWaiting = false;
        this.chatFailure = '';
      }
      return;
    }
    if (!this.conversationOpenSent && page.rows.some((row: InboxRow) => row.id === item.id)) {
      this.followConversation(item);
    }
  }

  private publishChatCache(key: string, rows: InboxRow[], empty: boolean, title: string): InboxPage {
    const owner = this.handle.toLowerCase();
    const verified = !!owner && this.verifiedReaderAccount === owner;
    const page = this.store.publishInbox(key, rows, empty, title, verified);
    if (!verified && validHandle(owner)) {
      if (owner !== this.pendingChatOwner) this.pendingChatCache.clear();
      this.pendingChatOwner = owner;
      if (!this.pendingChatCache.has(key) && this.pendingChatCache.size >= 16) {
        this.pendingChatCache.delete(Array.from(this.pendingChatCache.keys())[0]);
      }
      this.pendingChatCache.set(key, page);
    }
    return page;
  }

  private async openConversation(item: InboxRow): Promise<void> {
    if (this.session !== Session.Active || this.surface !== Surface.Chat || this.chatItem) return;
    const route = this.route;
    const key = 'chat:' + item.id;
    const stored = await this.store.readInbox(key).catch(() => null);
    const cached = stored || (this.pendingChatOwner === this.handle.toLowerCase() ? this.pendingChatCache.get(key) : undefined);
    if (this.route !== route || this.session !== Session.Active || this.chatItem) return;
    this.chatItem = item;
    this.chatLastRaw = '';
    this.chatDraft = '';
    this.composerFeedback = '';
    this.chatMessages = cached?.rows || [];
    this.chatWaiting = !cached;
    this.chatFailure = '';
    this.conversationOpenSent = false;
    this.conversationOpenAt = Date.now();
    this.messageAdvanceAt = 0;
    this.messageAdvancedCount = -1;
    this.readerPages.pushPath({ name: 'chat-detail' }, true);
    if (cached?.rows.length) {
      hilog.info(0x0000, 'QwitterReader', 'conversation local rows %{public}d', cached.rows.length);
      this.scrollMessagesToEnd(item);
    }
    this.chatConversationSeen = '';
    this.openChatConversation(item);
  }

  private async openChatConversation(item: InboxRow): Promise<void> {
    const address = chatConversationUrl(item.path);
    const click = !!this.chatEngine && this.chatEngineUsable() && (this.chatEngineShowsList || !address);
    this.logChat('open ' + (click ? 'click' : address ? 'load' : 'wait-for-list'));
    if (click) {
      // X Chat is a single-page app: clicking the row keeps it running and unlocked, unlike loading the URL.
      await this.followConversation(item);
      if (this.chatItem !== item) return;
      if (this.conversationOpenSent) {
        this.chatOpenedByClick = true;
        this.readChat(true);
        setTimeout(() => {
          if (this.chatItem === item && this.chatConversationSeen !== item.id && address) {
            this.conversationOpenSent = true;
            this.ensureChatEngine(address, true);
          }
        }, 1500);
        return;
      }
    }
    if (address) {
      this.conversationOpenSent = true;
      this.ensureChatEngine(address, true);
    } else {
      // No direct link: show the list again (reload if a conversation is covering it); acceptInbox clicks the row.
      this.ensureChatEngine(this.route.url(), this.chatEngineUsable() && !this.chatEngineShowsList);
    }
  }

  // After closing a conversation that was opened by a click, step the chat app back to its list in place.
  private returnChatEngineToList(): void {
    const engine = this.chatEngine;
    if (!engine || !this.chatOpenedByClick || !this.chatEngineUsable()) return;
    this.chatOpenedByClick = false;
    engine.controller.runJavaScript('(() => { if (history.length > 1) history.back(); })()').catch(() => {});
  }

  private prunePendingChat(item: InboxRow): void {
    if (!this.chatPending.length) return;
    const normalize = (value: string): string => value.replace(/\s+/g, ' ').trim();
    const shown = this.chatMessages.filter((row: InboxRow) => row.outgoing).map((row: InboxRow) => normalize(row.text));
    const remaining = this.chatPending.filter((pending: InboxRow) => {
      if (pending.path !== item.id || pending.kind !== 'sent') return true;
      const index = shown.indexOf(normalize(pending.text));
      if (index < 0) return true;
      shown.splice(index, 1);
      return false;
    });
    if (remaining.length !== this.chatPending.length) this.chatPending = remaining;
  }

  private dropPendingChat(id: string): void {
    if (this.chatPending.some((row: InboxRow) => row.id === id)) {
      this.chatPending = this.chatPending.filter((row: InboxRow) => row.id !== id);
    }
  }

  private chatRows(): InboxRow[] {
    const id = this.chatItem?.id || '';
    const pending = this.chatPending.filter((row: InboxRow) => row.path === id);
    return pending.length ? [...this.chatMessages, ...pending] : this.chatMessages;
  }

  private verifyInboxAccount(): void {
    if (this.verifiedReaderAccount || !validHandle(this.handle) || this.inboxAccountProbe ||
      !this.foreground || this.webUrl || Date.now() < this.nextInboxAccountProbe) return;
    this.nextInboxAccountProbe = Date.now() + 30000;
    this.inboxAccountProbe = new ReaderProbe(new XRoute(Surface.Home, '/home'));
  }

  private stopInboxAccountProbe(): void {
    const probe = this.inboxAccountProbe;
    this.inboxAccountProbe = null;
    try { probe?.controller.stop(); } catch (_) {}
  }

  private async readInboxAccount(probe: ReaderProbe): Promise<void> {
    const owner = this.handle.toLowerCase();
    const deadline = Date.now() + 7500;
    try {
      configureXWeb(probe.controller, true);
      probe.controller.loadUrl(probe.route.url());
      while (this.inboxAccountProbe === probe && this.foreground && !this.verifiedReaderAccount && Date.now() < deadline) {
        await this.waitForWeb(500);
        if (this.inboxAccountProbe !== probe || this.handle.toLowerCase() !== owner) return;
        let snapshot: Snapshot | undefined;
        try {
          if (!isXUrl(probe.controller.getUrl())) continue;
          snapshot = decodeSnapshot(await this.pageScripts.run(probe.controller, this.readerScript(-1, true, false)));
        } catch (_) { continue; }
        if (this.inboxAccountProbe !== probe || this.handle.toLowerCase() !== owner) return;
        if (snapshot?.path !== '/home' || !snapshot.authenticated || !snapshot.ownHandle) continue;
        if (snapshot.ownHandle.toLowerCase() === owner) {
          this.bindReaderAccount(snapshot.ownHandle);
          this.lastRead = 0;
        }
        return;
      }
    } finally {
      if (this.inboxAccountProbe === probe) this.stopInboxAccountProbe();
    }
  }

  private scrollMessagesToEnd(item: InboxRow): void {
    this.getUIContext().postFrameCallback(new RestoreThreadScroll(() => {
      if (this.chatItem === item) this.messageScroller.scrollEdge(Edge.Bottom);
    }));
  }

  private async followConversation(item: InboxRow): Promise<void> {
    const engine = this.chatEngine;
    if (!engine || !this.inboxScript || this.chatItem !== item || this.conversationOpenSent || !this.chatEngineUsable()) return;
    this.conversationOpenSent = true;
    try {
      const pages = this.pageScripts;
      const raw = await pages.run(engine.controller, pages.wrap('JSON.stringify(' +
        pages.inbox.call('{ qyxInboxOpenKey: ' + JSON.stringify(item.id) + ' }') + ')', [pages.inbox]));
      if (this.chatItem !== item || this.surface !== Surface.Chat) return;
      const data = JSON.parse(raw.startsWith('"') ? JSON.parse(raw) as string : raw) as InboxPage;
      if (data?.opened) return;
    } catch (_) {}
    if (this.chatItem === item) this.conversationOpenSent = false;
  }

  private clearOpenChat(): void {
    this.chatLastRaw = '';
    if (this.chatItem) {
      this.composerBusy = false;
      this.composerFeedback = '';
    }
    this.chatItem = null;
    this.chatMessages = [];
    this.chatDraft = '';
    this.chatScrollAfterSend = false;
    this.chatWaiting = false;
    this.chatFailure = '';
    this.conversationOpenSent = false;
  }

  private openPostComposer(reply: Post | null = null): void {
    if (this.session !== Session.Active || this.postComposer) return;
    this.rememberHomePosition();
    this.composerFeedback = '';
    this.reloadPostComposer = false;
    this.postEmojiOpen = false;
    if (reply && !/^\d{1,24}$/.test(reply.id)) return;
    this.replyTarget = reply;
    this.replyDraft = '';
    this.replyAttachments = [];
    this.postComposer = this.newComposerProbe();
    // Publishing waits for a verified account. Check it now, from any page, so Send does not stall.
    if (!this.verifiedReaderAccount) this.verifyInboxAccount();
    if (reply) {
      this.replyEmojiOpen = true;
    } else {
      this.readerPages.pushPath({ name: 'post-compose' }, true);
    }
  }

  private newComposerProbe(): ReaderProbe {
    const reply = this.replyTarget;
    if (!reply) return new ReaderProbe(new XRoute(Surface.Home, '/compose/post'));
    const path = (validHandle(reply.handle) ? '/' + reply.handle : '/i/web') + '/status/' + reply.id;
    return new ReaderProbe(new XRoute(Surface.Detail, path, '', 0, reply.id));
  }

  private setComposerKeyboard(active: boolean): void {
    const uiContext = this.getUIContext();
    if (active && this.previousKeyboardMode === undefined) {
      this.previousKeyboardMode = uiContext.getKeyboardAvoidMode();
      uiContext.setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    } else if (!active && this.previousKeyboardMode !== undefined) {
      uiContext.setKeyboardAvoidMode(this.previousKeyboardMode);
      this.previousKeyboardMode = undefined;
    }
  }

  private stopPostComposer(): void {
    const composer = this.postComposer;
    this.postComposer = null;
    this.postComposerWebRequested = false;
    this.postGifRevision++;
    this.postGifOpen = false;
    this.postGifBusy = false;
    this.postGif = null;
    this.postGifResults = [];
    try { composer?.controller.stop(); } catch (_) {}
    this.postMediaBridge.clear();
  }

  private closePostComposer(): void {
    const replying = this.replyTarget !== null;
    this.stopPostComposer();
    this.replyTarget = null;
    this.replyDraft = '';
    this.replyAttachments = [];
    this.composerFeedback = '';
    this.composerBusy = false;
    if (!replying) this.readerPages.pop(true);
    this.restoreHomePosition();
  }

  private async pickPostMedia(): Promise<void> {
    const composer = this.postComposer;
    const replying = this.replyTarget !== null;
    if (!composer || this.composerBusy || this.pickingPostMedia ||
      (!replying && (this.postPollChoices.length || this.postThread.length || this.postGif || this.postGifOpen))) return;
    this.pickingPostMedia = true;
    try {
      const attachments = await selectPostAttachments();
      if (this.postComposer === composer && attachments.length) {
        if (replying) this.replyAttachments = attachments;
        else this.postAttachments = attachments;
        this.composerFeedback = '';
      }
    } catch (_) {
      if (this.postComposer === composer) this.composerFeedback = ui('无法读取所选媒体，请选择其他文件。', this.locale);
    } finally {
      this.pickingPostMedia = false;
    }
  }

  private async postGifStep(composer: ReaderProbe, step: string, query: string = '', url: string = ''): Promise<GifResponse | null> {
    try {
      const request: GifRequest = { step, query, url };
      const pages = this.pageScripts;
      const raw = await pages.run(composer.controller, pages.wrap('JSON.stringify(' +
        pages.gif.call('{ qyxGifRequest: ' + JSON.stringify(request) + ' }') + ')', [pages.gif]));
      return JSON.parse(raw.startsWith('"') ? JSON.parse(raw) as string : raw) as GifResponse;
    } catch (_) {
      return null;
    }
  }

  private async findPostGifs(query: string, opening: boolean): Promise<void> {
    const composer = this.postComposer;
    if (!composer || !this.postGifScript || this.composerBusy || this.postAttachments.length ||
      this.postPollChoices.length || this.postThread.length || this.postGif) return;
    this.postEmojiOpen = false;
    this.postComposerWebRequested = true;
    this.postGifOpen = true;
    this.postGifBusy = true;
    this.postGifResults = [];
    this.composerFeedback = '';
    const generation = ++this.postGifRevision;
    const current = (): boolean => this.postComposer === composer && this.postGifRevision === generation;
    const until = Date.now() + 8500;
    if (!opening) {
      await this.postGifStep(composer, 'search', query);
      await this.waitForWeb(600);
    }
    let ready = false;
    while (current() && Date.now() < until) {
      const result: GifResponse | null = await this.postGifStep(composer, opening && !ready ? 'open' : 'list');
      if (!current()) return;
      ready = ready || !!result?.ready;
      if (result?.items.length) {
        this.postGifResults = result.items.filter((item: PostGif) =>
          /^https:\/\/(?:(?:[a-z0-9-]+\.)?(?:tenor\.com|giphy\.com)|pbs\.twimg\.com)\//i.test(item.url));
        break;
      }
      await this.waitForWeb(350);
    }
    if (!current()) return;
    this.postGifBusy = false;
    if (!this.postGifResults.length) {
      try {
        const path = composer.controller.getUrl().split(/[?#]/)[0];
        const stage = path === X_ORIGIN + '/compose/post' ? 'compose' :
          path.startsWith(X_ORIGIN + '/i/foundmedia') ? 'picker' : 'other';
        hilog.info(0x0000, 'QwitterComposer', 'GIF picker ended at %{public}s, search ready %{public}s',
          stage, ready.toString());
      } catch (_) {}
      this.composerFeedback = ui(ready ? '没有找到 GIF。' : '暂时无法读取 X 的 GIF 库。', this.locale);
    }
  }

  private async attachPostGif(item: PostGif): Promise<void> {
    const composer = this.postComposer;
    if (!composer || !this.postGifOpen || this.postGifBusy) return;
    this.postGifBusy = true;
    const result = await this.postGifStep(composer, 'select', '', item.url);
    if (this.postComposer !== composer || !this.postGifOpen) return;
    this.postGifBusy = false;
    if (!result?.selected) {
      this.composerFeedback = ui('无法添加此 GIF，请重试。', this.locale);
      return;
    }
    this.postGif = item;
    this.postGifOpen = false;
    this.postGifResults = [];
    this.composerFeedback = '';
  }

  private discardPostGif(): void {
    if (!this.postComposer) return;
    this.stopPostComposer();
    this.postComposer = new ReaderProbe(new XRoute(Surface.Home, '/compose/post'));
    this.composerFeedback = '';
  }

  private postPollDuration(): number {
    const days = Number(this.postPollDays);
    const hours = Number(this.postPollHours);
    const minutes = Number(this.postPollMinutes);
    const total = days * 1440 + hours * 60 + minutes;
    return Number.isInteger(total) && days >= 0 && days <= 7 && hours >= 0 && hours < 24 &&
      minutes >= 0 && minutes < 60 && total >= 5 && total <= 10080 ? total : 0;
  }

  private canPublishPost(): boolean {
    if (this.replyTarget) return !this.composerBusy && !this.pickingPostMedia &&
      (!!this.replyDraft.trim() || this.replyAttachments.length > 0);
    if (this.composerBusy || this.pickingPostMedia || this.postGifOpen ||
      (!this.postDraft.trim() && !this.postAttachments.length && !this.postGif)) return false;
    if (this.postThread.some((text: string) => !text.trim())) return false;
    return !this.postPollChoices.length || (this.postPollDuration() > 0 && this.postPollChoices.every((choice: string) =>
      choice.trim().length > 0));
  }

  private resetPostDraft(): void {
    this.postDraft = '';
    this.postAttachments = [];
    this.postPollChoices = [];
    this.postPollDays = '1';
    this.postPollHours = '0';
    this.postPollMinutes = '0';
    this.postThread = [];
    this.postGif = null;
  }

  private async runComposerStep(controller: webview.WebviewController, request: ComposerRequest, step: string): Promise<string> {
    request.step = step;
    const pages = this.pageScripts;
    const chat = request.mode === 'chat';
    const conversation = chat ? '(' + pages.inbox.call() + ')?.conversation || ""' : '""';
    const raw = await pages.run(controller, pages.wrap(pages.composer.call('{ qyxComposeRequest: ' +
      JSON.stringify(request) + ', qyxComposeConversation: ' + conversation + ' }'),
      chat ? [pages.composer, pages.inbox] : [pages.composer]));
    try { return JSON.parse(raw) as string; } catch (_) { return raw; }
  }

  private async submitComposer(chat: boolean): Promise<void> {
    if (!chat && !this.canPublishPost()) return;
    const reply = chat ? null : this.replyTarget;
    if (!chat && this.postComposer && this.reloadPostComposer && (reply || !this.postGif)) {
      this.stopPostComposer();
      this.postComposer = this.newComposerProbe();
      this.reloadPostComposer = false;
    }
    const item = chat ? this.chatItem : null;
    const composer = chat ? null : this.postComposer;
    const text = (chat ? this.chatDraft : reply ? this.replyDraft : this.postDraft).trim();
    const owner = this.handle.toLowerCase();
    const attachments = chat ? [] : reply ? this.replyAttachments : this.postAttachments;
    if ((!text && !attachments.length && (chat || !!reply || !this.postGif)) ||
      !owner || !this.composerScript || this.composerBusy || (!item && !composer) ||
      this.session !== Session.Active || (chat && (this.chatLocked || !!this.webUrl))) return;
    const chatEngine = chat ? this.chatEngine : null;
    if (chat && (!chatEngine || !this.chatEngineUsable())) {
      this.composerFeedback = ui('聊天仍在加载，请稍候再发送。', this.locale);
      return;
    }
    const controller = composer?.controller || chatEngine?.controller || this.controller;
    const active = (): boolean => this.session === Session.Active && this.handle.toLowerCase() === owner &&
      (item ? this.chatItem === item : this.postComposer === composer);
    const canSubmit = (): boolean => active() && this.foreground && (!item || (!this.chatLocked && !this.webUrl));
    this.composerBusy = true;
    if (composer) this.postComposerWebRequested = true;
    this.composerSubmitted = false;
    this.composerFeedback = '';
    const request: ComposerRequest = {
      key: ++probeSequence, step: '', text, target: item?.id || reply?.id || '', mode: chat ? 'chat' : reply ? 'reply' : 'post',
      choices: chat || reply ? [] : this.postPollChoices.map((choice: string) => choice.trim()),
      duration: chat || reply ? 0 : this.postPollDuration(), uploads: [],
      thread: chat || reply ? [] : this.postThread.map((value: string) => value.trim()), gif: chat || reply ? '' : this.postGif?.url || ''
    };
    const prepareUntil = Date.now() + (attachments.length ? 90000 : COMPOSER_PREPARE_MS);
    let mayHaveSubmitted = false;
    let result = '';
    let pendingId = '';
    if (item) {
      const pending = new InboxRow();
      pending.id = 'pending-' + request.key.toString();
      pending.path = item.id;
      pending.kind = 'pending';
      pending.text = text;
      pending.outgoing = true;
      pending.time = ui('发送中…', this.locale);
      pendingId = pending.id;
      this.chatPending = [...this.chatPending, pending];
      this.chatDraft = '';
      this.chatScrollAfterSend = true;
      this.scrollMessagesToEnd(item);
    }
    try {
      if (attachments.length) request.uploads = this.postMediaBridge.prepare(attachments);
      if (reply) {
        const response = await submitWebReply(
          async (step: string): Promise<string> => {
            if (step !== 'verify' && this.verifiedReaderAccount !== owner) return 'reply-account-pending';
            return this.runComposerStep(controller, request, step);
          },
          canSubmit, active,
          (ms: number) => this.waitForWeb(ms),
          (submitting: boolean) => { this.composerSubmitted = submitting; },
          attachments.length ? 90000 : COMPOSER_PREPARE_MS);
        result = response.stage;
        mayHaveSubmitted = response.mayHaveSubmitted;
      } else {
        while (canSubmit() && Date.now() < prepareUntil) {
          if (this.verifiedReaderAccount === owner) {
            const before = result;
            try { result = await this.runComposerStep(controller, request, 'prepare'); } catch (_) { result = 'bridge-not-ready'; }
            if (result !== before) hilog.info(0x0000, 'QwitterComposer', 'post prepare=%{public}s', result);
            if (result === 'prepared' || result === 'draft-conflict' || result === 'attachment-failed') break;

          }
          await this.waitForWeb(300);
        }
        if (result === 'prepared') {
          const submitUntil = Date.now() + COMPOSER_SUBMIT_MS;
          while (canSubmit() && this.verifiedReaderAccount === owner && Date.now() < submitUntil) {
            mayHaveSubmitted = true;
            this.composerSubmitted = true;
            const before: string = result;
            result = await this.runComposerStep(controller, request, 'submit');
            if (result !== before) hilog.info(0x0000, 'QwitterComposer', 'post submit=%{public}s', result);
            if (result === 'submitted') break;
            mayHaveSubmitted = false;
            this.composerSubmitted = false;
            await this.waitForWeb(220);
          }
        }
        if (result === 'submitted') {
          const verifyUntil = Date.now() + COMPOSER_VERIFY_MS;
          while (active() && Date.now() < verifyUntil) {
            try { result = await this.runComposerStep(controller, request, 'verify'); } catch (_) {}
            if (result === 'confirmed') break;
            await this.waitForWeb(350);
          }
        }
      }
    } catch (_) {
      // A bridge error after clicking does not establish whether X accepted it.
    }
    if (!active()) {
      if (pendingId) this.dropPendingChat(pendingId);
      return;
    }
    if (!chat) {
      const stage = result.startsWith('confirmed:') ? 'confirmed' : result || 'no-bridge-result';
      hilog.info(0x0000, 'QwitterComposer', '%{public}s stage=%{public}s accountReady=%{public}s submitted=%{public}s',
        reply ? 'reply' : 'post', stage, this.verifiedReaderAccount === owner ? 'yes' : 'no',
        mayHaveSubmitted ? 'yes' : 'no');
    }
    this.composerBusy = false;
    this.composerSubmitted = false;
    const confirmedReplyId = reply ? /^confirmed:(\d{1,24})$/.exec(result)?.[1] : undefined;
    if (result === 'confirmed' || confirmedReplyId) {
      if (reply && confirmedReplyId) {
        const published = new Post();
        published.id = confirmedReplyId;
        published.replyToId = reply.id;
        published.handle = this.handle;
        published.name = this.accountName;
        published.avatar = this.avatar;
        published.body = text;
        this.store.cacheConfirmedReply(reply, published).catch(() => this.observe('reply-cache-write-failed'));
        if (this.surface === Surface.Detail && !this.posts.some((post: Post) => post.id === published.id)) {
          this.posts = [published, ...this.posts];
          const inline = this.inlineState(reply.id);
          if (inline?.expanded) this.setInline(reply.id, [published, ...inline.replies], false, inline.finished);
        }
      }
      if (item) {
        this.chatScrollAfterSend = true;
        const sent = this.chatPending.find((row: InboxRow) => row.id === pendingId);
        if (sent) {
          const confirmed = new InboxRow();
          confirmed.id = sent.id;
          confirmed.path = sent.path;
          confirmed.kind = 'sent';
          confirmed.text = sent.text;
          confirmed.outgoing = true;
          this.chatPending = this.chatPending.map((row: InboxRow) => row.id === pendingId ? confirmed : row);
          this.prunePendingChat(item);
          // If X's list never shows it (for example the text was reformatted), stop showing the local copy.
          setTimeout(() => this.dropPendingChat(pendingId), 15000);
        }
        this.readChat(true);
      } else {
        if (!reply) this.resetPostDraft();
        this.closePostComposer();
        if (reply && this.surface === Surface.Detail) this.refreshFeed();
        this.getUIContext().getPromptAction().showToast({ message: ui('帖子已发布', this.locale) });
      }
      return;
    }
    if (!chat) {
      this.postMediaBridge.clear();
      this.reloadPostComposer = !!reply || !this.postGif;
    }
    if (pendingId) {
      this.dropPendingChat(pendingId);
      if (!this.chatDraft && !mayHaveSubmitted) this.chatDraft = text;
    }
    this.composerFeedback = ui(mayHaveSubmitted ? 'X 未确认提交结果，请核对后再重试。' :
      result === 'draft-conflict' ? (reply ? '无法确认回复编辑框，请关闭后重试。' : 'X 里已有另一份草稿。') :
        result === 'attachment-failed' ? '附件读取失败，请重新选择后重试。' : 'X 暂时无法提交，请稍后重试。', this.locale);
  }

  private showChatWeb(): void {
    if (this.surface !== Surface.Chat || this.session !== Session.Active) return;
    this.chatUnlockOffered = true;
    this.chatWebVisible = true;
    const target = chatConversationUrl(this.chatItem?.path || '') || this.route.url();
    if (!this.chatEngine) {
      this.ensureChatEngine(target);
      return;
    }
    let current = '';
    try { current = this.chatEngine.controller.getUrl(); } catch (_) {}
    if (!isXChatUrl(current)) this.loadChatEngine(target);
  }

  private retryInbox(): void {
    this.chatHostTried = false;
    this.inboxAdvanceAt = 0;
    this.inboxAdvancedCount = -1;
    this.deadline = Date.now() + WAIT_MS;
    if (!(this.surface === Surface.Chat ? this.conversations : this.notifications).length) this.content = Content.Loading;
    if (this.surface === Surface.Notifications) this.loadNotificationCategory(true);
    else {
      this.ensureChatEngine(this.route.url(), true);
      this.resumePolling();
    }
  }

  private openNotification(item: InboxRow): void {
    const post = this.notificationPost(item);
    if (post) {
      this.openPost(this.notificationPosts.get(post.id) || post, item.path);
    } else if (/^\/[A-Za-z0-9_]{1,15}$/.test(item.path)) {
      this.openProfile(item.path.slice(1));
    }
  }

  private notificationPost(row: InboxRow): Post | null {
    const match = /^\/(?:([A-Za-z0-9_]{1,15})|i\/web)\/status\/(\d{1,24})$/.exec(row.path);
    if (!match) return null;
    const post = new Post();
    post.id = match[2];
    post.handle = match[1] || 'i';
    return post;
  }

  private rememberNotificationPosts(posts: Post[]): void {
    if (!posts.length) return;
    const known = new Map(this.notificationPosts);
    for (const post of posts) {
      known.delete(post.id);
      known.set(post.id, post);
    }
    while (known.size > 64) {
      const oldest = known.keys().next();
      if (oldest.done) break;
      known.delete(oldest.value);
    }
    this.notificationPosts = known;
    this.queueTranslations(posts);
    this.mediaLookahead.prepare(posts, this.imageQuality);
  }

  private async warmNotifications(): Promise<void> {
    const owner = this.verifiedReaderAccount;
    const active = (): boolean => !!owner && owner === this.verifiedReaderAccount && this.foreground &&
      this.session === Session.Active && (this.homeIsVisible() || this.surface === Surface.Notifications) &&
      !this.drawerOpen && !this.webUrl && !this.settingsOpen && !this.playerPost && !this.fullPhotos.length &&
      !this.homeRefreshRequested && !this.routeRefreshRequested;
    if (!active() || this.notificationSelecting || this.readerProbe || this.libraryProbe || this.librarySelecting) return;
    this.notificationSelecting = true;
    try {
      if (this.homeIsVisible() && Date.now() - this.notificationReadAt >= HOME_CHECK_MS) {
        this.notificationReadAt = Date.now();
        const cached = await this.store.readInbox('v2:notifications').catch(() => null);
        if (!active()) return;
        if (this.homeIsVisible() && cached && (this.notificationPath !== '/notifications' || !this.notifications.length)) {
          this.notificationPath = '/notifications';
          this.notifications = cached.rows;
        }
        if (this.homeIsVisible() && !this.readerProbe && !this.translationProbe &&
          !this.librarySelecting && !this.libraryProbe) {
          this.readerProbe = new ReaderProbe(new XRoute(Surface.Notifications, '/notifications'));
          return;
        }
      }
      const start = Math.max(0, this.notificationEnd - 4);
      const pending = this.notifications.slice(start, this.notificationEnd + 6)
        .filter((row: InboxRow) => !this.notificationPosts.has(row.path.split('/').pop() || ''));
      const missing: InboxRow[] = [];
      const loaded: Post[] = [];
      for (const row of pending) {
        const post = this.notificationPost(row);
        if (!post || Date.now() - (this.notificationAttempts.get(post.id) || 0) < 120000) continue;
        const cached = await this.store.readPost(post.id).catch(() => undefined);
        if (!active()) return;
        if (cached && (cached.body || cached.photos.length || cached.video || cached.articleTitle)) loaded.push(cached);
        else missing.push(row);
      }
      this.rememberNotificationPosts(loaded);
      if (!missing.length || !active() || this.readerProbe || this.libraryProbe || this.translationProbe) return;
      const row = missing[0];
      const post = this.notificationPost(row);
      if (!post) return;
      this.recordPreviewAttempt(this.notificationAttempts, post.id);
      this.readerProbe = new ReaderProbe(new XRoute(Surface.Detail, row.path, '', 0, post.id), post, [],
        true, false, false, 0, true);
    } finally {
      this.notificationSelecting = false;
    }
  }

  private advanceInbox(): void {
    if (!(this.surface === Surface.Chat ? this.chatEngineUsable() : this.ready) || !this.foreground || this.webUrl || this.chatItem || this.chatLocked) return;
    const count = this.surface === Surface.Chat ? this.conversations.length : this.notifications.length;
    if (count >= 160 || count === this.inboxAdvancedCount || Date.now() - this.inboxAdvanceAt < 3000) return;
    this.inboxAdvancedCount = count;
    this.inboxAdvanceAt = Date.now();
    this.advanceInboxWeb(false);
  }

  private advanceMessages(): void {
    if (!this.chatEngineUsable() || !this.foreground || this.webUrl || !this.chatItem || this.chatLocked ||
      this.chatMessages.length >= 160 || this.chatMessages.length === this.messageAdvancedCount ||
      Date.now() - this.messageAdvanceAt < 3000) return;
    this.messageAdvancedCount = this.chatMessages.length;
    this.messageAdvanceAt = Date.now();
    this.advanceInboxWeb(true);
  }

  private advanceInboxWeb(older: boolean): void {
    const selector = older ? '[role="log"], [data-message-id], [data-testid="messageEntry"]' :
      this.surface === Surface.Chat ? '[role="option"], [data-conversation-id]' :
        '[data-testid="notification"], [data-testid="cellInnerDiv"], article';
    const js = '(() => { if (location.origin !== "https://x.com" && location.origin !== "https://chat.x.com") return; ' +
      'const root = document.querySelector(' +
      JSON.stringify(selector) + '); let scroller = root; while (scroller && ' +
      '!(/auto|scroll/.test(getComputedStyle(scroller).overflowY) && scroller.scrollHeight > scroller.clientHeight)) ' +
      'scroller = scroller.parentElement; scroller = scroller || document.scrollingElement; ' +
      'scroller?.scrollBy(0, ' + (older ? '-' : '') + 'Math.max(300, scroller.clientHeight * .9)); })()';
    const controller = this.surface === Surface.Chat ? this.chatEngine?.controller : this.controller;
    controller?.runJavaScript(js).catch(() => {});
  }

  private async restoreStoredHome(route: XRoute): Promise<void> {
    const tab = route.homeTab;
    const position = this.reset.readHomePosition(tab);
    const knownAccount = this.handle || this.reset.knownAccount();
    if (knownAccount) this.store.setAccount(knownAccount);
    const preloadInbox = this.session === Session.Starting && validHandle(knownAccount);
    const savedChats = preloadInbox ? this.store.readInbox('chats').catch(() => null) : Promise.resolve(null);
    const savedNotifications = preloadInbox ? this.store.readInbox('v2:notifications').catch(() => null) : Promise.resolve(null);
    let saved = await this.store.readHome(tab, position?.postId || '').catch(() => undefined);
    const chats = await savedChats;
    const notifications = await savedNotifications;
    if (this.route !== route || !this.sessionKnown || this.homeLoaded[tab]) return;
    if (chats && !this.conversations.length) this.conversations = chats.rows;
    if (notifications && !this.notifications.length) this.notifications = notifications.rows;
    if (chats) hilog.info(0x0000, 'QwitterReader', 'chats restored from RDB, rows %{public}d', chats.rows.length);
    this.homeRestoredFromDb[tab] = !!saved;
    if (!saved) {
      const legacy = this.reset.readHome(tab);
      if (legacy?.ownHandle && (legacy.homeTab < 0 || legacy.homeTab === tab) &&
        (!knownAccount || legacy.ownHandle.toLowerCase() === knownAccount.toLowerCase())) {
        saved = legacy;
        this.legacyHomePending[tab] = true;
      }
    }
    if (!saved?.ownHandle || (this.handle && saved.ownHandle.toLowerCase() !== this.handle.toLowerCase())) return;
    this.posts = saved.posts;
    this.rememberAvatars(this.posts);
    if (!this.handle) this.handle = saved.ownHandle;
    if (!this.avatar) this.avatar = saved.ownAvatar;
    if (!this.accountName) this.accountName = saved.ownName;
    if (tab === 0) this.recommendedPosts = this.posts;
    else this.followingPosts = this.posts;
    if (position && this.posts.some((post: Post) => post.id === position.postId)) {
      this.pendingHomePosition[tab] = position;
      this.homeHeaderPositions[tab] = position.headerHidden;
      this.homeHeaderHidden = position.headerHidden;
    }
    this.markHomeLoaded();
    this.lastHomeCheck[tab] = Date.now();
    if (this.verifiedReaderAccount) this.restoreNewHomeNotice(tab);
    this.showingSavedHome = this.session === Session.Starting;
    if (this.showingSavedHome && knownAccount && validHandle(knownAccount) &&
      saved.ownHandle.toLowerCase() === knownAccount.toLowerCase()) {
      // The cached account can browse while ArkWeb verifies its persisted session.
      this.session = Session.Active;
      this.observe('cached-reader-interactive');
    }
    if (this.session === Session.Active) this.content = Content.Ready;
    this.restoreHomePosition();
    this.observe('home-cache-restored');
  }

  private async restoreStoredThread(route: XRoute): Promise<void> {
    const saved = await this.store.readThread(route.postId).catch(() => undefined);
    if (!saved || this.route !== route || this.session !== Session.Active || this.posts.length ||
      (this.content !== Content.Loading && this.content !== Content.Failed)) return;
    const post = saved.posts.find((item: Post) => item.id === route.postId);
    if (!post) return;
    if (!this.detailConfirmed) this.detailPost = post;
    this.posts = saved.posts.filter((item: Post) => item.id !== route.postId);
    this.queueTranslations(saved.posts, true);
    this.content = this.posts.length ? Content.Ready : Content.Empty;
    this.observe('thread-cache-restored');
  }

  private async restoreStoredPost(route: XRoute): Promise<void> {
    const post = await this.store.readPost(route.postId).catch(() => undefined);
    if (post && this.route === route && this.session === Session.Active && !this.detailConfirmed &&
      this.detailPost?.id === post.id) this.detailPost = post;
  }

  private async openStoredRoute(route: XRoute): Promise<void> {
    const locale = this.locale;
    const handle = route.surface === Surface.Profile ? route.path.split('/')[1] : '';
    const ownLibrary = this.store.isOwnProfileLibraryTab(route);
    const timelineRead = this.store.readRoute(route, locale).catch(() => undefined);
    const profileRead = this.store.readProfile(locale, handle).catch(() => null);
    let saved = await timelineRead;
    const cachedProfile = await profileRead;
    const pending = this.libraryProbe;
    if (!saved && ownLibrary && pending?.route.path.toLowerCase() === route.path.toLowerCase()) {
      const until = Date.now() + 4000;
      while (this.libraryProbe === pending && this.route === route && this.foreground && Date.now() < until) {
        await this.waitForWeb(160);
      }
      if (this.route === route) {
        saved = await this.store.readRoute(route, locale).catch(() => undefined);
        if (!saved && this.route === route && this.libraryProbe === pending) {
          this.libraryProbe = null;
          try { pending.controller.stop(); } catch (_) {}
        }
      }
    }
    if (this.route !== route || this.session !== Session.Active) return;
    if (this.locale !== locale) {
      this.load(route.url());
      return;
    }
    const profile = cachedProfile || saved?.profile;
    if (profile && (!this.profile?.name || this.profile.handle.toLowerCase() === profile.handle.toLowerCase())) {
      this.profile = this.mergeProfile(profile);
    }
    if (saved?.posts.length || saved?.empty || (route.searchMode === 'people' && saved?.discovery.length)) {
      this.posts = saved.posts;
      if (route.surface === Surface.Search && route.searchMode === 'people') {
        this.searchPeople = saved.discovery.filter((section: DiscoverySection) => section.kind === 'people')
          .flatMap((section: DiscoverySection) => section.rows);
      }
      this.queueTranslations(this.feedPosts(-1), true);
      this.rememberAvatars(this.posts);
      this.content = this.feedItemCount() ? Content.Ready : Content.Empty;
      this.observe('page-cache-restored');
      if (handle) hilog.info(0x0000, 'QwitterProfile', 'profile timeline restored from local store');
      if (route.surface === Surface.Search && route.query) {
        this.routeRefreshRequested = true;
      } else if (ownLibrary || Date.now() - saved.cachedAt < 180000) {
        this.routeCachedOnly = true;
        this.resumePolling();
        return;
      }
    }
    if (handle && !saved?.posts.length && !saved?.empty) {
      hilog.info(0x0000, 'QwitterProfile', 'no cached timeline for requested profile tab');
    }
    this.load(route.url());
  }

  private isLocalBrowsing(route: XRoute): boolean {
    return route.surface === Surface.Bookmarks && route.path === LOCAL_BROWSING_PATH;
  }

  private async showLocalBrowsing(route: XRoute): Promise<void> {
    const posts = this.verifiedReaderAccount ? await this.store.readBrowsing().catch((): Post[] => []) : [];
    if (this.route !== route) return;
    this.posts = posts;
    this.rememberAvatars(posts);
    this.queueTranslations(this.feedPosts(-1), true);
    this.content = posts.length ? Content.Ready : Content.Empty;
    this.refreshing = false;
    this.routeRefreshRequested = false;
  }

  private recordBrowsing(post: Post): void {
    if (!this.verifiedReaderAccount || !validHandle(post.handle) || !/^\d{1,24}$/.test(post.id)) return;
    this.store.recordBrowsing(post).catch(() => this.observe('browsing-history-write-failed'));
  }

  private updateBrowsing(post: Post): void {
    if (!this.verifiedReaderAccount || !validHandle(post.handle) || !/^\d{1,24}$/.test(post.id)) return;
    this.store.updateBrowsing(post).catch(() => this.observe('browsing-history-write-failed'));
  }

  private confirmClearBrowsing(): void {
    this.getUIContext().showAlertDialog({
      title: ui('清除浏览记录？', this.locale),
      message: ui('只会删除 Qwitter 在此设备上为当前账号保存的浏览记录，不影响 X 上的喜欢和书签。', this.locale),
      primaryButton: { value: ui('取消', this.locale), action: () => {} },
      secondaryButton: {
        value: ui('清除', this.locale), action: () => {
          const route = this.route;
          this.store.clearBrowsing().catch(() => {}).finally(() => {
            if (this.route === route && this.isLocalBrowsing(route)) this.showLocalBrowsing(route);
          });
        }
      }
    });
  }

  // Tabs for the native History page: what X shows for this account, or Bookmarks and Likes until that is known,
  // followed by the local browsing history.
  private historyTabs(): PageTab[] {
    // X labels its tabs in the X account's language; show known sections in the app's language instead.
    const tabs: PageTab[] = this.historyTabsFromX.filter((tab: PageTab) => !!tab.path).map((tab: PageTab): PageTab => {
      const path = tab.path.toLowerCase();
      const known = path === HISTORY_PATH || path.endsWith('/bookmarks') ? '书签' : path.endsWith('/likes') ? '喜欢' :
        path.endsWith('/videos') ? '视频' : path.endsWith('/articles') ? '文章' : '';
      if (!known) return tab;
      const localized = new PageTab();
      localized.label = ui(known, this.locale);
      localized.path = tab.path;
      localized.selected = tab.selected;
      return localized;
    });
    if (!tabs.length) {
      const bookmarks = new PageTab();
      bookmarks.label = ui('书签', this.locale);
      bookmarks.path = '/i/bookmarks';
      tabs.push(bookmarks);
      if (validHandle(this.handle)) {
        const likes = new PageTab();
        likes.label = ui('喜欢', this.locale);
        likes.path = '/' + this.handle + '/likes';
        tabs.push(likes);
      }
    }
    const local = new PageTab();
    local.label = ui('浏览记录', this.locale);
    local.path = LOCAL_BROWSING_PATH;
    tabs.push(local);
    return tabs;
  }

  private historyTabActive(tab: PageTab): boolean {
    const current = this.libraryPath.toLowerCase();
    if (current === HISTORY_PATH) return tab.selected;
    return current === tab.path.toLowerCase();
  }

  private selectHistoryTab(tab: PageTab): void {
    if (this.surface !== Surface.Bookmarks || this.libraryPath.toLowerCase() === tab.path.toLowerCase()) return;
    this.navigate(new XRoute(Surface.Bookmarks, tab.path));
  }

  private openHistory(): void {
    if (this.session !== Session.Active) return;
    this.showDrawer(false);
    this.rememberHomePosition();
    this.webUrl = '';
    if (this.surface !== Surface.Bookmarks) this.trail.push(this.route);
    this.navigate(new XRoute(Surface.Bookmarks, HISTORY_PATH));
  }

  // Keeps X's History tabs for the native tab row, and logs History and own-profile tabs so changes in X's layout
  // show up in device logs.
  private notePageTabs(tabs: PageTab[], history: boolean, probe: string): void {
    const summary = probe + ' :: ' +
      tabs.map((tab: PageTab) => tab.label + '=' + (tab.path || '-') + (tab.selected ? '*' : '')).join(' | ');
    if (summary !== this.loggedPageTabs) {
      this.loggedPageTabs = summary;
      hilog.info(0x0000, 'QwitterTabs', '%{public}s', summary);
    }
    if (history && tabs.some((tab: PageTab) => !!tab.path) &&
      JSON.stringify(tabs) !== JSON.stringify(this.historyTabsFromX)) {
      this.historyTabsFromX = tabs;
    }
  }

  private loggedLibrary: string = '';

  private logLibrary(message: string): void {
    if (message === this.loggedLibrary) return;
    this.loggedLibrary = message;
    hilog.info(0x0000, 'QwitterTabs', '%{public}s', message);
  }

  private libraryRedirectMatches(route: string, page: string, tabs: PageTab[]): boolean {
    if (route === page) return true;
    const inLibrary = (value: string): boolean =>
      /^\/i\/(?:history|bookmarks)(?:\/|$)/.test(value) || /^\/[a-z0-9_]{1,15}\/likes$/.test(value);
    if (route === LOCAL_BROWSING_PATH || !inLibrary(route) || !inLibrary(page)) return false;
    const wantsLikes = route.endsWith('/likes');
    const wantsBookmarks = route === '/i/bookmarks' || route.endsWith('/bookmarks');
    const selected = tabs.find((tab: PageTab) => tab.selected);
    if (selected) {
      if (route === HISTORY_PATH || (!!selected.path && selected.path.toLowerCase() === route)) return true;
      if (wantsLikes) return /like|喜欢|喜歡|讚/i.test(selected.label);
      if (wantsBookmarks) return /bookmark|书签|書籤/i.test(selected.label);
      return false;
    }
    if (route === HISTORY_PATH) return true;
    if (wantsLikes) return page.endsWith('/likes');
    if (wantsBookmarks) return page === HISTORY_PATH || page.endsWith('/bookmarks');
    return false;
  }

  private saveRouteCache(empty: boolean = false): void {
    if (this.isLocalBrowsing(this.route)) return;
    if (!this.verifiedReaderAccount || (empty && this.routeCachedEmpty)) return;
    if (empty) this.routeCachedEmpty = true;
    this.store.saveRoute(this.route, this.locale, this.posts, this.profile, empty,
      this.surface === Surface.Search && this.searchMode === 'people' ?
        [{ kind: 'people', title: '', rows: this.searchPeople }] : [])
      .catch(() => this.observe('page-cache-write-failed'));
  }

  private rememberThread(): void {
    if (this.session !== Session.Active || this.surface !== Surface.Detail || !this.detailPost) return;
    const id = this.route.postId;
    let offset = this.threadCache.get(id)?.offset || 0;
    try {
      offset = this.detailScroller.currentOffset().yOffset;
    } catch (_) {
      // A detail page can be replaced before its list attaches.
    }
    this.threadCache.delete(id);
    this.threadCache.set(id, {
      post: this.detailPost,
      replies: this.posts,
      content: this.posts.length ? Content.Ready : this.content === Content.Empty ? Content.Empty : Content.Loading,
      offset
    });
    if (this.threadCache.size > THREAD_CACHE_LIMIT) {
      const oldest = this.threadCache.keys().next();
      if (!oldest.done) this.threadCache.delete(oldest.value);
    }
  }

  private threadReplies(postId: string): Post[] {
    const parents = new Set<string>([postId]);
    return this.posts.filter((post: Post) => {
      if (post.id === postId || !parents.has(post.replyToId)) return false;
      parents.add(post.id);
      return true;
    });
  }

  private refreshFeed(atEnd: boolean = false, allowStaged: boolean = true): void {
    if (this.isLocalBrowsing(this.route)) {
      this.showLocalBrowsing(this.route);
      return;
    }
    const isHome = this.surface === Surface.Home;
    if (!atEnd) this.recoveringHomePagination = false;
    const route = isHome ? new XRoute(Surface.Home, '/home', '', this.homeTab) : this.route;
    if (isHome && this.session === Session.Starting) {
      this.start();
      return;
    }
    if (isHome && (this.homeRefreshRequested || this.session !== Session.Active)) return;
    if (this.session === Session.Active && (this.feedItemCount() || this.detailPost || this.content === Content.Empty)) {
      if (this.routeRefreshRequested || this.homeRefreshRequested) return;
      this.cancelProbe();
      this.homeRefreshRequested = isHome;
      this.homeRefreshStartedAt = isHome ? Date.now() : 0;
      this.routeRefreshRequested = !isHome;
      this.routeCachedEmpty = false;
      this.routeCachedOnly = false;
      this.routeNeedsPaging = false;
      this.refreshing = true;
      this.paging = false;
      this.pageNote = '';
      this.detailConfirmed = false;
      this.profileRetried = false;
      this.profileWakeUsed = false;
      if (isHome) {
        this.homeWebPaged = false;
        this.libraryProbe = null;
        this.translationProbe = null;
        this.mediaLookahead.stop();
        this.mediaLookaheadKey = '';
        if (!atEnd) this.scrollHomeToTop();
      }
      this.deadline = Date.now() + (this.surface === Surface.Profile ? PROFILE_WAIT_MS : WAIT_MS);
      if (isHome && allowStaged) this.refreshHomeFromStage(this.route, route.url());
      else this.load(route.url());
      return;
    }
    this.navigate(route, this.detailPost, false, isHome);
  }

  private async refreshHomeFromStage(route: XRoute, address: string): Promise<void> {
    const epoch = this.epoch;
    const tab = this.homeTab;
    this.homeStagePending = true;
    try {
      const staged = await this.store.readHomeUpdates(tab, HOME_STAGE_MAX_AGE);
      if (this.route !== route || this.epoch !== epoch || !this.homeRefreshRequested) return;
      if (this.homeOrderChanged(tab, staged)) {
        await this.replaceHomeFromX(staged, true);
        if (!this.homeRefreshRequested) return;
      }
    } catch (_) {
      this.observe('home-staged-refresh-failed');
    } finally {
      if (this.route === route && this.epoch === epoch) this.homeStagePending = false;
    }
    if (this.route === route && this.epoch === epoch && this.homeRefreshRequested) this.load(address);
  }

  private rememberHomePosition(fromScroll: boolean = false): void {
    if (!this.homeIsVisible() || this.session !== Session.Active || this.showingSavedHome ||
      this.homeRefreshRequested || !this.homeLoaded[this.homeTab] || this.pendingHomePosition[this.homeTab]) return;
    const tab = this.homeTab;
    const index = this.homeFirstVisible[tab];
    if (index < 0) return;
    try {
      const scroller = this.homeScrollers[tab];
      const offset = scroller.currentOffset().yOffset;
      if (!Number.isFinite(offset)) return;
      if (offset <= 0 && !fromScroll && this.homeAnchors[tab]) return;
      const rect = scroller.getItemRect(index);
      if (rect.height <= 0) return;
      const position = new HomePosition();
      if (index > 0) {
        const post = this.timelinePosts(tab)[index - 1];
        if (!post) return;
        position.postId = post.id;
        position.offset = -rect.y;
        position.headerHidden = this.homeHeaderHidden;
      }
      this.homeHeaderPositions[tab] = this.homeHeaderHidden;
      this.homeAnchors[tab] = position.postId ? position : undefined;
      this.saveHomePosition(tab, position);
    } catch (_) {}
  }

  private saveHomePosition(tab: number, position: HomePosition): void {
    this.reset.saveHomePosition(tab, position).catch(() => this.observe('home-position-write-failed'));
  }

  private restoreHomePosition(): void {
    const route = this.route;
    const tab = this.homeTab;
    this.getUIContext().postFrameCallback(new RestoreThreadScroll(() => {
      if (route !== this.route || !this.homeIsVisible() || this.homeTab !== tab) return;
      const position = this.pendingHomePosition[tab];
      const scroller = this.homeScrollers[tab];
      if (position) {
        const index = this.timelinePosts(tab).findIndex((post: Post) => post.id === position.postId);
        if (index >= 0) {
          this.pendingHomePosition[tab] = position;
          this.homeAnchors[tab] = position;
          scroller.scrollToIndex(index + 1, false, ScrollAlign.START, { extraOffset: LengthMetrics.vp(position.offset) });
          this.getUIContext().postFrameCallback(new RestoreThreadScroll(() => {
            if (this.route !== route || this.pendingHomePosition[tab] !== position) return;
            this.pendingHomePosition[tab] = undefined;
            try {
              const rect = scroller.getItemRect(index + 1);
              const delta = rect.y + position.offset;
              if (rect.height > 0 && Math.abs(delta) >= 1) scroller.scrollBy(0, delta);
            } catch (_) {}
          }));
        } else {
          this.pendingHomePosition[tab] = undefined;
        }
      }
      this.homeHeaderHidden = this.homeHeaderPositions[tab];
    }));
  }

  private homeIsVisible(): boolean {
    return this.surface === Surface.Home && this.navIndex === 0 && !this.webUrl && !this.settingsOpen;
  }

  private markHomeLoaded(tab: number = this.homeTab): void {
    this.homeLoaded[tab] = true;
  }

  private hasNewHomePosts(tab: number): boolean {
    return tab === 0 ? this.recommendedHasNew : this.followingHasNew;
  }

  private setNewHomePosts(tab: number, value: boolean): void {
    if (tab === 0) this.recommendedHasNew = value;
    else this.followingHasNew = value;
  }

  private async observeHomePosts(tab: number, incoming: Post[]): Promise<void> {
    const owner = this.verifiedReaderAccount;
    if (!owner || !this.homeLoaded[tab] || this.stagingHome[tab] || this.applyingHome[tab] ||
      this.homeRefreshRequested) return;
    if (!this.homeOrderChanged(tab, incoming)) return;
    this.stagingHome[tab] = true;
    try {
      if (await this.store.stageHomeUpdates(tab, incoming) && owner === this.verifiedReaderAccount) {
        this.setNewHomePosts(tab, true);
        this.queueTranslations(incoming);
      }
    } catch (_) {
      this.observe('new-home-cache-write-failed');
    } finally {
      if (owner === this.verifiedReaderAccount) this.stagingHome[tab] = false;
    }
  }

  private async restoreNewHomeNotice(tab: number): Promise<void> {
    const owner = this.verifiedReaderAccount;
    if (!owner || this.applyingHome[tab] || this.stagingHome[tab]) return;
    const staged = await this.store.readHomeUpdates(tab).catch((): Post[] => []);
    if (owner !== this.verifiedReaderAccount || this.applyingHome[tab] || this.stagingHome[tab]) return;
    this.setNewHomePosts(tab, this.homeOrderChanged(tab, staged));
  }

  private homeOrderChanged(tab: number, incoming: Post[]): boolean {
    const existing = this.timelinePosts(tab);
    return incoming.slice(0, 12).some((post: Post, index: number) => post.id !== existing[index]?.id);
  }

  private async replaceHomeFromX(incoming: Post[], fromStage: boolean = false): Promise<void> {
    const owner = this.verifiedReaderAccount;
    const generation = this.epoch;
    const tab = this.homeTab;
    if (!owner) return;
    this.applyingHome[tab] = true;
    try {
      const recovering = this.recoveringHomePagination && !fromStage;
      const posts = recovering ? [...this.timelinePosts(tab)] : incoming.slice(0, PAGE_LIMIT);
      if (recovering) {
        const known = new Set(posts.map((post: Post) => post.id));
        for (const post of incoming) {
          if (posts.length >= PAGE_LIMIT) break;
          if (!known.has(post.id)) {
            known.add(post.id);
            posts.push(post);
          }
        }
      }
      this.rememberAvatars(posts);
      const saved = await this.store.saveHome(tab, this.accountName, this.avatar, posts, 0, true);
      if (!saved || owner !== this.verifiedReaderAccount || generation !== this.epoch) return;
      this.homeNeedsPageSource = fromStage;
      if (!recovering) this.homeSnapshotRevision[tab]++;
      this.posts = posts;
      if (tab === 0) {
        this.recommendedHighQuality = INITIAL_HIGH_QUALITY_POSTS;
        this.recommendedPosts = posts;
      } else {
        this.followingHighQuality = INITIAL_HIGH_QUALITY_POSTS;
        this.followingPosts = posts;
      }
      this.markHomeLoaded(tab);
      this.setNewHomePosts(tab, false);
      if (!recovering) this.homeLastVisible[tab] = 0;
      this.homePrefetchAt[tab] = -1;
      this.lastHomeCheck[tab] = Date.now();
      this.mediaLookaheadKey = '';
      this.paging = false;
      this.content = posts.length ? Content.Ready : Content.Empty;
      this.showingSavedHome = false;
      this.homeRefreshRequested = false;
      this.refreshing = false;
      this.recoveringHomePagination = false;
      if (recovering) this.nextPage();
      else this.scrollHomeToTop();
      if (this.homeRefreshStartedAt) {
        hilog.info(0x0000, 'QyxSession', 'home refresh %{public}s %{public}d ms', fromStage ? 'staged' : 'web',
          Date.now() - this.homeRefreshStartedAt);
        this.homeRefreshStartedAt = 0;
      }
      this.observe('home-order-replaced');
    } finally {
      if (owner === this.verifiedReaderAccount) this.applyingHome[tab] = false;
    }
  }

  private rememberAvatars(posts: Post[]): void {
    for (const post of posts) {
      const handle = post.handle.toLowerCase();
      if (post.avatar) this.authorAvatars.set(handle, post.avatar);
      const quote = post.quotedPost;
      if (quote?.avatar && quote.handle) this.authorAvatars.set(quote.handle.toLowerCase(), quote.avatar);
    }
    if (this.authorAvatars.size > 1500) {
      const oldest = this.authorAvatars.keys().next();
      if (!oldest.done) this.authorAvatars.delete(oldest.value);
    }
    for (const post of posts) this.fillAvatar(post);
  }

  private fillAvatar(post: Post): boolean {
    let changed = false;
    if (!post.avatar) {
      post.avatar = this.authorAvatars.get(post.handle.toLowerCase()) || '';
      changed = !!post.avatar;
    }
    const quote = post.quotedPost;
    if (quote && !quote.avatar && quote.handle) {
      quote.avatar = this.authorAvatars.get(quote.handle.toLowerCase()) || '';
      changed = changed || !!quote.avatar;
    }
    return changed;
  }

  private homeTabClicked(index: number): void {
    if (index !== 0 || !this.homeIsVisible() || this.session !== Session.Active || this.drawerOpen) {
      this.lastHomeTap = 0;
      this.changeTab(index);
      return;
    }
    const now = Date.now();
    if (now - this.lastHomeTap <= HOME_DOUBLE_TAP_MS) {
      this.lastHomeTap = 0;
      this.scrollHomeToTop();
    } else {
      this.lastHomeTap = now;
    }
  }

  private scrollHomeToTop(): void {
    const tab = this.homeTab;
    this.homeAnchors[tab] = undefined;
    this.homeHeaderPositions[tab] = false;
    this.homeScrollDelta = 0;
    this.homeScrolled = false;
    this.homeHeaderHidden = false;
    this.pendingHomePosition[tab] = undefined;
    this.saveHomePosition(tab, new HomePosition());
    this.homeScrollers[tab].scrollEdge(Edge.Top);
  }

  private maybeCheckHome(): void {
    if (this.readerProbe || !this.homeIsVisible() || this.drawerOpen || this.fullPhotos.length || this.playerPost ||
      this.session !== Session.Active || (this.content !== Content.Ready && this.content !== Content.Empty) ||
      this.homeRefreshRequested || this.paging || !this.homeLoaded[this.homeTab] ||
      this.translationProbe || this.libraryProbe) return;
    const now = Date.now();
    if (now - this.lastHomeCheck[this.homeTab] < HOME_CHECK_MS) return;
    this.lastHomeCheck[this.homeTab] = now;
    this.readerProbe = new ReaderProbe(new XRoute(Surface.Home, '/home', '', this.homeTab));
  }

  private maybePrefetchHome(): void {
    const tab = this.homeTab;
    const count = this.timelinePosts(tab).length;
    if (!this.homeIsVisible() || !this.foreground || this.session !== Session.Active || !this.ready ||
      !this.homeDocumentConfirmed || !this.homeLoaded[tab] || this.drawerOpen || this.playerPost || this.fullPhotos.length ||
      this.showingSavedHome || this.homeRefreshRequested || this.paging || this.content !== Content.Ready ||
      !count || count >= PAGE_LIMIT || this.homePrefetchAt[tab] === count ||
      (count >= 24 && this.homeLastVisible[tab] < count - MEDIA_LOOKAHEAD)) return;
    this.homePrefetchAt[tab] = count;
    this.nextPage();
  }

  private maybePrefetchRoute(): void {
    const count = this.feedItemCount();
    if (this.surface === Surface.Home || (this.surface === Surface.Search && !this.route.query) ||
      !this.foreground || this.session !== Session.Active || this.settingsOpen || this.drawerOpen || this.webUrl ||
      this.playerPost || this.fullPhotos.length || this.paging || this.routeNeedsPaging ||
      this.routeRefreshRequested || this.detailCachedOnly || this.content !== Content.Ready ||
      (!this.ready && !this.routeCachedOnly) || !count || count >= PAGE_LIMIT ||
      this.routePrefetchAt === count || (!this.routeScrolled && this.routeCachedOnly)) return;
    const visibleCount = this.surface === Surface.Detail ? this.replyGroups().length : this.feedItemCount();
    if (this.routeLastVisible < visibleCount - MEDIA_LOOKAHEAD) return;
    this.routePrefetchAt = count;
    this.nextPage();
  }

  private prepareUpcomingMedia(end: number = this.homeLastVisible[this.homeTab]): void {
    const home = this.surface === Surface.Home;
    if (!this.foreground || (home && (!this.homeIsVisible() || this.homeRefreshRequested)) || this.settingsOpen || this.webUrl ||
      this.session !== Session.Active || this.drawerOpen ||
      this.playerPost || this.fullPhotos.length) return;
    const first = Math.max(0, end + (home ? 0 : 1));
    const posts = (home ? this.timelinePosts(this.homeTab) : this.feedPosts(-1)).slice(first, first + MEDIA_LOOKAHEAD);
    if (!posts.length) return;
    const key = this.route.url() + ':' + this.homeTab.toString() + ':' + this.imageQuality +
      ':' + posts.map((post: Post) => post.id).join(',');
    if (key === this.mediaLookaheadKey) return;
    this.mediaLookaheadKey = key;
    this.mediaLookahead.prepare(posts, this.imageQuality);
    this.queueTranslations(posts);
  }

  private async warmPostPreviews(): Promise<void> {
    if (!this.canPreviewComments() || this.readerProbe || this.previewSelecting || this.libraryProbe ||
      this.librarySelecting || this.warmupPost || Date.now() < this.previewNextAt) return;
    this.previewNextAt = Date.now() + POST_PREVIEW_INTERVAL;
    const route = this.route;
    const tab = this.homeTab;
    const player = this.playerPost;
    const playingIndex = player ? this.videoFeed.findIndex((item: Post) => item.id === player.id) : -1;
    const home = this.surface === Surface.Home;
    const first = Math.max(0, home ? this.homeFirstVisible[tab] - 1 : this.routeFirstVisible);
    const last = Math.max(first + 1, home ? this.homeLastVisible[tab] : this.routeLastVisible + 1);
    const candidates = player ? [player, ...this.videoFeed.slice(playingIndex + 1, playingIndex + 3)] :
      this.surface === Surface.Detail ? (this.detailPost ? [this.detailPost] : []) :
        (home ? this.timelinePosts(tab) : this.feedPosts(-1)).slice(first, last + MEDIA_LOOKAHEAD);
    this.previewSelecting = true;
    try {
      for (const candidate of candidates) {
        if (this.route !== route || this.playerPost?.id !== player?.id ||
          !this.canPreviewComments() || this.readerProbe) return;
        const outer = this.previewPosts.get(candidate.id) || candidate;
        if (outer.quote && Date.now() - (this.quoteAttempts.get(outer.id) || 0) >= 120000) {
          this.recordPreviewAttempt(this.quoteAttempts, outer.id);
          const quote = outer.quotedPost || new QuotedPost();
          const path = await this.findQuotePath(outer.id, quote);
          if (this.route !== route || this.playerPost?.id !== player?.id ||
            !this.canPreviewComments() || this.readerProbe) {
            this.quoteAttempts.delete(outer.id);
            return;
          }
          if (!path) {
            this.startQuoteResolution(outer, false);
            return;
          }
          const original = this.quotedMediaPost(quote, path);
          if (original && this.canPreviewThread(original, true)) {
            if (await this.startThreadPreview(original, path, route, true)) return;
          }
        }
        if ((player || this.surface !== Surface.Detail) && this.canPreviewThread(outer, !!player)) {
          if (await this.startThreadPreview(outer, '/' + outer.handle + '/status/' + outer.id, route, !!player)) return;
        }
      }
    } finally {
      this.previewSelecting = false;
    }
  }

  private async warmProfileLibrary(): Promise<void> {
    const owner = this.verifiedReaderAccount;
    const locale = this.locale;
    const eligible = (): boolean => !!owner && owner === this.verifiedReaderAccount && locale === this.locale &&
      this.foreground && this.session === Session.Active && (this.homeIsVisible() ||
        (this.surface === Surface.Profile && this.route.path.split('/')[1]?.toLowerCase() === owner)) &&
      !this.readerProbe && !this.translationProbe && !this.libraryProbe && !this.playerPost &&
      !this.settingsOpen && !this.webUrl && !this.homeRefreshRequested && !this.routeRefreshRequested &&
      (this.content === Content.Ready || this.content === Content.Empty);
    if (this.librarySelecting || !eligible()) return;
    this.librarySelecting = true;
    try {
      for (const tab of ['likes', 'media']) {
        const path = '/' + owner + '/' + tab;
        if ((path === this.route.path.toLowerCase() && (!this.routeCachedOnly || this.paging)) ||
          Date.now() - (this.libraryAttempts.get(tab) || 0) < 60000) continue;
        const route = new XRoute(Surface.Profile, path);
        const saved = await this.store.readRoute(route, locale).catch(() => undefined);
        if (!eligible()) return;
        this.libraryAttempts.set(tab, Date.now());
        if (saved && Date.now() - saved.cachedAt < PROFILE_LIBRARY_FRESH_MS) continue;
        if (path === this.route.path.toLowerCase() && (!this.routeCachedOnly || this.paging)) continue;
        this.libraryProbe = new ReaderProbe(route);
        hilog.info(0x0000, 'QwitterProfile', 'background library sync started %{public}s', tab);
        return;
      }
    } finally {
      this.librarySelecting = false;
    }
  }

  private async warmProfileTab(): Promise<void> {
    if (this.previewSelecting || !this.foreground || this.session !== Session.Active || !this.verifiedReaderAccount || this.surface !== Surface.Profile ||
      !this.profile || (!this.ready && !this.routeCachedOnly) || this.readerProbe || this.paging || this.playerPost || this.webUrl ||
      (this.content !== Content.Ready && this.content !== Content.Empty) || Date.now() - this.profileWarmAt < 4000) return;
    const current = this.route;
    const base = '/' + this.profile.handle;
    const path = ['', ...this.profile.tabs].filter((tab: string) =>
      this.profile?.handle.toLowerCase() !== this.verifiedReaderAccount || (tab !== 'likes' && tab !== 'media'))
      .map((tab: string) => base + (tab ? '/' + tab : ''))
      .find((candidate: string) => candidate !== current.path && !this.profileWarmAttempted.has(candidate));
    if (!path) return;
    const locale = this.locale;
    this.profileWarmAt = Date.now();
    if (this.profileWarmAttempted.size >= 48) this.profileWarmAttempted.delete(Array.from(this.profileWarmAttempted)[0]);
    this.profileWarmAttempted.add(path);
    const route = new XRoute(Surface.Profile, path);
    const cached = await this.store.readRoute(route, locale).catch(() => undefined);
    if (cached?.posts.length || cached?.empty || this.route !== current || this.locale !== locale ||
      this.readerProbe || !this.foreground || this.paging) return;
    this.readerProbe = new ReaderProbe(route);
  }

  private async warmOwnProfile(): Promise<void> {
    if (this.playerPost || !this.homeIsVisible() || !this.canPreviewComments() || this.readerProbe || this.previewSelecting ||
      Date.now() - this.lastHomeCheck[this.homeTab] < 2500) return;
    const path = '/' + this.handle;
    const key = path.toLowerCase();
    if (!validHandle(this.handle) || this.profileWarmAttempted.has(key)) return;
    const owner = this.verifiedReaderAccount;
    const locale = this.locale;
    this.profileWarmAttempted.add(key);
    const route = new XRoute(Surface.Profile, path);
    const cached = await this.store.readRoute(route, locale).catch(() => undefined);
    if (cached?.posts.length || cached?.empty || owner !== this.verifiedReaderAccount || locale !== this.locale) return;
    if (!this.canPreviewComments() || this.readerProbe) {
      this.profileWarmAttempted.delete(key);
      return;
    }
    this.readerProbe = new ReaderProbe(route);
  }

  private async warmOtherTimeline(): Promise<void> {
    const route = this.route;
    const activeTab = this.homeTab;
    const tab = 1 - activeTab;
    if (this.playerPost || !this.homeIsVisible() || !this.canPreviewComments() || this.readerProbe || this.previewSelecting || this.homeWarmAttempted[tab] ||
      this.homeLoaded[tab] || !this.homeLoaded[activeTab] || Date.now() - this.lastHomeCheck[activeTab] < 2500) return;
    this.homeWarmAttempted[tab] = true;
    const anchor = this.reset.readHomePosition(tab);
    if (await this.store.readHome(tab, anchor?.postId || '').catch(() => undefined)) return;
    if (this.route !== route || !this.canPreviewComments() || this.readerProbe || this.homeLoaded[tab]) {
      this.homeWarmAttempted[tab] = false;
      return;
    }
    if (this.reset.readHome(tab)) return;
    this.readerProbe = new ReaderProbe(new XRoute(Surface.Home, '/home', '', tab), null, [], false, true);
  }

  private inlineState(id: string): InlineReplies | undefined {
    return this.inlineReplies.find((entry: InlineReplies) => entry.id === id);
  }

  private setInline(id: string, replies: Post[], loading: boolean, finished: boolean, error: boolean = false): void {
    const next = this.inlineReplies.filter((entry: InlineReplies) => entry.id !== id);
    const limit = this.inlineState(id)?.limit || INLINE_REPLY_BATCH;
    next.push({ id, replies, expanded: true, loading, finished, error, limit });
    this.inlineReplies = next.slice(-64);
  }

  private cancelProbe(): void {
    this.quoteRequest = null;
    const probe = this.readerProbe;
    if (!probe) return;
    this.readerProbe = null;
    try { probe.controller.stop(); } catch (_) {}
    if (probe.post && probe.preview) {
      if (probe.resolveQuote) this.quoteAttempts.delete(probe.post.id);
      else this.commentAttempts.delete(probe.post.id);
    }
    if (probe.post && !probe.preview) {
      const state = this.inlineState(probe.post.id);
      if (state?.loading) this.setInline(state.id, state.replies, false, false);
    }
  }

  private recordPreviewAttempt(attempts: Map<string, number>, id: string): void {
    if (attempts.size >= 96) attempts.delete(Array.from(attempts.keys())[0]);
    attempts.set(id, Date.now());
  }

  private canPreviewComments(): boolean {
    if (this.playerPost && (!this.videoPlaybackReady || this.videoSlideTarget)) return false;
    const readingFeed = !!this.playerPost || this.homeIsVisible() || this.surface === Surface.Detail || this.surface === Surface.Profile ||
      this.surface === Surface.Bookmarks || (this.surface === Surface.Search && !!this.route.query);
    return this.foreground && readingFeed && this.session === Session.Active && !!this.verifiedReaderAccount && !this.settingsOpen && !this.webUrl &&
      !this.drawerOpen && !this.fullPhotos.length && !this.homeRefreshRequested && !this.paging;
  }

  private canPreviewThread(post: Post, original: boolean = false): boolean {
    return (original || (!!post.replies && !/^0(?:\D|$)/.test(post.replies))) &&
      (original || validHandle(post.handle)) && /^\d{1,24}$/.test(post.id) &&
      Date.now() - (this.commentAttempts.get(post.id) || 0) >= 120000;
  }

  private async startThreadPreview(post: Post, path: string, route: XRoute, original: boolean = false): Promise<boolean> {
    this.recordPreviewAttempt(this.commentAttempts, post.id);
    const cached = await this.store.readThread(post.id).catch(() => undefined);
    if (cached) {
      const full = cached.posts.find((item: Post) => item.id === post.id);
      if (full?.quote && !this.previewPosts.has(post.id)) {
        if (this.previewPosts.size >= 64) this.previewPosts.delete(Array.from(this.previewPosts.keys())[0]);
        this.previewPosts.set(post.id, full);
      }
      return false;
    }
    if (this.route !== route || !this.canPreviewComments() || this.readerProbe) {
      this.commentAttempts.delete(post.id);
      return true;
    }
    if (!original && this.threadCache.get(post.id)?.replies.length) return false;
    this.readerProbe = new ReaderProbe(new XRoute(Surface.Detail, path, '', 0, post.id), post, [], true);
    return true;
  }

  private finishCommentPreview(probe: ReaderProbe, replies: Post[], empty: boolean, fullPost: Post | null): void {
    const post = fullPost || probe.post;
    if (!post) return;
    this.queueTranslations([post, ...replies]);
    if (replies.length || empty) {
      const model = this.store.publishThread(post, replies, empty, empty, !!this.verifiedReaderAccount);
      this.observe('thread-preview-ready');
      if (this.surface === Surface.Detail && this.route.postId === post.id) {
        if (replies.length) this.posts = model.posts.slice(1);
        this.content = this.posts.length ? Content.Ready : Content.Empty;
        this.mediaLookahead.prepare(this.posts.slice(0, MEDIA_LOOKAHEAD), this.imageQuality);
      }
    }
    if (this.surface === Surface.Detail && this.route.postId === post.id && this.detailCachedOnly) {
      this.load(this.route.url());
    }
  }

  private collapseReplies(post: Post): void {
    if (this.readerProbe?.post?.id === post.id) this.cancelProbe();
    this.inlineReplies = this.inlineReplies.map((entry: InlineReplies): InlineReplies => entry.id === post.id ?
      { id: entry.id, replies: entry.replies, expanded: false, loading: false, finished: entry.finished,
        error: entry.error, limit: entry.limit } : entry);
  }

  private queueInlinePreview(post: Post, visible: boolean): void {
    if (!visible) {
      this.inlinePreviewQueue = this.inlinePreviewQueue.filter((item: Post) => item.id !== post.id);
      return;
    }
    if (this.inlineState(post.id) || !post.replies || /^0(?:\D|$)/.test(post.replies) ||
      this.inlinePreviewQueue.some((item: Post) => item.id === post.id)) return;
    this.inlinePreviewQueue = [...this.inlinePreviewQueue, post].slice(-5);
    this.scheduleInlinePreview();
  }

  private scheduleInlinePreview(): void {
    clearTimeout(this.inlinePreviewTimer);
    if (!this.foreground || this.surface !== Surface.Detail || this.readerProbe || !this.inlinePreviewQueue.length) return;
    this.inlinePreviewTimer = setTimeout(() => {
      if (!this.foreground || this.surface !== Surface.Detail || this.readerProbe) return;
      const next = this.inlinePreviewQueue.shift();
      if (next) this.expandReplies(next, false, true);
    }, 350);
  }

  private async expandReplies(post: Post, more: boolean = false, automatic: boolean = false): Promise<void> {
    if (this.session !== Session.Active || this.surface !== Surface.Detail) return;
    const state = this.inlineState(post.id);
    if (state?.loading || (automatic && (state || this.readerProbe))) return;
    let known = state?.replies || this.posts.filter((child: Post) => child.replyToId === post.id);
    const limit = Math.min(PAGE_LIMIT, (state?.limit || INLINE_REPLY_BATCH) +
      (more && !state?.error ? INLINE_REPLY_BATCH : 0));
    this.cancelProbe();
    this.setInline(post.id, known, true, false);
    this.inlineReplies = this.inlineReplies.map((entry: InlineReplies): InlineReplies => entry.id === post.id ?
      { id: entry.id, replies: entry.replies, expanded: true, loading: true, finished: false, error: false, limit } : entry);
    const revision = ++this.inlineOpenRevision;
    const route = this.route;
    const cached = await this.store.readThread(post.id).catch(() => undefined);
    if (this.route !== route || this.session !== Session.Active || !this.inlineState(post.id)?.expanded) return;
    if (revision !== this.inlineOpenRevision) {
      this.setInline(post.id, known, false, false);
      return;
    }
    if (cached) {
      const merged = new Map<string, Post>();
      for (const item of [...cached.posts.filter((item: Post) => item.id !== post.id), ...known]) {
        if (!merged.has(item.id)) merged.set(item.id, item);
      }
      known = Array.from(merged.values());
      this.mediaLookahead.prepare(known.slice(0, MEDIA_LOOKAHEAD), this.imageQuality);
    }
    const complete = !!state?.finished || cached?.threadComplete === true;
    const direct = known.filter((item: Post) => item.replyToId === post.id).length;
    if (complete || direct >= limit) {
      this.setInline(post.id, known, false, complete);
      this.scheduleInlinePreview();
      return;
    }
    this.setInline(post.id, known, true, false);
    this.cancelProbe();
    this.readerProbe = new ReaderProbe(new XRoute(Surface.Detail, '/' + post.handle + '/status/' + post.id,
      '', 0, post.id), post, known, false, false, false, limit);
  }

  private publishInline(post: Post, replies: Post[], loading: boolean, complete: boolean, error: boolean = false): void {
    const model = this.store.publishThread(post, replies, complete && !replies.length, complete, !!this.verifiedReaderAccount);
    this.setInline(post.id, model.posts.slice(1), loading, complete, error);
    this.queueTranslations(model.posts, this.surface === Surface.Detail);
    if (replies.length) this.mediaLookahead.prepare(replies.slice(0, MEDIA_LOOKAHEAD), this.imageQuality);
  }

  private async waitForWeb(ms: number): Promise<void> {
    await new Promise<void>((resolve) => { setTimeout(resolve, ms); });
  }

  private async readProbe(probe: ReaderProbe): Promise<void> {
    if (probe.resolveQuote) {
      await this.readQuoteProbe(probe);
      return;
    }
    const library = this.libraryProbe === probe;
    const active = (): boolean => (library ? this.libraryProbe : this.readerProbe) === probe && this.foreground;
    const tab = probe.route.homeTab;
    const post = probe.post;
    const profileProbe = probe.route.surface === Surface.Profile;
    const notificationFeed = probe.route.surface === Surface.Notifications;
    const locale = this.locale;
    const web = probe.controller;
    const until = Date.now() + (probe.preview ? 8500 : post ? 60000 : 12000);
    const known = new Map<string, Post>(probe.existing.map((item: Post): [string, Post] => [item.id, item]));
    const expected = post && /^\d[\d,]*$/.test(post.replies) ? Number(post.replies.replace(/,/g, '')) : 0;
    let idleRounds = 0;
    let sawPost = false;
    let empty = false;
    let fullPost: Post | null = null;
    let inlineComplete = false;
    let nextPageAt = 0;
    const seenDuringProbe = new Set<string>();
    try {
      configureXWeb(web, true);
      if (post || profileProbe) this.loadReadingPage(web, probe.route.url());
      else web.loadUrl(probe.route.url());
      while (active() && Date.now() < until) {
        await this.waitForWeb(post ? 480 : 900);
        if (!active()) return;
        let snapshot: Snapshot | undefined;
        try {
          const url = web.getUrl();
          if (!isXUrl(url)) continue;
          const script = this.readerScript(post ? -1 : tab, false, false, '', notificationFeed);
          snapshot = decodeSnapshot(await this.pageScripts.run(web, script));
        } catch (_) {
          continue;
        }
        if (!active()) return;
        if (!snapshot?.authenticated || snapshot.pageError) continue;
        const path = snapshot.path.replace(/\/$/, '');
        if (probe.preview) {
          if (path.match(/\/status\/(\d{1,24})$/)?.[1] !== post?.id) continue;
        } else if (path.toLowerCase() !== probe.route.path.toLowerCase() &&
          !(profileProbe && probe.route.path.endsWith('/media') && path.toLowerCase() === probe.route.path.toLowerCase() + '/grid')) {
          continue;
        }
        if (snapshot.ownHandle && this.handle && snapshot.ownHandle.toLowerCase() !== this.handle.toLowerCase()) break;
        if (notificationFeed) {
          const inbox = snapshot.inbox;
          if (!this.homeIsVisible() || !inbox || (!inbox.rows.length && !inbox.empty)) continue;
          const rows = this.mergeInbox(inbox.rows, this.notificationPath === '/notifications' ? this.notifications : [], false);
          this.notificationPath = '/notifications';
          this.notifications = this.store.publishInbox('v2:notifications', rows, inbox.empty, inbox.title,
            !!this.verifiedReaderAccount).rows;
          if (this.surface === Surface.Notifications && this.notifications.length) this.content = Content.Ready;
          return;
        }
        if (profileProbe) {
          if (locale !== this.locale) return;
          if (!snapshot.posts.length && !snapshot.empty) {
            if (snapshot.profile && idleRounds === 0) {
              idleRounds++;
              this.store.saveProfile(locale, snapshot.profile).catch(() => {});
              await web.runJavaScript(ADVANCE_PAGE).catch(() => {});
            }
            continue;
          }
          if (snapshot.profile) this.store.saveProfile(locale, snapshot.profile).catch(() => {});
          this.queueTranslations(snapshot.posts);
          if (library) {
            const cached = await this.store.readRoute(probe.route, locale).catch(() => undefined);
            if (!active()) return;
            const posts = new Map<string, Post>();
            for (const item of [...snapshot.posts, ...(cached?.posts || [])]) {
              if (!posts.has(item.id)) posts.set(item.id, item);
            }
            const saved = await this.store.commitProfileLibrary(probe.route, locale, Array.from(posts.values()),
              snapshot.profile || cached?.profile || null, snapshot.empty && !posts.size);
            if (saved && active()) {
              this.observe('profile-library-preloaded');
              if (this.route.path.toLowerCase() === probe.route.path.toLowerCase() && this.routeCachedOnly &&
                !this.routeScrolled && !this.routeRefreshRequested && !this.paging) {
                this.posts = saved.posts;
                this.rememberAvatars(this.posts);
                this.content = this.posts.length ? Content.Ready : Content.Empty;
              }
            }
          } else {
            await this.store.saveRoute(probe.route, locale, snapshot.posts, snapshot.profile, snapshot.empty);
            if (active()) this.observe('profile-tab-preloaded');
          }
          return;
        }
        if (!post) {
          if ((snapshot.homeTab !== tab && !(tab === 0 && snapshot.homeTab < 0)) || !snapshot.posts.length) continue;
          if (probe.warmHome && this.homeTab !== tab && !this.homeLoaded[tab] && this.canPreviewComments()) {
            this.queueTranslations(snapshot.posts);
            this.rememberAvatars(snapshot.posts);
            if (tab === 0) this.recommendedPosts = snapshot.posts;
            else this.followingPosts = snapshot.posts;
            this.markHomeLoaded(tab);
            this.lastHomeCheck[tab] = Date.now();
            this.saveHomeCache(tab, 0);
            this.observe('home-tab-preloaded');
          } else if (!probe.warmHome) {
            this.observeHomePosts(tab, snapshot.posts);
          }
          return;
        }
        this.rememberAvatars(snapshot.posts);
        const source = snapshot.posts.find((item: Post) => item.id === post.id);
        if (probe.notificationPreview) {
          if (!source) continue;
          await this.store.savePost(source).catch(() => {});
          if (active()) this.rememberNotificationPosts([source]);
          return;
        }
        if (source) sawPost = true;
        if (!sawPost) continue;
        if (probe.preview) {
          if (source && !fullPost) {
            if (this.previewPosts.size >= 64) this.previewPosts.delete(Array.from(this.previewPosts.keys())[0]);
            this.previewPosts.set(source.id, source);
            if (this.verifiedReaderAccount) {
              this.store.savePost(source).catch(() => this.observe('post-cache-write-failed'));
            }
            if (this.surface === Surface.Detail && this.route.postId === source.id) this.detailPost = source;
            this.observe('post-preview-ready');
          }
          if (source) fullPost = source;
          const replies = snapshot.posts.filter((item: Post) => item.id !== post.id);
          if (replies.length) {
            for (const item of replies.slice(0, 24)) known.set(item.id, item);
            return;
          }
          if (source && (snapshot.empty || source.replies === '0')) {
            empty = true;
            return;
          }
          if (source && idleRounds === 0) {
            idleRounds++;
            await web.runJavaScript(ADVANCE_REPLIES).catch(() => {});
          }
          continue;
        }
        const before = known.size;
        let advanced = false;
        for (const item of snapshot.posts) {
          if (item.id === post.id) continue;
          if (!seenDuringProbe.has(item.id)) {
            seenDuringProbe.add(item.id);
            advanced = true;
          }
          if (!known.has(item.id) && known.size < PAGE_LIMIT) {
            if (!item.replyToId) item.replyToId = post.id;
            known.set(item.id, item);
          }
        }
        if (known.size > before) this.publishInline(source || post, Array.from(known.values()), true, false);
        if (advanced) idleRounds = 0;
        const direct = Array.from(known.values()).filter((item: Post) => item.replyToId === post.id).length;
        if ((expected > 0 && direct >= expected) || (source?.replies === '0' && !known.size)) {
          inlineComplete = true;
          return;
        }
        if (probe.replyLimit && direct >= probe.replyLimit) return;
        if (Date.now() < nextPageAt) continue;
        if (idleRounds >= 5) break;
        try {
          await web.runJavaScript(ADVANCE_REPLIES);
        } catch (_) {}
        idleRounds++;
        nextPageAt = Date.now() + 1100;
      }
    } catch (_) {
      // The visible post and replies stay available if the background reader fails.
    } finally {
      if (library && this.libraryProbe === probe) this.libraryProbe = null;
      else if (this.readerProbe === probe) {
        this.readerProbe = null;
        if (probe.preview && !probe.notificationPreview) {
          if (fullPost) {
            if (this.surface === Surface.Detail && this.route.postId === fullPost.id) this.detailPost = fullPost;
          }
          this.finishCommentPreview(probe, Array.from(known.values()), empty, fullPost);
          this.scheduleInlinePreview();
        } else if (post && !probe.notificationPreview) {
          const complete = inlineComplete || (sawPost && expected === 0 && idleRounds >= 5 && known.size > 0);
          this.publishInline(post, Array.from(known.values()), false, complete, !complete && (!sawPost || !known.size));
          this.scheduleInlinePreview();
        }
      }
    }
  }

  @Builder
  backgroundReader(probe: ReaderProbe, videoFeed: boolean = false) {
    Web({ src: '', controller: probe.controller })
      .width('100%').height('100%').opacity(0).hitTestBehavior(HitTestMode.None).focusable(false)
      .accessibilityLevel('no-hide-descendants').javaScriptAccess(true).domStorageAccess(true).fileAccess(false)
      .onlineImageAccess(false)
      .runJavaScriptOnDocumentStart([{ script: X_CONNECTIVITY, scriptRules: [X_ORIGIN] },
        { script: videoFeed ? VIDEO_FEED_PAUSE_WHILE_IDLE : READER_PAUSE_WEB_VIDEO, scriptRules: [X_ORIGIN] }])
      .onLoadIntercept((event) => event.data.isMainFrame() &&
        event.data.getRequestUrl() !== BLANK && !isXUrl(event.data.getRequestUrl()))
      .onResourceLoad((event) => {
        if (videoFeed && this.videoFeedProbe === probe) this.captureRecommendedSource(event.url);
      })
      .onControllerAttached(() => {
        if (this.inboxAccountProbe === probe) this.readInboxAccount(probe).catch(() => {});
        else if (videoFeed) this.readVideoFeed(probe);
        else this.readProbe(probe);
      })
  }

  private syncRecommendedPosts(): void {
    this.recommendedSource.replace(this.recommendedPosts);
  }

  private syncFollowingPosts(): void {
    this.followingSource.replace(this.followingPosts);
  }

  private usesLazyRouteFeed(): boolean {
    return this.surface === Surface.Search || this.surface === Surface.Profile;
  }

  private syncRouteFeed(): void {
    if (this.usesLazyRouteFeed()) this.routeFeedSource.replace(this.feedPosts(-1));
  }

  private feedPostKey(post: Post): string {
    return post.id + ':' + post.photos.length.toString() + ':' + post.video.toString() + ':' + post.videoPoster +
      ':' + post.avatar + ':' + (post.quotedPost?.avatar || '') + ':' + (post.quotedPost?.path || '') +
      ':' + post.translationLanguage;
  }

  private timelinePosts(tab: number): Post[] {
    return tab === 0 ? this.recommendedPosts : this.followingPosts;
  }

  private activeFeed(tab: number): boolean {
    return tab < 0 || (this.homeIsVisible() && tab === this.homeTab);
  }

  private upgradeMedia(tab: number, lastVisible: number): void {
    const count = lastVisible + MEDIA_LOOKAHEAD + 1;
    if (tab === 0 && count > this.recommendedHighQuality) this.recommendedHighQuality = count;
    if (tab === 1 && count > this.followingHighQuality) this.followingHighQuality = count;
  }

  private selectTimeline(tab: number): void {
    if (this.session === Session.Active && this.surface === Surface.Home && tab !== this.homeTab) {
      this.homePullOffset = 0;
      this.navigate(new XRoute(Surface.Home, '/home', '', tab));
      this.reset.saveHomeTab(tab).catch(() => this.observe('home-tab-write-failed'));
    }
  }

  private handleWebError(code: number): void {
    if (code !== -3) {
      this.fail(ui('无法连接 X，请检查网络后重试。', this.locale));
      return;
    }
    if (this.session !== Session.Starting || this.ready || this.startupRetryUsed) return;
    this.startupRetryUsed = true;
    const generation = this.epoch;
    this.startupRetryTimer = setTimeout(() => {
      if (generation === this.epoch && this.session === Session.Starting && !this.ready) this.load(this.route.url());
    }, 300);
  }

  private retryProfile(): boolean {
    if (this.surface !== Surface.Profile || this.session !== Session.Active || this.posts.length > 0) return false;
    if (this.profileRetryTimer >= 0) return true;
    if (this.profileRetried) return false;
    this.profileRetried = true;
    const route = this.route;
    this.content = Content.Loading;
    this.profileRetryTimer = setTimeout(() => {
      this.profileRetryTimer = -1;
      if (this.route !== route || this.session !== Session.Active || this.posts.length) return;
      this.deadline = Date.now() + PROFILE_WAIT_MS;
      this.load(route.url());
    }, 420);
    return true;
  }

  private profileRequest(address: string): boolean {
    const current = address.split(/[?#]/)[0].replace(/\/$/, '').toLowerCase();
    const expected = this.route.url().toLowerCase();
    return current === expected || (expected.endsWith('/media') && current === expected + '/grid');
  }

  private fail(message: string): void {
    if (this.detailCachedOnly) return;
    this.signedOutSince = -1;
    if (this.session === Session.SigningIn) {
      this.loginProblem = message;
      return;
    }
    if (this.session !== Session.Active && this.session !== Session.Starting) return;
    const inboxCount = this.surface === Surface.Notifications ? this.notifications.length :
      this.surface === Surface.Chat ? this.conversations.length : 0;
    const retained = this.session === Session.Active && (this.posts.length > 0 || inboxCount > 0);
    const retainedHome = retained && this.surface === Surface.Home;
    if (retained && (this.homeRefreshRequested || this.routeRefreshRequested)) {
      this.getUIContext().getPromptAction().showToast({ message });
    }
    this.homeRefreshRequested = false;
    this.homeRefreshStartedAt = 0;
    this.routeRefreshRequested = false;
    if (retainedHome) this.showingSavedHome = false;
    this.content = retained ? Content.Ready : Content.Failed;
    if (this.routeNeedsPaging) {
      this.routeNeedsPaging = false;
      this.pageNote = ui('加载失败，请重试', this.locale);
    }
    this.refreshing = false;
    this.problem = message;
    this.paging = false;
    this.detailNeedsPaging = false;
  }

  private detailNeedsFill(): boolean {
    const main = this.detailPost;
    if (this.surface !== Surface.Detail || !this.detailConfirmed || !main || this.paging || this.detailCachedOnly ||
      this.detailFillRounds >= DETAIL_FILL_ROUNDS || main.replies === '0') return false;
    const direct = this.posts.filter((post: Post) => !post.replyToId || post.replyToId === main.id).length;
    const total = replyCountValue(main.replies);
    return direct < (total > 0 ? Math.min(DETAIL_REPLY_TARGET, total) : DETAIL_REPLY_TARGET);
  }

  private async poll(): Promise<void> {
    if (!this.foreground || !this.script || this.detailCachedOnly || this.session === Session.SignedOut ||
      this.session === Session.Clearing || this.session === Session.ResetFailed) return;
    // Keep account verification available for publishing when the session has not been checked yet.
    if (this.postComposer && this.verifiedReaderAccount) return;
    if (this.playerPost) {
      if (this.videoPlaybackReady && !this.videoSlideTarget) this.warmPostPreviews();
      return;
    }
    if (this.homeStagePending) return;
    if (this.surface === Surface.Chat && this.chatItem && this.chatWaiting &&
      Date.now() - this.conversationOpenAt > 15000) {
      this.chatWaiting = false;
      this.chatFailure = ui('暂时无法读取', this.locale);
    }
    if (this.paging && Date.now() > this.pageDeadline) {
      this.paging = false;
      this.detailNeedsPaging = false;
      this.pageNote = ui('加载失败，请重试', this.locale);
    }
    if (this.session !== Session.SigningIn &&
      (this.content === Content.Loading || this.routeNeedsPaging || this.routeRefreshRequested || this.homeRefreshRequested) &&
      Date.now() > this.deadline) {
      if (this.retryProfile()) return;
      this.fail(this.session === Session.Starting ? ui('暂时无法确认 X 登录状态。', this.locale) : ui('暂时无法读取此页的内容。', this.locale));
    }
    if (this.session === Session.SigningIn && !this.loginDocument && !this.loginProblem &&
      Date.now() > this.deadline) {
      this.fail(ui('暂时无法加载 X 登录页，请重试。', this.locale));
    }
    this.startDiscovery();
    if (!this.homeRefreshRequested && !this.routeRefreshRequested) {
      this.maybeCheckHome();
      this.maybePrefetchHome();
      this.maybePrefetchRoute();
      this.warmProfileLibrary();
      this.warmNotifications();
      this.nextTranslation();
      if (this.homeIsVisible()) this.prepareUpcomingMedia();
      this.warmPostPreviews();
      if (!this.translationProbe && !this.libraryProbe && !this.librarySelecting && !this.notificationSelecting) {
        if (this.homeIsVisible()) {
          this.warmOtherTimeline();
          this.warmOwnProfile();
        } else {
          this.warmProfileTab();
        }
      }
    }
    if (this.surface === Surface.Chat) {
      this.readChat();
      return;
    }
    if (this.routeCachedOnly || this.applyingHome[this.homeTab] ||
      (this.surface === Surface.Home && this.homeNeedsPageSource && !this.homeRefreshRequested)) return;
    if (!this.ready || this.reading === this.epoch) return;
    if (this.session === Session.Active && (this.content === Content.Ready || this.content === Content.Empty) &&
      !this.paging && !this.routeRefreshRequested && !this.homeRefreshRequested &&
      Date.now() - this.lastRead < (this.surface === Surface.Detail ?
        (this.detailConfirmed && !this.detailNeedsFill() ? 2000 : 300) :
        this.surface === Surface.Home ? (this.verifiedReaderAccount ? 15000 : 850) : 5000)) return;
    const generation = this.epoch;
    try {
      const url = this.controller.getUrl();
      if (!isXUrl(url)) return;
      this.updateLoginDocument(url);
      this.reading = generation;
      this.lastRead = Date.now();
      if (this.session === Session.SigningIn && this.loginDocument) return;
      if (this.paging && this.pageAdvanceRounds > 0 && this.pageAdvanceRounds < 6 && Date.now() >= this.pageAdvanceAt) {
        this.pageAdvanceRounds++;
        this.pageAdvanceAt = Date.now() + 2100;
        await this.controller.runJavaScript(this.surface === Surface.Detail ? ADVANCE_REPLIES : ADVANCE_PAGE);
        if (generation !== this.epoch) return;
      } else if (this.detailNeedsFill() && this.posts.length > 0 && Date.now() >= this.detailFillAt) {
        // X renders only the replies near its viewport. Scroll its hidden page until the first batch is complete.
        this.detailFillRounds++;
        this.detailFillAt = Date.now() + DETAIL_FILL_GAP_MS;
        hilog.info(0x0000, 'QyxDetail', 'reply fill round=%{public}d shown=%{public}d count=%{public}s',
          this.detailFillRounds, this.posts.length, this.detailPost?.replies || '');
        await this.controller.runJavaScript(ADVANCE_REPLIES);
        if (generation !== this.epoch) return;
      }
      const homeTarget = this.surface === Surface.Home ? this.route.homeTab : -1;
      const discoverAccount = this.surface === Surface.Home && !this.verifiedReaderAccount;
      if (this.surface === Surface.Notifications && this.inboxScript &&
        /^https:\/\/x\.com\/notifications(?:[/?#]|$)/.test(url)) {
        const pages = this.pageScripts;
        const rawInbox = await pages.run(this.controller, pages.wrap('JSON.stringify(' +
          pages.inbox.call('{ qyxNotificationCategory: ' + JSON.stringify(this.route.path) + ' }') + ')', [pages.inbox]));
        if (generation !== this.epoch || !this.foreground) return;
        const inboxJson = rawInbox?.startsWith('"') ? JSON.parse(rawInbox) as string : rawInbox;
        const page = inboxJson ? decodeInbox(JSON.parse(inboxJson) as InboxPage) : null;
        if (page && (page.rows.length || page.empty)) {
          this.acceptInbox(page);
          return;
        }
      }
      const script = this.readerScript(homeTarget, discoverAccount);
      const raw = await this.pageScripts.run(this.controller, script);
      if (generation !== this.epoch || !this.foreground || (this.postComposer && this.verifiedReaderAccount) ||
        (this.surface === Surface.Home && (this.homeStagePending || this.homeNeedsPageSource))) return;
      const snapshot = decodeSnapshot(raw);
      if (snapshot) {
        const observation = snapshot.authenticated ? 'authenticated' : snapshot.signedOut ? 'signed-out' : 'unknown';
        const result = observation + (snapshot.posts.length > 0 ? '-with-posts' : '');
        this.observe(result);
        if (snapshot.accountMenuPending) this.lastRead = 0;
        await this.accept(snapshot);
      } else {
        this.signedOutSince = -1;
        this.observe('empty-web-result');
      }
    } catch (_) {
      // ArkWeb can replace its document while this read is in progress. The next tick retries.
      if (generation === this.epoch) {
        this.signedOutSince = -1;
        this.observe('web-read-failed');
      }
    } finally {
      if (this.reading === generation) this.reading = -1;
    }
  }

  private observe(result: string): void {
    if (result === this.lastObservation) return;
    this.lastObservation = result;
    hilog.info(0x0000, 'QyxSession', 'session %{public}s', result);
  }

  private async accept(snapshot: Snapshot): Promise<void> {
    // Chat is read from the dedicated chat engine (readChat); ignore main-web results that arrive after switching to Chat.
    if (this.surface === Surface.Chat) return;
    if (snapshot.signedOut && this.session !== Session.SigningIn && !snapshot.pageError) {
      const now = Date.now();
      const known = this.session === Session.Active || this.sessionKnown;
      if (known && this.signedOutSince < 0) this.signedOutSince = now;
      if (known && now - this.signedOutSince < SIGN_OUT_CONFIRM_MS) return;
      this.expired = known;
      this.showSignedOut();
      this.load(BLANK);
      this.stopPolling();
      return;
    }
    this.signedOutSince = -1;
    if (!snapshot.authenticated) return;
    if (this.surface === Surface.Notifications &&
      (!snapshot.inbox || (snapshot.ownHandle && this.handle && snapshot.ownHandle.toLowerCase() !== this.handle.toLowerCase()))) return;
    if (this.session !== Session.Active && !snapshot.ownHandle &&
      snapshot.posts.length === 0 && !snapshot.empty) return;
    if (this.session === Session.SigningIn) {
      this.expired = false;
      this.loginProblem = '';
      this.route = new XRoute(Surface.Home, '/home');
      this.surface = Surface.Home;
      this.homeTab = 0;
      this.content = Content.Loading;
      this.deadline = Date.now() + WAIT_MS;
      this.enterReader();
      if (snapshot.path !== '/home') {
        this.navigate(this.route);
        return;
      }
    }
    if (snapshot.ownHandle && this.handle && snapshot.ownHandle.toLowerCase() !== this.handle.toLowerCase()) {
      this.trail = [];
      this.resetReaderChrome();
      this.fullPhotos = [];
      this.handle = snapshot.ownHandle;
      this.accountName = snapshot.ownName;
      this.avatar = snapshot.ownAvatar;
      this.discardSavedHome();
      this.bindReaderAccount(snapshot.ownHandle);
      this.navigate(new XRoute(Surface.Home, '/home'));
      return;
    }
    if (snapshot.ownHandle && snapshot.ownHandle !== this.handle) this.handle = snapshot.ownHandle;
    if (snapshot.ownHandle) this.bindReaderAccount(snapshot.ownHandle);
    if (snapshot.ownName && snapshot.ownName !== this.accountName) this.accountName = snapshot.ownName;
    if (snapshot.ownAvatar && snapshot.ownAvatar !== this.avatar) this.avatar = snapshot.ownAvatar;
    if (this.session === Session.Starting) this.enterReader();
    else this.flushCookies();

    const path = snapshot.path.replace(/\/$/, '');
    const isHome = this.surface === Surface.Home;
    const isDetail = this.surface === Surface.Detail;
    if (isHome && path !== '/home' && path !== '') return;
    if (isDetail && path.match(/^\/(?:[A-Za-z0-9_]{1,15}|i\/web)\/status\/(\d{1,24})$/)?.[1] !== this.route.postId) return;
    const routePath = this.route.path.toLowerCase();
    const mediaGrid = this.surface === Surface.Profile && routePath.endsWith('/media') &&
      path.toLowerCase() === routePath + '/grid';
    // X redirects Bookmarks and Likes into its History page, so a library route can land on another History address.
    const libraryRedirect = this.surface === Surface.Bookmarks &&
      this.libraryRedirectMatches(routePath, path.toLowerCase(), snapshot.pageTabs);
    const historyHub = libraryRedirect && routePath === HISTORY_PATH;
    if (this.surface === Surface.Bookmarks && path.toLowerCase() !== routePath) {
      this.logLibrary((libraryRedirect ? 'library redirect ' : 'library rejected ') + routePath + ' -> ' + path.toLowerCase());
    }
    if (!isHome && !isDetail && path.toLowerCase() !== routePath && !mediaGrid && !libraryRedirect) return;
    if (this.surface === Surface.Search &&
      (snapshot.query.trim() !== this.route.requestQuery() || (!!this.route.query && snapshot.searchMode !== this.route.searchMode))) return;
    if (snapshot.pageTabsProbe) {
      this.notePageTabs(snapshot.pageTabs, snapshot.pageTabsProbe.startsWith('history'), snapshot.pageTabsProbe);
    }
    if (snapshot.pageError && historyHub) {
      // This account has no History page on X's web yet: show Bookmarks.
      this.navigate(new XRoute(Surface.Bookmarks, '/i/bookmarks'));
      return;
    }
    if (snapshot.pageError) {
      if (this.retryProfile()) return;
      this.fail(ui('X 网页暂时无法显示此页。', this.locale));
      return;
    }
    if (this.surface === Surface.Notifications) return;
    if (isHome && snapshot.homeTab !== this.route.homeTab &&
      !(this.route.homeTab === 0 && snapshot.homeTab < 0)) return;
    if (this.surface === Surface.Search && this.route.query) {
      this.acceptSearchResults(snapshot);
      return;
    }
    this.queueTranslations(snapshot.posts);
    if (isHome) this.homeDocumentConfirmed = true;
    if (isHome && this.verifiedReaderAccount && (snapshot.posts.length || snapshot.empty) &&
      (this.homeRefreshRequested || (this.showingSavedHome && !this.homeAnchors[this.homeTab] &&
        !this.pendingHomePosition[this.homeTab]))) {
      await this.replaceHomeFromX(snapshot.posts);
      return;
    }
    if (this.surface === Surface.Profile &&
      snapshot.profile?.handle.toLowerCase() === this.route.path.split('/')[1].toLowerCase()) {
      const profile = this.mergeProfile(snapshot.profile);
      if (JSON.stringify(this.profile) !== JSON.stringify(profile)) {
        const route = this.route;
        const epoch = this.epoch;
        const locale = this.locale;
        let stored: Profile | null = null;
        if (this.verifiedReaderAccount) {
          stored = await this.store.saveProfile(locale, profile)
            .then(() => this.store.readProfile(locale, profile.handle)).catch(() => null);
        }
        if (this.route !== route || this.epoch !== epoch) return;
        this.profile = stored || profile;
      }
      if (!snapshot.posts.length && !snapshot.empty && !this.profileWakeUsed) {
        this.profileWakeUsed = true;
        this.controller.runJavaScript(ADVANCE_PAGE).catch(() => {});
      }
    }
    const localLibrary = this.store.isOwnProfileLibraryTab(this.route);
    const readingRoute = this.route;
    const readingEpoch = this.epoch;
    let incoming = snapshot.posts;
    const replacingRoute = !isHome && this.routeRefreshRequested;
    this.rememberAvatars(incoming);
    if (isDetail) {
      const main = incoming.find((post: Post) => post.id === this.route.postId);
      if (!main && !this.detailConfirmed) return;
      if (main) incoming = incoming.filter((post: Post) => post.id !== main.id);
      if (main && !this.detailConfirmed) {
        this.detailConfirmed = true;
        if (this.detailPost) {
          if (!main.translation && this.detailPost.translation) {
            main.body = this.detailPost.body;
            main.translation = this.detailPost.translation;
            main.translationLanguage = this.detailPost.translationLanguage;
          } else if (!main.body) {
            main.body = this.detailPost.body;
          }
          if (!main.avatar) main.avatar = this.detailPost.avatar;
          if (!main.videoSources.length) main.videoSources = this.detailPost.videoSources;
        }
        this.detailPost = main;
        if (this.verifiedReaderAccount) this.store.savePost(main).catch(() => this.observe('post-cache-write-failed'));
        this.updateBrowsing(main);
        this.deadline = Math.min(this.deadline, Date.now() + REPLY_WAIT_MS);
        if (!this.detailNeedsPaging && !incoming.length && !this.posts.length && !snapshot.empty && main.replies !== '0') {
          this.controller.runJavaScript(ADVANCE_PAGE).catch(() => {});
        }
      }
      if (main?.translation && (this.detailPost?.translation !== main.translation ||
        this.detailPost?.translationLanguage !== main.translationLanguage || this.detailPost?.body !== main.body)) {
        this.detailPost = main;
      }
      if (!incoming.length && (!this.posts.length || replacingRoute) && (snapshot.empty || main?.replies === '0')) {
        this.content = this.posts.length ? Content.Ready : Content.Empty;
        this.refreshing = false;
        this.routeRefreshRequested = false;
        if (main && !this.posts.length) this.store.publishThread(main, [], true, true, !!this.verifiedReaderAccount);
      }
    }
    if (incoming.length === 0 && !this.detailNeedsPaging) {
      if (snapshot.empty) {
        if (isHome) {
          if (!this.homeLoaded[this.homeTab]) {
            this.markHomeLoaded();
            this.lastHomeCheck[this.homeTab] = Date.now();
          }
        }
        if (localLibrary && !this.routeCachedEmpty) {
          const saved = await this.store.commitProfileLibrary(readingRoute, this.locale, this.posts,
            this.profile, !this.posts.length);
          if (this.route !== readingRoute || this.epoch !== readingEpoch || !saved) return;
          this.routeCachedEmpty = saved.empty;
        }
        this.homeRefreshRequested = false;
        this.routeRefreshRequested = false;
        this.showingSavedHome = false;
        this.content = this.posts.length ? Content.Ready : Content.Empty;
        this.refreshing = false;
        if (!localLibrary && !isHome && !isDetail) this.saveRouteCache(!this.posts.length);
      }
      return;
    }

    const replacingHome = isHome && this.homeRefreshRequested;
    const addingHome = isHome && (!this.homeLoaded[this.homeTab] || replacingHome);
    if (isHome && !addingHome && !this.paging && !this.homeWebPaged) {
      this.observeHomePosts(this.homeTab, incoming);
    }
    const canAppend = !isHome || addingHome || this.paging;
    const mergingRefresh = replacingRoute;
    const known = new Map<string, Post>(this.posts
      .map((post: Post): [string, Post] => [post.id, post]));
    const fresh: Post[] = [];
    const count = known.size;
    let postDetailsChanged = false;
    for (const post of incoming) {
      const previous = known.get(post.id);
      if (!previous && canAppend && (mergingRefresh || known.size < PAGE_LIMIT)) {
        if (mergingRefresh) fresh.push(post);
        else known.set(post.id, post);
      } else if (previous) {
        if (mergingRefresh) {
          if (post.body && post.body !== previous.body) {
            previous.body = post.body;
            previous.bodyLinks = post.bodyLinks;
            previous.translation = post.translation;
            previous.translationLanguage = post.translationLanguage;
            postDetailsChanged = true;
          }
          if (post.name && post.name !== previous.name) {
            previous.name = post.name;
            postDetailsChanged = true;
          }
          if (post.replies !== previous.replies || post.views !== previous.views || post.time !== previous.time) {
            previous.replies = post.replies || previous.replies;
            previous.views = post.views || previous.views;
            previous.time = post.time || previous.time;
            postDetailsChanged = true;
          }
        }
        if (this.fillAvatar(previous)) postDetailsChanged = true;
        if (post.quotedPost?.path && !previous.quotedPost?.path) {
          previous.quotedPost = post.quotedPost;
          previous.quote = true;
          postDetailsChanged = true;
        }
        if (post.translation && (previous.translation !== post.translation ||
          previous.translationLanguage !== post.translationLanguage || previous.body !== post.body)) {
          previous.body = post.body;
          previous.translation = post.translation;
          previous.translationLanguage = post.translationLanguage;
          postDetailsChanged = true;
        }
        if (previous.body === post.body && post.bodyLinks &&
          JSON.stringify(previous.bodyLinks) !== JSON.stringify(post.bodyLinks)) {
          previous.bodyLinks = post.bodyLinks;
          postDetailsChanged = true;
        }
        if (isDetail && post.replyToId && previous.replyToId !== post.replyToId) {
          previous.replyToId = post.replyToId;
          postDetailsChanged = true;
        }
        if (post.photos.length > previous.photos.length) {
          previous.photos = post.photos;
          previous.photoRatios = post.photoRatios;
          postDetailsChanged = true;
        }
        if (post.video && (!previous.video || (!previous.videoPoster && !!post.videoPoster) ||
          post.videoSources.some((url: string) => !previous.videoSources.includes(url)))) {
          previous.video = true;
          if (post.videoPoster) {
            previous.videoPoster = post.videoPoster;
            previous.videoRatio = post.videoRatio;
          }
          previous.videoSources = normalizeVideoSources([...previous.videoSources, ...post.videoSources]);
          postDetailsChanged = true;
        }
        if (post.videoDuration && previous.videoDuration !== post.videoDuration) {
          previous.videoDuration = post.videoDuration;
          previous.videoDurationVerified = true;
          postDetailsChanged = true;
        }
        const localLike = this.postActionStates.get('like:' + post.id);
        if ((!localLike || localLike.liked === post.liked) && (previous.likes !== post.likes || previous.liked !== post.liked)) {
          previous.likes = post.likes;
          previous.liked = post.liked;
          postDetailsChanged = true;
        }
        const localRepost = this.postActionStates.get('repost:' + post.id);
        if ((!localRepost || localRepost.liked === post.reposted) &&
          (previous.reposts !== post.reposts || previous.reposted !== post.reposted)) {
          previous.reposts = post.reposts;
          previous.reposted = post.reposted;
          postDetailsChanged = true;
        }
        const localBookmark = this.postActionStates.get('bookmark:' + post.id);
        if ((!localBookmark || localBookmark.liked === post.bookmarked) && previous.bookmarked !== post.bookmarked) {
          previous.bookmarked = post.bookmarked;
          postDetailsChanged = true;
        }
      }
    }
    if (isHome) {
      for (const post of known.values()) {
        if (this.fillAvatar(post)) postDetailsChanged = true;
      }
    }
    if (fresh.length || known.size !== count || postDetailsChanged || mergingRefresh) {
      const entries = [...fresh, ...Array.from(known.values())].slice(0, PAGE_LIMIT);
      if (localLibrary) {
        const saved = await this.store.commitProfileLibrary(readingRoute, this.locale, entries, this.profile, false);
        if (this.route !== readingRoute || this.epoch !== readingEpoch) return;
        if (!saved) return;
        this.posts = saved.posts;
        this.observe('profile-library-rendered');
      } else if (readingRoute.surface === Surface.Profile && this.verifiedReaderAccount) {
        const locale = this.locale;
        const saved = await this.store.saveRoute(readingRoute, locale, entries, this.profile, false)
          .then(() => this.store.readRoute(readingRoute, locale)).catch(() => undefined);
        if (this.route !== readingRoute || this.epoch !== readingEpoch) return;
        this.posts = saved?.posts.length ? saved.posts : entries;
      } else {
        this.posts = isDetail && this.detailPost ?
          this.store.publishThread(this.detailPost, entries, false, false, !!this.verifiedReaderAccount).posts.slice(1) :
          entries;
      }
      this.showingSavedHome = false;
      if (fresh.length || known.size !== count) {
        this.paging = false;
        this.pageNote = '';
        if (this.playerPost) this.prepareNextVideos(this.playerPost);
      }
      if (isHome) {
        if (this.homeTab === 0) this.recommendedPosts = this.posts;
        else this.followingPosts = this.posts;
        if (addingHome) {
          if (!replacingHome && !this.homeAnchors[this.homeTab] && !this.homeScrolled) {
            const position = this.reset.readHomePosition(this.homeTab);
            if (position && this.posts.some((post: Post) => post.id === position.postId)) {
              this.homeHeaderPositions[this.homeTab] = position.headerHidden;
              this.pendingHomePosition[this.homeTab] = position;
              this.restoreHomePosition();
            }
          }
          this.markHomeLoaded();
          this.restoreNewHomeNotice(this.homeTab);
          this.lastHomeCheck[this.homeTab] = Date.now();
          if (this.homeTab === 0) this.recommendedHighQuality = INITIAL_HIGH_QUALITY_POSTS;
          else this.followingHighQuality = INITIAL_HIGH_QUALITY_POSTS;
        }
        if (known.size !== count || replacingHome || addingHome || this.legacyHomePending[this.homeTab]) {
          this.saveHomeCache(this.homeTab, addingHome || this.legacyHomePending[this.homeTab] ? 0 : count);
        }
      } else if (!isDetail && !localLibrary && readingRoute.surface !== Surface.Profile) {
        this.saveRouteCache();
      }
    }
    this.content = isHome && !this.posts.length ? Content.Empty : Content.Ready;
    this.refreshing = false;
    this.homeRefreshRequested = false;
    this.routeRefreshRequested = false;
    this.showingSavedHome = false;
    if (this.routeNeedsPaging) {
      this.routeNeedsPaging = false;
      if (known.size === count) this.nextPage();
    }
    if (isDetail && this.detailNeedsPaging) {
      this.detailNeedsPaging = false;
      this.paging = false;
      if (known.size === count) this.nextPage();
    }
  }

  private feedItemCount(): number {
    return this.surface === Surface.Search && this.searchMode === 'people' ? this.searchPeople.length : this.posts.length;
  }

  private acceptSearchResults(snapshot: Snapshot): void {
    if (this.previousSearchDocumentTime && snapshot.documentTime === this.previousSearchDocumentTime) return;
    const people = snapshot.discovery.filter((section: DiscoverySection) => section.kind === 'people')
      .flatMap((section: DiscoverySection) => section.rows);
    if (!(this.searchMode === 'people' ? people.length : snapshot.posts.length) && !snapshot.empty) return;
    const replace = this.routeRefreshRequested || this.content === Content.Loading || this.content === Content.Failed;
    if (this.searchMode === 'people') {
      if (!replace && !this.paging) return;
      const results = new Map<string, DiscoveryRow>();
      if (!replace) for (const row of this.searchPeople) results.set(row.path.toLowerCase(), row);
      const before = results.size;
      for (const row of people) {
        if (results.size >= PAGE_LIMIT) break;
        results.set(row.path.toLowerCase(), row);
      }
      if (!replace && results.size === before && !snapshot.empty) return;
      this.searchPeople = Array.from(results.values());
      hilog.info(0x0000, 'QwitterSearch', 'mode=people rows=%{public}d', this.searchPeople.length);
      this.previousSearchDocumentTime = 0;
      this.searchDocumentTime = snapshot.documentTime || 0;
      this.content = this.searchPeople.length ? Content.Ready : Content.Empty;
      this.paging = false;
      this.refreshing = false;
      this.routeRefreshRequested = false;
      this.routeNeedsPaging = false;
      this.pageNote = '';
      this.saveRouteCache(!this.searchPeople.length);
      return;
    }
    if (!replace && !this.paging) {
      // X can attach lazy image URLs after the text result has already been read.
      // Enrich existing cards without changing the user's ordering or adding posts.
      const incoming = new Map<string, Post>();
      for (const post of snapshot.posts) incoming.set(post.id, post);
      let changed = false;
      for (const post of this.posts) {
        const loaded = incoming.get(post.id);
        if (!loaded) continue;
        if (loaded.photos.length > post.photos.length) {
          post.photos = loaded.photos;
          post.photoRatios = loaded.photoRatios;
          changed = true;
        }
        if (!post.avatar && loaded.avatar) { post.avatar = loaded.avatar; changed = true; }
        if (loaded.video && (!post.video || (!post.videoPoster && !!loaded.videoPoster))) {
          post.video = true;
          post.videoPoster = loaded.videoPoster;
          post.videoRatio = loaded.videoRatio;
          post.videoSources = loaded.videoSources;
          changed = true;
        }
      }
      if (changed) {
        this.posts = this.posts.slice();
        this.saveRouteCache(false);
        hilog.info(0x0000, 'QwitterSearch', 'media hydrated mode=%{public}s photos=%{public}d', this.searchMode,
          this.posts.reduce((count: number, post: Post) => count + post.photos.length, 0));
      }
      return;
    }
    this.rememberAvatars(snapshot.posts);
    const results = new Map<string, Post>();
    if (!replace) {
      for (const post of this.posts) results.set(post.id, post);
    }
    const before = results.size;
    for (const post of snapshot.posts) {
      if (results.size >= PAGE_LIMIT) break;
      if (!results.has(post.id)) results.set(post.id, post);
    }
    if (!replace && results.size === before) {
      if (snapshot.empty) this.paging = false;
      return;
    }
    this.previousSearchDocumentTime = 0;
    this.searchDocumentTime = snapshot.documentTime || 0;
    this.posts = Array.from(results.values());
    hilog.info(0x0000, 'QwitterSearch', 'mode=%{public}s rows=%{public}d photos=%{public}d', this.searchMode, this.posts.length,
      this.posts.reduce((count: number, post: Post) => count + post.photos.length, 0));
    this.content = this.posts.length ? Content.Ready : Content.Empty;
    this.queueTranslations(this.posts);
    this.paging = false;
    this.refreshing = false;
    this.routeRefreshRequested = false;
    this.routeNeedsPaging = false;
    this.pageNote = '';
    this.saveRouteCache(!this.posts.length);
  }

  private rememberKnownAccount(): void {
    const handle = this.verifiedReaderAccount;
    if (!handle || handle !== this.handle.toLowerCase()) return;
    this.store.rememberKnownAccount(handle, this.ownProfile?.name || this.accountName, this.ownProfile?.avatar || this.avatar)
      .catch(() => {})
      .finally(() => this.refreshKnownAccounts());
  }

  private async refreshKnownAccounts(): Promise<void> {
    this.knownAccounts = await this.store.readKnownAccounts().catch((): KnownAccount[] => this.knownAccounts);
  }

  private switchAccount(handle: string): void {
    if (this.session !== Session.Active || this.switchingAccount || !validHandle(handle)) return;
    if (handle.toLowerCase() === this.handle.toLowerCase()) {
      this.showDrawer(false);
      return;
    }
    this.switchingAccount = handle.toLowerCase();
    this.accountSwitchProbe = new ReaderProbe(new XRoute(Surface.Home, '/account/switch'));
  }

  // Adding an account uses X's own flow: its account switcher page has "Add an existing account".
  private addAccount(): void {
    this.getUIContext().getPromptAction().showToast({ message: ui('请在 X 页面中选择"添加已有账号"', this.locale) });
    this.openWeb(ui('添加账号', this.locale), '/account/switch');
  }

  private async runAccountSwitch(probe: ReaderProbe): Promise<void> {
    if (this.accountSwitchProbe !== probe) return;
    const target = this.switchingAccount;
    let success = false;
    try {
      configureXWeb(probe.controller, true);
      probe.controller.loadUrl(X_ORIGIN + '/account/switch');
      const until = Date.now() + ACCOUNT_SWITCH_TIMEOUT_MS;
      let tapped = false;
      while (this.accountSwitchProbe === probe && this.session === Session.Active && Date.now() < until) {
        await this.waitForWeb(600);
        if (this.accountSwitchProbe !== probe) return;
        let url = '';
        try { url = probe.controller.getUrl(); } catch (_) {}
        if (!isXUrl(url)) continue;
        if (!tapped) {
          tapped = await probe.controller.runJavaScript(accountSwitchScript(target)).catch(() => 'false') === 'true';
          if (tapped) hilog.info(0x0000, 'QwitterAccounts', 'switch row tapped');
          continue;
        }
        const snapshot = decodeSnapshot(await this.pageScripts.run(probe.controller, this.readerScript(-1, true, false)));
        if (snapshot?.ownHandle && snapshot.ownHandle.toLowerCase() === target) {
          success = true;
          break;
        }
      }
    } catch (_) {
      // Falls back to X's switcher page below.
    } finally {
      if (this.accountSwitchProbe === probe) {
        this.accountSwitchProbe = null;
        this.switchingAccount = '';
        hilog.info(0x0000, 'QwitterAccounts', 'switch %{public}s', success ? 'done' : 'fallback');
        if (success) {
          await this.flushCookies(true);
          this.completeAccountSwitch();
        } else if (this.session === Session.Active) {
          this.getUIContext().getPromptAction().showToast({ message: ui('无法自动切换，请在 X 页面中选择账号', this.locale) });
          this.openWeb(ui('管理账号', this.locale), '/account/switch');
        }
      }
    }
  }

  // Same reset as returning from X's switcher page: forget the verified account and reload Home, which detects the
  // new account and resets everything scoped to the previous one.
  private completeAccountSwitch(): void {
    this.showDrawer(false);
    this.webUrl = '';
    this.verifiedReaderAccount = '';
    this.navIndex = 0;
    this.trail = [];
    this.navigate(new XRoute(Surface.Home, '/home'));
  }

  @Builder
  accountSwitchReader(probe: ReaderProbe) {
    Web({ src: '', controller: probe.controller })
      .width('100%').height('100%').opacity(0).hitTestBehavior(HitTestMode.None).focusable(false)
      .accessibilityLevel('no-hide-descendants').javaScriptAccess(true).domStorageAccess(true).fileAccess(false)
      .onlineImageAccess(false)
      .runJavaScriptOnDocumentStart([{ script: X_CONNECTIVITY, scriptRules: [X_ORIGIN] }])
      .onLoadIntercept((event) => event.data.isMainFrame() &&
        event.data.getRequestUrl() !== BLANK && !isXUrl(event.data.getRequestUrl()))
      .onControllerAttached(() => this.runAccountSwitch(probe))
  }

  private bindReaderAccount(handle: string): void {
    const verified = this.verifiedReaderAccount === handle.toLowerCase();
    this.verifiedReaderAccount = handle.toLowerCase();
    this.store.setAccount(handle);
    if (this.pendingChatOwner === this.verifiedReaderAccount) {
      this.pendingChatCache.forEach((page: InboxPage, key: string) => {
        this.store.publishInbox(key, page.rows, page.empty, page.title, true);
      });
    }
    this.pendingChatCache.clear();
    this.pendingChatOwner = '';
    if (verified) return;
    this.rememberKnownAccount();
    hilog.info(0x0000, 'QwitterReader', 'authenticated local account selected');
    if (this.drawerOpen && !this.ownProfile) this.loadDrawerProfile();
    this.reset.rememberAccount(handle).catch(() => this.observe('account-marker-write-failed'));
    for (let tab = 0; tab < 2; tab++) {
      if (!this.homeRestoredFromDb[tab] && this.timelinePosts(tab).length) this.saveHomeCache(tab, 0);
      this.restoreNewHomeNotice(tab);
    }
  }

  private saveHomeCache(tab: number, previousCount: number): void {
    if (!this.verifiedReaderAccount || this.verifiedReaderAccount !== this.handle.toLowerCase()) return;
    const owner = this.verifiedReaderAccount;
    this.store.saveHome(tab, this.accountName, this.avatar, this.timelinePosts(tab), previousCount)
      .then((saved: boolean) => {
        if (!saved || this.verifiedReaderAccount !== owner) return;
        this.legacyHomePending[tab] = false;
        this.reset.removeLegacyHome(tab);
      })
      .catch(() => this.observe('home-cache-write-failed'));
  }

  private discardSavedHome(tab: number = -1): void {
    if (this.showingSavedHome) this.posts = [];
    this.showingSavedHome = false;
    for (let index = 0; index < 2; index++) {
      if (tab >= 0 && index !== tab) continue;
      this.homeLoaded[index] = false;
      this.legacyHomePending[index] = false;
      this.homeRestoredFromDb[index] = false;
      this.homeLastVisible[index] = 0;
      this.homePrefetchAt[index] = -1;
      this.homeWarmAttempted[index] = false;
      this.stagingHome[index] = false;
      this.applyingHome[index] = false;
      this.homeAnchors[index] = undefined;
      this.homeFirstVisible[index] = -1;
      this.pendingHomePosition[index] = undefined;
      this.homeHeaderPositions[index] = false;
      this.lastHomeCheck[index] = 0;
      this.setNewHomePosts(index, false);
    }
    if (tab <= 0) this.recommendedPosts = [];
    if (tab !== 0) this.followingPosts = [];
    if (tab <= 0) this.recommendedHighQuality = INITIAL_HIGH_QUALITY_POSTS;
    if (tab !== 0) this.followingHighQuality = INITIAL_HIGH_QUALITY_POSTS;
    try {
      this.reset.forgetHome(tab);
    } catch (_) {
      this.observe('home-cache-delete-failed');
    }
  }

  private enterReader(): void {
    if (this.session === Session.SigningIn && this.tabletReaderUserAgent) {
      try {
        this.controller.setCustomUserAgent(this.tabletReaderUserAgent);
      } catch (_) {
        this.observe('reader-user-agent-restore-failed');
      }
    }
    this.session = Session.Active;
    this.sessionKnown = true;
    this.reset.rememberSession(true).catch(() => this.observe('session-marker-write-failed'));
    this.flushCookies(true);
  }

  private showSignedOut(): void {
    this.verifiedReaderAccount = '';
    this.store.setAccount('');
    this.discardSavedHome();
    if (this.sessionKnown) {
      this.sessionKnown = false;
      this.reset.rememberSession(false).catch(() => this.observe('session-marker-write-failed'));
    }
    this.session = Session.SignedOut;
    this.trail = [];
    this.handle = '';
    this.accountName = '';
    this.avatar = '';
    this.posts = [];
    this.detailPost = null;
    this.profile = null;
    this.resetReaderChrome();
    this.fullPhotos = [];
    this.paging = false;
    this.query = '';
    this.stopPolling();
  }

  private beginLogin(): void {
    this.session = Session.SigningIn;
    this.loginProblem = '';
    this.deadline = Date.now() + WAIT_MS;
    if (deviceInfo.deviceType === 'tablet') {
      configureXWeb(this.controller, true, true);
    }
    this.load(X_LOGIN);
  }

  private async clearSession(): Promise<void> {
    if (this.clearRunning) return;
    this.clearRunning = true;
    this.session = Session.Clearing;
    this.verifiedReaderAccount = '';
    this.store.setAccount('');
    this.resetReaderChrome();
    this.showingSavedHome = false;
    this.stopPolling();
    this.posts = [];
    this.detailPost = null;
    this.profile = null;
    this.fullPhotos = [];
    this.handle = '';
    this.accountName = '';
    this.avatar = '';
    this.epoch++;
    try {
      await this.reset.markPending();
      this.sessionKnown = false;
      this.controller.stop();
      if (this.controller.getUrl() === BLANK && this.ready) {
        await this.finishReset();
      } else {
        this.ready = false;
        this.awaitingBlank = true;
        this.clearTimer = setTimeout(() => this.resetFailed(), 7000);
        this.controller.loadUrl(BLANK);
      }
    } catch (_) {
      this.resetFailed();
    }
  }

  private async finishReset(): Promise<void> {
    this.awaitingBlank = false;
    clearTimeout(this.clearTimer);
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.store.clear(context);
      this.mediaLookahead.clear();
      await this.reset.clear(this.controller);
      this.observe('local-reset-complete');
      this.expired = false;
      this.showSignedOut();
      this.clearRunning = false;
    } catch (_) {
      this.resetFailed();
    }
  }

  private resetFailed(): void {
    this.observe('local-reset-failed');
    this.awaitingBlank = false;
    clearTimeout(this.clearTimer);
    this.clearRunning = false;
    this.session = Session.ResetFailed;
  }

  private pageEnded(url: string): void {
    try {
      if (url !== this.controller.getUrl()) return;
    } catch (_) {
      return;
    }
    this.ready = true;
    this.updateLoginDocument(url);
    if (this.awaitingBlank && url === BLANK) {
      this.finishReset();
      return;
    }
    this.poll();
  }

  private pageVisible(url: string): void {
    if ((!isXUrl(url) && !(this.surface === Surface.Chat && isXChatUrl(url))) || this.awaitingBlank) return;
    this.pageEnded(url);
  }

  private updateLoginDocument(url: string): void {
    if (this.session !== Session.SigningIn) return;
    const loginDocument = isXLoginUrl(url);
    if (this.loginDocument && !loginDocument) this.deadline = Date.now() + WAIT_MS;
    this.loginDocument = loginDocument;
  }

  private loginWebVisible(): boolean {
    return this.session === Session.SigningIn && this.loginDocument && !this.loginProblem;
  }

  private confirmReset(): void {
    this.getUIContext().showAlertDialog({
      title: ui('退出此设备上的 Qwitter？', this.locale),
      message: ui('将清除 Qwitter 的 X 网页会话。下次使用时需要重新登录。', this.locale),
      primaryButton: { value: ui('取消', this.locale), action: () => {} },
      secondaryButton: { value: ui('退出登录', this.locale), action: () => { this.clearSession(); } }
    });
  }

  private select(surface: Surface): void {
    if (surface === this.surface && this.trail.length === 0) return;
    this.trail = [];
    if (surface === Surface.Search) {
      const retained = this.retainedSearch;
      this.query = retained?.query || '';
      this.navigate(new XRoute(surface, retained?.path || '/explore', this.query, 0, '', retained?.latestSearch || false, retained?.searchMode || 'top'),
        null, true, false, retained);
    } else if (surface === Surface.Bookmarks) {
      this.navigate(new XRoute(surface, '/i/bookmarks'));
    } else {
      this.navigate(new XRoute(Surface.Home, '/home', '', Math.max(0, this.homeTab)));
    }
  }

  private resetReaderChrome(): void {
    this.setComposerKeyboard(false);
    this.stopPostComposer();
    this.replyTarget = null;
    this.replyDraft = '';
    this.replyAttachments = [];
    this.resetPostDraft();
    this.composerBusy = false;
    this.composerFeedback = '';
    this.threadCache.clear();
    this.commentAttempts.clear();
    this.libraryAttempts.clear();
    this.libraryProbe = null;
    this.previewPosts.clear();
    this.quoteAttempts.clear();
    this.resolvedQuotes.clear();
    clearTimeout(this.inlinePreviewTimer);
    this.inlinePreviewQueue = [];
    this.profileWarmAttempted.clear();
    this.drawerProfileLoading = false;
    this.resumePreviewDetail = false;
    this.authorAvatars.clear();
    this.cancelProbe();
    this.stopInboxAccountProbe();
    this.nextInboxAccountProbe = 0;
    this.resetTranslations();
    this.inlineReplies = [];
    this.detailCachedOnly = false;
    this.detailNeedsPaging = false;
    this.readerPages.clear(false);
    this.settingsPaths.clear(false);
    this.settingsOpen = false;
    this.drawerOpen = false;
    this.ownProfile = null;
    this.notifications = [];
    this.discoveryProbe = null;
    this.discoverySections = [];
    this.discoveryKey = '';
    this.discoveryRefreshAt = 0;
    this.notificationPosts = new Map();
    this.notificationEnd = 0;
    this.notificationReadAt = 0;
    this.notificationAttempts.clear();
    this.chatWebVisible = false;
    this.chatUnlockOffered = false;
    this.chatHostTried = false;
    this.discardChatEngine();
    this.discardTranslationHost();
    this.historyTabsFromX = [];
    this.pendingChatCache.clear();
    this.pendingChatOwner = '';
    this.conversations = [];
    this.retainedSearch = undefined;
    this.chatLocked = false;
    this.clearOpenChat();
    this.navIndex = 0;
    this.webUrl = '';
    this.closeVideo();
    this.clearVideoWarmup();
    this.preparedVideoSources = new Map();
    this.successfulVideoSources.clear();
    this.profileCache.clear();
    clearTimeout(this.profileRetryTimer);
    this.profileRetryTimer = -1;
    this.videoDurations = new Map();
    this.postActionOperation = null;
    this.postActionProbe = null;
    this.postActionStates = new Map();
    this.pendingPostActions = [];
    this.postActionQueue = [];
    this.queuedPostActionIntents.clear();
    this.refreshing = false;
  }

  private changeTab(index: number): void {
    if (this.session !== Session.Active) return;
    const rootSurface = [Surface.Home, Surface.Search, Surface.Notifications, Surface.Chat][index];
    const tabletOverlay = this.wideTablet && (this.surface !== rootSurface || this.settingsOpen ||
      !!this.postComposer || !!this.chatItem || !!this.webUrl);
    if (index === this.navIndex && !tabletOverlay &&
      (index !== 0 || (!this.webUrl && !this.settingsOpen && !this.drawerOpen && !this.trail.length))) return;
    if (tabletOverlay) {
      if (this.composerBusy) return;
      if (this.settingsOpen) this.closeSettings();
      if (this.postComposer) this.closePostComposer();
      if (this.chatItem) {
        this.clearOpenChat();
        this.readerPages.pop(false);
      }
    }
    const switchedAccount = this.webUrl === X_ORIGIN + '/account/switch';
    if (switchedAccount) this.verifiedReaderAccount = '';
    const previousRoute = this.route;
    if (previousRoute.surface === Surface.Search && this.surface === Surface.Search &&
      previousRoute.query && (this.content === Content.Ready || this.content === Content.Empty)) {
      const retained = new Snapshot();
      retained.path = previousRoute.path;
      retained.query = previousRoute.query;
      retained.latestSearch = previousRoute.latestSearch;
      retained.searchMode = previousRoute.searchMode;
      retained.discovery = previousRoute.searchMode === 'people' ?
        [{ kind: 'people', title: '', rows: this.searchPeople }] : [];
      retained.posts = this.posts;
      retained.empty = this.content === Content.Empty;
      this.retainedSearch = retained;
    }
    this.rememberHomePosition();
    this.cancelProbe();
    this.lastHomeTap = 0;
    this.navIndex = index;
    hilog.info(0x0000, 'QwitterTabs', 'primary tab selected %{public}d', index);
    this.webUrl = '';
    this.drawerOpen = false;
    this.refreshing = false;
    this.trail = [];
    if (index === 0 && switchedAccount) this.navigate(new XRoute(Surface.Home, '/home'));
    else if (index < 2) this.select(index === 0 ? Surface.Home : Surface.Search);
    else if (index === 2) this.navigate(new XRoute(Surface.Notifications, '/notifications'));
    else if (index === 3) this.navigate(new XRoute(Surface.Chat, '/i/chat'));
    if (index === 0 && this.surface === Surface.Home && this.route === previousRoute) this.restoreHomePosition();
  }

  private showDrawer(open: boolean): void {
    if (this.session !== Session.Active || (this.wideTablet && open)) return;
    this.getUIContext().animateTo({ duration: 245, curve: Curve.EaseOut }, () => {
      this.drawerOpen = open;
      this.drawerDrag = 0;
    });
    if (open && !this.ownProfile) this.loadDrawerProfile();
    if (open) this.rememberKnownAccount();
    if (!open) this.drawerProfileLoading = false;
  }

  private async loadDrawerProfile(): Promise<void> {
    const handle = this.handle;
    const route = new XRoute(Surface.Profile, '/' + handle);
    if (!validHandle(handle) || this.drawerProfileLoading) return;
    const timelineRead = this.store.readRoute(route, this.locale).catch(() => undefined);
    const profileRead = this.store.readProfile(this.locale, handle).catch(() => null);
    const saved = await timelineRead;
    const profile = await profileRead;
    if (!this.drawerOpen || this.handle !== handle || this.ownProfile) return;
    const localProfile = profile || saved?.profile;
    if (localProfile && (localProfile.following || localProfile.followers)) {
      this.ownProfile = this.mergeProfile(localProfile);
      this.observe('sidebar-cache-restored');
      return;
    }
    this.profileWeb = new webview.WebviewController();
    this.drawerProfileLoading = true;
  }

  private canSwipeDrawer(): boolean {
    return !this.wideTablet && this.session === Session.Active && (this.drawerOpen ||
      (this.navIndex === 0 && this.surface === Surface.Home && this.homeTab === 0 &&
        !this.settingsOpen && !this.webUrl && !this.galleryTouchPost && this.fullPhotos.length === 0));
  }

  private drawerOffset(): number {
    return (this.drawerOpen ? this.drawerWidth : 0) + this.drawerDrag;
  }

  private dragDrawer(offset: number): void {
    if (!this.canSwipeDrawer()) return;
    this.drawerDrag = this.drawerOpen ? Math.min(0, Math.max(-this.drawerWidth, offset)) :
      Math.max(0, Math.min(this.drawerWidth, offset));
  }

  private endDrawerDrag(event: GestureEvent): void {
    if (!this.canSwipeDrawer() || !this.drawerDrag) return;
    const moved = Math.abs(this.drawerDrag);
    const commit = moved >= this.drawerWidth * 0.28 ||
      (moved >= 20 && Math.abs(event.velocityX) > 500 && this.drawerDrag * event.velocityX > 0);
    this.showDrawer(commit ? !this.drawerOpen : this.drawerOpen);
  }

  private async readOwnProfile(url: string): Promise<void> {
    const handle = this.handle;
    const controller = this.profileWeb;
    if (url !== X_ORIGIN + '/' + handle && url !== X_ORIGIN + '/' + handle + '/') return;
    let cachedHeader = false;
    for (let attempt = 0; attempt < 16; attempt++) {
      if (!this.drawerOpen || this.handle !== handle || controller !== this.profileWeb) return;
      try {
        const snapshot = decodeSnapshot(await this.pageScripts.run(controller, this.plainReaderScript()));
        if (snapshot?.profile?.handle.toLowerCase() === handle.toLowerCase() &&
          this.handle === handle && this.drawerOpen && controller === this.profileWeb) {
          this.ownProfile = snapshot.profile;
          if (snapshot.profile.avatar) this.avatar = snapshot.profile.avatar;
          if (this.verifiedReaderAccount === handle.toLowerCase()) {
            if (!cachedHeader) {
              cachedHeader = true;
              this.store.saveProfile(this.locale, snapshot.profile).catch(() => {});
            }
            this.store.saveRoute(new XRoute(Surface.Profile, '/' + handle), this.locale, snapshot.posts, snapshot.profile,
              snapshot.empty).catch(() => this.observe('sidebar-cache-write-failed'));
          }
          if (snapshot.posts.length || snapshot.empty) break;
        }
      } catch (_) {
        // X may still be hydrating the profile.
      }
      await new Promise<void>((resolve) => { setTimeout(resolve, 420); });
    }
    if (controller === this.profileWeb) this.drawerProfileLoading = false;
  }

  private openWeb(title: string, path: string): void {
    if (this.session !== Session.Active) return;
    const setting = settingsRoute(path);
    if (setting.startsWith(SETTINGS_ROOT + '/') || setting === SETTINGS_ROOT) {
      this.openSettings(title, setting);
      return;
    }
    this.rememberHomePosition();
    this.showDrawer(false);
    this.webTitle = title;
    this.webUrl = path.startsWith('/') ? X_ORIGIN + path : path;
  }

  private openSettings(title: string = SETTINGS_TITLE, route: string = SETTINGS_ROOT): void {
    if (this.settingsOpen || this.session !== Session.Active) return;
    this.rememberHomePosition();
    this.cancelProbe();
    this.showDrawer(false);
    this.settingsEntry = route;
    this.settingsEntryTitle = route === SETTINGS_ROOT ? SETTINGS_TITLE : title;
    this.settingsPaths.clear(false);
    this.settingsOpen = true;
    this.readerPages.pushPath({ name: 'settings' }, true);
  }

  private closeSettings(): void {
    if (!this.settingsOpen) return;
    this.settingsOpen = false;
    this.nextTranslation();
    this.settingsPaths.clear(false);
    this.readerPages.pop(true);
    this.restoreHomePosition();
  }

  private openBookmarks(): void {
    this.webUrl = '';
    this.trail.push(this.route);
    this.navigate(new XRoute(Surface.Bookmarks, '/i/bookmarks'));
  }

  private async copyPostLink(post: Post): Promise<void> {
    const url = X_ORIGIN + '/' + post.handle + '/status/' + post.id;
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url));
      this.getUIContext().getPromptAction().showToast({ message: ui('已复制帖子链接', this.locale) });
    } catch (_) {
      this.getUIContext().getPromptAction().showToast({ message: ui('暂时无法复制链接', this.locale) });
    }
  }

  private searchDiscovery(value: string): void {
    if (this.navIndex !== 1 || this.surface !== Surface.Search || this.settingsOpen || this.webUrl) this.changeTab(1);
    this.search(value);
  }

  private startDiscovery(): void {
    if (!this.foreground || this.session !== Session.Active || !this.verifiedReaderAccount ||
      (!this.wideTablet && !(this.surface === Surface.Search && !this.submittedQuery))) return;
    const key = this.verifiedReaderAccount + ':' + this.locale;
    if (key !== this.discoveryKey) {
      this.discoveryProbe = null;
      this.discoverySections = [];
      this.discoveryKey = key;
      this.discoveryRefreshAt = 0;
    }
    if (this.discoveryProbe || Date.now() < this.discoveryRefreshAt) return;
    this.discoveryRefreshAt = Date.now() + 600000;
    this.discoveryProbe = new ReaderProbe(new XRoute(Surface.Search, '/explore'));
  }

  private async readDiscovery(probe: ReaderProbe): Promise<void> {
    const key = this.discoveryKey;
    const locale = this.locale;
    const owner = this.verifiedReaderAccount;
    const active = (): boolean => this.foreground && this.session === Session.Active &&
      this.discoveryProbe === probe && this.verifiedReaderAccount === owner && this.locale === locale;
    const web = probe.controller;
    try {
      const cached = await this.store.readDiscovery(locale).catch(() => []);
      if (!active()) return;
      this.discoverySections = cached;
      configureXWeb(web, true);
      const groups = new Map<string, DiscoverySection>();
      for (const path of ['/explore', '/home', '/explore/tabs/trending', '/explore/tabs/sports']) {
        if (!active()) return;
        web.loadUrl(X_ORIGIN + path);
        for (let attempt = 0; attempt < 5; attempt++) {
          await this.waitForWeb(850);
          if (!active()) return;
          let snapshot: Snapshot | undefined;
          try {
            snapshot = decodeSnapshot(await this.pageScripts.run(web, this.plainReaderScript()));
          } catch (_) {
            continue;
          }
          if (!active()) return;
          if (!snapshot?.authenticated || snapshot.path.replace(/\/$/, '') !== path || !snapshot.discovery.length ||
            (snapshot.ownHandle && snapshot.ownHandle.toLowerCase() !== owner)) continue;
          for (const group of snapshot.discovery) {
            const groupKey = group.kind === 'other' ? group.kind + ':' + group.title : group.kind;
            if (!groups.has(groupKey)) groups.set(groupKey, group);
          }
          const next = Array.from(groups.values());
          for (const group of cached) {
            const groupKey = group.kind === 'other' ? group.kind + ':' + group.title : group.kind;
            if (!groups.has(groupKey)) next.push(group);
          }
          if (next.length && active()) {
            await this.store.saveDiscovery(locale, next);
            if (!active()) return;
            const saved = await this.store.readDiscovery(locale);
            if (active()) this.discoverySections = saved;
          }
          break;
        }
      }
      if (!groups.size && !cached.length) this.discoveryRefreshAt = Date.now() + 60000;
    } catch (_) {
      if (this.discoveryKey === key) this.discoveryRefreshAt = Date.now() + 60000;
    } finally {
      if (this.discoveryProbe === probe) this.discoveryProbe = null;
    }
  }

  private discoveryTitle(section: DiscoverySection): string {
    if (section.title) return section.title;
    if (section.kind === 'sports') return ui('体育', this.locale);
    if (section.kind === 'us') return ui('美国趋势', this.locale);
    return ui(section.kind === 'people' ? '推荐关注' : '当前地区趋势', this.locale);
  }

  private openDiscoveryItem(item: DiscoveryRow): void {
    if (item.query) this.searchDiscovery(item.query);
    else if (/^\/[A-Za-z0-9_]{1,15}$/.test(item.path) && item.path !== '/premium') this.openProfile(item.path.slice(1));
    else if (item.path) this.openWeb(item.title, item.path);
  }

  @Builder
  discoveryContent(bottomOffset: number) {
    Scroll() {
      Column({ space: 12 }) {
        Text(ui('有什么新鲜事', this.locale)).fontSize(22).fontWeight(FontWeight.Bold)
          .fontColor(INK).width('100%').margin({ bottom: 2 })
        if (!this.discoverySections.length) {
          if (this.discoveryProbe) LoadingProgress().width(24).height(24).color(this.accentInk)
          else Text(ui('暂时没有推荐内容', this.locale)).fontSize(14).fontColor(MUTED).width('100%')
        }
        ForEach(this.discoverySections, (section: DiscoverySection) => {
          Column() {
            Text(this.discoveryTitle(section)).fontSize(17).fontWeight(FontWeight.Bold)
              .fontColor(INK).width('100%').padding({ left: 13, right: 13, top: 12, bottom: 5 })
            ForEach(section.rows, (item: DiscoveryRow) => {
              Row({ space: 10 }) {
                if (item.avatar) Avatar({ src: item.avatar, diameter: 33 })
                Column({ space: 3 }) {
                  Text(item.title).fontSize(15).fontColor(INK).fontWeight(FontWeight.Medium)
                    .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                  if (item.subtitle) Text(item.subtitle).fontSize(12).fontColor(MUTED)
                    .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              }.width('100%').padding({ left: 13, right: 13, top: 9, bottom: 9 })
                .onClick(() => { if (item.query || item.path) this.openDiscoveryItem(item); })
            }, (item: DiscoveryRow) => item.path + ':' + item.query + ':' + item.title + ':' + item.subtitle + ':' + item.avatar)
            if (this.wideTablet && (section.kind === 'trends' || section.kind === 'us') &&
              (this.surface !== Surface.Search || this.submittedQuery)) {
              Text(ui('显示更多', this.locale)).fontSize(14).fontColor(this.accentInk)
                .width('100%').padding({ left: 13, top: 8, bottom: 9 }).onClick(() => this.searchDiscovery(''))
            }
          }.width('100%').border({ width: 1, color: RULE }).borderRadius(14).padding({ bottom: 4 })
        }, (section: DiscoverySection) => section.kind + ':' + section.title)
      }.width('100%').padding({ left: 14, right: 14, top: 10, bottom: bottomOffset + 14 })
    }.width('100%').layoutWeight(1).align(Alignment.TopStart).scrollBar(BarState.Off)
  }

  @Builder
  tabletDiscovery() {
    Column() {
      Search({ value: this.discoveryQuery, placeholder: ui('搜索', this.locale) })
        .height(42).margin({ left: 14, right: 14, bottom: 8 })
        .onChange((value: string) => { this.discoveryQuery = value; })
        .onSubmit((value: string) => this.searchDiscovery(value))
      this.discoveryContent(this.bottomInset)
    }.width(310).height('100%').padding({ top: this.statusInset + 12 })
      .border({ width: { left: 1 }, color: RULE }).backgroundColor(PAPER)
  }

  private search(value: string): void {
    if (this.session !== Session.Active || this.surface !== Surface.Search) return;
    this.retainedSearch = undefined;
    const query = Array.from(value.trim()).slice(0, 200).join('');
    this.query = query;
    if (this.submittedQuery) this.searchScroller.scrollEdge(Edge.Top);
    if (query && this.route.query === query) {
      this.refreshFeed();
      return;
    }
    this.navigate(new XRoute(Surface.Search, query ? '/search' : '/explore', query, 0, '', this.searchMode === 'latest', this.searchMode));
  }

  private sortSearch(mode: string): void {
    if (this.session !== Session.Active || !this.submittedQuery || this.searchMode === mode) return;
    this.retainedSearch = undefined;
    this.searchScroller.scrollEdge(Edge.Top);
    hilog.info(0x0000, 'QwitterSearch', 'selected mode=%{public}s', mode);
    this.navigate(new XRoute(Surface.Search, '/search', this.submittedQuery, 0, '', mode === 'latest', mode));
  }

  private openPost(post: Post, path: string = '/' + post.handle + '/status/' + post.id): void {
    const canRead = this.session === Session.Active ||
      (this.session === Session.Starting && this.sessionKnown && this.showingSavedHome);
    hilog.info(0x0000, 'QwitterNavigation', 'post tap allowed=%{public}s same=%{public}s depth=%{public}d',
      canRead ? 'yes' : 'no', this.route.postId === post.id ? 'yes' : 'no', this.trail.length);
    if (!canRead || this.route.postId === post.id || this.trail.length >= 12) return;
    this.trail.push(this.route);
    // Every detail entry point (feed, search, profile, notifications, quotes, replies, video) comes through here,
    // so the post is recorded the moment it opens, before X loads it or its replies.
    this.recordBrowsing(post);
    this.navigate(new XRoute(Surface.Detail, path, '', 0, post.id), post);
  }

  private async findQuotePath(outerId: string, quote: QuotedPost): Promise<string> {
    return quoteStatusPath(quote.path, outerId) || this.resolvedQuotes.get(outerId) ||
      await this.store.readQuotePath(outerId).catch(() => '');
  }

  private async openQuote(quote: QuotedPost, outer: Post): Promise<void> {
    const route = this.route;
    const path = await this.findQuotePath(outer.id, quote);
    if (this.route !== route || this.session !== Session.Active) return;
    const original = this.quotedMediaPost(quote, path);
    if (original) {
      this.openPost(original, path);
      return;
    }
    this.startQuoteResolution(outer, true);
  }

  private startQuoteResolution(outer: Post, requested: boolean): void {
    if (!validHandle(outer.handle) || !/^\d{1,24}$/.test(outer.id)) return;
    let probe = this.readerProbe;
    if (!probe?.resolveQuote || probe.post?.id !== outer.id) {
      this.cancelProbe();
      probe = new ReaderProbe(new XRoute(Surface.Detail, '/' + outer.handle + '/status/' + outer.id, '', 0, outer.id),
        outer, [], true, false, true);
      this.readerProbe = probe;
    }
    if (requested && this.quoteRequest !== probe) {
      this.quoteRequest = probe;
      this.getUIContext().getPromptAction().showToast({ message: ui('正在加载…', this.locale) });
    }
  }

  private async readQuoteProbe(probe: ReaderProbe): Promise<void> {
    const outer = probe.post;
    if (!outer) return;
    const route = this.route;
    const owner = this.verifiedReaderAccount;
    const web = probe.controller;
    const script = this.pageScripts.wrap(this.pageScripts.read.call('{ qyxOpenQuote: ' + JSON.stringify(outer.id) + ' }'),
      [this.pageScripts.read]);
    let quote = outer.quotedPost || new QuotedPost();
    let path = '';
    let clickAt = 0;
    try {
      configureXWeb(web, true);
      this.loadReadingPage(web, probe.route.url());
      const deadline = Date.now() + 8500;
      while (this.readerProbe === probe && this.foreground && Date.now() < deadline) {
        await this.waitForWeb(350);
        if (this.readerProbe !== probe || this.route !== route || owner !== this.verifiedReaderAccount) return;
        try {
          const url = web.getUrl();
          if (!isXUrl(url)) continue;
          const snapshot = decodeSnapshot(await this.pageScripts.run(web, this.plainReaderScript()));
          if (this.readerProbe !== probe) return;
          const current = snapshot?.path || url.slice(X_ORIGIN.length).split(/[?#]/)[0];
          if (clickAt) {
            path = quoteStatusPath(current, outer.id);
            if (path) break;
          }
          if (!current.replace(/\/$/, '').endsWith('/status/' + outer.id)) continue;
          const found = snapshot?.posts.find((item: Post) => item.id === outer.id);
          if (found?.quotedPost) quote = found.quotedPost;
          path = quoteStatusPath(quote.path, outer.id);
          if (path) break;
          if (snapshot?.authenticated && found?.quote && Date.now() - clickAt > 1500) {
            clickAt = Date.now();
            await this.pageScripts.run(web, script);
          }
        } catch (_) {}
      }
    } catch (_) {}
    if (this.readerProbe !== probe) return;
    const requested = this.quoteRequest === probe;
    this.readerProbe = null;
    this.quoteRequest = null;
    if (this.route !== route || this.session !== Session.Active || owner !== this.verifiedReaderAccount) return;
    const original = this.quotedMediaPost(quote, path);
    if (original) {
      if (this.resolvedQuotes.size >= 96) this.resolvedQuotes.delete(Array.from(this.resolvedQuotes.keys())[0]);
      this.resolvedQuotes.set(outer.id, path);
      if (owner) this.store.saveQuotePath(outer.id, path).catch(() => {});
      this.observe('quote-link-resolved');
      if (requested) this.openPost(original, path);
      else if (this.canPreviewThread(original, true)) await this.startThreadPreview(original, path, route, true);
    } else if (requested) {
      this.getUIContext().getPromptAction().showToast({ message: ui('X 暂未提供被引用帖的链接', this.locale) });
    }
    this.scheduleInlinePreview();
  }

  private quotedMediaPost(quote: QuotedPost, path: string = quote.path): Post | null {
    const match = /^\/(?:([A-Za-z0-9_]{1,15})|i\/web)\/status\/(\d{1,24})$/.exec(path);
    if (!match) return null;
    const post = new Post();
    post.id = match[2];
    post.handle = match[1] || quote.handle;
    post.name = quote.name;
    post.avatar = quote.avatar;
    post.time = quote.time;
    post.body = quote.body;
    post.bodyLinks = quote.bodyLinks;
    if (quote.photo && !quote.video) {
      post.photos = [quote.photo];
      post.photoRatios = [quote.ratio || 1.33];
    }
    post.video = quote.video;
    post.videoPoster = quote.poster;
    post.videoRatio = quote.ratio || 1.78;
    return post;
  }

  private openProfile(handle: string, post?: Post): void {
    if (this.session !== Session.Active || !validHandle(handle) || this.route.path === '/' + handle || this.trail.length >= 12) return;
    this.trail.push(this.route);
    this.navigate(new XRoute(Surface.Profile, '/' + handle));
    if (this.profile) return;
    if (this.ownProfile?.handle.toLowerCase() === handle.toLowerCase()) {
      this.profile = this.ownProfile;
    } else {
      const preview = new Profile();
      const own = handle.toLowerCase() === this.handle.toLowerCase();
      preview.handle = handle;
      preview.name = post?.name || (own ? this.accountName : '');
      preview.avatar = post?.avatar || (own ? this.avatar : '');
      preview.verified = post?.verified ?? false;
      if (own) preview.tabs = ['reposts'];
      this.profile = preview;
    }
  }

  private mergeProfile(incoming: Profile): Profile {
    const key = incoming.handle.toLowerCase();
    const previous = this.profileCache.get(key);
    if (previous) {
      incoming.name ||= previous.name;
      incoming.bio ||= previous.bio;
      incoming.avatar ||= previous.avatar;
      incoming.banner ||= previous.banner;
      incoming.location ||= previous.location;
      incoming.website ||= previous.website;
      incoming.websiteUrl ||= previous.websiteUrl;
      incoming.birthday ||= previous.birthday;
      incoming.joined ||= previous.joined;
      incoming.following ||= previous.following;
      incoming.followers ||= previous.followers;
      incoming.followersPath ||= previous.followersPath;
      incoming.aboutPath ||= previous.aboutPath;
      incoming.editPath ||= previous.editPath;
      incoming.verified ||= previous.verified;
      incoming.tabs = Array.from(new Set([...previous.tabs, ...incoming.tabs]));
    }
    if (key === this.handle.toLowerCase()) {
      // X shows Reposts on the signed-in account's profile and has moved its Likes into History.
      incoming.tabs = incoming.tabs.filter((tab: string) => tab !== 'likes');
      if (!incoming.tabs.includes('reposts')) incoming.tabs.splice(incoming.tabs.includes('with_replies') ? 1 : 0, 0, 'reposts');
      this.ownProfile = incoming;
    }
    if (this.profileCache.size >= 40 && !previous) this.profileCache.delete(Array.from(this.profileCache.keys())[0]);
    this.profileCache.set(key, incoming);
    return incoming;
  }

  private selectProfileTab(tab: string): void {
    if (!this.profile || tab === this.profileTab) return;
    const ownLikes = tab === 'likes' && this.profile.handle.toLowerCase() === this.handle.toLowerCase();
    if (tab && !ownLikes && !this.profile.tabs.includes(tab)) return;
    this.navigate(new XRoute(Surface.Profile, '/' + this.profile.handle + (tab ? '/' + tab : '')));
  }

  private selectProfileMediaFilter(filter: number): void {
    if (this.profileMediaFilter === filter) return;
    this.profileMediaFilter = filter;
    this.routeHighQuality = INITIAL_HIGH_QUALITY_POSTS;
    this.routePrefetchAt = -1;
    this.syncRouteFeed();
  }

  private async shareProfile(handle: string): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const data = new systemShare.SharedData({ utd: 'general.hyperlink', content: X_ORIGIN + '/' + handle });
      await new systemShare.ShareController(data).show(context, {});
    } catch (_) {
      this.getUIContext().getPromptAction().showToast({ message: ui('暂时无法分享个人资料', this.locale) });
    }
  }

  private openPostBodyLink(target: string): void {
    if (target.startsWith('@')) this.openProfile(target.slice(1));
    else if (isPostWebLink(target)) this.openWebsite(target, true);
  }

  private async openWebsite(url: string, browserOnly: boolean = false): Promise<void> {
    if (!url) return;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (browserOnly) {
        await context.startAbility({ action: 'ohos.want.action.viewData', uri: url,
          entities: ['entity.system.browsable'], type: 'text/html' });
      } else {
        await context.openLink(url);
      }
    } catch (_) {
      this.getUIContext().getPromptAction().showToast({ message: ui('暂时无法打开链接', this.locale) });
    }
  }

  private searchProfile(): void {
    if (!this.profile || this.trail.length >= 12) return;
    this.trail.push(this.route);
    this.query = 'from:' + this.profile.handle + ' ';
    this.navigate(new XRoute(Surface.Search, '/explore'));
  }

  private async resolveVideoSources(post: Post): Promise<string[]> {
    const key = post.videoPoster.match(/\/(?:ext_tw_video_thumb|amplify_video_thumb|tweet_video_thumb)\/([\w-]+)/)?.[1];
    if (!key) return post.videoSources;
    const token = post.id + '-' + Date.now().toString();
    const path = '/' + post.handle + '/status/' + post.id;
    const start = `(() => {
      if (location.origin !== 'https://x.com') return false;
      const token = ${JSON.stringify(token)};
      const key = ${JSON.stringify(key)};
      window.__qyxVideoRequest = token;
      window.__qyxVideoResult = null;
      fetch(${JSON.stringify(path)}, { credentials: 'same-origin' })
        .then(response => response.ok ? response.text() : '')
        .then(html => (html.match(/https:\\/\\/video\\.twimg\\.com\\/[\\w/.-]+\\.(?:mp4|m3u8)(?:\\?[\\w=&.%+-]+)?/g) || [])
          .filter(src => src.includes('/' + key + '/') || src.includes('/tweet_video/' + key + '.mp4')))
        .catch(() => [])
        .then(result => {
          if (window.__qyxVideoRequest === token) window.__qyxVideoResult = result.slice(0, 24);
        });
      return true;
    })()`;
    try {
      if (!isXUrl(this.controller.getUrl())) return post.videoSources;
      if (await this.controller.runJavaScript(start) !== 'true') return post.videoSources;
      // The page keeps the result under a per-request token, so a route change in the app does not invalidate it.
      for (let attempt = 0; attempt < 15; attempt++) {
        await new Promise<void>((resolve) => { setTimeout(resolve, 350); });
        const raw = await this.controller.runJavaScript('JSON.stringify(window.__qyxVideoRequest === ' +
          JSON.stringify(token) + ' ? window.__qyxVideoResult : null)');
        if (!raw || raw === 'null') continue;
        const result = raw.startsWith('"') ? JSON.parse(raw) as string : raw;
        if (result === 'null') continue;
        const sources = JSON.parse(result) as string[];
        if (Array.isArray(sources)) return normalizeVideoSources([...post.videoSources, ...sources]);
      }
    } catch (_) {}
    return post.videoSources;
  }

  private playVideo(post: Post): void {
    if (this.session !== Session.Active || !validHandle(post.handle) || !/^\d{1,24}$/.test(post.id)) return;
    this.videoRate = 1;
    this.cancelProbe();
    this.libraryProbe = null;
    this.translationProbe = null;
    this.mediaLookahead.stop();
    this.warmupQueue = [];
    clearTimeout(this.warmupTimer);
    if (this.warmupPost && this.warmupPost.id !== post.id) {
      clearTimeout(this.warmupUntil);
      this.warmupPost = null;
    }
    this.videoPaging = '';
    this.videoFeed = [post];
    this.videoRecommendationLabels.clear();
    this.startVideoFeed(post);
    this.selectVideoPost(post);
    this.configureVideoDisplay(post);
  }

  private startVideoFeed(post: Post): void {
    this.videoFeedExhausted = false;
    const route = new XRoute(Surface.Detail, '/' + post.handle + '/status/' + post.id + '/mediaViewer', '', 0, post.id);
    this.videoFeedProbe = new ReaderProbe(route, post);
  }

  private selectVideoPost(post: Post): void {
    this.videoPlaybackReady = false;
    this.cancelProbe();
    this.playerPost = post;
    const owner = this.verifiedReaderAccount;
    this.store.readVideo(post.id).then((sources: string[]) => {
      if (sources.length && this.playerPost?.id === post.id && this.verifiedReaderAccount === owner) {
        this.setPreparedVideoSources(post, sources);
      }
    }).catch(() => {});
    this.prepareNextVideos(post);
  }

  private prepareNextVideos(post: Post): void {
    if (this.playerPost?.id !== post.id) return;
    const index = this.videoFeed.findIndex((item: Post) => item.id === post.id);
    if (index < 0) return;
    const next = this.videoFeed.slice(index + 1, index + 3);
    this.queueTranslations([post, ...next], true);
    if (next.length) {
      this.mediaLookahead.prepare(next, this.imageQuality);
      this.scheduleVideoWarmup(next);
    }
  }

  private async readVideoFeed(probe: ReaderProbe): Promise<void> {
    const owner = this.verifiedReaderAccount;
    const web = probe.controller;
    const sources = [probe.route.path, '/i/video', '/home'];
    let sourceIndex = 0;
    let sourceDeadline = Date.now() + 8000;
    let nextAdvance = 0;
    let parked = false;
    try {
      configureXWeb(web, true);
      this.loadReadingPage(web, probe.route.url());
      while (this.videoFeedProbe === probe && this.verifiedReaderAccount === owner) {
        await this.waitForWeb(parked ? 900 : 650);
        if (this.videoFeedProbe !== probe || this.verifiedReaderAccount !== owner) return;
        const current = this.playerPost;
        const index = current ? this.videoFeed.findIndex((item: Post) => item.id === current.id) : -1;
        const canPark = !this.foreground || index < 0 || this.videoFeed.length - index > 3;
        if (canPark !== parked) {
          parked = canPark;
          if (parked) {
            await web.runJavaScript('window.__qyxVideoFeedIdle = true; document.querySelectorAll("video").forEach(video => video.pause());')
              .catch(() => {});
            if (this.videoFeedProbe !== probe) return;
            web.onInactive();
          } else {
            web.onActive();
            await web.runJavaScript('window.__qyxVideoFeedIdle = false;').catch(() => {});
            if (this.videoFeedProbe !== probe) return;
            sourceDeadline = Date.now() + 10000;
          }
        }
        if (parked || this.videoSlideTarget) continue;
        const address = sources[sourceIndex];
        let snapshot: Snapshot | undefined;
        try {
          if (isXUrl(web.getUrl())) {
            const script = address === '/home' ? this.readerScript(0, false, false) : this.plainReaderScript();
            snapshot = decodeSnapshot(await this.pageScripts.run(web, script));
          }
        } catch (_) {}
        if (this.videoFeedProbe !== probe || this.verifiedReaderAccount !== owner) return;
        const now = Date.now();
        if (snapshot?.ownHandle && owner && snapshot.ownHandle.toLowerCase() !== owner) break;
        const correctPage = !!snapshot?.authenticated && snapshot.path.replace(/\/$/, '').toLowerCase() === address.toLowerCase();
        if (snapshot && correctPage && !snapshot.pageError && (address !== '/home' || snapshot.homeTab === 0)) {
          const label = address === '/home' ? ui('为你推荐', this.locale) :
            address === '/i/video' ? ui('视频', this.locale) : '';
          const added = this.appendVideoFeed(snapshot.posts, label);
          if (added) {
            sourceDeadline = now + 12000;
            const source = address === '/home' ? 'for-you' : address === '/i/video' ? 'video-tab' : 'immersive';
            hilog.info(0x0000, 'QyxVideo', 'X recommendation source %{public}s added %{public}d total %{public}d',
              source, added, this.videoFeed.length);
          }
          if (this.videoFeed.length - index <= 3 && now >= nextAdvance) {
            nextAdvance = now + 1200;
            await web.runJavaScript(ADVANCE_VIDEO_FEED).catch(() => {});
            if (this.videoFeedProbe !== probe) return;
          }
        }
        if (now >= sourceDeadline || (correctPage && snapshot?.pageError)) {
          if (sourceIndex === sources.length - 1) break;
          sourceIndex++;
          sourceDeadline = now + 10000;
          nextAdvance = 0;
          this.loadReadingPage(web, X_ORIGIN + sources[sourceIndex]);
        }
      }
    } catch (_) {}
    if (this.videoFeedProbe === probe) {
      this.videoFeedExhausted = true;
      try { web.loadUrl(BLANK); } catch (_) {}
    }
  }

  private captureRecommendedSource(address: string): void {
    const sources = normalizeVideoSources([address]);
    const current = this.playerPost;
    if (!sources.length || !current) return;
    const position = this.videoFeed.findIndex((item: Post) => item.id === current.id);
    if (position < 0) return;
    const post = this.videoFeed.slice(position, position + 3).find((item: Post) =>
      matchesVideoAsset(address, videoPosterKey(item.videoPoster)));
    if (!post || post.videoSources.includes(address)) return;
    post.videoSources = normalizeVideoSources([...post.videoSources, ...sources]);
    this.setPreparedVideoSources(post, post.videoSources);
    if (post.id === current.id) return;
    this.warmedAt.delete(post.id);
    if (this.warmupPost?.id === post.id) {
      clearTimeout(this.warmupUntil);
      this.warmupPost = null;
    }
    this.prepareNextVideos(current);
  }

  private appendVideoFeed(posts: Post[], label: string): number {
    const known = new Map<string, Post>(this.videoFeed.map((post: Post): [string, Post] => [post.id, post]));
    let added = 0;
    let enriched = false;
    for (const post of posts) {
      if (!post.video || !validHandle(post.handle)) continue;
      const previous = known.get(post.id);
      if (!previous) {
        known.set(post.id, post);
        this.videoRecommendationLabels.set(post.id, label);
        added++;
      } else if (post.videoSources.some((source: string) => !previous.videoSources.includes(source))) {
        previous.videoSources = normalizeVideoSources([...previous.videoSources, ...post.videoSources]);
        this.setPreparedVideoSources(previous, previous.videoSources);
        this.warmedAt.delete(previous.id);
        if (this.warmupPost?.id === previous.id) {
          clearTimeout(this.warmupUntil);
          this.warmupPost = null;
        }
        enriched = true;
      }
    }
    if (!added && !enriched) return 0;
    this.videoFeed = Array.from(known.values());
    const current = this.playerPost;
    if (current) {
      this.prepareNextVideos(current);
    }
    if (added) this.observe('video-recommendations-ready');
    return added;
  }

  private async configureVideoDisplay(post: Post): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const displayWindow = await window.getLastWindow(context);
      if (this.videoFeedProbe?.post !== post) return;
      this.videoWindow = displayWindow;
      this.videoPreviousOrientation = displayWindow.getPreferredOrientation();
      this.videoPreviousBrightness = displayWindow.getWindowProperties().brightness;
      await displayWindow.setPreferredOrientation(window.Orientation.AUTO_ROTATION);
      if (this.videoFeedProbe?.post !== post) return;
      const displayId = displayWindow.getWindowProperties().displayId ?? display.getDefaultDisplaySync().id;
      const screen = display.getBrightnessInfo(displayId).brightnessPosition;
      this.videoBrightness = this.videoPreviousBrightness >= 0 ? this.videoPreviousBrightness : screen ?? 0.5;
    } catch (_) {}

  }

  private setVideoBrightness(value: number): void {
    this.videoBrightness = value;
    this.videoWindow?.setWindowBrightness(value).catch(() => {});
  }

  private setVideoVolume(value: number): void {
    this.videoVolume = value;
  }

  private clearVideoWarmup(): void {
    clearTimeout(this.warmupTimer);
    clearTimeout(this.warmupUntil);
    this.warmupGeneration++;
    this.warmupQueue = [];
    this.warmupPost = null;
    this.bufferingStartup = false;
    this.warmedAt.clear();
    this.videoStartup.clear();
  }

  private scheduleVideoWarmup(posts: Post[]): void {
    this.warmupQueue = posts.filter((post: Post) => post.video && validHandle(post.handle) &&
      /^\d{1,24}$/.test(post.id)).slice(0, 2);
    clearTimeout(this.warmupTimer);
    if (this.warmupQueue.length) this.warmupTimer = setTimeout(() => this.runVideoWarmup(), 180);
  }

  private runVideoWarmup(): void {
    if (!this.foreground || this.session !== Session.Active || !this.playbackWebSource.available ||
      this.warmupPost || this.bufferingStartup) return;
    const next = this.warmupQueue.shift();
    if (!next) return;
    if (Date.now() - (this.warmedAt.get(next.id) || 0) < 24000) {
      this.runVideoWarmup();
      return;
    }
    if (this.warmedAt.size >= 64) this.warmedAt.delete(Array.from(this.warmedAt.keys())[0]);
    this.warmedAt.set(next.id, Date.now());
    this.resolveWarmVideo(next);
  }

  private async resolveWarmVideo(next: Post): Promise<void> {
    const generation = this.warmupGeneration;
    this.bufferingStartup = true;
    const cached = await this.store.readVideo(next.id).catch((): string[] => []);
    if (generation !== this.warmupGeneration) return;
    this.bufferingStartup = false;
    if (!this.foreground || this.session !== Session.Active) return;
    const gif = next.videoPoster.includes('/tweet_video_thumb/') ? videoPosterKey(next.videoPoster) : '';
    const sources = [this.successfulVideoSources.get(next.id) || '', ...(this.preparedVideoSources.get(next.id) || []),
      ...cached, ...next.videoSources, gif ? 'https://video.twimg.com/tweet_video/' + gif + '.mp4' : ''];
    if (this.bufferVideoStartup(next, sources)) return;
    this.warmupPost = next;
    this.warmupUntil = setTimeout(() => {
      if (this.warmupPost?.id !== next.id) return;
      this.warmupPost = null;
      this.runVideoWarmup();
    }, 6500);
  }

  private bufferVideoStartup(post: Post, candidates: string[]): boolean {
    const sources = normalizeVideoSources(candidates).filter((source: string) => !/\/(?:aud|audio|mp4a)\//i.test(source));
    if (!sources.length) return false;
    this.setPreparedVideoSources(post, sources);
    const source = videoSourceOrder(sources, this.successfulVideoSources.get(post.id) || '', this.videoQuality)[0];
    const generation = this.warmupGeneration;
    this.bufferingStartup = true;
    this.videoStartup.warm(source, this.videoQuality).catch(() => {}).finally(() => {
      if (generation !== this.warmupGeneration) return;
      this.bufferingStartup = false;
      this.runVideoWarmup();
    });
    return true;
  }

  private acceptWarmupSources(post: Post, sources: string[]): void {
    if (this.warmupPost?.id !== post.id || !this.bufferVideoStartup(post, sources)) return;
    if (this.verifiedReaderAccount) this.store.saveVideo(post.id, sources).catch(() => {});
    clearTimeout(this.warmupUntil);
    this.warmupPost = null;
  }

  private setPreparedVideoSources(post: Post, sources: string[]): void {
    const prepared = new Map(this.preparedVideoSources);
    if (prepared.size >= 64 && !prepared.has(post.id)) prepared.delete(Array.from(prepared.keys())[0]);
    prepared.set(post.id, normalizeVideoSources([...sources, ...(prepared.get(post.id) || [])]));
    this.preparedVideoSources = prepared;
  }

  private attachPlaybackWebSource(address: string): void {
    if (!address.startsWith(X_ORIGIN + '/') || isXLoginUrl(address)) return;
    try { this.playbackWebSource.attach(this.controller); }
    catch (_) { hilog.warn(0x0000, 'QyxVideo', 'reader video channel unavailable'); }
  }

  private rememberVideoSource(post: Post, source: string): void {
    if (this.successfulVideoSources.size >= 64 && !this.successfulVideoSources.has(post.id)) {
      const first = Array.from(this.successfulVideoSources.keys())[0];
      if (first) this.successfulVideoSources.delete(first);
    }
    this.successfulVideoSources.set(post.id, source);
    if (this.verifiedReaderAccount) {
      this.store.saveVideo(post.id, [source, ...(this.preparedVideoSources.get(post.id) || []), ...post.videoSources])
        .catch(() => {});
    }
    this.prepareNextVideos(post);
  }

  private recordVideoDuration(post: Post, duration: number): void {
    const total = Math.ceil(duration);
    if (!Number.isFinite(total) || total <= 0) return;
    const hours = Math.floor(total / 3600);
    const minutes = Math.floor(total / 60) % 60;
    const seconds = (total % 60).toString().padStart(2, '0');
    const label = (hours ? hours.toString() + ':' + minutes.toString().padStart(2, '0') : minutes.toString()) +
      ':' + seconds;
    if (this.videoDurations.get(post.id) !== label) {
      const durations = new Map(this.videoDurations);
      durations.set(post.id, label);
      this.videoDurations = durations;
    }
  }

  private async readPostAction(controller: webview.WebviewController, operation: PostActionOperation): Promise<PostActionResult | null> {
    try {
      if (this.postActionOperation !== operation || this.session !== Session.Active || !isXUrl(controller.getUrl())) return null;
      const args = JSON.stringify({ id: operation.post.id, kind: operation.kind, token: operation.token,
        desired: operation.desired, click: !operation.sent });
      const raw = await this.pageScripts.run(controller, this.pageScripts.wrap(
        this.pageScripts.read.call('{ qyxLikeAction: ' + args + ' }'), [this.pageScripts.read]));
      if (!raw || raw === 'null') return null;
      const decoded = raw.startsWith('"') ? JSON.parse(raw) as string : raw;
      const result = JSON.parse(decoded) as PostActionResult;
      if (result?.status === 'clicked') operation.sent = true;
      return result?.status ? result : null;
    } catch (_) {
      return null;
    }
  }

  private handlePostMenuAction(post: Post, kind: string): void {
    if (this.session !== Session.Active || !validHandle(post.handle) || !/^\d{1,24}$/.test(post.id) ||
      !this.postMenuScript) return;
    if (this.postMenuOperation) {
      this.getUIContext().getPromptAction().showToast({ message: ui('正在处理上一个操作，请稍候', this.locale) });
      return;
    }
    const own = post.handle.toLowerCase() === this.handle.toLowerCase();
    if (own ? kind !== 'delete' : !['follow', 'mute', 'block'].includes(kind)) return;
    if (kind === 'delete' || kind === 'block') this.confirmPostMenu(post, kind);
    else this.startPostMenu(post, kind);
  }

  private confirmPostMenu(post: Post, kind: string): void {
    const deleting = kind === 'delete';
    this.getUIContext().getPromptAction().showDialog({
      title: deleting ? ui('删除这条帖子？', this.locale) : ui('屏蔽 @{0}？', this.locale, post.handle),
      message: deleting ? ui('删除后无法恢复，X 上的这条帖子也会被删除。', this.locale) :
        ui('对方将无法关注你或查看你的帖子，你也不会再看到对方的帖子。', this.locale),
      buttons: [
        { text: ui('取消', this.locale), color: INK },
        { text: deleting ? ui('删除', this.locale) : ui('屏蔽', this.locale), color: DESTRUCTIVE }
      ]
    }).then((result) => {
      if (result.index === 1) this.startPostMenu(post, kind);
    }).catch(() => {});
  }

  private startPostMenu(post: Post, kind: string): void {
    if (this.postMenuOperation || this.session !== Session.Active) return;
    this.postMenuOperation = new PostMenuOperation(post, kind);
    this.getUIContext().getPromptAction().showToast({ message: ui('正在提交到 X…', this.locale) });
  }

  private async runPostMenuAction(operation: PostMenuOperation): Promise<void> {
    let result = '';
    const args = JSON.stringify({ id: operation.post.id, handle: operation.post.handle, kind: operation.kind,
      token: operation.token });
    try {
      configureXWeb(operation.controller, true);
      this.loadReadingPage(operation.controller,
        X_ORIGIN + '/' + operation.post.handle + '/status/' + operation.post.id);
      const until = Date.now() + POST_MENU_TIMEOUT_MS;
      while (this.postMenuOperation === operation && Date.now() < until) {
        await this.waitForWeb(450);
        if (this.postMenuOperation !== operation) return;
        try {
          if (!isXUrl(operation.controller.getUrl())) continue;
          const raw = await operation.controller.runJavaScript('(' + this.postMenuScript + ')(' + args + ')');
          const stage = raw.startsWith('"') ? JSON.parse(raw) as string : raw;
          if (stage !== result) hilog.info(0x0000, 'QwitterMenu', '%{public}s stage=%{public}s', operation.kind, stage);
          result = stage;
        } catch (_) {
          continue;
        }
        if (POST_MENU_FINAL.includes(result)) break;
      }
    } catch (_) {}
    this.finishPostMenu(operation, result);
  }

  private finishPostMenu(operation: PostMenuOperation, result: string): void {
    if (this.postMenuOperation !== operation) return;
    this.postMenuOperation = null;
    const post = operation.post;
    const prompt = this.getUIContext().getPromptAction();
    if (!POST_MENU_DONE.includes(result)) {
      prompt.showToast({ message: ui(result === 'no-delete' ? '无法删除这条帖子' : '操作失败，请重试', this.locale) });
      return;
    }
    if (operation.kind === 'delete') {
      this.removeLocalPosts((item: Post) => item.id === post.id);
      if (this.surface === Surface.Detail && this.route.postId === post.id) this.back();
      prompt.showToast({ message: ui('帖子已删除', this.locale) });
      return;
    }
    if (operation.kind !== 'follow') {
      const author = post.handle.toLowerCase();
      if (!(this.surface === Surface.Profile && this.route.path.split('/')[1]?.toLowerCase() === author)) {
        this.removeLocalPosts((item: Post) => item.handle.toLowerCase() === author);
      }
    }
    const done = operation.kind === 'follow' ? '已关注 @{0}' : operation.kind === 'mute' ? '已隐藏 @{0}' : '已屏蔽 @{0}';
    prompt.showToast({ message: ui(done, this.locale, post.handle) });
  }

  // Drops posts from what is on screen. X's own pages no longer show them, so the next refresh agrees.
  private removeLocalPosts(match: (post: Post) => boolean): void {
    if (this.posts.some(match)) this.posts = this.posts.filter((post: Post) => !match(post));
    if (this.recommendedPosts.some(match)) this.recommendedPosts = this.recommendedPosts.filter((post: Post) => !match(post));
    if (this.followingPosts.some(match)) this.followingPosts = this.followingPosts.filter((post: Post) => !match(post));
  }

  private togglePostAction(post: Post, kind: string): void {
    const key = kind + ':' + post.id;
    const pending = this.pendingPostActions.includes(key);
    if (this.session !== Session.Active || !validHandle(post.handle) ||
      !/^\d{1,24}$/.test(post.id)) return;
    const previous = this.postActionStates.get(key);
    const active = previous?.liked ?? (kind === 'like' ? post.liked : kind === 'repost' ? post.reposted : post.bookmarked);
    const count = previous?.count ?? (kind === 'like' ? post.likes : kind === 'repost' ? post.reposts : post.bookmarks || '');
    const actions = new Map(this.postActionStates);
    let displayCount = count;
    if (/^\d*$/.test(count)) {
      const updated = Math.max(0, Number(count) + (active ? -1 : 1));
      displayCount = updated ? updated.toString() : '';
    }
    actions.set(key, { liked: !active, count: displayCount });
    this.postActionStates = actions;
    if (pending) {
      const intents = this.queuedPostActionIntents.get(key) || [];
      intents.push(!active);
      this.queuedPostActionIntents.set(key, intents);
      return;
    }
    this.pendingPostActions = [...this.pendingPostActions, key];
    this.postActionQueue.push(new PostActionOperation(post, kind, !active, previous));
    this.submitPostAction();
  }

  private async submitPostAction(): Promise<void> {
    if (this.postActionOperation || this.session !== Session.Active) return;
    const operation = this.postActionQueue.shift();
    if (!operation) return;
    this.postActionOperation = operation;
    let result = await this.readPostAction(this.controller, operation);
    for (let check = 0; check < 8 && this.postActionOperation === operation; check++) {
      if (result?.status !== 'menu' && !operation.sent) break;
      if (result?.status === 'confirmed') break;
      await this.waitForWeb(result?.status === 'clicked' ? 750 : 200);
      result = await this.readPostAction(this.controller, operation);
    }
    if (this.postActionOperation !== operation) return;
    if (result?.status === 'confirmed') this.finishPostAction(operation, result);
    else this.postActionProbe = operation;
  }

  private async runPostActionProbe(operation: PostActionOperation): Promise<void> {
    let result: PostActionResult | null = null;
    try {
      configureXWeb(operation.controller, true);
      this.loadReadingPage(operation.controller, X_ORIGIN + '/' + operation.post.handle + '/status/' + operation.post.id);
      for (let attempt = 0; attempt < 24 && this.postActionOperation === operation; attempt++) {
        await this.waitForWeb(result?.status === 'clicked' ? 950 : 400);
        result = await this.readPostAction(operation.controller, operation);
        if (result?.status === 'confirmed') break;
      }
    } catch (_) {}
    this.finishPostAction(operation, result);
  }

  private finishPostAction(operation: PostActionOperation, result: PostActionResult | null): void {
    if (this.postActionOperation !== operation) return;
    this.postActionOperation = null;
    this.postActionProbe = null;
    const intents = this.queuedPostActionIntents.get(operation.key);
    const followup = intents?.shift();
    if (!intents?.length) this.queuedPostActionIntents.delete(operation.key);
    const actions = new Map(this.postActionStates);
    const confirmed = result?.status === 'confirmed' && result.liked === operation.desired;
    let settled = operation.previous;
    if (confirmed && result) {
      let count = typeof result.count === 'string' ? result.count.slice(0, 20) : '';
      // X's page does not always show a bookmark count; keep the local count then.
      if (!count && operation.kind === 'bookmark') count = this.postActionStates.get(operation.key)?.count ?? '';
      settled = { liked: operation.desired, count };
    }
    if (followup !== undefined) {
      this.postActionQueue.unshift(new PostActionOperation(operation.post, operation.kind, followup, settled));
      this.submitPostAction();
      return;
    }
    this.pendingPostActions = this.pendingPostActions.filter((key: string) => key !== operation.key);
    if (settled) actions.set(operation.key, settled);
    else actions.delete(operation.key);
    if (!confirmed) {
      this.getUIContext().getPromptAction().showToast({ message: ui('操作失败，请重试', this.locale) });
    }
    this.postActionStates = actions;
    this.submitPostAction();
  }

  private dragVideo(offset: number): void {
    const current = this.playerPost;
    if (!current || this.videoAnimating || this.videoPaging) return;
    const direction = offset < 0 ? 1 : -1;
    const adjacent = this.adjacentVideo(current, direction);
    this.videoSlideDirection = direction;
    if (this.videoSlideTarget?.id !== adjacent?.id) this.videoSlideTarget = adjacent || null;
    const limit = adjacent ? this.playerHeight : this.playerHeight * 0.12;
    this.videoSlide = Math.max(-limit, Math.min(limit, adjacent ? offset : offset * 0.25));
  }

  private resetVideoDrag(): void {
    if (this.videoAnimating || !this.videoSlide) return;
    const revision = ++this.videoSwitchRevision;
    this.videoAnimating = true;
    const finish = (): void => {
      if (revision !== this.videoSwitchRevision || !this.videoAnimating) return;
      this.videoAnimating = false;
      this.videoSlideTarget = null;
    };
    this.getUIContext().animateTo({ duration: 150, curve: Curve.EaseOut, onFinish: finish }, () => {
      this.videoSlide = 0;
    });
    setTimeout(finish, 210);
  }

  private adjacentVideo(post: Post, direction: number): Post | undefined {
    const index = this.videoFeed.findIndex((entry: Post) => entry.id === post.id);
    return index < 0 ? undefined : this.videoFeed[index + direction];
  }

  private async swipeVideo(direction: number): Promise<void> {
    const current = this.playerPost;
    if (!current || this.videoAnimating) return;
    if (direction !== 1 && direction !== -1) {
      this.resetVideoDrag();
      return;
    }
    const adjacent = this.adjacentVideo(current, direction);
    if (adjacent) {
      this.animateVideoSwitch(current, adjacent, direction);
      return;
    }
    this.resetVideoDrag();
    if (direction < 0 || !this.videoFeedProbe || this.videoPaging === current.id) return;
    if (this.videoFeedExhausted) this.startVideoFeed(current);
    const feed = this.videoFeedProbe;
    this.videoPaging = current.id;
    this.getUIContext().getPromptAction().showToast({ message: ui('正在加载…', this.locale) });
    try {
      const deadline = Date.now() + 36000;
      while (!this.videoFeedExhausted && Date.now() < deadline) {
        await this.waitForWeb(200);
        if (this.playerPost?.id !== current.id || this.videoFeedProbe !== feed) return;
        const next = this.adjacentVideo(current, 1);
        if (next) {
          this.animateVideoSwitch(current, next, 1);
          return;
        }
      }
      const next = this.adjacentVideo(current, 1);
      if (this.playerPost?.id === current.id && this.videoFeedProbe === feed) {
        if (next) this.animateVideoSwitch(current, next, 1);
        else this.getUIContext().getPromptAction().showToast({
          message: ui(this.videoFeedExhausted ? '暂时没有更多视频' : '加载失败，请重试', this.locale)
        });
      }
    } finally {
      if (this.videoPaging === current.id) this.videoPaging = '';
    }
  }

  private animateVideoSwitch(current: Post, next: Post, direction: number): void {
    if (this.playerPost?.id !== current.id || this.videoAnimating) return;
    this.videoAnimating = true;
    const revision = ++this.videoSwitchRevision;
    this.videoSlideDirection = direction;
    this.videoSlideTarget = next;
    const finish = (): void => {
      if (revision !== this.videoSwitchRevision || this.playerPost?.id !== current.id ||
        this.videoSlideTarget?.id !== next.id) return;
      this.videoSlideTarget = null;
      this.videoSlide = 0;
      this.videoAnimating = false;
      this.selectVideoPost(next);
      hilog.info(0x0000, 'QyxVideo', 'recommendation switched');
    };
    this.getUIContext().animateTo({ duration: 170, curve: Curve.EaseOut, onFinish: finish }, () => {
      this.videoSlide = -direction * this.playerHeight;
    });
    setTimeout(finish, 240);
  }

  private closeVideo(): void {
    this.videoSwitchRevision++;
    this.videoAnimating = false;
    this.videoPlaybackReady = false;
    const probe = this.videoFeedProbe;
    this.videoFeedProbe = null;
    try { probe?.controller.stop(); } catch (_) {}
    this.clearVideoWarmup();
    this.cancelProbe();
    this.mediaLookahead.stop();
    this.playerPost = null;
    hilog.info(0x0000, 'QyxVideo', 'player work cancelled');
    this.videoFeed = [];
    this.videoRecommendationLabels.clear();
    this.videoPaging = '';
    const videoWindow = this.videoWindow;
    this.videoWindow = null;
    videoWindow?.setPreferredOrientation(this.videoPreviousOrientation).catch(() => {});
    videoWindow?.setWindowBrightness(this.videoPreviousBrightness).catch(() => {});
    this.videoSlideTarget = null;
    this.videoSlide = 0;
  }

  private async downloadVideoSources(post: Post): Promise<string[]> {
    const owner = this.verifiedReaderAccount;
    const cached = await this.store.readVideo(post.id).catch((): string[] => []);
    const sources = normalizeVideoSources([...(this.preparedVideoSources.get(post.id) || []),
      ...cached, ...await this.resolveVideoSources(post)]);
    if (sources.some((source: string) => !isAudioVideoSource(source))) return sources;
    return new Promise<string[]>((resolve) => {
      const timer = setTimeout(() => {
        this.downloadVideoResolve = undefined;
        resolve(sources);
      }, 12000);
      this.downloadVideoResolve = (next: string[]) => {
        if (this.session !== Session.Active || this.verifiedReaderAccount !== owner) {
          clearTimeout(timer);
          this.downloadVideoResolve = undefined;
          resolve([]);
          return;
        }
        const combined = normalizeVideoSources([...sources, ...next]);
        if (!combined.some((source: string) => !isAudioVideoSource(source))) return;
        clearTimeout(timer);
        this.downloadVideoResolve = undefined;
        this.setPreparedVideoSources(post, combined);
        resolve(combined);
      };
      this.downloadVideoPost = post;
    });
  }

  private async downloadMedia(post: Post, photo: string = '', suffix: string = ''): Promise<void> {
    if (this.session !== Session.Active) return;
    if (this.mediaBusy) {
      this.getUIContext().getPromptAction().showToast({ message: ui('正在下载上一个文件，请稍候', this.locale) });
      return;
    }
    this.mediaBusy = true;
    let target: MediaSaveTarget | undefined;
    let task: DownloadBackgroundTask | undefined;
    let saved = false;
    try {
      const prompt = this.getUIContext().getPromptAction();
      prompt.showToast({ message: ui('正在下载', this.locale) });
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const name = 'Qwitter-' + post.id + suffix;
      target = await createMediaSaveTarget(context, name, photo);
      task = new DownloadBackgroundTask(context, name);
      await task.start();
      const background = task;
      if (photo) {
        saved = await savePhoto(context, photo, name, target);
        if (saved) prompt.showToast({ message: ui('已保存', this.locale) });
        return;
      }
      const owner = this.handle.toLowerCase();
      const active = (): boolean => this.session === Session.Active && this.handle.toLowerCase() === owner;
      hilog.info(0x0000, 'QwitterDownload', 'video begin');
      this.downloadVideoPost = post;
      const sources = await this.downloadVideoSources(post);
      if (!active()) return;
      hilog.info(0x0000, 'QwitterDownload', 'sources count=%{public}d', sources.length);
      for (let ready = 0; ready < 100 && !this.downloadWebSource.available && active(); ready++) {
        await this.waitForWeb(100);
      }
      if (!active()) return;
      this.downloadWebSource.stopProbe();
      saved = await saveVideo(context, sources, this.downloadWebSource, name, active, target,
        (fraction: number) => background.update(fraction));
      if (saved) {
        hilog.info(0x0000, 'QwitterDownload', 'saved');
        prompt.showToast({ message: ui('已保存', this.locale) });
      }
    } catch (error) {
      const failure = error as Error;
      hilog.error(0x0000, 'QwitterDownload', 'failed %{public}s', failure.message || 'unknown');
      this.getUIContext().getPromptAction().showToast({ message: ui('下载失败，请重试', this.locale) });
    } finally {
      if (target) {
        await fileIo.close(target.file).catch(() => { hilog.warn(0x0000, 'QwitterDownload', 'asset close failed'); });
      }
      await task?.stop();
      if (target && !saved) {
        fileIo.unlink(target.uri).catch(() => { hilog.warn(0x0000, 'QwitterDownload', 'unfinished asset cleanup unavailable'); });
      }
      this.downloadVideoResolve = undefined;
      this.downloadVideoPost = null;
      this.downloadWebSource.close();
      this.mediaBusy = false;
    }
  }

  private back(): boolean {
    if (this.composerBusy && (!this.postComposer || this.composerSubmitted)) return true;
    if (this.postComposer) {
      if (this.postGifOpen) {
        this.discardPostGif();
        return true;
      }
      this.closePostComposer();
      return true;
    }
    if (this.chatWebVisible) {
      this.chatWebVisible = false;
      return true;
    }
    if (this.playerPost) {
      this.closeVideo();
      return true;
    }
    if (this.fullPhotos.length > 0) {
      this.closePhotos();
      return true;
    }
    if (this.drawerOpen) {
      this.showDrawer(false);
      return true;
    }
    if (this.settingsOpen) {
      if (this.settingsPaths.size()) this.settingsPaths.pop(true);
      else this.closeSettings();
      return true;
    }
    if (this.webUrl) {
      const switched = this.webUrl === X_ORIGIN + '/account/switch';
      this.webUrl = '';
      if (this.surface === Surface.Chat && !switched) {
        this.chatWaiting = !!this.chatItem && !this.chatMessages.length;
        this.conversationOpenAt = Date.now();
        this.ensureChatEngine(this.route.url());
        this.resumePolling();
        return true;
      }
      if (switched) {
        this.verifiedReaderAccount = '';
        this.navIndex = 0;
        this.trail = [];
        this.navigate(new XRoute(Surface.Home, '/home'));
      } else {
        this.restoreHomePosition();
      }
      return true;
    }
    if (this.chatItem) {
      this.clearOpenChat();
      this.readerPages.pop(true);
      this.returnChatEngineToList();
      return true;
    }
    if (this.session === Session.SigningIn) {
      this.flushCookies(true);
      this.session = Session.Starting;
      this.navigate(new XRoute(Surface.Home, '/home'));
      return true;
    }
    if (this.session === Session.Clearing || this.session === Session.ResetFailed) return true;
    const previous = this.trail.pop();
    if (previous) {
      if (previous.surface === Surface.Search) this.query = previous.query;
      this.navigate(previous);
      return true;
    }
    if (this.session === Session.Active && this.navIndex !== 0) {
      hilog.info(0x0000, 'QwitterTabs', 'system back to home from %{public}d', this.navIndex);
      this.changeTab(0);
      return true;
    }
    return false;
  }

  onBackPress(): boolean {
    return this.back();
  }

  private async nextPage(): Promise<void> {
    if (this.isLocalBrowsing(this.route)) return;
    if (!this.foreground || this.session !== Session.Active || this.content !== Content.Ready || this.settingsOpen || this.webUrl ||
      (this.navIndex > 1 && (this.surface === Surface.Home || this.surface === Surface.Search)) ||
      this.showingSavedHome || this.paging || this.routeRefreshRequested || this.feedItemCount() >= PAGE_LIMIT) return;
    if (this.surface === Surface.Home && this.homeNeedsPageSource) {
      this.recoveringHomePagination = true;
      this.refreshFeed(true, false);
      return;
    }
    if (this.routeCachedOnly) {
      this.routeCachedOnly = false;
      this.routeNeedsPaging = true;
      this.deadline = Date.now() + WAIT_MS;
      this.load(this.route.url());
      return;
    }
    if (this.detailCachedOnly) {
      this.detailNeedsPaging = true;
      this.detailConfirmed = false;
      this.paging = true;
      this.pageDeadline = Date.now() + WAIT_MS;
      this.pageAdvanceRounds = 0;
      this.load(this.route.url());
      return;
    }
    if (!this.ready || (this.surface === Surface.Home && !this.homeDocumentConfirmed)) return;
    if (this.surface === Surface.Home) {
      this.homeScrolled = false;
      this.homeWebPaged = true;
    }
    this.paging = true;
    this.pageNote = '';
    this.pageAdvanceRounds = 1;
    this.pageAdvanceAt = Date.now() + 2100;
    this.pageDeadline = Date.now() + (this.surface === Surface.Home ? 13500 : 15000);
    const generation = this.epoch;
    try {
      await this.controller.runJavaScript(this.surface === Surface.Detail ? ADVANCE_REPLIES : ADVANCE_PAGE);
      if (generation !== this.epoch) return;
      this.poll();
    } catch (_) {
      if (generation === this.epoch) {
        this.paging = false;
        this.pageNote = ui('加载失败，请重试', this.locale);
      }
    }
  }

  @Builder
  iconButton(icon: Resource, label: string, action: () => void) {
    Row() {
      GlassButton({ symbol: icon, accessibilityLabel: label, fixedWidth: 38, buttonHeight: 38, iconSize: 19, onTap: action })
    }.width(46).height(44).justifyContent(FlexAlign.Center)
  }

  @Builder
  chatEngineWeb(engine: ReaderProbe) {
    Web({ src: '', controller: engine.controller })
      .width('100%').height('100%')
      .opacity(this.chatWebVisible ? 1 : 0)
      .hitTestBehavior(this.chatWebVisible ? HitTestMode.Default : HitTestMode.None)
      .focusable(this.chatWebVisible || (this.composerBusy && !!this.chatItem))
      .accessibilityLevel(this.chatWebVisible ? 'auto' : 'no-hide-descendants')
      .javaScriptAccess(true)
      .domStorageAccess(true)
      .fileAccess(false)
      .onlineImageAccess(true)
      .enableAutoFill(false)
      .mixedMode(MixedMode.None)
      .runJavaScriptOnDocumentStart([
        { script: X_CONNECTIVITY, scriptRules: [X_ORIGIN, 'https://chat.x.com'] },
        { script: CHAT_HIDE_SITE_TABS, scriptRules: [X_ORIGIN, 'https://chat.x.com'] },
        { script: CHAT_CHANGE_SIGNAL, scriptRules: [X_ORIGIN, 'https://chat.x.com'] }])
      .onConsole((event) => {
        const message = event.message.getMessage();
        if (message === 'qyx-chat-change') this.chatSignal(engine);
        else if (/^qyx-chat-dom:[0-9:]+$/.test(message)) hilog.info(0x0000, 'QwitterChat', '%{public}s', message);
        return false;
      })
      .onWindowNew((event) => { event.handler.setWebController(null); })
      .onLoadIntercept((event) => {
        if (!event.data.isMainFrame()) return false;
        const url = event.data.getRequestUrl();
        return url !== BLANK && !isXUrl(url) && !isXChatUrl(url);
      })
      .onControllerAttached(() => this.attachChatEngine(engine))
      .onPageBegin((event) => {
        if (this.chatEngine !== engine) return;
        this.chatEngineReady = false;
        this.chatEngineLoadAt = Date.now();
        this.logChat('begin ' + this.chatHost(event.url));
      })
      .onPageVisible((event) => this.chatPageEnded(engine, event.url))
      .onLoadFinished((event) => this.chatPageEnded(engine, event.url))
      .onPageEnd((event) => this.chatPageEnded(engine, event.url))
  }

  @Builder
  sessionWeb() {
    Web({ src: '', controller: this.controller })
      .cacheMode(this.session === Session.Active && this.surface === Surface.Search && this.submittedQuery ?
        CacheMode.Online : CacheMode.Default)
      .width('100%').height('100%')
      .opacity(this.loginWebVisible() ? 1 : 0)
      .hitTestBehavior(this.loginWebVisible() ? HitTestMode.Default : HitTestMode.None)
      .focusable(this.loginWebVisible())
      .accessibilityLevel(this.loginWebVisible() ? 'auto' : 'no-hide-descendants')
      .javaScriptAccess(true)
      .domStorageAccess(true)
      .fileAccess(false)
      .onlineImageAccess(this.session === Session.SigningIn || this.surface === Surface.Chat ||
        (this.surface === Surface.Search && this.searchMode === 'photos'))
      .enableAutoFill(false)
      .multiWindowAccess(this.session === Session.SigningIn)
      .allowWindowOpenMethod(this.session === Session.SigningIn)
      .mixedMode(MixedMode.None)
      .runJavaScriptOnDocumentStart([{
        script: X_CONNECTIVITY,
        scriptRules: [X_ORIGIN, 'https://chat.x.com', 'https://www.x.com', 'https://twitter.com', 'https://www.twitter.com',
          'https://mobile.twitter.com']
      }, { script: LOGIN_PASSWORD_TRACE, scriptRules: [X_ORIGIN] },
        { script: VIDEO_TRANSPORT_SCRIPT, scriptRules: [X_ORIGIN] },
        { script: CHAT_HIDE_SITE_TABS, scriptRules: [X_ORIGIN, 'https://chat.x.com'] },
        { script: READER_PAUSE_WEB_VIDEO, scriptRules: [X_ORIGIN] }])
      .onConsole((event) => {
        const message = event.message.getMessage();
        if (this.session === Session.SigningIn &&
          /^qwitter-login-trace:(continue-button|form-submit-button|password-button|password-field|no-password-field|phone-invalid|field-invalid|field-synced|form-submitted|script-error|script-rejection|onboarding-response-(?:0|[1-5][0-9]{2})|subtask-[A-Za-z-]{1,250}|webauthn-[A-Za-z-]{1,60}|passkeys-hidden|after-password:[a-z,]{0,80}:frames=[0-9])$/.test(message)) {
          hilog.info(0x0000, 'QwitterLogin', '%{public}s', message);
        }
        if (this.session === Session.SigningIn &&
          (message === 'qwitter-login-trace:onboarding-response-429' || message === 'qwitter-login-trace:cooldown')) {
          this.getUIContext().getPromptAction().showToast({ message: ui('X 请求过于频繁，请稍后再试', this.locale) });
        }
        if (message === 'qyx-arkweb-online-corrected') this.observe('web-online-corrected');
        if (this.surface === Surface.Chat && /^qyx-chat-dom:[0-9:]+$/.test(message)) {
          hilog.info(0x0000, 'QwitterChat', '%{public}s', message);
        }
        return false;
      })
      .onWindowNew((event) => {
        event.handler.setWebController(null);
        if (this.session !== Session.SigningIn) return;
        if (isXLoginUrl(event.targetUrl)) {
          this.load(event.targetUrl);
          this.observe('login-window-opened-in-place');
        } else {
          this.observe('login-window-blocked');
        }
      })
      .onLoadIntercept((event) => {
        if (!event.data.isMainFrame()) return false;
        const url = event.data.getRequestUrl();
        if (url === BLANK) return false;
        if (this.session === Session.Clearing || this.session === Session.ResetFailed ||
          this.session === Session.SignedOut) return true;
        if (isXUrl(url) || (this.surface === Surface.Chat && isXChatUrl(url)) ||
          (this.session === Session.SigningIn && isXLoginUrl(url))) return false;
        if (this.session === Session.SigningIn) this.observe('login-navigation-blocked');
        return true;
      })
      .onControllerAttached(() => {
        configureXWeb(this.controller, true);
        if (deviceInfo.deviceType === 'tablet') {
          try { this.tabletReaderUserAgent = this.controller.getUserAgent(); } catch (_) {}
        }
        this.start();
      })
      .onPageBegin((event) => {
        this.playbackWebSource.documentChanging();
        if (this.followingPostId && isXUrl(event.url) &&
          event.url.split(/[?#]/)[0].replace(/\/$/, '').endsWith('/status/' + this.followingPostId)) {
          this.followedPostStarted = true;
        }
      })
      .onNavigationEntryCommitted((event) => {
        if (!event.isMainFrame) return;
        this.updateLoginDocument(event.url);
        if (((this.surface === Surface.Detail || this.surface === Surface.Search || this.surface === Surface.Profile ||
          this.surface === Surface.Notifications) &&
          isXUrl(event.url) && !this.detailCachedOnly) ||
          (this.surface === Surface.Chat && isXChatUrl(event.url))) {
          this.pageEnded(event.url);
        }
        if (this.session === Session.SigningIn) {
          this.observe(isXLoginUrl(event.url) ? 'login-page-committed' : 'login-redirect-committed');
        }
      })
      .onPageVisible((event) => {
        this.pageVisible(event.url);
        this.attachPlaybackWebSource(event.url);
      })
      .onLoadFinished((event) => this.pageEnded(event.url))
      .onPageEnd((event) => {
        this.pageEnded(event.url);
        this.attachPlaybackWebSource(event.url);
      })
      .onErrorReceive((event) => {
        if (!event.request.isMainFrame()) return;
        const code = event.error.getErrorCode();
        if (this.surface === Surface.Profile) {
          if (!this.profileRequest(event.request.getRequestUrl())) return;
          if (code !== -3 && this.retryProfile()) return;
        }
        if (this.session === Session.SigningIn) this.observe('login-network-error-' + code);
        this.handleWebError(code);
      })
      .onHttpErrorReceive((event) => {
        const mainFrame = event.request.isMainFrame();
        if (mainFrame && this.surface === Surface.Profile) {
          if (!this.profileRequest(event.request.getRequestUrl())) return;
          const code = event.response.getResponseCode();
          if ((code >= 500 || code === 408) && this.retryProfile()) return;
        }
        if (this.session === Session.SigningIn) {
          if (mainFrame) {
            this.observe('login-http-error-' + event.response.getResponseCode());
          } else if (/^https:\/\/(?:x\.com|api\.x\.com)\/[^?#]*\/onboarding\//.test(event.request.getRequestUrl())) {
            this.observe('login-request-error-' + event.response.getResponseCode());
          }
        }
        if (mainFrame) this.fail(ui('X 网页加载失败，请稍后重试。', this.locale));
      })
      .onRenderExited(() => {
        this.ready = false;
        this.fail(ui('网页进程已退出，请重试。', this.locale));
      })
  }

  @Builder
  startupIcon() {
    if (this.launcherIconId !== 'pending') {
      Image(launcherIconImage(this.launcherIconId)).width(78).height(78).borderRadius(18)
        .accessibilityLevel('no')
    }
  }

  @Builder
  welcome() {
    Column({ space: 14 }) {
      this.startupIcon()
      Text('Qwitter').fontSize(52).fontWeight(FontWeight.Bold).letterSpacing(-2).fontColor(INK)
      Text(ui('只为热爱，去写', this.locale)).fontSize(21).fontWeight(FontWeight.Medium).fontColor(INK)
      Text(this.expired ? ui('X 会话已失效，请重新登录。', this.locale) : ui('在鸿蒙上阅读你的 X 时间线。', this.locale))
        .fontSize(14).fontColor(MUTED).textAlign(TextAlign.Center).margin({ top: 3 })
      GlassButton({ label: ui('在 x.com 登录', this.locale), filled: true, fixedWidth: 280, buttonHeight: 50, fontSize: 16,
        onTap: () => this.beginLogin() })
        .margin({ top: 12 })
    }.width('100%').height('100%').justifyContent(FlexAlign.Center).padding(28)
  }

  @Builder
  feedback(title: string, description: string, actionLabel: string, action: () => void) {
    Column({ space: 10 }) {
      Text(title).fontSize(22).fontWeight(FontWeight.Bold).fontColor(INK).textAlign(TextAlign.Center)
      Text(description).fontSize(14).fontColor(MUTED).textAlign(TextAlign.Center)
      if (actionLabel) {
        GlassButton({ label: actionLabel, filled: true, onTap: action }).margin({ top: 5 })
      }
    }.width('100%').padding({ left: 22, right: 22, top: 38, bottom: 38 })
  }

  @Builder
  loginHeader() {
    Row({ space: 4 }) {
      this.iconButton($r('sys.symbol.chevron_left'), ui('返回', this.locale), () => { this.back(); })
      Text(ui('登录 X', this.locale)).fontWeight(FontWeight.Bold).fontSize(17).fontColor(INK)
    }.width('100%').height(55).backgroundColor(PAPER)
      .border({ width: { bottom: 1 }, color: RULE })
  }

  @Builder
  titleBar(home: boolean = false) {
    Stack({ alignContent: Alignment.Center }) {
      if (home) {
        Image($r('app.media.qwitter_mark')).height(23).width(23).objectFit(ImageFit.Contain)
          .draggable(false).accessibilityText('Qwitter')
      } else {
        Text(this.surface === Surface.Search ? ui('搜索', this.locale) : this.surface === Surface.Bookmarks ? ui('历史', this.locale) :
          this.surface === Surface.Detail ? ui('帖子', this.locale) : ui('个人资料', this.locale))
          .fontSize(19).fontWeight(FontWeight.Bold).fontColor(INK)
      }
      Row() {
        if (!home && (this.surface === Surface.Profile || this.surface === Surface.Detail || this.surface === Surface.Bookmarks)) {
          this.iconButton($r('sys.symbol.chevron_left'), ui('返回', this.locale), () => { this.back(); })
        } else if (!this.wideTablet) {
          Button({ type: ButtonType.Circle }) {
            Avatar({ src: this.ownProfile?.avatar || this.avatar, diameter: 30 })
          }.width(45).height(44).backgroundColor(Color.Transparent).accessibilityText(ui('打开账号侧栏', this.locale))
            .onClick(() => { this.showDrawer(true); })
        }
        Blank()
      }.width('100%').padding({ left: 7 })
    }.width('100%').height(50)
  }

  @Builder
  homeSelector(label: string, tab: number) {
    Column({ space: 8 }) {
      Row({ space: 5 }) {
        Text(label).fontSize(15).fontColor(this.homeTab === tab ? INK : MUTED)
          .fontWeight(this.homeTab === tab ? FontWeight.Bold : FontWeight.Medium)
        if (tab === 0) {
          Image($r('app.media.menu_chevron')).width(12).height(12)
        }
      }
      Row().width(87).height(2).borderRadius(2).backgroundColor(this.homeTab === tab ? INK : Color.Transparent)
    }.layoutWeight(1).height(42).justifyContent(FlexAlign.End)
      .accessibilityText(label + (this.homeTab === tab ? ui('，已选择', this.locale) : ''))
      .onClick(() => this.selectTimeline(tab))
  }

  @Builder
  tabIcon(label: string, icon: Resource, activeIcon: Resource, index: number) {
    Stack({ alignContent: Alignment.Center }) {
      Stack({ alignContent: Alignment.Center }) {
        Image(this.navIndex === index ? activeIcon : icon).width(23).height(23).draggable(false)
          .fillColor(this.navIndex === index ? this.accentInk : INK)
        if (this.tabLabels) {
          Text(label).width(56).height(12).fontSize(10).textAlign(TextAlign.Center)
            .fontColor(this.navIndex === index ? this.accentInk : INK).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .position({ x: 2, y: this.tabHeight / 2 + 12 })
        }
        // Floating Tabs place custom content below the visual center of the material.
      }.width('100%').height('100%').translate({ y: -3.5 })
    }.width(60).height(this.tabHeight)
      .accessibilityText(label).accessibilitySelected(this.navIndex === index)
      .onClick(() => {
        hilog.info(0x0000, 'QwitterTabs', 'primary icon clicked %{public}d', index);
        this.homeTabClicked(index);
      }, 6)
  }

  private updateHomeHeader(delta: number, source: ScrollSource): void {
    if (this.drawerOpen || (source !== ScrollSource.DRAG && source !== ScrollSource.OTHER_USER_INPUT)) return;
    if (this.homeScrollDelta * delta < 0) this.homeScrollDelta = 0;
    this.homeScrollDelta += delta;
    if (Math.abs(this.homeScrollDelta) < 26) return;
    const hide = this.homeScrollDelta > 0;
    this.homeScrollDelta = 0;
    if (hide === this.homeHeaderHidden) return;
    this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
      this.homeHeaderHidden = hide;
    });
  }

  private hideReaderTabs(): boolean {
    return this.wideTablet || /\/(?:status|article)\/\d+/.test(this.webUrl);
  }

  private replyGroups(): ReplyGroup[] {
    const groups: ReplyGroup[] = [];
    const byId = new Map<string, ReplyGroup>();
    for (const post of this.posts) {
      const parent = byId.get(post.replyToId);
      if (parent) {
        parent.replies.push(post);
        byId.set(post.id, parent);
      } else {
        const group = new ReplyGroup(post);
        groups.push(group);
        byId.set(post.id, group);
      }
    }
    return groups;
  }

  private showPhotos(photos: string[], index: number = 0): void {
    if (!photos.length) return;
    this.photoIndex = index;
    this.photoSlide = 0;
    this.photoClosing = false;
    this.galleryTouchPost = '';
    this.fullPhotos = photos;
  }

  private closePhotos(direction: number = 1): void {
    if (!this.fullPhotos.length || this.photoClosing) return;
    this.photoClosing = true;
    this.getUIContext().animateTo({
      duration: 190,
      curve: Curve.EaseOut,
      onFinish: () => {
        this.fullPhotos = [];
        this.photoSlide = 0;
        this.photoClosing = false;
      }
    }, () => {
      this.photoSlide = direction * this.photoHeight;
    });
  }

  @Builder
  postCard(post: Post, highQuality: boolean = true) {
    PostCard({
      post,
      likeState: this.postActionStates.get('like:' + post.id) || null,
      repostState: this.postActionStates.get('repost:' + post.id) || null,
      bookmarkState: this.postActionStates.get('bookmark:' + post.id) || null,
      videoDuration: this.videoDurations.get(post.id) || null,
      translatedPost: this.translatedPosts.get(post.id) || null,
      translatedQuote: this.translatedPosts.get(post.quotedPost?.path.split('/').pop() || '') || null,
      separated: this.surface !== Surface.Detail,
      selectableText: this.surface === Surface.Detail,
      highQuality,
      onPost: () => this.openPost(post),
      onReply: () => this.openPostComposer(post),
      onProfile: () => this.openProfile(post.handle, post),
      onBodyLink: (target: string) => this.openPostBodyLink(target),
      onPhoto: (index: number) => this.showPhotos(post.photos, index),
      onGalleryTouch: (active: boolean) => {
        if (active) this.galleryTouchPost = post.id;
        else if (this.galleryTouchPost === post.id) this.galleryTouchPost = '';
      },
      onArticle: () => this.openWebsite(X_ORIGIN + post.articlePath),
      onQuote: (quote: QuotedPost) => this.openQuote(quote, post),
      onDownloadQuote: (quote: QuotedPost) => {
        if (quote.video) {
          const quoted = this.quotedMediaPost(quote);
          if (quoted) this.downloadMedia(quoted);
        } else if (quote.photo) {
          this.downloadMedia(post, quote.photo, '-quote');
        }
      },
      onPlayVideo: () => this.playVideo(post),
      onDownloadVideo: () => this.downloadMedia(post),
      onDownloadPhoto: (index: number) => this.downloadMedia(post, post.photos[index], '-' + (index + 1).toString()),
      onShare: () => this.copyPostLink(post),
      onLike: () => this.togglePostAction(post, 'like'),
      onRepost: () => this.togglePostAction(post, 'repost'),
      onBookmark: () => this.togglePostAction(post, 'bookmark'),
      ownHandle: this.handle,
      onMore: (kind: string) => this.handlePostMenuAction(post, kind)
    })
  }

  @Builder
  feed(bottomOffset: number, homeTab: number = -1) {
    Refresh({ refreshing: this.activeFeed(homeTab) && this.refreshing }) {
      List({ space: homeTab < 0 && this.surface === Surface.Detail ? 0 : 8,
        scroller: this.feedScroller(homeTab) }) {
        if (homeTab >= 0) {
          ListItem() {
            Row().width('100%').height(Math.max(0, this.statusInset + HOME_HEADER_HEIGHT - 8))
          }.accessibilityLevel('no')
        }
        if (homeTab < 0 && this.profile) {
          ListItem() {
            ProfileHeader({
              profile: this.profile,
              own: this.profile.handle.toLowerCase() === this.handle.toLowerCase(),
              selectedTab: this.profileTab,
              mediaFilter: this.profileMediaFilter,
              onShare: () => { if (this.profile) this.shareProfile(this.profile.handle); },
              onWeb: (title: string, path: string) => { if (path) this.openWeb(title, path); },
              onWebsite: (url: string) => this.openWebsite(url),
              onTab: (tab: string) => this.selectProfileTab(tab),
              onMediaFilter: (filter: number) => this.selectProfileMediaFilter(filter)
            })
          }
        }
        if (homeTab < 0 && this.surface === Surface.Detail && this.detailPost) {
          ListItem() { this.postCard(this.detailPost) }
            .onVisibleAreaChange([0.3], (visible: boolean) => {
              if (visible && this.detailPost) this.queueTranslation(this.detailPost);
            })
          ListItem() { Row().width('100%').height(8).backgroundColor(SOFT) }
          ListItem() {
            Text(this.detailPost.replies ? ui('评论 {0}', this.locale, this.detailPost.replies) : ui('评论', this.locale))
              .fontSize(16).fontWeight(FontWeight.Bold).fontColor(INK)
              .width('100%').padding({ left: 14, top: 12, bottom: 10 })
              .border({ width: { bottom: 1 }, color: RULE })
          }
        }
        if (this.activeFeed(homeTab) && this.showingSavedHome && this.content === Content.Failed) {
          ListItem() {
            Row({ space: 8 }) {
              Text(this.content === Content.Failed ? ui('上次保存 · 同步失败', this.locale) : ui('上次保存 · 正在同步', this.locale))
                .fontSize(12).fontColor(MUTED)
              if (this.content === Content.Failed) {
                Button(ui('重试', this.locale)).buttonStyle(ButtonStyleMode.TEXTUAL).fontSize(12).fontColor(this.accentInk)
                  .onClick(() => this.refreshFeed())
              }
            }.width('100%').height(33).justifyContent(FlexAlign.Center)
          }
        } else if (this.activeFeed(homeTab) && this.surface === Surface.Detail && !this.posts.length &&
          (this.detailPost?.replies.trim() === '0' || this.content === Content.Empty)) {
          ListItem() {
            this.feedback(ui('暂无回复', this.locale), '', '', () => {})
          }
        } else if (this.activeFeed(homeTab) && !this.showingSavedHome && this.content === Content.Loading &&
          (this.surface !== Surface.Detail || !this.posts.length) && this.surface !== Surface.Profile) {
          ListItem() {
            Row({ space: 10 }) {
              LoadingProgress().width(23).height(23).color(this.accentInk)
              Text(this.detailPost ? ui('正在加载回复…', this.locale) : this.surface === Surface.Search ? ui('正在搜索 X…', this.locale) : ui('正在读取 X…', this.locale))
                .fontSize(14).fontColor(MUTED)
            }.width('100%').height(106).justifyContent(FlexAlign.Center)
          }
        } else if (this.activeFeed(homeTab) && this.content === Content.Failed) {
          ListItem() {
            this.feedback(this.detailPost ? ui('暂未读取到回复', this.locale) : ui('暂时无法读取', this.locale), this.problem, ui('重试', this.locale), () => this.refreshFeed())
          }
        } else if (this.activeFeed(homeTab) && this.content === Content.Empty) {
          ListItem() {
            this.feedback(this.detailPost ? ui('暂无回复', this.locale) : this.surface === Surface.Search ? ui(this.searchMode === 'people' ? '未找到相关用户' : '未找到相关帖子', this.locale) : ui('这里还没有帖子', this.locale),
              this.detailPost ? '' : this.surface === Surface.Search ? ui('试试其他关键词。', this.locale) : ui('当前没有可显示的帖子。', this.locale),
              ui('刷新', this.locale), () => this.refreshFeed())
          }
        }
        if (homeTab < 0 && this.surface === Surface.Search && this.searchMode === 'people') {
          ForEach(this.searchPeople, (person: DiscoveryRow) => {
            ListItem() {
              Row({ space: 12 }) {
                Avatar({ src: person.avatar, diameter: 44 })
                Column({ space: 4 }) {
                  Row({ space: 5 }) {
                    Text(person.title).fontSize(15).fontWeight(FontWeight.Bold).fontColor(INK)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
                    if (person.verified) Image($r('app.media.menu_verified')).width(14).height(14)
                  }.width('100%')
                  Text(person.subtitle).fontSize(14).lineHeight(19).fontColor(MUTED).maxLines(4)
                    .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              }.width('100%').padding(14).alignItems(VerticalAlign.Top).backgroundColor(PAPER)
                .onClick(() => this.openProfile(person.path.slice(1)))
            }
          }, (person: DiscoveryRow) => person.path.toLowerCase())
        } else if (homeTab < 0 && this.surface === Surface.Detail) {
          ForEach(this.replyGroups(), (group: ReplyGroup) => {
            ListItem() {
              ReplyThread({
                group,
                inline: this.inlineReplies,
                translations: this.translatedPosts,
                likes: this.postActionStates,
                onExpand: (post: Post, force: boolean) => this.expandReplies(post, force),
                onReply: (post: Post) => this.openPostComposer(post),
                onCollapse: (post: Post) => this.collapseReplies(post),
                onPhotos: (photos: string[], index: number) => this.showPhotos(photos, index),
                onVideo: (post: Post) => this.playVideo(post),
                onProfile: (post: Post) => this.openProfile(post.handle, post),
                onBodyLink: (target: string) => this.openPostBodyLink(target),
                onLike: (post: Post) => this.togglePostAction(post, 'like'),
                ownHandle: this.handle,
                onMore: (post: Post, kind: string) => this.handlePostMenuAction(post, kind)
              })
            }.onVisibleAreaChange([0.25], (visible: boolean) => {
              this.queueInlinePreview(group.post, visible);
              if (visible) this.queueTranslations([group.post, ...group.replies], true);
            })
          }, (group: ReplyGroup) => group.post.id + ':' + group.replies.length.toString())
        } else if (homeTab >= 0) {
          LazyForEach(homeTab === 0 ? this.recommendedSource : this.followingSource, (post: Post, index: number) => {
            ListItem() {
              this.postCard(post, index < (homeTab === 0 ? this.recommendedHighQuality : this.followingHighQuality))
            }.onVisibleAreaChange([0.25], (visible: boolean) => {
              if (visible && this.activeFeed(homeTab)) this.queueTranslation(post);
            })
          }, (post: Post) => this.homeSnapshotRevision[homeTab].toString() + ':' + this.feedPostKey(post))
        } else if (this.usesLazyRouteFeed()) {
          LazyForEach(this.routeFeedSource, (post: Post, index: number) => {
            ListItem() {
              this.postCard(post, index < this.routeHighQuality)
            }.onVisibleAreaChange([0.25], (visible: boolean) => {
              if (visible) this.queueTranslation(post);
            })
          }, (post: Post) => this.feedPostKey(post))
        } else {
          ForEach(this.feedPosts(homeTab), (post: Post) => {
            ListItem() {
              this.postCard(post)
            }.onVisibleAreaChange([0.25], (visible: boolean) => {
              if (visible && this.activeFeed(homeTab)) {
                this.queueTranslation(post);
              }
            })
          }, (post: Post) => this.feedPostKey(post))
        }
        if (homeTab < 0 && this.surface === Surface.Profile && this.profileTab === 'media' && this.profileMediaFilter !== 0 &&
          this.content === Content.Ready && !this.feedPosts(homeTab).length && !this.paging && !this.pageNote) {
          ListItem() {
            Button(ui('加载更多', this.locale)).buttonStyle(ButtonStyleMode.TEXTUAL).fontColor(this.accentInk)
              .width('100%').onClick(() => this.nextPage())
          }
        }
        if (this.activeFeed(homeTab) && this.content === Content.Ready && (this.paging || this.pageNote)) {
          ListItem() {
            Row({ space: 8 }) {
              if (this.paging) LoadingProgress().width(18).height(18).color(this.accentInk)
              Text(this.paging ? ui('正在加载…', this.locale) : this.pageNote).fontColor(MUTED).fontSize(12)
              if (!this.paging && this.posts.length < PAGE_LIMIT) {
                Button(ui('重试', this.locale)).buttonStyle(ButtonStyleMode.TEXTUAL).fontColor(this.accentInk)
                  .onClick(() => this.nextPage())
              }
            }.height(44).width('100%').justifyContent(FlexAlign.Center)
          }
        }
        if (homeTab < 0 && this.detailCachedOnly && this.content === Content.Ready && this.posts.length < PAGE_LIMIT) {
          ListItem() {
            Button(ui('加载更多回复', this.locale)).buttonStyle(ButtonStyleMode.TEXTUAL).fontColor(this.accentInk)
              .width('100%').height(44).onClick(() => this.nextPage())
          }
        }
        if (homeTab < 0 && this.routeCachedOnly && this.content === Content.Ready && this.posts.length < PAGE_LIMIT) {
          ListItem() {
            Button(ui('加载更多', this.locale)).buttonStyle(ButtonStyleMode.TEXTUAL).fontColor(this.accentInk)
              .width('100%').height(44).onClick(() => this.nextPage())
          }
        }
      }.width('100%').height('100%').scrollBar(BarState.Off)
        .cachedCount(2)
        .backgroundColor(homeTab < 0 && this.surface === Surface.Detail ? PAPER : SOFT)
        .contentEndOffset(bottomOffset)
        .onWillStartFling(() => { this.feedFlinging[homeTab + 1] = true; })
        .onDidStopFling(() => { this.feedFlinging[homeTab + 1] = false; })
        .onDisAppear(() => { this.feedFlinging[homeTab + 1] = false; })
        .onTouchIntercept((event: TouchEvent): HitTestMode => {
          if (event.type !== TouchType.Down || !this.feedFlinging[homeTab + 1]) return HitTestMode.Default;
          this.feedFlinging[homeTab + 1] = false;
          const scroller = this.feedScroller(homeTab);
          scroller.scrollTo({ xOffset: 0, yOffset: scroller.currentOffset().yOffset, animation: false });
          return HitTestMode.Block;
        })
        .onWillScroll((offset: number, _state: ScrollState, source: ScrollSource) => {
          if (homeTab < 0 && offset > 0 && (source === ScrollSource.DRAG || source === ScrollSource.OTHER_USER_INPUT)) {
            this.routeScrolled = true;
          }
          if (homeTab >= 0 && this.activeFeed(homeTab)) {
            if (offset > 0 && (source === ScrollSource.DRAG || source === ScrollSource.OTHER_USER_INPUT)) {
              this.homeScrolled = true;
              this.pendingHomePosition[homeTab] = undefined;
            }
            this.updateHomeHeader(offset, source);
          }
        })
        .onReachStart(() => {
          if (homeTab >= 0 && this.activeFeed(homeTab)) {
            this.homeHeaderHidden = false;
            this.homeScrollDelta = 0;
          }
        })
        .onReachEnd(() => {
          if (homeTab >= 0 && this.activeFeed(homeTab) && this.homeScrolled && !this.homeRefreshRequested) {
            if (this.posts.length >= PAGE_LIMIT && !this.hasNewHomePosts(homeTab)) {
              this.refreshFeed(true);
              return;
            }
          }
          if (this.activeFeed(homeTab) && (homeTab < 0 || this.homeScrolled) &&
            !this.pageNote && !this.detailCachedOnly && (!this.routeCachedOnly || this.routeScrolled)) this.nextPage();
        })
        .onScrollStop(() => {
          this.feedFlinging[homeTab + 1] = false;
          if (homeTab >= 0 && this.activeFeed(homeTab)) {
            this.rememberHomePosition(true);
            this.warmPostPreviews();
          }
        })
        .onScrollIndex((start: number, end: number) => {
          if (homeTab >= 0 && this.activeFeed(homeTab)) {
            this.homeFirstVisible[homeTab] = start;
            this.homeLastVisible[homeTab] = end;
            if (end > 0) this.upgradeMedia(homeTab, end - 1);
            this.maybePrefetchHome();
            this.prepareUpcomingMedia();
          } else if (homeTab < 0 && this.surface !== Surface.Home) {
            const header = this.surface === Surface.Profile && this.profile ? 1 : 0;
            this.routeFirstVisible = Math.max(0, start - header);
            this.routeLastVisible = end - header;
            if (this.usesLazyRouteFeed()) {
              this.routeHighQuality = Math.max(this.routeHighQuality, this.routeLastVisible + MEDIA_LOOKAHEAD + 1);
            }
            if (this.surface !== Surface.Detail) this.prepareUpcomingMedia(this.routeLastVisible);
            this.maybePrefetchRoute();
          }
          if (homeTab >= 0 && this.activeFeed(homeTab) &&
            (!this.routeCachedOnly || this.routeScrolled) &&
            (homeTab < 0 || this.homeScrolled) && end >= this.posts.length - (homeTab >= 0 ? 1 : 2) && !this.pageNote) this.nextPage();
        })
    }.width('100%').layoutWeight(1)
      .onOffsetChange((offset: number) => {
        if (homeTab >= 0 && this.activeFeed(homeTab)) {
          this.homePullOffset = Math.min(HOME_PULL_REFRESH_DISTANCE, Math.max(0, offset));
        }
      })
      .onRefreshing(() => {
        if (this.session !== Session.Active || !this.activeFeed(homeTab)) return;
        if (homeTab < 0) this.refreshing = true;
        this.refreshFeed();
      })
  }

  private feedScroller(homeTab: number): Scroller {
    if (homeTab >= 0) return this.homeScrollers[homeTab];
    if (this.surface === Surface.Detail) return this.detailScroller;
    return this.surface === Surface.Search ? this.searchScroller : this.routeScroller;
  }

  private feedPosts(homeTab: number): Post[] {
    if (homeTab >= 0) return this.timelinePosts(homeTab);
    if (this.surface !== Surface.Profile || this.profileTab !== 'media' || this.profileMediaFilter === 0) {
      return this.posts;
    }
    return this.posts.filter((post: Post) => this.profileMediaFilter === 1 ? post.photos.length > 0 : post.video);
  }

  @Builder
  homeContent(bottomOffset: number) {
    Stack({ alignContent: Alignment.TopStart }) {
      Swiper() {
        Column() { this.feed(bottomOffset, 0) }.width('100%').height('100%')
        Column() { this.feed(bottomOffset, 1) }.width('100%').height('100%')
      }.width('100%').height('100%').index(this.homeTab).loop(false).indicator(false).cachedCount(1)
        .disableSwipe(this.drawerOpen || this.drawerDrag !== 0 || !!this.galleryTouchPost)
        .onChange((tab: number) => this.selectTimeline(tab))
      Column().width('100%').height(this.statusInset)
        .backgroundColor(this.homeHeaderHidden ? $r('app.color.header_scroll') : $r('app.color.header_idle'))
        .backgroundBlurStyle(this.homeHeaderHidden ? BlurStyle.Thin : BlurStyle.NONE, { scale: 0.52 })
        .hitTestBehavior(HitTestMode.None)
      Column() {
        Column() {
          this.titleBar(true)
          Row() {
            this.homeSelector(ui('为你推荐', this.locale), 0)
            this.homeSelector(ui('正在关注', this.locale), 1)
            Row({ space: 4 }) {
              Text(ui('添加', this.locale)).fontSize(15).fontColor(MUTED).fontWeight(FontWeight.Medium)
              Image($r('app.media.menu_add')).width(14).height(14)
            }.height(42).width(76).justifyContent(FlexAlign.Center).accessibilityText(ui('添加时间线', this.locale))
              .onClick(() => this.openWeb(ui('添加时间线', this.locale), '/i/lists'))
          }.width('100%').border({ width: { bottom: 1 }, color: RULE })
        }.width('100%').backgroundColor($r('app.color.header_idle'))
      }.width('100%').padding({ top: this.statusInset })
        .translate({ y: this.homeHeaderHidden ? -HOME_HEADER_HEIGHT : 0 })
        .opacity(this.homeHeaderHidden ? 0 : 1)
        .hitTestBehavior(this.homeHeaderHidden ? HitTestMode.None : HitTestMode.Default)
        .accessibilityLevel(this.homeHeaderHidden ? 'no-hide-descendants' : 'auto')
      if (this.surface === Surface.Home && !this.drawerOpen && (this.homePullOffset > 4 || this.refreshing)) {
        Row() {
          Button({ type: ButtonType.Circle }) {
            if (this.refreshing) {
              LoadingProgress().width(23).height(23).color(this.accentInk)
            } else {
              SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(20).fontColor([this.accentInk])
                .rotate({ angle: this.homePullOffset * 360 / HOME_PULL_REFRESH_DISTANCE })
            }
          }.width(40).height(40).padding(0).backgroundColor(PAPER)
            .border({ width: 1, color: RULE }).shadow({ radius: 10, color: '#22000000', offsetY: 2 })
            .id('home-pull-refresh-indicator')
            .accessibilityText(ui(this.refreshing ? '正在刷新' : '刷新', this.locale))
            .onClick(() => { if (!this.refreshing) this.refreshFeed(); })
        }.width('100%').justifyContent(FlexAlign.Center)
          .padding({ top: this.statusInset + (this.homeHeaderHidden ? 8 : HOME_HEADER_HEIGHT + 8) })
          .opacity(this.refreshing ? 1 : Math.min(1, this.homePullOffset / 28))
          .hitTestBehavior(HitTestMode.Transparent)
      } else if (this.hasNewHomePosts(this.homeTab) && !this.homeRefreshRequested && !this.refreshing && !this.drawerOpen) {
        Row() {
          NewPostsButton({ label: ui('↑  有新帖子', this.locale), onOpen: () => this.refreshFeed() })
        }.width('100%').justifyContent(FlexAlign.Center)
          .padding({ top: this.statusInset + (this.homeHeaderHidden ? 8 : HOME_HEADER_HEIGHT + 8) })
          .hitTestBehavior(HitTestMode.Transparent)
      }
    }.width('100%').height('100%').backgroundColor(PAPER)
  }

  @Builder
  searchSort(label: string, mode: string) {
    Column() {
      Text(label).fontSize(15).fontColor(this.searchMode === mode ? INK : MUTED)
        .fontWeight(this.searchMode === mode ? FontWeight.Bold : FontWeight.Medium)
        .layoutWeight(1).textAlign(TextAlign.Center)
      Row().width(38).height(3).borderRadius(2)
        .backgroundColor(this.searchMode === mode ? this.accent : Color.Transparent)
    }.height(42).layoutWeight(1).accessibilityText(label)
      .accessibilitySelected(this.searchMode === mode).onClick(() => this.sortSearch(mode))
  }

  @Builder
  historyTab(tab: PageTab) {
    Column() {
      Text(tab.label).fontSize(15).fontColor(this.historyTabActive(tab) ? INK : MUTED)
        .fontWeight(this.historyTabActive(tab) ? FontWeight.Bold : FontWeight.Medium)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1).textAlign(TextAlign.Center)
      Row().width(38).height(3).borderRadius(2)
        .backgroundColor(this.historyTabActive(tab) ? this.accent : Color.Transparent)
    }.height(42).layoutWeight(1).accessibilityText(tab.label)
      .accessibilitySelected(this.historyTabActive(tab)).onClick(() => this.selectHistoryTab(tab))
  }

  @Builder
  nativeContent(bottomOffset: number) {
    if (this.surface !== Surface.Home) {
      Column() {
        this.titleBar()
        if (this.surface === Surface.Search) {
          Search({ value: this.query, placeholder: ui('搜索 X 上的帖子', this.locale) })
            .searchButton(ui('搜索', this.locale)).height(40).margin({ left: 14, right: 14, top: 6, bottom: 8 })
            .onChange((value: string) => { this.query = value; })
            .onSubmit((value: string) => this.search(value))
          if (this.submittedQuery) {
            Row() {
              this.searchSort(ui('热度', this.locale), 'top')
              this.searchSort(ui('最新', this.locale), 'latest')
              this.searchSort(ui('用户', this.locale), 'people')
              this.searchSort(ui('视频', this.locale), 'videos')
              this.searchSort(ui('图片', this.locale), 'photos')
            }.width('100%').border({ width: { bottom: 1 }, color: RULE })
          }
        }
        if (this.surface === Surface.Bookmarks) {
          Row() {
            ForEach(this.historyTabs(), (tab: PageTab) => {
              this.historyTab(tab)
            }, (tab: PageTab) => tab.path + ':' + tab.label)
            if (this.libraryPath === LOCAL_BROWSING_PATH && this.posts.length) {
              GlassButton({ label: ui('清除', this.locale), buttonHeight: 32, fontSize: 14,
                onTap: () => this.confirmClearBrowsing() }).margin({ right: 8 })
            }
          }.width('100%').border({ width: { bottom: 1 }, color: RULE })
        }
        if (this.surface === Surface.Search && !this.submittedQuery) {
          if (!this.wideTablet) this.discoveryContent(bottomOffset)
          else Blank()
        } else {
          this.feed(bottomOffset)
        }
      }.width('100%').height('100%').padding({ top: this.statusInset }).backgroundColor(PAPER)
    }
  }

  @Builder
  webContent(bottomOffset: number) {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        Text(this.webTitle).fontSize(18).fontWeight(FontWeight.Bold).fontColor(INK)
        Row() {
          this.iconButton($r('sys.symbol.chevron_left'), ui('返回', this.locale), () => { this.back(); })
          Blank()
          if (this.webUrl === X_ORIGIN + '/i/history') {
            this.iconButton($r('sys.symbol.bookmark'), ui('书签', this.locale), () => this.openBookmarks())
          }
        }.width('100%')
      }.height(50).width('100%')
      Column() {
        XWebPage({ url: this.webUrl, accountLogin: this.webUrl === X_ORIGIN + '/account/switch',
          loginTraceScript: LOGIN_PASSWORD_TRACE })
      }.layoutWeight(1).width('100%')
    }.width('100%').height('100%').padding({ top: this.statusInset, bottom: bottomOffset })
  }

  @Builder
  profilePage() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.feed(this.bottomInset)
      }.width('100%').height('100%')
      Row({ space: 8 }) {
        GlassButton({ symbol: $r('sys.symbol.chevron_left'), accessibilityLabel: ui('返回', this.locale),
          fixedWidth: 36, buttonHeight: 36, iconSize: 18, onTap: () => { this.back(); } })
        Blank()
        GlassButton({ symbol: $r('sys.symbol.arrow_clockwise'), fixedWidth: 36, buttonHeight: 36, iconSize: 18,
          busy: this.content === Content.Loading || this.refreshing,
          accessibilityLabel: ui(this.content === Content.Loading || this.refreshing ? '正在刷新' : '刷新', this.locale),
          onTap: () => { if (this.content !== Content.Loading && !this.refreshing) this.refreshFeed(); } })
        GlassButton({ image: $r('app.media.nav_search'), fixedWidth: 36, buttonHeight: 36, iconSize: 19,
          accessibilityLabel: ui('搜索此账号', this.locale), onTap: () => this.searchProfile() })
      }.width('100%').padding({ left: 14, right: 14, top: this.statusInset + 9 })
    }.width('100%').height('100%').constraintSize({ maxWidth: this.wideTablet ? '100%' : 650 }).backgroundColor(PAPER)
  }

  @Builder
  notificationCategory(label: string, path: string) {
    Button({ type: ButtonType.Normal }) {
      Stack({ alignContent: Alignment.Bottom }) {
        Text(ui(label, this.locale)).fontSize(15)
          .fontColor(this.selectedNotificationPath === path ? INK : MUTED)
          .fontWeight(this.selectedNotificationPath === path ? FontWeight.Bold : FontWeight.Medium)
          .width('100%').height('100%').textAlign(TextAlign.Center)
        Row().width(48).height(3).borderRadius(2)
          .backgroundColor(this.selectedNotificationPath === path ? this.accent : Color.Transparent)
      }.width('100%').height('100%')
    }.height(46).layoutWeight(1).padding(0).borderRadius(0).backgroundColor(Color.Transparent)
      .accessibilityText(ui(label, this.locale)).accessibilitySelected(this.selectedNotificationPath === path)
      .onClick(() => this.selectNotificationCategory(path))
  }

  private notificationScroller(path: string): Scroller {
    return this.notificationScrollers[path === '/notifications/mentions' ? 2 : path === '/notifications/verified' ? 1 : 0];
  }

  @Builder
  inboxPage(chat: boolean, path: string, bottomOffset: number) {
    Refresh({ refreshing: this.refreshing }) {
      InboxList({
        rows: chat ? this.conversations : this.notificationPath === path ? this.notifications : [],
        relatedPosts: chat ? new Map<string, Post>() : this.notificationPosts,
        translations: this.translatedPosts,
        loading: this.content === Content.Loading,
        locked: chat && this.chatLocked,
        canOpenWeb: chat,
        error: this.content === Content.Failed ? this.problem : '',
        bottomInset: bottomOffset,
        scroller: chat ? this.inboxScroller : this.notificationScroller(path),
        onOpen: (row: InboxRow) => { if (chat) this.openConversation(row); else this.openNotification(row); },
        onUnlock: () => this.showChatWeb(),
        onRetry: () => this.retryInbox(),
        onVisibleEnd: (end: number) => {
          if (!chat && this.route.path === path) {
            this.notificationEnd = end;
            this.warmNotifications();
          }
        },
        onNearEnd: () => { if (chat || this.route.path === path) this.advanceInbox(); }
      })
    }.width('100%').layoutWeight(1).onRefreshing(() => {
      this.refreshing = true;
      this.retryInbox();
    })
  }

  @Builder
  inboxContent(chat: boolean, bottomOffset: number) {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        Text(ui(chat ? '聊天' : '通知', this.locale)).fontSize(19).fontWeight(FontWeight.Bold).fontColor(INK)
        Row() {
          if (!this.wideTablet) {
            Button({ type: ButtonType.Circle }) {
              Avatar({ src: this.ownProfile?.avatar || this.avatar, diameter: 30 })
            }.width(45).height(44).backgroundColor(Color.Transparent)
              .accessibilityText(ui('打开账号侧栏', this.locale)).onClick(() => this.showDrawer(true))
          }
          Blank()
        }.width('100%').padding({ left: 7 })
      }.width('100%').height(50)
      if (!chat) {
        Row() {
          this.notificationCategory('全部', '/notifications')
          this.notificationCategory('优先', '/notifications/verified')
          this.notificationCategory('提及', '/notifications/mentions')
        }.width('100%').border({ width: { bottom: 1 }, color: RULE })
      }
      if (chat) {
        this.inboxPage(true, '', bottomOffset)
      } else {
        ForEach([this.selectedNotificationPath], (path: string) => {
          this.inboxPage(false, path, bottomOffset)
        }, (path: string) => path)
      }
    }.width('100%').height('100%').padding({ top: this.statusInset }).backgroundColor(PAPER)
  }

  private canSendChat(): boolean {
    return !this.composerBusy && !this.chatLocked && !!this.chatEngine &&
      this.chatDraft.trim().length > 0;
  }

  @Builder
  chatContent() {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        Text(this.chatItem?.title || ui('聊天', this.locale)).fontSize(18).fontWeight(FontWeight.Bold).fontColor(INK)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: '60%' })
        Row() {
          this.iconButton($r('sys.symbol.chevron_left'), ui('返回', this.locale), () => { this.back(); })
          Blank()
          Button('X').buttonStyle(ButtonStyleMode.TEXTUAL).fontColor(INK).width(44).height(44)
            .accessibilityText(ui('在 X 打开', this.locale))
            .onClick(() => this.showChatWeb())
        }.width('100%')
      }.width('100%').height(50)
      Column() {
        InboxList({
          rows: this.chatRows(),
          messages: true,
          ownAvatar: this.ownProfile?.avatar || this.avatar,
          peerAvatar: /^c:\d{1,24}-\d{1,24}$/.test(this.chatItem?.id || '') ? this.chatItem?.avatar || '' : '',
          loading: this.chatWaiting,
          locked: this.chatLocked,
          canOpenWeb: true,
          error: this.chatFailure,
          bottomInset: 0,
          scroller: this.messageScroller,
          onUnlock: () => this.showChatWeb(),
          onRetry: () => {
            this.chatWaiting = !this.chatMessages.length;
            this.chatFailure = '';
            this.conversationOpenAt = Date.now();
            const address = chatConversationUrl(this.chatItem?.path || '');
            this.conversationOpenSent = !!address;
            this.ensureChatEngine(address || this.route.url(), true);
          },
          onNearStart: () => this.advanceMessages()
        })
      }.width('100%').layoutWeight(1)
      Column({ space: 6 }) {
        if (this.composerFeedback) {
          Text(this.composerFeedback).fontSize(12).fontColor(MUTED).width('100%')
        }
        Row({ space: 10 }) {
          TextArea({ text: this.chatDraft, placeholder: ui('输入消息', this.locale) })
            .height(46).layoutWeight(1).maxLength(10000).enabled(!this.composerBusy)
            .fontSize(15).backgroundColor(SOFT)
            .onChange((value: string) => { this.chatDraft = value; this.composerFeedback = ''; })
          GlassButton({ label: ui(this.composerBusy ? '正在提交…' : '发送', this.locale), filled: true,
            enabledState: this.canSendChat(), onTap: () => this.submitComposer(true) })
        }.width('100%')
      }.width('100%').padding({ left: 14, right: 14, top: 8, bottom: 8 + this.bottomInset })
        .border({ width: { top: 1 }, color: RULE })
    }.width('100%').height('100%').padding({ top: this.statusInset }).backgroundColor(PAPER)
  }

  @Builder
  postPollNumber(label: string, value: string, setValue: (value: string) => void) {
    Column({ space: 4 }) {
      Text(ui(label, this.locale)).fontSize(12).fontColor(MUTED)
      TextInput({ text: value, placeholder: '0' }).type(InputType.Number).maxLength(2).height(36)
        .enabled(!this.composerBusy).accessibilityText(ui(label, this.locale)).onChange(setValue)
    }.layoutWeight(1)
  }

  @Builder
  postPollEditor() {
    Column({ space: 8 }) {
      Row() {
        Text(ui('投票选项', this.locale)).fontSize(15).fontWeight(FontWeight.Bold).fontColor(INK).layoutWeight(1)
        Button(ui('移除投票', this.locale)).buttonStyle(ButtonStyleMode.TEXTUAL).height(32).fontColor(MUTED)
          .enabled(!this.composerBusy).onClick(() => { this.postPollChoices = []; this.composerFeedback = ''; })
      }.width('100%')
      ForEach([0, 1, 2, 3].slice(0, this.postPollChoices.length), (index: number) => {
        Row({ space: 4 }) {
          TextInput({ text: this.postPollChoices[index], placeholder: ui('选项 {0}', this.locale, (index + 1).toString()) })
            .maxLength(25).height(40).layoutWeight(1).enabled(!this.composerBusy)
            .onChange((value: string) => {
              this.postPollChoices = this.postPollChoices.map((choice: string, slot: number) => slot === index ? value : choice);
              this.composerFeedback = '';
            })
          if (index > 1) {
            Button(ui('移除', this.locale)).buttonStyle(ButtonStyleMode.TEXTUAL).height(34)
              .enabled(!this.composerBusy).onClick(() => {
                this.postPollChoices = this.postPollChoices.filter((_choice: string, slot: number) => slot !== index);
              })
          }
        }.width('100%')
      }, (index: number) => index.toString())
      if (this.postPollChoices.length < 4) {
        Button(ui('添加选项', this.locale)).buttonStyle(ButtonStyleMode.TEXTUAL).height(34)
          .enabled(!this.composerBusy).onClick(() => { this.postPollChoices = [...this.postPollChoices, '']; })
      }
      Text(ui('投票时长', this.locale)).fontSize(15).fontWeight(FontWeight.Bold).fontColor(INK)
      Row({ space: 8 }) {
        this.postPollNumber('天', this.postPollDays, (value: string) => { this.postPollDays = value; })
        this.postPollNumber('小时', this.postPollHours, (value: string) => { this.postPollHours = value; })
        this.postPollNumber('分钟', this.postPollMinutes, (value: string) => { this.postPollMinutes = value; })
      }.width('100%')
      if (!this.postPollDuration()) {
        Text(ui('投票时长须为 5 分钟到 7 天。', this.locale)).fontSize(12).fontColor(MUTED)
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(10)
  }

  @Builder
  postAttachmentPreview(replying: boolean = false) {
    Row({ space: 8 }) {
      ForEach(replying ? this.replyAttachments : this.postAttachments, (item: PostAttachment) => {
        Column({ space: 3 }) {
          if (item.type.startsWith('image/')) {
            Image(item.uri).width(62).height(62).objectFit(ImageFit.Cover).borderRadius(8)
          } else {
            Text(item.name).fontSize(13).fontColor(INK).maxLines(2).width(160)
          }
          Button(ui('移除', this.locale)).buttonStyle(ButtonStyleMode.TEXTUAL).height(32).fontSize(12)
            .enabled(!this.composerBusy).onClick(() => {
              if (replying) {
                this.replyAttachments = this.replyAttachments.filter((other: PostAttachment) => other.uri !== item.uri);
              } else {
                this.postAttachments = this.postAttachments.filter((other: PostAttachment) => other.uri !== item.uri);
              }
              this.composerFeedback = '';
            })
        }
      }, (item: PostAttachment) => item.uri)
    }.width('100%')
  }

  @Builder
  postGifPicker() {
    Column({ space: 8 }) {
      Row() {
        Text('GIF').fontSize(17).fontWeight(FontWeight.Bold).fontColor(INK).layoutWeight(1)
        Button(ui('取消', this.locale)).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(() => this.discardPostGif())
      }.width('100%')
      Search({ value: this.postGifQuery, placeholder: ui('搜索 GIF', this.locale) })
        .height(40).onChange((value: string) => { this.postGifQuery = value; })
        .onSubmit((value: string) => this.findPostGifs(value.trim(), false))
      if (this.postGifBusy) {
        LoadingProgress().width(24).height(24).color(this.accentInk)
      }
      Grid() {
        ForEach(this.postGifResults, (item: PostGif) => {
          GridItem() {
            Button({ type: ButtonType.Normal }) {
              Image(item.url).width('100%').height(104).objectFit(ImageFit.Cover)
            }.width('100%').height(104).borderRadius(8).accessibilityText(item.label)
              .enabled(!this.postGifBusy).onClick(() => this.attachPostGif(item))
          }
        }, (item: PostGif) => item.url)
      }.columnsTemplate('1fr 1fr').rowsGap(6).columnsGap(6).width('100%').layoutWeight(1)
    }.width('100%').layoutWeight(1).padding({ left: 14, right: 14 })
  }

  @Builder
  postThreadEditor() {
    ForEach([0, 1, 2, 3, 4, 5, 6, 7, 8].slice(0, this.postThread.length), (index: number) => {
      Row({ space: 10 }) {
        Avatar({ src: this.ownProfile?.avatar || this.avatar, diameter: 32 })
        TextArea({ text: this.postThread[index], placeholder: ui('继续串文', this.locale) })
          .layoutWeight(1).height(94).maxLength(1000).enabled(!this.composerBusy)
          .fontSize(16).backgroundColor(PAPER)
          .onChange((value: string) => {
            this.postThread = this.postThread.map((item: string, slot: number) => slot === index ? value : item);
          })
        Button(ui('移除', this.locale)).buttonStyle(ButtonStyleMode.TEXTUAL).fontSize(12)
          .enabled(!this.composerBusy).onClick(() => {
            this.postThread = this.postThread.filter((_item: string, slot: number) => slot !== index);
          })
      }.width('100%').alignItems(VerticalAlign.Top).padding({ top: 8 }).border({ width: { top: 1 }, color: RULE })
    }, (index: number) => index.toString())
  }

  private floatingTabMaterial(): uiMaterial.ImmersiveMaterial {
    return new uiMaterial.ImmersiveMaterial({
      style: TAB_MATERIAL_STYLES[this.tabMaterial],
      interactive: true,
      lightEffect: { color: this.accent }
    });
  }

  private replyMaterial(): uiMaterial.ImmersiveMaterial {
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.REGULAR,
      materialColor: Color.Transparent, interactive: true, applyShadow: false,
      lightEffect: { color: Color.White }
    });
  }

  @Builder
  detailMaterialAnchor() {
    Row().height(1)
  }

  @Builder
  detailGlass(width: number) {
    Tabs({ barPosition: BarPosition.End }) {
      TabContent() { Column() }
        .tabBar(this.detailMaterialAnchor)
    }.width(width).height(46).barHeight(46).barMode(BarMode.Fixed).barOverlap(true)
      .scrollable(false).fadingEdge(false).backgroundColor(Color.Transparent).barBackgroundColor(Color.Transparent)
      .barFloatingStyle({
        barWidth: { smallBarWidth: width, mediumBarWidth: width, largeBarWidth: width },
        barSideMargin: 0, barBottomMargin: 0, maskHeight: 0, maskColor: Color.Transparent,
        systemMaterial: this.floatingTabMaterial(), adaptToHandedness: false
      }).clip(false).hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
  }

  @Builder
  detailMetric(icon: Resource, count: string, color: ResourceColor) {
    Row({ space: 3 }) {
      Image(icon).width(17).height(17).fillColor(color).draggable(false)
      if (count) {
        Text(count).fontSize(11).fontColor(color).maxLines(1)
      }
    }.justifyContent(FlexAlign.Center)
  }

  @Builder
  detailAction(icon: Resource, label: string, count: string, action: () => void, color: ResourceColor = $r('app.color.reply_glass_ink')) {
    Button({ type: ButtonType.Capsule }) {
      this.detailMetric(icon, count, color)
    }.layoutWeight(count ? 1.25 : 0.8).height(46).padding(0).backgroundColor(Color.Transparent)
      .accessibilityText(count ? label + ' ' + count : label).onClick(action)
  }

  // Reads postActionStates inside the builder body. Values handed to a @Builder as plain parameters are copied
  // once and never refresh, which left the detail toolbar showing the old Like count after a tap.
  private detailActionPost(post: Post): Post {
    const current = this.detailPost;
    return current && current.id === post.id ? current : post;
  }

  private detailActionActive(post: Post, kind: string): boolean {
    const current = this.detailActionPost(post);
    return this.postActionStates.get(kind + ':' + current.id)?.liked ??
      (kind === 'like' ? current.liked : kind === 'repost' ? current.reposted : current.bookmarked);
  }

  private detailActionCount(post: Post, kind: string): string {
    const current = this.detailActionPost(post);
    if (kind === 'bookmark') return this.postActionStates.get(kind + ':' + current.id)?.count ?? (current.bookmarks || '');
    return (this.postActionStates.get(kind + ':' + current.id)?.count ??
      (kind === 'like' ? current.likes : current.reposts)) || '0';
  }

  private detailActionColor(post: Post, kind: string): ResourceColor {
    if (!this.detailActionActive(post, kind)) return $r('app.color.reply_glass_ink');
    return kind === 'like' ? '#F23A53' : this.accentInk;
  }

  @Builder
  detailStateAction(post: Post, kind: string) {
    Button({ type: ButtonType.Capsule }) {
      Row({ space: 3 }) {
        Image(kind === 'like' ? (this.detailActionActive(post, kind) ? $r('app.media.feed_liked') : $r('app.media.feed_like')) :
          kind === 'repost' ? $r('app.media.feed_repost') : $r('app.media.detail_star'))
          .width(17).height(17).fillColor(this.detailActionColor(post, kind)).draggable(false)
        if (this.detailActionCount(post, kind)) {
          Text(this.detailActionCount(post, kind)).fontSize(11).fontColor(this.detailActionColor(post, kind)).maxLines(1)
        }
      }.justifyContent(FlexAlign.Center)
    }.layoutWeight(this.detailActionCount(post, kind) ? 1.25 : 0.8).height(46).padding(0).backgroundColor(Color.Transparent)
      .accessibilityText(ui(kind === 'like' ? '喜欢' : kind === 'repost' ? '转帖' : '收藏', this.locale) +
        (this.detailActionCount(post, kind) ? ' ' + this.detailActionCount(post, kind) : ''))
      .onClick(() => this.togglePostAction(this.detailActionPost(post), kind))
  }

  @Builder
  detailActions(post: Post) {
    Row() {
      Stack() {
        this.detailGlass(86)
        Button({ type: ButtonType.Capsule }) {
          Row({ space: 5 }) {
            Image($r('app.media.detail_write')).width(17).height(17).fillColor($r('app.color.reply_glass_ink'))
            Text(ui('回复', this.locale)).fontSize(14).fontColor($r('app.color.reply_glass_ink')).maxLines(1)
          }
        }.width(86).height(46).padding({ left: 15, right: 15 }).backgroundColor(Color.Transparent)
          .onClick(() => this.openPostComposer(post))
      }.width(86).height(46)
      Blank()
      Stack() {
        this.detailGlass(214)
      Row() {
        this.detailStateAction(post, 'like')
        this.detailStateAction(post, 'repost')
        this.detailStateAction(post, 'bookmark')
        this.detailAction($r('app.media.feed_share'), ui('分享', this.locale), '', () => this.copyPostLink(post))
        Row() {
          this.detailMetric($r('app.media.feed_views'), post.views, $r('app.color.reply_glass_ink'))
        }.height(46).layoutWeight(1.4).justifyContent(FlexAlign.Center)
          .accessibilityText(ui('浏览', this.locale) + ' ' + post.views)
      }.width(214).height(46).padding({ left: 5, right: 5 })
      }.width(214).height(46)
    }.width('100%').constraintSize({ maxWidth: 560 }).padding({ left: 12, right: 12, bottom: this.bottomInset + 8 })
  }

  @Builder
  replyOverlay() {
      Column({ space: 5 }) {
        TextArea({ text: this.replyDraft, placeholder: ui('回复', this.locale) + (this.replyTarget?.handle ? '@' + this.replyTarget.handle : '') })
          .id('qwitter-reply-editor').width('100%').height(70).maxLength(1000)
          .fontSize(16).fontColor($r('app.color.reply_glass_ink'))
          .placeholderColor($r('app.color.reply_glass_muted')).caretColor(this.accent).padding({ left: 4, right: 4, top: 6 }).backgroundColor(Color.Transparent).enabled(!this.composerBusy)
          .onChange((value: string) => { this.replyDraft = value; this.composerFeedback = ''; })
        Row({ space: 7 }) {
          Button({ type: ButtonType.Circle }) {
            Image($r('app.media.compose_emoji')).width(20).height(20).fillColor($r('app.color.reply_glass_ink'))
          }.width(36).height(36).padding(0).backgroundColor(Color.Transparent).accessibilityText(ui('表情', this.locale))
            .enabled(!this.composerBusy).onClick(() => { this.replyEmojiOpen = !this.replyEmojiOpen; })
          Button({ type: ButtonType.Circle }) {
            Image($r('app.media.compose_media')).width(20).height(20).fillColor($r('app.color.reply_glass_ink'))
          }.width(36).height(36).padding(0).backgroundColor(Color.Transparent).accessibilityText(ui('添加图片或视频', this.locale))
            .enabled(!this.composerBusy && !this.pickingPostMedia).onClick(() => this.pickPostMedia())
          Button('@').width(36).height(36).padding(0).buttonStyle(ButtonStyleMode.TEXTUAL).fontSize(21).fontColor($r('app.color.reply_glass_ink'))
            .enabled(!this.composerBusy).onClick(() => { if (this.replyDraft.length < 1000) this.replyDraft += '@'; })
          Button('#').width(36).height(36).padding(0).buttonStyle(ButtonStyleMode.TEXTUAL).fontSize(21).fontColor($r('app.color.reply_glass_ink'))
            .enabled(!this.composerBusy).onClick(() => { if (this.replyDraft.length < 1000) this.replyDraft += '#'; })
          Blank()
          GlassButton({ label: ui(this.composerBusy ? '正在提交…' : '发布', this.locale), filled: true, buttonHeight: 32,
            fontSize: 14, enabledState: this.canPublishPost(), onTap: () => this.submitComposer(false) })
        }.width('100%')
        if (this.replyAttachments.length) {
          Scroll() { this.postAttachmentPreview(true) }
            .width('100%').scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
        }
        if (this.replyEmojiOpen) {
          Row() {
            ForEach(['😎', '😁', '😂', '😯', '😡', '😭', '🙂'], (emoji: string) => {
              Button(emoji).height(37).layoutWeight(1).padding(0).fontSize(23).backgroundColor(Color.Transparent)
                .enabled(!this.composerBusy).onClick(() => {
                  if (this.replyDraft.length + emoji.length <= 1000) this.replyDraft += emoji;
                })
            })
          }.width('100%')
        }
        if (this.composerFeedback) {
          Text(this.composerFeedback).fontSize(13).fontColor($r('app.color.reply_glass_ink')).width('100%')
        }
      }.width('100%').padding({ left: 16, right: 16, top: 10, bottom: 9 })
  }

  @Builder
  postComposerPage() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Button(ui('取消', this.locale)).buttonStyle(ButtonStyleMode.TEXTUAL).fontSize(16).fontColor(INK)
          .onClick(() => { this.back(); })
        Blank()
        GlassButton({ label: ui(this.composerBusy ? '正在提交…' : this.postThread.length ? '全部发布' : '发布', this.locale),
          filled: true, buttonHeight: 38, enabledState: this.canPublishPost(), onTap: () => this.submitComposer(false) })
      }.width('100%').height(52).padding({ left: 6, right: 14 })
      if (this.postGifOpen) {
        this.postGifPicker()
      } else {
        Scroll() {
          Column({ space: 10 }) {
            Row({ space: 12 }) {
              Avatar({ src: this.ownProfile?.avatar || this.avatar, diameter: 42 })
              TextArea({ text: this.postDraft, placeholder: ui(this.postPollChoices.length ? '输入投票问题' : '有什么新鲜事？', this.locale) })
                .id('qwitter-post-editor')
                .layoutWeight(1).height(this.postThread.length ? 100 : 150).maxLength(1000).enabled(!this.composerBusy)
                .fontSize(17).backgroundColor(PAPER)
                .onChange((value: string) => { this.postDraft = value; this.composerFeedback = ''; })
            }.width('100%').alignItems(VerticalAlign.Top)
            if (this.postAttachments.length) this.postAttachmentPreview()
            if (this.postGif) {
              Stack({ alignContent: Alignment.TopEnd }) {
                Image(this.postGif.url).width('100%').height(150).objectFit(ImageFit.Cover).borderRadius(12)
                  .accessibilityText(this.postGif.label)
                Button(ui('移除', this.locale)).height(32).margin(6).fontSize(12)
                  .enabled(!this.composerBusy).onClick(() => this.discardPostGif())
              }.width('100%')
            }
            if (this.postPollChoices.length) this.postPollEditor()
            if (this.postThread.length) this.postThreadEditor()
          }.width('100%').padding({ left: 14, right: 14 })
        }.width('100%').layoutWeight(1).align(Alignment.Top)
      }
      if (this.composerFeedback) {
        Text(this.composerFeedback).fontSize(13).fontColor(MUTED).width('100%').padding({ left: 14, right: 14 })
      }
      if (this.postEmojiOpen && !this.postGifOpen) {
        Scroll() {
          Row({ space: 2 }) {
            ForEach(['😀', '😂', '❤️', '👍', '🎉', '🔥', '✨', '🙏'], (emoji: string) => {
              Button({ type: ButtonType.Normal }) {
                Text(emoji).fontSize(22).maxLines(1).textAlign(TextAlign.Center).width('100%')
              }.width(40).height(42).padding(0).backgroundColor(Color.Transparent)
                .accessibilityText(emoji).enabled(!this.composerBusy).onClick(() => {
                  if (this.postDraft.length + emoji.length <= 1000) this.postDraft += emoji;
                })
            }, (emoji: string) => emoji)
          }.padding({ left: 10, right: 10 })
        }.width('100%').height(42).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
      }
      if (!this.postGifOpen) {
        Row() {
          Button({ type: ButtonType.Circle }) {
            Image($r('app.media.compose_media')).width(22).height(22).fillColor(this.accentInk)
          }.width(42).height(42).backgroundColor(Color.Transparent)
            .id('post-tool-照片或视频').accessibilityText(ui('照片或视频', this.locale))
            .enabled(!this.composerBusy && !this.pickingPostMedia && !this.postPollChoices.length &&
              !this.postThread.length && !this.postGif)
            .onClick(() => this.pickPostMedia())
          Button({ type: ButtonType.Circle }) {
            Image($r('app.media.compose_gif')).width(22).height(22).fillColor(this.accentInk)
          }.width(42).height(42).backgroundColor(Color.Transparent)
            .id('post-tool-GIF').accessibilityText('GIF')
            .enabled(!this.composerBusy && !this.pickingPostMedia && !this.postAttachments.length &&
              !this.postPollChoices.length && !this.postThread.length && !this.postGif)
            .onClick(() => {
              this.postGifQuery = '';
              this.findPostGifs('', true);
            })
          Button({ type: ButtonType.Circle }) {
            Image($r('app.media.compose_poll')).width(22).height(22).fillColor(this.accentInk)
          }.width(42).height(42).backgroundColor(Color.Transparent)
            .id('post-tool-投票').accessibilityText(ui('投票', this.locale))
            .enabled(!this.composerBusy && !this.pickingPostMedia && !this.postAttachments.length &&
              !this.postPollChoices.length && !this.postThread.length && !this.postGif)
            .onClick(() => {
              this.postPollDays = '1';
              this.postPollHours = '0';
              this.postPollMinutes = '0';
              this.postPollChoices = ['', ''];
              this.composerFeedback = '';
            })
          Button({ type: ButtonType.Circle }) {
            Image($r('app.media.compose_emoji')).width(22).height(22).fillColor(this.accentInk)
          }.width(42).height(42).backgroundColor(Color.Transparent)
            .id('post-tool-表情').accessibilityText(ui('表情', this.locale))
            .enabled(!this.composerBusy).onClick(() => { this.postEmojiOpen = !this.postEmojiOpen; })
          Blank()
          GlassButton({ image: $r('app.media.compose_plus'), filled: true, fixedWidth: 28, buttonHeight: 28, iconSize: 14,
            accessibilityLabel: ui('添加串文', this.locale),
            enabledState: !this.composerBusy && !this.pickingPostMedia && !this.postAttachments.length &&
              !this.postPollChoices.length && !this.postGif && !!this.postDraft.trim() && this.postThread.length < 9 &&
              this.postThread.every((value: string) => !!value.trim()),
            onTap: () => { this.postThread = [...this.postThread, '']; } })
            .id('post-tool-thread').margin({ right: 6 })
        }.width('100%').padding({ left: 8, right: 12 }).border({ width: { top: 1 }, color: RULE })
      }
    }.width('100%').height('100%').padding({ top: this.statusInset, bottom: 12 + this.bottomInset })
      .backgroundColor(PAPER)
  }

  @Builder
  readerPage(name: string) {
    NavDestination() {
      if (name === 'settings') {
        SettingsMenu({
          handle: this.handle,
          store: this.store,
          canPersist: () => this.session === Session.Active && !!this.verifiedReaderAccount,
          topInset: this.statusInset,
          bottomInset: this.bottomInset,
          entryRoute: this.settingsEntry,
          entryTitle: this.settingsEntryTitle,
          paths: this.settingsPaths,
          onClose: () => this.closeSettings(),
          onLogout: () => this.confirmReset()
        })
      } else if (name === 'post-compose') {
        this.postComposerPage()
      } else if (name === 'chat-detail') {
        if (this.webUrl) this.webContent(this.bottomInset)
        else this.chatContent()
      } else if (name === 'post-detail') {
        Stack({ alignContent: Alignment.Bottom }) {
          this.nativeContent(this.bottomInset + 64)
          if (this.detailPost && !this.replyTarget) this.detailActions(this.detailPost)
        }.width('100%').height('100%')
      } else if (this.webUrl) {
        this.webContent(this.bottomInset)
      } else {
        this.profilePage()
      }
    }.hideTitleBar(true).backgroundColor(PAPER)
      .systemTransition(NavigationSystemTransitionType.DEFAULT)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .onShown(() => {
        if (name === 'chat-detail' || name === 'post-compose') this.setComposerKeyboard(true);
      })
      .onHidden(() => {
        if (name === 'chat-detail' || name === 'post-compose') this.setComposerKeyboard(false);
      })
      .onBackPressed(() => this.back())
  }

  @Builder
  mountedHome() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      this.homeContent(this.bottomInset + (this.wideTablet ? 0 : this.tabHeight + 27))
      if (this.session === Session.Active) {
        ComposeFloatingButton({ label: ui('发帖', this.locale), trackGrip: this.foreground && this.homeIsVisible(),
          onOpen: () => this.openPostComposer() })
          .margin({ bottom: this.bottomInset + (this.wideTablet ? 12 : this.tabHeight + 23) })
      }
    }.width('100%').height('100%')
      .visibility(this.homeIsVisible() ? Visibility.Visible : Visibility.Hidden)
  }

  @Builder
  primaryTabBar() {
    // The native bar owns its selection effect. Root pages have no pager.
    Tabs({ barPosition: BarPosition.End, index: this.navIndex }) {
      TabContent() {}.tabBar(this.tabIcon(ui('首页', this.locale), $r('app.media.nav_home'), $r('app.media.nav_home_filled'), 0))
      TabContent() {}.tabBar(this.tabIcon(ui('搜索', this.locale), $r('app.media.nav_search'), $r('app.media.nav_search_filled'), 1))
      TabContent() {}.tabBar(this.tabIcon(ui('通知', this.locale), $r('app.media.nav_bell'), $r('app.media.nav_bell_filled'), 2))
      TabContent() {}.tabBar(this.tabIcon(ui('聊天', this.locale), $r('app.media.nav_message'), $r('app.media.nav_message_filled'), 3))
    }.width('100%').height(this.tabHeight + 11 + this.bottomInset).scrollable(false).animationMode(AnimationMode.NO_ANIMATION)
      .animationDuration(0).barMode(BarMode.Fixed)
      .barHeight(this.tabHeight).barOverlap(true)
      .barFloatingStyle({
        barWidth: { smallBarWidth: 240, mediumBarWidth: 240, largeBarWidth: 240 },
        barSideMargin: 18,
        barBottomMargin: 7 + this.bottomInset,
        maskHeight: 0,
        maskColor: Color.Transparent,
        systemMaterial: this.floatingTabMaterial()
      })
      .backgroundColor(Color.Transparent)
      .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  reader() {
    Stack({ alignContent: Alignment.Bottom }) {
      this.mountedHome()
      if (this.surface !== Surface.Detail && this.surface !== Surface.Profile) {
        if (this.webUrl) {
          this.webContent(this.bottomInset + (this.hideReaderTabs() ? 0 : this.tabHeight + 19))
        } else if (this.surface === Surface.Notifications) {
          this.inboxContent(false, this.bottomInset + (this.wideTablet ? 0 : this.tabHeight + 19))
        } else if (this.surface === Surface.Chat) {
          this.inboxContent(true, this.bottomInset + (this.wideTablet ? 0 : this.tabHeight + 19))
        } else if (this.surface === Surface.Search || this.surface === Surface.Bookmarks) {
          this.nativeContent(this.bottomInset + (this.wideTablet ? 0 : this.tabHeight + 27))
        }
      }
      if (!this.hideReaderTabs()) this.primaryTabBar()
    }.width('100%').height('100%').backgroundColor(PAPER)
  }

  @Builder
  accountSidebar(persistent: boolean) {
    AccountMenu({
          persistent,
          activeTab: this.navIndex,
          onTab: (index: number) => this.changeTab(index),
          handle: this.handle,
          name: this.accountName,
          topInset: this.statusInset,
          bottomInset: this.bottomInset,
          avatar: this.avatar,
          profile: this.ownProfile,
          entries: this.store.sidebarEntries(),
          onProfile: () => {
            this.showDrawer(false);
            if (this.handle) this.openProfile(this.handle);
            else this.openWeb(ui('管理账号', this.locale), '/account/switch');
          },
          onSettings: () => this.openSettings(),
          onWeb: (name: string, path: string) => {
            if (path === HISTORY_PATH) this.openHistory();
            else this.openWeb(name, path);
          },
          accounts: this.knownAccounts,
          switching: this.switchingAccount,
          onSwitchAccount: (handle: string) => this.switchAccount(handle),
          onAddAccount: () => this.addAccount()
        }).width(persistent ? 204 : this.drawerWidth)
  }

  @Builder
  readerWithDrawer() {
    Stack({ alignContent: Alignment.Start }) {
      if (this.drawerOpen || this.drawerDrag > 0) {
        if (this.drawerOpen && this.handle && this.drawerProfileLoading) {
          Web({ src: '', controller: this.profileWeb })
            .width(1).height(1).opacity(0).hitTestBehavior(HitTestMode.None).focusable(false)
            .accessibilityLevel('no-hide-descendants').javaScriptAccess(true).domStorageAccess(true).fileAccess(false)
            .runJavaScriptOnDocumentStart([{ script: X_CONNECTIVITY, scriptRules: [X_ORIGIN] }])
            .onControllerAttached(() => {
              configureXWeb(this.profileWeb, true);
              this.profileWeb.loadUrl(X_ORIGIN + '/' + this.handle);
            })
            .onLoadIntercept((event) => event.data.isMainFrame() &&
              event.data.getRequestUrl() !== BLANK && !isXUrl(event.data.getRequestUrl()))
            .onPageEnd((event) => this.readOwnProfile(event.url))
        }
        this.accountSidebar(false)
        Column().width(20).height('100%')
          .linearGradient({ direction: GradientDirection.Right,
            colors: [[Color.Transparent, 0], [$r('app.color.drawer_shadow'), 1]] })
          .opacity(this.drawerOffset() / this.drawerWidth)
          .translate({ x: this.drawerOffset() - 19 })
          .hitTestBehavior(HitTestMode.None)
      }
      Stack() {
        this.reader()
        if (this.drawerOpen || this.drawerDrag > 0) {
          Column().width('100%').height('100%').backgroundColor(PAPER)
            .opacity(0.30 * this.drawerOffset() / this.drawerWidth)
            .hitTestBehavior(this.drawerOpen ? HitTestMode.Default : HitTestMode.None)
            .accessibilityText(ui('关闭账号侧栏', this.locale))
            .onClick(() => this.showDrawer(false))
        }
      }.width('100%').height('100%')
        .borderRadius({ topLeft: this.drawerOffset() > 0 ? 30 : 0, bottomLeft: this.drawerOffset() > 0 ? 30 : 0 })
        .clip(this.drawerOffset() > 0)
        .translate({ x: this.drawerOffset() })
    }.width('100%').height('100%').constraintSize({ maxWidth: this.wideTablet ? '100%' : 650 }).clip(true)
      .parallelGesture(
        PanGesture({ direction: PanDirection.Horizontal, distance: 12 })
          .onActionUpdate((event: GestureEvent) => this.dragDrawer(event.offsetX))
          .onActionEnd((event: GestureEvent) => this.endDrawerDrag(event))
          .onActionCancel(() => { if (this.drawerDrag) this.showDrawer(this.drawerOpen); })
      )
      .onAreaChange((_old: Area, area: Area) => {
        const width = Number(area.width);
        if (width > 0) this.drawerWidth = Math.min(340, width * 0.73);
      })
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        if (this.session === Session.SigningIn) this.loginHeader()
        if (this.chatWebVisible) {
          Row() {
            this.iconButton($r('sys.symbol.chevron_left'), ui('返回', this.locale), () => { this.back(); })
            Text(ui('聊天', this.locale)).fontSize(18).fontWeight(FontWeight.Bold).fontColor(INK)
              .textAlign(TextAlign.Center).layoutWeight(1)
            Blank().width(46)
          }.width('100%').height(46)
        }
        Stack({ alignContent: Alignment.Center }) {
          this.sessionWeb()
          ForEach(this.chatEngine ? [this.chatEngine] : [], (engine: ReaderProbe) => {
            this.chatEngineWeb(engine)
          }, (engine: ReaderProbe) => engine.key)
          if (this.session === Session.SigningIn && !this.loginWebVisible()) {
            if (this.loginProblem) {
              this.feedback(ui('暂时无法连接 X', this.locale), this.loginProblem, ui('重试', this.locale), () => this.beginLogin())
            } else {
              LoadingProgress().width(28).height(28).color(this.accentInk)
            }
          }
        }.width('100%').layoutWeight(1)
      }.width('100%').height('100%').padding({ top: this.statusInset, bottom: this.bottomInset })
      ForEach(this.discoveryProbe ? [this.discoveryProbe] : [], (probe: ReaderProbe) => {
        Web({ src: '', controller: probe.controller })
          .width('100%').height('100%').opacity(0).hitTestBehavior(HitTestMode.None).focusable(false)
          .accessibilityLevel('no-hide-descendants').javaScriptAccess(true).domStorageAccess(true)
          .fileAccess(false).onlineImageAccess(false)
          .runJavaScriptOnDocumentStart([{ script: X_CONNECTIVITY, scriptRules: [X_ORIGIN] }])
          .onLoadIntercept((event) => event.data.isMainFrame() &&
            event.data.getRequestUrl() !== BLANK && !isXUrl(event.data.getRequestUrl()))
          .onControllerAttached(() => { if (this.discoveryProbe === probe) this.readDiscovery(probe); })
      }, (probe: ReaderProbe) => probe.key)
      ForEach(this.readerProbe ? [this.readerProbe] : [], (probe: ReaderProbe) => {
        this.backgroundReader(probe)
      }, (probe: ReaderProbe) => probe.key)
      ForEach(this.libraryProbe ? [this.libraryProbe] : [], (probe: ReaderProbe) => {
        this.backgroundReader(probe)
      }, (probe: ReaderProbe) => probe.key)
      ForEach(this.inboxAccountProbe ? [this.inboxAccountProbe] : [], (probe: ReaderProbe) => {
        this.backgroundReader(probe)
      }, (probe: ReaderProbe) => probe.key)
      ForEach(this.videoFeedProbe ? [this.videoFeedProbe] : [], (probe: ReaderProbe) => {
        this.backgroundReader(probe, true)
      }, (probe: ReaderProbe) => probe.key)
      ForEach(this.downloadVideoPost ? [this.downloadVideoPost] : [], (post: Post) => {
        XWebPage({ url: X_ORIGIN + '/' + post.handle + '/status/' + post.id,
          videoPostId: post.id, videoPoster: post.videoPoster, backgroundOnly: true,
          videoWebSource: this.downloadWebSource,
          onVideoSources: (sources: string[]) => this.downloadVideoResolve?.(sources)
        }).opacity(0.01).hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
      }, (post: Post) => post.id)
      ForEach(this.warmupPost ? [this.warmupPost] : [], (post: Post) => {
        XWebPage({
          url: X_ORIGIN + '/' + post.handle + '/status/' + post.id,
          videoPostId: post.id,
          videoPoster: post.videoPoster,
          backgroundOnly: true,
          onVideoSources: (sources: string[]) => this.acceptWarmupSources(post, sources)
        }).opacity(0.01).hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
      }, (post: Post) => post.id)
      ForEach(this.translationHost ? [this.translationHost] : [], (probe: ReaderProbe) => {
        this.translationReader(probe)
      }, (probe: ReaderProbe) => probe.key)
      ForEach(this.accountSwitchProbe ? [this.accountSwitchProbe] : [], (probe: ReaderProbe) => {
        this.accountSwitchReader(probe)
      }, (probe: ReaderProbe) => probe.key)
      // Mount the X editor only for publishing or GIF lookup. Loading it during typing can steal IME focus.
      ForEach(this.postComposer && this.postComposerWebRequested ? [this.postComposer] : [], (probe: ReaderProbe) => {
        // X's editor only accepts text once its page has focus. Allow focus while sending, never while the user types.
        Web({ src: '', controller: probe.controller })
          .width('100%').height('100%').opacity(0).hitTestBehavior(HitTestMode.None)
          .focusable(this.composerBusy || this.postGifBusy)
          .accessibilityLevel('no-hide-descendants').javaScriptAccess(true).domStorageAccess(true).fileAccess(false)
          .runJavaScriptOnDocumentStart([{ script: X_CONNECTIVITY, scriptRules: [X_ORIGIN] }])
          .onLoadIntercept((event) => event.data.isMainFrame() &&
            event.data.getRequestUrl() !== BLANK && !isXUrl(event.data.getRequestUrl()))
          .onInterceptRequest((event) => this.postMediaBridge.respond(event.request) as WebResourceResponse)
          .onControllerAttached(() => {
            if (this.postComposer === probe) {
              configureXWeb(probe.controller, true);
              probe.controller.loadUrl(probe.route.url());
            }
          })
      }, (probe: ReaderProbe) => probe.key)
      ForEach(this.postMenuOperation ? [this.postMenuOperation] : [], (operation: PostMenuOperation) => {
        Web({ src: '', controller: operation.controller })
          .width('100%').height('100%').opacity(0).hitTestBehavior(HitTestMode.None).focusable(false)
          .accessibilityLevel('no-hide-descendants').javaScriptAccess(true).domStorageAccess(true).fileAccess(false)
          .runJavaScriptOnDocumentStart([{ script: X_CONNECTIVITY, scriptRules: [X_ORIGIN] }])
          .onLoadIntercept((event) => event.data.isMainFrame() &&
            event.data.getRequestUrl() !== BLANK && !isXUrl(event.data.getRequestUrl()))
          .onControllerAttached(() => { this.runPostMenuAction(operation); })
      }, (operation: PostMenuOperation) => operation.token.toString())
      ForEach(this.postActionProbe ? [this.postActionProbe] : [], (operation: PostActionOperation) => {
        Web({ src: '', controller: operation.controller })
          .width('100%').height('100%').opacity(0).hitTestBehavior(HitTestMode.None).focusable(false)
          .accessibilityLevel('no-hide-descendants').javaScriptAccess(true).domStorageAccess(true).fileAccess(false)
          .runJavaScriptOnDocumentStart([{ script: X_CONNECTIVITY, scriptRules: [X_ORIGIN] }])
          .onLoadIntercept((event) => event.data.isMainFrame() &&
            event.data.getRequestUrl() !== BLANK && !isXUrl(event.data.getRequestUrl()))
          .onControllerAttached(() => { this.runPostActionProbe(operation); })
      }, (operation: PostActionOperation) => operation.token.toString())
      if (this.session === Session.Active ||
        (this.session === Session.Starting && (this.showingSavedHome || this.detailPost !== null))) {
        Row() {
          if (this.wideTablet) {
            this.accountSidebar(true)
            Divider().vertical(true).height('100%').color(RULE)
          }
          Navigation(this.readerPages) {
            this.readerWithDrawer()
          }.mode(NavigationMode.Stack).hideTitleBar(true).navDestination(this.readerPage)
            .layoutWeight(1).height('100%')
          if (this.wideTablet) this.tabletDiscovery()
        }.width('100%').height('100%')
          .visibility(this.chatWebVisible ? Visibility.Hidden : Visibility.Visible)
          .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
        if (this.fullPhotos.length > 0) {
          Column() {
            Row() {
              this.iconButton($r('sys.symbol.chevron_left'), ui('关闭图片', this.locale), () => this.closePhotos())
            }.width('100%').height(54)
            Swiper(this.photoSwiper) {
              ForEach(this.fullPhotos, (photo: string, index: number) => {
                ZoomablePhoto({
                  source: imageAtSize(photo, this.imageQuality),
                  onFlip: (delta: number) => {
                    if (index !== this.photoIndex) return;
                    const next = index + delta;
                    if (next >= 0 && next < this.fullPhotos.length) this.photoSwiper.changeIndex(next, true);
                  },
                  onDismiss: (direction: number) => {
                    if (index === this.photoIndex) this.closePhotos(direction);
                  }
                })
              }, (photo: string, index: number) => index.toString() + ':' + photo)
            }.width('100%').layoutWeight(1).loop(false).indicator(false).disableSwipe(true)
              .index(this.photoIndex).duration(245).cachedCount(1).onChange((index: number) => this.photoIndex = index)
          }.width('100%').height('100%').padding({ top: this.statusInset, bottom: this.bottomInset })
            .backgroundColor(PAPER).translate({ y: this.photoSlide })
            .onSizeChange((_old: SizeOptions, size: SizeOptions) => {
              if (Number(size.height) > 0) this.photoHeight = Number(size.height);
            })
        }
        if (this.playerPost) {
          Stack() {
            ForEach([this.playerPost], (post: Post) => {
              PostVideoPlayer({
              post,
              translatedPost: this.translatedPosts.get(post.id) || null,
              topInset: this.statusInset,
              bottomInset: this.bottomInset,
              preferredSource: this.successfulVideoSources.get(post.id) || '',
              preparedSources: this.preparedVideoSources.get(post.id) || [],
              waitingForProbe: this.warmupPost?.id === post.id,
              recommendationLabel: this.videoRecommendationLabels.get(post.id) || '',
              sharedWebSource: this.playbackWebSource.available ? this.playbackWebSource : undefined,
              startup: this.playbackWebSource.available ? this.videoStartup : undefined,
              rate: $videoRate,
              screenLevel: this.videoBrightness,
              soundLevel: this.videoVolume,
              onBrightness: (value: number) => this.setVideoBrightness(value),
              onVolume: (value: number) => this.setVideoVolume(value),
              onFinished: () => {
                if (this.playerPost?.id === post.id && !this.videoSlideTarget) this.swipeVideo(1);
              },
              onClose: () => this.closeVideo(),
              onAuthor: () => {
                if (this.playerPost?.id !== post.id || !validHandle(post.handle)) return;
                this.closeVideo();
                this.openProfile(post.handle, post);
              },
              onReplies: () => {
                if (this.playerPost?.id !== post.id) return;
                const full = this.previewPosts.get(post.id) || post;
                this.closeVideo();
                this.openPost(full);
                const route = this.route;
                if (route.surface !== Surface.Detail || route.postId !== post.id) return;
                this.getUIContext().postFrameCallback(new RestoreThreadScroll(() => {
                  if (this.route === route && this.detailPost?.id === post.id) {
                    this.detailScroller.scrollToIndex(2, false, ScrollAlign.START);
                  }
                }));
              },
              onDrag: (offset: number) => this.dragVideo(offset),
              onSwipe: (direction: number) => { this.swipeVideo(direction); },
              onDuration: (seconds: number) => this.recordVideoDuration(post, seconds),
              onSourceReady: (source: string) => {
                if (this.playerPost?.id !== post.id) return;
                this.videoPlaybackReady = true;
                this.rememberVideoSource(post, source);
              }
              }).translate({ y: this.videoSlide })
            }, (post: Post) => post.id)
            if (this.videoSlideTarget) {
              Stack() {
                if (this.videoSlideTarget.videoPoster) {
                  Image(imageAtSize(this.videoSlideTarget.videoPoster, 'small')).width('100%').height('100%')
                    .objectFit(ImageFit.Contain).draggable(false)
                }
              }.width('100%').height('100%').backgroundColor(Color.Black)
                .translate({ y: this.videoSlide + this.videoSlideDirection * this.playerHeight })
                .hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
            }
          }.width('100%').height('100%').clip(true).backgroundColor(Color.Black)
            .onSizeChange((_old: SizeOptions, size: SizeOptions) => {
              if (Number(size.height) > 0) this.playerHeight = Number(size.height);
            })
        }
      } else if (this.session === Session.Starting) {
        if (this.content === Content.Failed) {
          this.feedback(ui('暂时无法恢复 X 会话', this.locale), this.problem, ui('重试', this.locale), () => this.start())
        } else {
          this.feedback(this.sessionKnown ? ui('正在恢复 X 会话', this.locale) : ui('正在检查 X 会话', this.locale),
            ui('正在连接 X。', this.locale), '', () => {})
        }
      } else if (this.session === Session.SignedOut) {
        this.welcome()
      } else if (this.session === Session.ResetFailed) {
        this.feedback(ui('尚未完成退出', this.locale), ui('重试清除本机的 X 网页会话。', this.locale), ui('重试清除', this.locale), () => this.clearSession())
      } else if (this.session === Session.Clearing) {
        this.feedback(ui('正在退出', this.locale), ui('正在清除此设备上的 X 网页会话。', this.locale), '', () => {})
      }
      if (this.mediaBusy && this.session === Session.Active) {
        GlassButton({ label: ui('正在下载', this.locale), busy: true, fixedWidth: 170, buttonHeight: 40 })
          .align(Alignment.Top).margin({ top: this.statusInset + 55 }).hitTestBehavior(HitTestMode.None)
      }
      if (this.showStartupIcon) {
        Column() {
          if (this.launcherIconId !== 'pending') {
            Column() { this.startupIcon() }
              .onAppear(() => {
                this.startupIconTimer = setTimeout(() => { this.showStartupIcon = false; }, 280);
              })
          }
        }.width('100%').height('100%').backgroundColor(PAPER).justifyContent(FlexAlign.Center)
          .accessibilityLevel('no-hide-descendants')
      }
    }.width('100%').height('100%').backgroundColor(PAPER)
      .bindSheet(!!this.replyTarget, this.replyOverlay(), {
        // The edge-to-edge window reports the keyboard overlap. Reserve that space inside the sheet.
        height: 144 + (this.replyEmojiOpen ? 42 : 0) + (this.replyAttachments.length ? 103 : 0) +
          (this.composerFeedback ? 42 : 0) + Math.max(0, this.keyboardInset - this.bottomInset),
        dragBar: false, showClose: false, preferType: SheetType.BOTTOM,
        maskColor: '#33000000', keyboardAvoidMode: SheetKeyboardAvoidMode.NONE,
        onAppear: () => {
          this.getUIContext().postFrameCallback(new RestoreThreadScroll(() => {
            if (this.replyTarget) this.getUIContext().getFocusController().requestFocus('qwitter-reply-editor');
          }));
        },
        systemMaterial: this.replyMaterial(),
        onWillDismiss: (action: DismissSheetAction) => {
          if (this.composerSubmitted || this.pickingPostMedia) return;
          this.closePostComposer();
          action.dismiss();
        }
      })
      .onSizeChange((_old: SizeOptions, size: SizeOptions) => {
        const wide = deviceInfo.deviceType === 'tablet' && Number(size.width) >= 900;
        if (this.wideTablet === wide) return;
        this.wideTablet = wide;
        this.drawerOpen = false;
        this.drawerDrag = 0;
        if (wide) this.startDiscovery();
      })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}
