import { decodeDiscovery, DiscoverySection } from './Discovery';
import { webview } from '@kit.ArkWeb';
import { decodeInbox, InboxPage } from './InboxPage';
import { isAudioVideoSource, videoSourceOrder } from './VideoQuality';

export const X_ORIGIN: string = 'https://x.com';
export const X_LOGIN: string = X_ORIGIN + '/i/flow/login';
export const BLANK: string = 'about:blank';

// OpenTwit-Web documented that ArkWeb can report offline while serving X.
// Correct that initial reading only in the top-level X document.
export const X_CONNECTIVITY: string = `(() => {
  if (window !== window.top || navigator.onLine ||
      !/^https:\\/\\/(?:x\\.com|www\\.x\\.com|twitter\\.com|www\\.twitter\\.com|mobile\\.twitter\\.com)$/.test(location.origin)) return;
  let online = true;
  try {
    Object.defineProperty(navigator, 'onLine', { configurable: true, get: () => online });
    window.addEventListener('online', () => { online = true; });
    window.addEventListener('offline', () => { online = false; });
    console.info('qyx-arkweb-online-corrected');
  } catch (_) {}
})();`;

export const X_HIDE_SITE_TABS: string = `(() => {
  if (location.origin !== 'https://x.com' || window !== window.top) return;
  const style = document.createElement('style');
  style.textContent = '[data-testid="BottomBar"], ' +
    'nav:has(a[href^="/home"]):has(a[href^="/notifications"]) { display:none !important; }';
  document.documentElement.appendChild(style);
})();`;

export function configureXWeb(controller: webview.WebviewController, silent: boolean = false,
  useMobileLoginAgent: boolean = false): void {
  if (silent) {
    try { controller.setAudioMuted(true); } catch (_) {}
  }
  try {
    const agent = controller.getUserAgent();
    const chrome = agent.match(/Chrome\/[\d.]+/);
    if (chrome && (useMobileLoginAgent || /\bMobile\b/.test(agent))) {
      controller.setCustomUserAgent('Mozilla/5.0 (Linux; HarmonyOS) AppleWebKit/537.36 ' +
        '(KHTML, like Gecko) ' + chrome[0] + ' Mobile Safari/537.36');
    }
  } catch (_) {
    // Keep ArkWeb's default agent if the controller is not ready.
  }
}

export enum Surface {
  Home,
  Search,
  Bookmarks,
  Profile,
  Detail,
  Notifications,
  Chat
}

export const SEARCH_MODES: string[] = ['top', 'latest', 'people', 'videos', 'photos'];

export function normalizeSearchMode(mode: string): string {
  return SEARCH_MODES.includes(mode) ? mode : 'top';
}

export function searchModeFilter(mode: string): string {
  if (mode === 'latest') return 'live';
  if (mode === 'people') return 'user';
  if (mode === 'videos') return 'video';
  if (mode === 'photos') return 'image';
  return '';
}

export class XRoute {
  readonly surface: Surface;
  readonly path: string;
  readonly query: string;
  readonly homeTab: number;
  readonly postId: string;
  readonly latestSearch: boolean;
  readonly searchMode: string;

  constructor(surface: Surface, path: string, query: string = '', homeTab: number = 0, postId: string = '',
    latestSearch: boolean = false, searchMode: string = '') {
    this.surface = surface;
    this.path = path;
    this.query = query;
    this.homeTab = homeTab;
    this.postId = postId;
    this.searchMode = normalizeSearchMode(searchMode || (latestSearch ? 'latest' : 'top'));
    this.latestSearch = this.searchMode === 'latest';
  }

  requestQuery(): string {
    return this.searchMode === 'photos' && this.query && !/(?:^|\s)filter:images(?:\s|$)/i.test(this.query) ?
      this.query + ' filter:images' : this.query;
  }

  url(): string {
    const query = this.query ? '?q=' + encodeURIComponent(this.requestQuery()) + '&src=typed_query' +
      (searchModeFilter(this.searchMode) ? '&f=' + searchModeFilter(this.searchMode) : '') : '';
    return X_ORIGIN + this.path + query;
  }
}

export class PostBodyLink {
  label: string = '';
  target: string = '';
}

