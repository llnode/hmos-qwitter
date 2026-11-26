import { accentForeground, DEFAULT_ACCENT } from '../data/AppearancePreferences';
import { ui } from '../i18n/LanguageSettings';
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { configureXWeb, isXLoginUrl, isXUrl, matchesVideoAsset, normalizeVideoSources, videoPosterKey, X_CONNECTIVITY,
  X_HIDE_SITE_TABS, X_ORIGIN } from '../web/XPage';
import { PAPER } from './PostCard';
import { GlassButton } from './GlassButton';
import { VIDEO_TRANSPORT_SCRIPT, VideoWebSource } from '../web/VideoWebSource';

@Component
export struct XWebPage {
  @StorageProp('qyxAccent') private accent: string = DEFAULT_ACCENT;
  @StorageProp('qyxLocale') private locale: string = 'zh-Hans';
  @Prop @Watch('locationChanged') url: string = '';
  @Prop videoPostId: string = '';
  @Prop videoPoster: string = '';
  @Prop accountLogin: boolean = false;
  @Prop backgroundOnly: boolean = false;
  @Prop loginTraceScript: string = '';
  @State private failed: boolean = false;
  private attached: boolean = false;
  private controller: webview.WebviewController = new webview.WebviewController();
  onVideoSources: (sources: string[]) => void = () => {};
  videoWebSource?: VideoWebSource;

  aboutToDisappear(): void {
    if (this.videoPostId && this.attached) {
      try { this.controller.pauseAllMedia(); } catch (_) {}
    }
  }

  private attachVideoSource(url: string): void {
    if (!url.startsWith(X_ORIGIN + '/') || !this.videoWebSource) return;
    try { this.videoWebSource.attach(this.controller); }
    catch (_) { hilog.warn(0x0000, 'QyxVideo', 'browser video channel unavailable'); }
  }

  private allowed(url: string): boolean {
    return isXUrl(url) || (this.accountLogin && isXLoginUrl(url)) ||
      url.startsWith('https://help.x.com/') || url.startsWith('https://chat.x.com/') ||
      url.startsWith('https://money.x.com/');
  }

  private locationChanged(): void {
    if (!this.attached || !this.allowed(this.url)) return;
    this.failed = false;
    try {
      this.controller.loadUrl(this.url);
    } catch (_) {
      this.failed = true;
    }
  }

  private focusVideoScript(): string {
    if (!/^\d{1,24}$/.test(this.videoPostId)) return '';
    return `(() => {
      const suffix = '/status/${this.videoPostId}';
      if (window !== window.top || !location.pathname.replace(/\\/$/, '').endsWith(suffix)) return;
      const owner = location.pathname.split('/')[1].toLowerCase();
      const articleSelector = 'article, [role="article"]';
      const quoteSelector = '[data-testid="quoteTweet"], [role="link"]:not(a):has([data-testid="tweetText"])';
      const belongsTo = (node, article) => node.closest(articleSelector) === article && !node.closest(quoteSelector);
      const mediaSelector = '[data-testid="videoPlayer"], [data-testid="videoComponent"], ' +
        '[aria-label="Embedded video" i], [aria-label="Video player" i], [aria-label="嵌入式视频"], ' +
        '[aria-label="嵌入式影片"], [aria-label="嵌入式視訊"], video';
      let attempts = 0;
      let focused = false;
      let pressed = false;
      let requestedVideo;
      let targetSeen = false;
      let lastResult = '';
      const key = ${JSON.stringify(videoPosterKey(this.videoPoster))};
      const valid = /^https:\\/\\/video\\.twimg\\.com\\/[\\w/.-]+\\.(?:mp4|m3u8)(?:\\?[^\\s"'<>]*)?$/;
      const matches = (url) => url.includes('/' + key + '/') || url.includes('/tweet_video/' + key + '.mp4');
      const requests = new Set();
      const publish = (urls) => {
        const unique = Array.from(new Set(urls.filter(src => valid.test(src || ''))));
        const isAudio = (src) => /[/](?:aud|audio|mp4a)[/]/i.test(src.split('?')[0]);
        const audio = unique.filter(isAudio).slice(0, 3);
        const sources = [...unique.filter(src => !isAudio(src)).slice(0, 12 - audio.length), ...audio];
        if (!sources.length) return;
        const result = JSON.stringify(sources);
        if (lastResult === result) return;
        lastResult = result;
        console.info('qyx-video:${this.videoPostId}:' + result);
      };
      const observe = (input) => {
        const url = typeof input === 'string' ? input : input?.url || input?.href || '';
        if (requests.size < 16 && valid.test(url) && (key ? matches(url) : focused)) {
          requests.add(url);
          publish([...requests]);
        }
      };
      const fetch = window.fetch;
      if (fetch) window.fetch = function (input, options) {
        observe(input);
        return fetch.call(this, input, options);
      };
      const open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (...args) {
        observe(args[1]);
        return open.apply(this, args);
      };
      const postMedia = (post) => Array.from(post.querySelectorAll(mediaSelector)).find(node => belongsTo(node, post));
      const timer = setInterval(() => {
        if (++attempts > 58 || !location.pathname.replace(/\\/$/, '').endsWith(suffix)) {
          clearInterval(timer);
          return;
        }
        const articles = Array.from((document.querySelector('main, [data-testid="primaryColumn"]') ||
          document).querySelectorAll(articleSelector));
        let post = articles.find(article =>
          Array.from(article.querySelectorAll('a[href]')).some(link => {
            const url = new URL(link.href, location.origin);
            const path = url.pathname;
            return url.origin === location.origin && belongsTo(link, article) &&
              (path.endsWith(suffix) || path.endsWith(suffix + '/analytics') || path.endsWith(suffix + '/video/1'));
          }));
        if (!post && key) post = articles.find(article => Array.from(article.querySelectorAll('img')).some(image =>
          belongsTo(image, article) && (image.currentSrc || image.src).includes('/' + key + '/')));
        if (!post) {
          const own = articles.filter(article => postMedia(article) && Array.from(article.querySelectorAll('a[href]'))
            .some(link => belongsTo(link, article) && link.pathname.toLowerCase() === '/' + owner));
          if (own.length === 1) post = own[0];
        }
        if (post && !targetSeen) {
          targetSeen = true;
          console.info('qyx-video-state:post');
        }
        const media = post && postMedia(post);
        if (media && !focused) {
          media.scrollIntoView({ block: 'center' });
          focused = true;
          console.info('qyx-video-state:media');
        }
        const video = media?.matches('video') ? media : media?.querySelector('video');
        const urls = [video?.currentSrc, video?.src,
          ...Array.from(media?.querySelectorAll('source[src]') || [], source => source.src), ...requests];
        if (key) urls.push(...performance.getEntriesByType('resource').map(entry => entry.name).filter(matches));
        publish(urls);
        if (video) video.muted = true;
        if (video && video !== requestedVideo && (video.currentSrc || video.src)) {
          requestedVideo = video;
          video.play().catch(() => {});
        }
        const play = media && Array.from(media.querySelectorAll('button, [role="button"]')).find(node =>
          node.dataset.testid === 'playButton' ||
            /^(?:play(?: this)? video|播放(?:此)?(?:视频|影片|視訊))$/i.test(
              (node.getAttribute('aria-label') || node.textContent || '').trim().replace(/播放\\s+/g, '播放')));
        if (!pressed && play && (!video || video.paused)) {
          pressed = true;
          play.click();
          console.info('qyx-video-state:play-requested');
        }
      }, 200);
      window.addEventListener('qyx-stop-video-probe', () => clearInterval(timer), { once: true });
    })()`;
  }