export function isPostWebLink(value: string): boolean {
  return typeof value === 'string' && value.length <= 2000 && /^https?:\/\/[^\s/?#@\\]+(?:[/?#][^\s\\]*)?$/i.test(value);
}

function cleanBodyLinks(links: PostBodyLink[] | undefined): PostBodyLink[] | undefined {
  if (!Array.isArray(links)) return undefined;
  return links.slice(0, 32).filter((link: PostBodyLink) => link && typeof link.label === 'string' &&
    link.label.length > 0 && link.label.length <= 400 && typeof link.target === 'string' &&
    (/^@[A-Za-z0-9_]{1,15}$/.test(link.target) || isPostWebLink(link.target)));
}

export class QuotedPost {
  path: string = '';
  handle: string = '';
  name: string = '';
  avatar: string = '';
  time: string = '';
  body: string = '';
  bodyLinks?: PostBodyLink[];
  photo: string = '';
  video: boolean = false;
  poster: string = '';
  ratio: number = 0;
}

export class Post {
  id: string = '';
  replyToId: string = '';
  handle: string = '';
  name: string = '';
  avatar: string = '';
  time: string = '';
  body: string = '';
  bodyLinks?: PostBodyLink[];
  translation: string = '';
  translationLanguage: string = '';
  sourceLanguage: string = '';
  articlePath: string = '';
  articleTitle: string = '';
  articleCover: string = '';
  photos: string[] = [];
  photoRatios: number[] = [];
  verified: boolean = false;
  video: boolean = false;
  videoPoster: string = '';
  videoSources: string[] = [];
  videoRatio: number = 0;
  videoDuration: string = '';
  videoDurationVerified: boolean = false;
  quote: boolean = false;
  quotedPost: QuotedPost | null = null;
  context: string = '';
  replies: string = '';
  reposts: string = '';
  reposted: boolean = false;
  likes: string = '';
  liked: boolean = false;
  bookmarked: boolean = false;
  bookmarks?: string;
  views: string = '';
}

export interface PostLikeState {
  liked: boolean;
  count: string;
}

export class Profile {
  handle: string = '';
  name: string = '';
  bio: string = '';
  avatar: string = '';
  banner: string = '';
  verified: boolean = false;
  location: string = '';
  website: string = '';
  websiteUrl: string = '';
  birthday: string = '';
  joined: string = '';
  aboutPath: string = '';
  following: string = '';
  followers: string = '';
  followersPath: string = '';
  editPath: string = '';
  tabs: string[] = [];
}

// A tab link X shows on its History page or on the signed-in account's profile.
export class PageTab {
  label: string = '';
  path: string = '';
  selected: boolean = false;
}

export class Snapshot {
  cachedAt: number = 0;
  threadComplete: boolean = false;
  path: string = '';
  query: string = '';
  latestSearch: boolean = false;
  searchMode: string = 'top';
  documentLanguage: string = '';
  documentTime: number = 0;
  authenticated: boolean = false;
  signedOut: boolean = false;
  ownHandle: string = '';
  ownName: string = '';
  accountMenuPending: boolean = false;
  ownAvatar: string = '';
  homeTab: number = -1;
  empty: boolean = false;
  pageError: boolean = false;
  posts: Post[] = [];
  profile: Profile | null = null;
  inbox: InboxPage | null = null;
  discovery: DiscoverySection[] = [];
  pageTabs: PageTab[] = [];
  pageTabsProbe: string = '';
}

export function isXUrl(url: string): boolean {
  // A slash after the exact authority rules out lookalike hosts and userinfo.
  return url === X_ORIGIN || url.startsWith(X_ORIGIN + '/');
}

export function isXChatUrl(url: string): boolean {
  return url === 'https://chat.x.com' || url.startsWith('https://chat.x.com/') ||
    /^https:\/\/x\.com\/(?:i\/chat|messages)(?:[/?#]|$)/.test(url);
}

export function quoteStatusPath(path: string, outerId: string): string {
  const match = /^(\/(?:[A-Za-z0-9_]{1,15}|i\/web)\/status\/(\d{1,24}))(?:\/(?:photo|video)\/\d+)?\/?$/.exec(path);
  return match && match[2] !== outerId ? match[1] : '';
}

export function isXLoginUrl(url: string): boolean {
  const match = /^https:\/\/(?:x\.com|www\.x\.com|twitter\.com|www\.twitter\.com|mobile\.twitter\.com)(\/[^?#]*)/.exec(url);
  if (!match) return false;
  const path = match[1];
  return /^\/(?:login|i\/jf\/onboarding)(?:\/|$)/.test(path) ||
    /^\/i\/flow\/(?:login|challenge|single_sign_on|password_reset)(?:\/|$)/.test(path) ||
    /^\/account\/(?:access|login[-_][a-z_]+|begin_password_reset|confirm_email)(?:\/|$)/.test(path);
}

export function decodeSnapshot(raw: string, postLimit: number = 32, maxLength: number = 1100000): Snapshot | undefined {
  if (!raw || raw === '""' || raw.length > maxLength) return undefined;
  const json: string = raw.startsWith('"') ? JSON.parse(raw) as string : raw;
  const snapshot: Snapshot = JSON.parse(json) as Snapshot;
  if (!snapshot || typeof snapshot.path !== 'string' || typeof snapshot.authenticated !== 'boolean' ||
    !Array.isArray(snapshot.posts)) return undefined;
  snapshot.inbox = decodeInbox(snapshot.inbox);
  snapshot.searchMode = normalizeSearchMode(snapshot.searchMode || (snapshot.latestSearch ? 'latest' : 'top'));
  snapshot.latestSearch = snapshot.searchMode === 'latest';
  snapshot.discovery = decodeDiscovery(snapshot.discovery, snapshot.searchMode === 'people' ? 100 : 10);
  snapshot.pageTabs = decodePageTabs(snapshot.pageTabs);
  snapshot.pageTabsProbe = typeof snapshot.pageTabsProbe === 'string' ?
    snapshot.pageTabsProbe.replace(/[^\x20-\x7e]/g, '').slice(0, 200) : '';
  // The web result is untrusted. These fields can initiate navigation and image requests.
  snapshot.ownHandle = validHandle(snapshot.ownHandle) ? snapshot.ownHandle : '';
  snapshot.ownName = typeof snapshot.ownName === 'string' ? snapshot.ownName.slice(0, 80) : '';
  snapshot.ownAvatar = mediaUrl(snapshot.ownAvatar, 'profile_images');
  snapshot.posts = snapshot.posts.slice(0, postLimit).filter((post: Post) =>
    post && validHandle(post.handle) && typeof post.id === 'string' && /^\d{1,24}$/.test(post.id));
  for (const post of snapshot.posts) {
    post.bodyLinks = cleanBodyLinks(post.bodyLinks);
    post.replyToId = typeof post.replyToId === 'string' && /^\d{1,24}$/.test(post.replyToId) &&
      post.replyToId !== post.id ? post.replyToId : '';
    post.avatar = mediaUrl(post.avatar, 'profile_images');
    post.translation = typeof post.translation === 'string' ? post.translation.slice(0, 4000) : '';
    post.translationLanguage = typeof post.translationLanguage === 'string' &&
      /^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,2}$/.test(post.translationLanguage) ? post.translationLanguage : '';
    if (!post.body || post.body === post.translation) {
      post.translation = '';
      post.translationLanguage = '';
    }
    post.sourceLanguage = typeof post.sourceLanguage === 'string' &&
      /^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,2}$/.test(post.sourceLanguage) ? post.sourceLanguage : '';
    post.articlePath = typeof post.articlePath === 'string' &&
      /^\/(?:i|[A-Za-z0-9_]{1,15})\/article\/\d{1,24}$/.test(post.articlePath) ? post.articlePath : '';
    post.articleTitle = typeof post.articleTitle === 'string' ? post.articleTitle.slice(0, 140) : '';
    post.articleCover = mediaUrl(post.articleCover, 'media');
    const photos: string[] = [];
    const ratios: number[] = [];
    if (Array.isArray(post.photos)) {
      for (let index = 0; index < Math.min(post.photos.length, 12); index++) {
        const url = mediaUrl(post.photos[index], 'media');
        if (!url) continue;
        photos.push(url);
        const ratio = Array.isArray(post.photoRatios) ? post.photoRatios[index] : 0;
        ratios.push(Number.isFinite(ratio) && ratio > 0 ? Math.min(2.5, Math.max(0.68, ratio)) : 1.33);
      }
    }
    post.photos = photos;
    post.photoRatios = ratios;
    post.videoPoster = videoPosterUrl(post.videoPoster);
    post.videoSources = Array.isArray(post.videoSources) ? normalizeVideoSources(post.videoSources) : [];
    post.videoRatio = Number.isFinite(post.videoRatio) && post.videoRatio > 0 ?
      Math.min(2.5, Math.max(0.56, post.videoRatio)) : 1.78;
    post.videoDuration = post.videoDurationVerified === true && typeof post.videoDuration === 'string' && /^(?:\d{1,3}:)?\d{1,3}:\d{2}$/
      .test(post.videoDuration) ? post.videoDuration : '';
    post.liked = post.liked === true;
    post.reposted = post.reposted === true;
    post.bookmarked = post.bookmarked === true;
    const quote = post.quotedPost;
    if (quote) quote.bodyLinks = cleanBodyLinks(quote.bodyLinks);
    if (quote && typeof quote === 'object') {
      quote.path = typeof quote.path === 'string' ? quoteStatusPath(quote.path, post.id) : '';
      quote.handle = validHandle(quote.handle) ? quote.handle : '';
      quote.avatar = mediaUrl(quote.avatar, 'profile_images');
      quote.photo = mediaUrl(quote.photo, 'media');
      quote.poster = videoPosterUrl(quote.poster);
      quote.video = quote.video === true;
      quote.ratio = Number.isFinite(quote.ratio) && quote.ratio > 0 ? Math.min(2.5, Math.max(0.56, quote.ratio)) : 0;
      quote.name = typeof quote.name === 'string' ? quote.name.slice(0, 80) : '';
      quote.body = typeof quote.body === 'string' ? quote.body.slice(0, 600) : '';
      quote.time = typeof quote.time === 'string' ? quote.time.slice(0, 40) : '';
    } else {
      post.quotedPost = null;
    }
  }
  if (snapshot.profile) {
    const profile = snapshot.profile;
    if (!validHandle(profile.handle)) {
      snapshot.profile = null;
    } else {
      profile.avatar = mediaUrl(profile.avatar, 'profile_images');
      profile.banner = mediaUrl(profile.banner, 'profile_banners');
      profile.websiteUrl = typeof profile.websiteUrl === 'string' && profile.websiteUrl.length <= 600 &&
        /^https?:\/\/[^\s]+$/i.test(profile.websiteUrl) ? profile.websiteUrl : '';
      const prefix = '/' + profile.handle.toLowerCase();
      profile.aboutPath = profile.aboutPath?.toLowerCase() === prefix + '/about' ? profile.aboutPath : '';
      profile.followersPath = [prefix + '/followers', prefix + '/verified_followers']
        .includes(profile.followersPath?.toLowerCase()) ? profile.followersPath : '';
      profile.editPath = profile.editPath === '/settings/profile' ? profile.editPath : '';
      profile.tabs = Array.isArray(profile.tabs) ? profile.tabs.filter((tab: string) =>
        ['with_replies', 'reposts', 'likes', 'media', 'photos', 'videos', 'articles', 'highlights', 'subs'].includes(tab)) : [];
    }
  }
  return snapshot;
}

function decodePageTabs(tabs: PageTab[] | undefined): PageTab[] {
  if (!Array.isArray(tabs)) return [];
  const result: PageTab[] = [];
  for (const tab of tabs.slice(0, 12)) {
    if (!tab || typeof tab.label !== 'string' || !tab.label.trim()) continue;
    const entry = new PageTab();
    entry.label = tab.label.trim().slice(0, 40);
    entry.path = typeof tab.path === 'string' && /^\/[A-Za-z0-9_\/-]{1,120}$/.test(tab.path) ? tab.path : '';
    entry.selected = tab.selected === true;
    result.push(entry);
  }
  return result;
}

export function validHandle(handle: string): boolean {
  return typeof handle === 'string' && /^[A-Za-z0-9_]{1,15}$/.test(handle);
}

function mediaUrl(src: string, folder: string): string {
  return typeof src === 'string' && src.length <= 600 &&
    (src.startsWith('https://pbs.twimg.com/' + folder + '/') ||
      (folder === 'profile_images' && src.startsWith('https://pbs.twimg.com/default_profile_images/'))) ? src : '';
}

function videoPosterUrl(src: string): string {
  return typeof src === 'string' && src.length <= 600 &&
    /^https:\/\/pbs\.twimg\.com\/(?:ext_tw_video_thumb|amplify_video_thumb|tweet_video_thumb|media)\//.test(src) ? src : '';
}

export function imageAtSize(src: string, size: string = 'orig'): string {
  if (!mediaUrl(src, 'media') && !videoPosterUrl(src)) return src;
  const clean = src.replace(/:(?:orig|large|medium|small|thumb)(?=\?|$)/, '');
  if (/[?&]name=/.test(clean)) return clean.replace(/([?&]name=)[^&#]*/, (_match: string, prefix: string) => prefix + size);
  return clean + (clean.includes('?') ? '&' : '?') + 'name=' + size;
}

export function videoDimensions(src: string): RegExpMatchArray | null {
  return src.match(/\/(\d{2,5})x(\d{2,5})\//);
}

export function videoPosterKey(poster: string): string {
  return poster.match(/\/(?:ext_tw_video_thumb|amplify_video_thumb|tweet_video_thumb)\/([\w-]+)/)?.[1] || '';
}

export function matchesVideoAsset(source: string, key: string): boolean {
  return !!key && (source.includes('/' + key + '/') || source.includes('/tweet_video/' + key + '.mp4'));
}

function videoPixels(src: string): number {
  if (/\.m3u8(?:\?|$)/.test(src)) return -1;
  const dimensions = videoDimensions(src);
  return dimensions ? Number(dimensions[1]) * Number(dimensions[2]) : 0;
}

export function normalizeVideoSources(sources: string[]): string[] {
  const playable = Array.from(new Set(sources.filter((source: string) => typeof source === 'string' &&
    source.length <= 700 && /^https:\/\/video\.twimg\.com\/[\w/.-]+\.(?:mp4|m3u8)(?:\?[\w=&.%+\-]+)?$/.test(source))));
  playable.sort((a: string, b: string) => videoPixels(b) - videoPixels(a));
  const audio = playable.filter((source: string) => isAudioVideoSource(source) && /\.m3u8(?:\?|$)/i.test(source)).slice(0, 3);
  return [...videoSourceOrder(playable, '', '').slice(0, 12 - audio.length), ...audio];
}

export const ADVANCE_PAGE: string = '(() => {' +
  'if (location.origin !== "https://x.com") return false;' +
  'const root = document.querySelector(\'[data-testid="primaryColumn"], main, [role="main"]\');' +
  'let posts = root ? Array.from(root.querySelectorAll("article,[role=article]")).filter(a => !a.parentElement.closest("article,[role=article]")) : [];' +
  'if (!posts.length && root && /[/](media|photos|videos)([/]|$)/.test(location.pathname)) {' +
  'posts = Array.from(root.querySelectorAll("a[href*=\\"/status/\\"]:has(img)"));}' +
  'if (!posts.length) return false;' +
  'const start = Math.max(0, posts.findIndex(post => post.getBoundingClientRect().bottom > 0) - 3);' +
  'const last = posts[Math.min(posts.length - 1, start + 31)];' +
  'let scroller = last.parentElement;' +
  'while (scroller && !(/auto|scroll/.test(getComputedStyle(scroller).overflowY) && scroller.scrollHeight > scroller.clientHeight)) scroller = scroller.parentElement;' +
  'last.scrollIntoView({block:"end", behavior:"instant"});' +
  'scroller = scroller || document.scrollingElement;' +
  'scroller.scrollBy(0, Math.round(scroller.clientHeight * 0.65)); return true;' +
  '})()';

export const ADVANCE_VIDEO_FEED: string = `(() => {
  if (location.origin !== 'https://x.com') return false;
  const immersive = /[/]mediaViewer[/]?$/.test(location.pathname);
  let scroller = document.querySelector('[data-testid="vss-scroll-view"]:has([data-testid^="cellInnerDiv-tweet-"])');
  if (!scroller && immersive) {
    const card = document.querySelector('[data-testid="modalContainer"] [data-testid^="cellInnerDiv-tweet-"], ' +
      '[role="dialog"] [data-testid^="cellInnerDiv-tweet-"]');
    scroller = card?.parentElement;
    while (scroller && !(/auto|scroll/.test(getComputedStyle(scroller).overflowY) &&
      scroller.scrollHeight > scroller.clientHeight)) scroller = scroller.parentElement;
  }
  if (scroller?.clientHeight) {
    const before = scroller.scrollTop;
    // X mounts adjacent cards only and requests the next page at the last two positions.
    scroller.scrollBy({ top: scroller.clientHeight, behavior: 'instant' });
    return scroller.scrollTop > before;
  }
  return immersive ? false : ${ADVANCE_PAGE};
})()`;

export const ADVANCE_REPLIES: string = '(() => {' +
  'if (location.origin !== "https://x.com") return false;' +
  'const root = document.querySelector(\'[data-testid="primaryColumn"], main, [role="main"]\');' +
  'if (!root) return false;' +
  'const more = /^(show|see|view|load) (?:\\d+ )?(?:more |additional )?repl(?:y|ies)$|^(显示|查看|載入|加载|顯示|檢視)(?:更多|其他)?(?:回覆|回复|回應)(?:\\s*\\(\\d+\\))?$/i;' +
  'const buttons = [...root.querySelectorAll("button, [role=button]")];' +
  'const next = buttons.find(node => !node.closest("article") && ' +
  'node.getBoundingClientRect().top < innerHeight * 2 && ' +
  'node.getBoundingClientRect().bottom > 0 && more.test((node.getAttribute("aria-label") || node.textContent).trim()));' +
  'if (next) { next.click(); return true; }' +
  'return ' + ADVANCE_PAGE + ';' +
  '})()';