  build() {
    Stack() {
      Web({ src: '', controller: this.controller })
        .width('100%').height('100%')
        .javaScriptAccess(true).domStorageAccess(true).fileAccess(false).mixedMode(MixedMode.None)
        .focusable(!this.backgroundOnly)
        .enableAutoFill(!this.accountLogin && !this.backgroundOnly)
        .multiWindowAccess(this.accountLogin).allowWindowOpenMethod(this.accountLogin)
        .darkMode(WebDarkMode.Auto).forceDarkAccess(true)
        .mediaPlayGestureAccess(!this.videoPostId)
        .runJavaScriptOnDocumentStart([
          { script: X_CONNECTIVITY, scriptRules: [X_ORIGIN] },
          { script: X_HIDE_SITE_TABS, scriptRules: [X_ORIGIN] },
          { script: this.videoWebSource ? VIDEO_TRANSPORT_SCRIPT : 'void 0', scriptRules: [X_ORIGIN] },
          { script: this.focusVideoScript() || 'void 0', scriptRules: [X_ORIGIN] },
          { script: this.accountLogin ? this.loginTraceScript : 'void 0', scriptRules: [X_ORIGIN] }
        ])
        .onControllerAttached(() => {
          configureXWeb(this.controller, !!this.videoPostId, this.accountLogin);
          this.attached = true;
          this.locationChanged();
        })
        .onPageBegin(() => { this.videoWebSource?.documentChanging(); })
        .onPageVisible((event) => this.attachVideoSource(event.url))
        .onPageEnd((event) => this.attachVideoSource(event.url))
        .onLoadIntercept((event) => event.data.isMainFrame() &&
          event.data.getRequestUrl() !== 'about:blank' && !this.allowed(event.data.getRequestUrl()))
        .onWindowNew((event) => {
          event.handler.setWebController(null);
          if (this.accountLogin && isXLoginUrl(event.targetUrl)) this.controller.loadUrl(event.targetUrl);
        })
        .onResourceLoad((event) => {
          if (!this.videoPostId || !matchesVideoAsset(event.url, videoPosterKey(this.videoPoster))) return;
          const sources = normalizeVideoSources([event.url]);
          if (sources.length) this.onVideoSources(sources);
        })
        .onConsole((event) => {
          const message = event.message.getMessage();
          if (this.accountLogin &&
            (message === 'qwitter-login-trace:onboarding-response-429' || message === 'qwitter-login-trace:cooldown')) {
            this.getUIContext().getPromptAction().showToast({ message: ui('X 请求过于频繁，请稍后再试', this.locale) });
          }
          if (this.accountLogin &&
            /^qwitter-login-trace:(continue-button|form-submit-button|password-button|password-field|no-password-field|phone-invalid|field-invalid|field-synced|form-submitted|script-error|script-rejection|onboarding-response-(?:0|[1-5][0-9]{2})|subtask-[A-Za-z-]{1,250}|webauthn-[A-Za-z-]{1,60}|passkeys-hidden|after-password:[a-z,]{0,80}:frames=[0-9])$/.test(message)) {
            hilog.info(0x0000, 'QwitterLogin', 'add-account %{public}s', message);
          }
          if (!this.videoPostId) return false;
          const prefix = 'qyx-video:' + this.videoPostId + ':';
          if (message === 'qyx-video-state:post' || message === 'qyx-video-state:media' ||
            message === 'qyx-video-state:play-requested') {
            hilog.info(0x0000, 'QyxVideo', '%{public}s', message);
            return true;
          }
          if (!message.startsWith(prefix) || message.length > 9000) return false;
          try {
            if (!isXUrl(this.controller.getUrl())) return false;
            const urls = JSON.parse(message.slice(prefix.length)) as string[];
            if (Array.isArray(urls)) this.onVideoSources(normalizeVideoSources(urls));
          } catch (_) {}
          return true;
        })
        .onErrorReceive((event) => {
          if (event.request.isMainFrame() && event.error.getErrorCode() !== -3) this.failed = true;
        })
        .onHttpErrorReceive((event) => {
          if (event.request.isMainFrame()) this.failed = true;
        })
        .onRenderExited(() => { this.failed = true; })
      if (this.failed) {
        Column({ space: 10 }) {
          Text(ui('暂时无法打开 X 页面', this.locale))
          GlassButton({ label: ui('重试', this.locale), filled: true, onTap: () => this.locationChanged() })
        }.width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor(PAPER)
      }
    }.width('100%').height('100%')
  }
}
