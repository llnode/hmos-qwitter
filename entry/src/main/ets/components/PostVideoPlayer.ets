import { media } from '@kit.MediaKit';
import { ui } from '../i18n/LanguageSettings';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { normalizeVideoSources, Post, videoDimensions, videoPosterKey, X_ORIGIN } from '../web/XPage';
import { isStandaloneVideoPlaylist, matchingHlsAudio, videoSourceOrder, VideoQuality } from '../web/VideoQuality';
import { VideoTransport } from '../web/VideoTransport';
import { VideoWebSource } from '../web/VideoWebSource';
import { Avatar, hasPostTranslation, postWithTranslation } from './PostCard';
import { XWebPage } from './XWebPage';
import { VideoStartupCache } from '../web/VideoStartupCache';

const VIDEO_RATES: number[] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];

@Component
export struct PostVideoPlayer {
  @StorageProp('qyxLocale') private locale: string = 'zh-Hans';
  @StorageProp('qyxVideoQuality') private defaultQuality: string = '';
  @StorageProp('qyxTranslationLanguage') @Watch('resetOriginal') private targetLanguage: string = '';
  @Prop post: Post = new Post();
  @Prop translatedPost: Post | null = null;
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;
  @Prop preferredSource: string = '';
  @Prop @Watch('preparedSourcesChanged') preparedSources: string[] = [];
  @Prop waitingForProbe: boolean = false;
  @Prop recommendationLabel: string = '';
  @Prop screenLevel: number = 0.5;
  @Prop soundLevel: number = 1;
  @Link @Watch('applyPlaybackRate') rate: number;
  @State private overlayVisible: boolean = true;
  @State private showOriginal: boolean = false;
  @State private zoom: number = 1;
  @State private levelLabel: string = '';
  @State private level: number = 0;
  @State private duration: number = 0;
  @State private sliderTime: number = 0;
  private seeking: boolean = false;
  private viewportWidth: number = 0;
  private viewportHeight: number = 0;
  private swipeZone: number = 0;
  private verticalOffset: number = 0;
  private levelAtStart: number = 0;
  private zoomAtStart: number = 1;
  private levelTimer: number = -1;
  private completionNotified: boolean = false;
  @State private source: string = '';
  @State private localSource: string = '';
  @State private started: boolean = false;
  @State private discovering: boolean = false;
  @State private ownProbe: boolean = false;
  @State private failed: boolean = false;
  @State private qualities: VideoQuality[] = [];
  @State private qualityLabel: string = '';
  private qualityResolution: string = '';
  @State private autoPlay: boolean = true;
  @State private checkingQuality: boolean = false;
  private attempted: Set<string> = new Set();
  private discoveredSources: string[] = [];
  private discoveryTried: boolean = false;
  private timeout: number = -1;
  private discoveryTimeout: number = -1;
  private probeDelay: number = -1;
  private resumeTimer: number = -1;
  private progressReported: boolean = false;
  private openedAt: number = 0;
  private transport: VideoTransport | null = null;
  private readonly localWebSource: VideoWebSource = new VideoWebSource();
  private readonly surfaceController: XComponentController = new XComponentController();
  private nativePlayer: media.AVPlayer | null = null;
  private playerGeneration: number = 0;
  private outputVolume: number = 1;
  @State private rendered: boolean = false;
  private localStartup: VideoStartupCache = new VideoStartupCache(this.localWebSource);
  private closed: boolean = false;
  private automaticSource: string = '';
  private playbackSeconds: number = 0;
  @State private playing: boolean = false;
  private resumePosition: number = -1;
  private resumePlayback: boolean = false;
  onClose: () => void = () => {};
  onReplies: () => void = () => {};
  onAuthor: () => void = () => {};
  onDrag: (offset: number) => void = () => {};
  onSwipe: (direction: number) => void = () => {};
  onDuration: (seconds: number) => void = () => {};
  onFinished: () => void = () => {};
  onBrightness: (value: number) => void = () => {};
  onVolume: (value: number) => void = () => {};
  onSourceReady: (source: string) => void = () => {};
  sharedWebSource?: VideoWebSource;
  startup?: VideoStartupCache;

  aboutToAppear(): void {
    this.openedAt = Date.now();
    this.outputVolume = this.soundLevel;
    const key = videoPosterKey(this.post.videoPoster);
    if (key && this.post.videoPoster.includes('/tweet_video_thumb/')) {
      this.discoveredSources = ['https://video.twimg.com/tweet_video/' + key + '.mp4'];
    }
    this.nextSource();
  }

  private resetOriginal(): void {
    this.showOriginal = false;
  }

  private textPost(): Post {
    return postWithTranslation(this.post, this.translatedPost, this.targetLanguage);
  }

  aboutToDisappear(): void {
    this.closed = true;
    clearTimeout(this.levelTimer);
    this.releaseNativePlayer();
    this.clearTimeout();
    clearTimeout(this.discoveryTimeout);
    clearTimeout(this.probeDelay);
    clearTimeout(this.resumeTimer);
    this.transport?.close();
    this.transport = null;
    this.localWebSource.close();
    this.localStartup.clear();
  }

  private clearTimeout(): void {
    clearTimeout(this.resumeTimer);
    this.resumeTimer = -1;
    if (this.timeout < 0) return;
    clearTimeout(this.timeout);
    this.timeout = -1;
  }

  private nextSource(previous: string = ''): void {
    if (this.closed || (previous && this.source !== previous)) return;
    if (previous && this.qualityLabel) {
      this.commitQuality();
      return;
    }
    this.clearTimeout();
    this.releaseNativePlayer();
    this.started = false;
    const sources = this.availableSources();
    const next = videoSourceOrder(sources, this.preferredSource, this.defaultQuality)
      .find((source: string) => !this.attempted.has(source));
    if (next && isStandaloneVideoPlaylist(next) && !matchingHlsAudio(next, sources)) {
      if (this.discovering) return;
      if (!this.discoveryTried) {
        this.source = '';
        this.localSource = '';
        this.discoverSources(3000);
        return;
      }
    }
    if (next && this.attempted.size < 4) {
      this.attempted.add(next);
      this.source = next;
      this.automaticSource = next;
      this.localSource = '';
      this.qualities = [];
      this.autoPlay = this.resumePosition < 0;
      this.progressReported = false;
      hilog.info(0x0000, 'QyxVideo', 'native source candidate %{public}d', this.attempted.size);
      this.openSource(next);
      return;
    }
    this.source = '';
    this.localSource = '';
    if (this.discovering) return;
    if (this.discoveryTried || this.attempted.size >= 4) {
      this.failed = true;
      hilog.warn(0x0000, 'QyxVideo', 'sources exhausted after %{public}d attempts', this.attempted.size);
      return;
    }
    this.discoverSources(18000);
  }

  private availableSources(): string[] {
    return normalizeVideoSources([this.preferredSource, ...this.preparedSources, ...this.post.videoSources,
      ...this.discoveredSources]);
  }

  private discoverSources(timeout: number): void {
    this.discoveryTried = true;
    this.discovering = true;
    if (this.waitingForProbe && this.sharedWebSource) {
      this.probeDelay = setTimeout(() => {
        if (this.discovering && !this.source) this.ownProbe = true;
      }, 800);
    } else {
      this.ownProbe = true;
    }
    this.discoveryTimeout = setTimeout(() => {
      this.discovering = false;
      this.ownProbe = false;
      if (!this.source) this.nextSource();
    }, timeout);
  }

  private preparedSourcesChanged(): void {
    this.acceptSources(this.preparedSources);
  }

  private acceptSources(sources: string[]): void {
    if (!this.discovering) return;
    this.discoveredSources = normalizeVideoSources([...this.discoveredSources, ...sources]);
    if (this.source) return;
    const candidates = this.availableSources();
    if (videoSourceOrder(candidates, this.preferredSource, this.defaultQuality).some((source: string) =>
      !this.attempted.has(source) && (!isStandaloneVideoPlaylist(source) || !!matchingHlsAudio(source, candidates)))) {
      this.nextSource();
    }
  }

  private receiveResolutions(source: string, resolutions: string[]): void {
    if (source !== this.automaticSource) return;
    this.qualities = resolutions.map((resolution: string) => new VideoQuality(resolution, source, true));
  }

  private qualityMenu(): MenuElement[] {
    const automatic: MenuElement = {
      value: (!this.qualityLabel ? '✓  ' : '') + (this.defaultQuality ?
        ui('默认', this.locale) + ' ' + this.defaultQuality.slice(1) + 'p' : ui('自动', this.locale)),
      action: () => this.selectQuality()
    };
    const choices = [...this.qualities];
    const seen = new Set<string>(choices.map((quality: VideoQuality) => quality.resolution));
    for (const source of normalizeVideoSources([...this.post.videoSources, ...this.discoveredSources])) {
      if (this.qualities.length) break;
      if (isStandaloneVideoPlaylist(source)) continue;
      if (!/\.mp4(?:\?|$)/.test(source)) continue;
      const dimensions = videoDimensions(source);
      if (dimensions && !seen.has(dimensions[1] + 'x' + dimensions[2])) {
        const resolution = dimensions[1] + 'x' + dimensions[2];
        choices.push(new VideoQuality(resolution, source, false));
        seen.add(resolution);
      }
    }
    choices.sort((a: VideoQuality, b: VideoQuality) => parseInt(b.label) - parseInt(a.label));
    return [automatic, ...choices.map((quality: VideoQuality): MenuElement => ({
      value: (this.qualityResolution === quality.resolution ? '✓  ' : '') + quality.label + '  ·  ' + quality.resolution.replace('x', ' × '),
      action: () => this.selectQuality(quality)
    }))];
  }

  private speedMenu(): MenuElement[] {
    return VIDEO_RATES.map((rate: number): MenuElement => ({
      value: (rate === this.rate ? '✓  ' : '') + rate.toString() + '×',
      action: () => { this.rate = rate; }
    }));
  }

  private async selectQuality(quality?: VideoQuality): Promise<void> {
    if (this.checkingQuality || this.closed || this.qualityResolution === (quality?.resolution || '')) return;
    const source = this.source;
    this.checkingQuality = true;
    try {
      if (quality?.hls) {
        await (this.startup || this.localStartup).warm(quality.source, quality.resolution);
      } else if (quality) {
        const response = await (this.sharedWebSource || this.localWebSource).request(quality.source, true, '');
        if (response.status !== 200 && response.status !== 206) throw new Error('Video quality unavailable');
      }
      if (!this.closed && this.source === source) this.commitQuality(quality);
    } catch (_) {
      if (!this.closed && this.source === source) {
        this.getUIContext().getPromptAction().showToast({ message: ui('加载失败，请重试', this.locale) });
      }
    } finally {
      this.checkingQuality = false;
    }
  }

  private commitQuality(quality?: VideoQuality): void {
    const remote = quality?.source || this.automaticSource;
    const resolution = quality ? (quality.hls ? quality.resolution : '') : this.defaultHlsQuality(remote);
    const audio = matchingHlsAudio(remote, this.availableSources());
    const local = (audio ? this.transport?.pairedSource(remote, audio) : '') ||
      this.transport?.source(remote, resolution) || '';
    if (!local || local === this.localSource) return;
    this.clearTimeout();
    if (this.resumePosition < 0) {
      this.resumePosition = this.playbackSeconds;
      this.resumePlayback = this.playing;
    }
    this.releaseNativePlayer();
    this.qualityLabel = quality?.label || '';
    this.qualityResolution = quality?.resolution || '';
    this.source = remote;
    this.started = false;
    this.progressReported = false;
    this.autoPlay = false;
    this.localSource = local;
  }

  private finishQualitySwitch(): void {
    if (this.resumePosition < 0) return;
    this.resumePosition = -1;
    this.clearTimeout();
    this.started = true;
    if (this.resumePlayback) this.startNativePlayback();
  }

  private async openSource(source: string): Promise<void> {
    let transport = this.transport;
    try {
      if (!transport) {
        transport = new VideoTransport(this.sharedWebSource || this.localWebSource,
          (remote: string, resolutions: string[]) => this.receiveResolutions(remote, resolutions),
          this.startup || this.localStartup);
        this.transport = transport;
        transport.prefetchPlaylist(source);
        await transport.open();
      } else {
        transport.prefetchPlaylist(source);
      }
      if (this.source !== source || this.transport !== transport) return;
      const audio = matchingHlsAudio(source, this.availableSources());
      this.localSource = (audio ? transport.pairedSource(source, audio) : '') ||
        transport.source(source, this.defaultHlsQuality(source));
      if (!this.localSource) throw new Error('Local video source unavailable');
    } catch (_) {
      if (this.transport !== transport) return;
      this.transport?.close();
      this.transport = null;
      if (this.source === source) this.nextSource(source);
    }
  }

  private releaseNativePlayer(): void {
    this.playerGeneration++;
    const player = this.nativePlayer;
    this.nativePlayer = null;
    this.playing = false;
    this.rendered = false;
    player?.release().catch(() => {});
  }

  private startNativePlayback(): void {
    const player = this.nativePlayer;
    if (player && (player.state === 'prepared' || player.state === 'paused' || player.state === 'completed')) {
      player.play().catch(() => this.failNativePlayer(player));
    }
  }

  private seekNativePlayback(seconds: number): void {
    const player = this.nativePlayer;
    if (!player || !['prepared', 'playing', 'paused', 'completed'].includes(player.state)) return;
    try { player.seek(Math.round(seconds * 1000), media.SeekMode.SEEK_CLOSEST); } catch (_) {}
  }

  private applyPlaybackVolume(): void {
    const player = this.nativePlayer;
    if (!player || !['prepared', 'playing', 'paused', 'completed'].includes(player.state)) return;
    try { player.setVolume(this.outputVolume); } catch (_) {
      hilog.warn(0x0000, 'QyxVideo', 'native player volume change failed');
    }
  }

  private applyPlaybackRate(): void {
    const player = this.nativePlayer;
    if (!player || !['prepared', 'playing', 'paused', 'completed'].includes(player.state)) return;
    const speeds: media.PlaybackSpeed[] = [
      media.PlaybackSpeed.SPEED_FORWARD_0_25_X, media.PlaybackSpeed.SPEED_FORWARD_0_50_X,
      media.PlaybackSpeed.SPEED_FORWARD_0_75_X, media.PlaybackSpeed.SPEED_FORWARD_1_00_X,
      media.PlaybackSpeed.SPEED_FORWARD_1_25_X, media.PlaybackSpeed.SPEED_FORWARD_1_50_X,
      media.PlaybackSpeed.SPEED_FORWARD_1_75_X, media.PlaybackSpeed.SPEED_FORWARD_2_00_X
    ];
    try { player.setSpeed(speeds[VIDEO_RATES.indexOf(this.rate)] ?? media.PlaybackSpeed.SPEED_FORWARD_1_00_X); } catch (_) {}
  }

  private failNativePlayer(player: media.AVPlayer): void {
    if (this.nativePlayer !== player || this.closed) return;
    hilog.warn(0x0000, 'QyxVideo', 'native playback error');
    this.nextSource(this.source);
  }

  private async mountNativePlayer(local: string): Promise<void> {
    this.waitForPlayback(local);
    const generation = ++this.playerGeneration;
    try {
      const surface = this.surfaceController.getXComponentSurfaceId();
      const player = await media.createAVPlayer();
      if (this.closed || this.localSource !== local || this.playerGeneration !== generation) {
        await player.release();
        return;
      }
      this.nativePlayer = player;
      const current = (): boolean => this.nativePlayer === player && this.localSource === local && !this.closed;
      player.on('error', () => this.failNativePlayer(player));
      player.on('startRenderFrame', () => {
        if (!current()) return;
        this.rendered = true;
        player.getTrackDescription().then((tracks: media.MediaDescription[]) => {
          if (!current()) return;
          const audio = tracks.filter((track: media.MediaDescription) =>
            track[media.MediaDescriptionKey.MD_KEY_TRACK_TYPE] === media.MediaType.MEDIA_TYPE_AUD).length;
          hilog.info(0x0000, 'QyxVideo', 'native audio tracks %{public}d', audio);
        }).catch(() => {});
      });
      player.on('durationUpdate', (ms: number) => {
        if (!current() || ms <= 0) return;
        this.duration = ms / 1000;
        this.onDuration(this.duration);
      });
      player.on('seekDone', (ms: number) => {
        if (!current()) return;
        this.playbackSeconds = ms / 1000;
        this.finishQualitySwitch();
      });
      player.on('timeUpdate', (ms: number) => {
        if (!current()) return;
        this.playbackSeconds = ms / 1000;
        if (!this.seeking) this.sliderTime = this.playbackSeconds;
        if (ms > 0 && !this.progressReported) {
          this.progressReported = true;
          clearTimeout(this.timeout);
          this.timeout = -1;
          hilog.info(0x0000, 'QyxVideo', 'native playback advanced after %{public}d ms', Date.now() - this.openedAt);
        }
      });
      player.on('stateChange', (state: media.AVPlayerState) => {
        if (!current()) return;
        if (state === 'initialized') {
          try {
            player.surfaceId = surface;
            player.prepare().catch(() => this.failNativePlayer(player));
          } catch (_) { this.failNativePlayer(player); }
        } else if (state === 'prepared') {
          try { player.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_SCALED_ASPECT; } catch (_) {}
          this.applyPlaybackVolume();
          this.applyPlaybackRate();
          this.duration = Math.max(0, player.duration / 1000);
          if (this.duration > 0) this.onDuration(this.duration);
          if (this.resumePosition > 0) {
            this.seekNativePlayback(this.duration > 0 ? Math.min(this.resumePosition, this.duration) : this.resumePosition);
            if (this.resumePosition >= 0) {
              this.resumeTimer = setTimeout(() => { if (current()) this.finishQualitySwitch(); }, 600);
            }
          } else if (this.resumePosition === 0) {
            this.finishQualitySwitch();
          } else if (this.autoPlay) {
            this.startNativePlayback();
          }
        } else if (state === 'playing') {
          this.playing = true;
          this.clearTimeout();
          this.started = true;
          this.discovering = false;
          this.ownProbe = false;
          clearTimeout(this.discoveryTimeout);
          if (!this.sharedWebSource) this.localWebSource.stopProbe();
          if (this.automaticSource === this.source) this.onSourceReady(this.source);
        } else if (state === 'paused') {
          this.playing = false;
        } else if (state === 'completed') {
          this.finishPlayback(local);
        }
      });
      player.url = local;
    } catch (_) {
      if (!this.closed && this.localSource === local && this.playerGeneration === generation) this.nextSource(this.source);
    }
  }

  private defaultHlsQuality(source: string): string {
    return /\.m3u8(?:\?|$)/i.test(source) ? this.defaultQuality : '';
  }

  private retry(): void {
    this.attempted.clear();
    this.discoveryTried = false;
    this.failed = false;
    this.qualityLabel = '';
    this.qualityResolution = '';
    this.resumePosition = -1;
    this.playbackSeconds = 0;
    this.nextSource();
  }

  private waitForPlayback(local: string): void {
    if (this.started || this.progressReported || this.localSource !== local) return;
    this.clearTimeout();
    this.timeout = setTimeout(() => {
      if (this.localSource === local && !this.started && !this.progressReported) this.nextSource(this.source);
    }, 19000);
  }

  private togglePlayback(): void {
    if (!this.localSource) return;
    if (this.playing) this.nativePlayer?.pause().catch(() => {});
    else this.startNativePlayback();
  }

  private startVerticalGesture(event: GestureEvent): void {
    const finger = event.fingerList.find((item: FingerInfo) => !!item);
    const x = finger?.localX ?? this.viewportWidth / 2;
    this.swipeZone = x < this.viewportWidth * 0.2 ? -1 : x >= this.viewportWidth * 0.9 ? 1 : 0;
    this.verticalOffset = 0;
    this.levelAtStart = this.swipeZone < 0 ? this.screenLevel : this.outputVolume;
    this.level = this.levelAtStart;
  }

  private adjustLevel(offset: number): void {
    this.verticalOffset = offset;
    if (!this.swipeZone) {
      this.onDrag(offset);
      return;
    }
    const value = Math.max(this.swipeZone < 0 ? 0.03 : 0,
      Math.min(1, this.levelAtStart - offset / Math.max(150, this.viewportHeight * 0.55)));
    if (Math.abs(value - this.level) < 0.015 && value !== 0 && value !== 1) return;
    this.levelLabel = this.swipeZone < 0 ? ui('亮度', this.locale) : ui('音量', this.locale);
    const changed = this.level !== value;
    this.level = value;
    if (changed) {
      if (this.swipeZone < 0) this.onBrightness(value);
      else {
        this.outputVolume = value;
        this.applyPlaybackVolume();
        this.onVolume(value);
      }
    }
    clearTimeout(this.levelTimer);
    this.levelTimer = setTimeout(() => this.levelLabel = '', 800);
  }

  private finishPlayback(local: string): void {
    if (this.localSource !== local || this.closed || !this.started || this.completionNotified) return;
    this.completionNotified = true;
    this.playing = false;
    hilog.info(0x0000, 'QyxVideo', 'native playback completed');
    this.onFinished();
  }

  private timeLabel(seconds: number): string {
    const whole = Math.max(0, Math.floor(seconds));
    return Math.floor(whole / 60).toString() + ':' + (whole % 60).toString().padStart(2, '0');
  }

  @Builder
  playerControls() {
    Column() {
      Row() {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(20).fontColor([Color.White])
        }.width(40).height(40).backgroundColor('#55333333').accessibilityText(ui('关闭视频', this.locale))
          .onClick(() => this.onClose())
        Blank()
        if (this.recommendationLabel) {
          Text(this.recommendationLabel).fontSize(13).fontColor(Color.White)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 }).backgroundColor('#55333333').borderRadius(12)
        }
      }.width('100%').padding({ left: 16, right: 16, top: this.topInset + 10 }).hitTestBehavior(HitTestMode.Transparent)
      Blank().hitTestBehavior(HitTestMode.None)
      Column({ space: 8 }) {
        Row({ space: 10 }) {
          Row({ space: 10 }) {
            Avatar({ src: this.post.avatar, diameter: 36 })
            Column({ space: 2 }) {
              Text(this.post.name || '@' + this.post.handle).fontSize(15).fontWeight(FontWeight.Bold)
                .fontColor(Color.White).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text('@' + this.post.handle).fontSize(13).fontColor('#DDEFF3F4')
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          }.layoutWeight(1).constraintSize({ minHeight: 44 })
            .accessibilityText(ui('个人资料', this.locale) + ' @' + this.post.handle)
            .onClick(() => this.onAuthor())
          Button({ type: ButtonType.Capsule }) {
            Row({ space: 5 }) {
              Image($r('app.media.feed_reply')).width(17).height(17).fillColor(Color.White)
              if (this.post.replies) Text(this.post.replies).fontSize(12).fontColor(Color.White)
            }.padding({ left: 12, right: 12 })
          }.height(44).backgroundColor('#55333333').accessibilityText(ui('评论', this.locale))
            .onClick(() => this.onReplies())
        }.width('100%')
        if (hasPostTranslation(this.textPost(), this.targetLanguage)) {
          Row({ space: 8 }) {
            if (!this.showOriginal) Text(ui('由 X 翻译', this.locale)).fontSize(12).fontColor('#DDEFF3F4')
            Button(ui(this.showOriginal ? '查看译文' : '查看原文', this.locale))
              .buttonStyle(ButtonStyleMode.TEXTUAL).fontSize(12).fontColor(Color.White).height(28)
              .onClick(() => { this.showOriginal = !this.showOriginal; })
          }.width('100%')
        }
        if (this.post.body) {
          Text(hasPostTranslation(this.textPost(), this.targetLanguage) && !this.showOriginal ?
            this.textPost().translation : this.post.body).fontColor(Color.White).fontSize(15).lineHeight('20fp')
            .width('100%').maxLines(4).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Slider({ value: this.sliderTime, min: 0, max: Math.max(1, this.duration), step: 1, style: SliderStyle.InSet })
          .width('100%').trackThickness(3).selectedColor(Color.White).trackColor('#66FFFFFF')
          .enabled(this.duration > 0).onChange((value: number, mode: SliderChangeMode) => {
            this.sliderTime = value;
            this.seeking = mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving;
            if (!this.seeking && this.localSource) this.seekNativePlayback(value);
          })
        Row({ space: 10 }) {
          Button({ type: ButtonType.Capsule }) {
            if (this.playing) {
              SymbolGlyph($r('sys.symbol.pause_fill')).fontSize(18).fontColor([Color.White])
            } else {
              SymbolGlyph($r('sys.symbol.play_fill')).fontSize(18).fontColor([Color.White])
            }
          }.width(40).height(36).padding(0).backgroundColor('#55333333')
            .accessibilityText(ui(this.playing ? '暂停' : '播放视频', this.locale)).onClick(() => this.togglePlayback())
          Text(this.timeLabel(this.sliderTime) + ' / ' + this.timeLabel(this.duration))
            .fontSize(12).fontColor(Color.White).layoutWeight(1)
          Button(this.qualityLabel || ui('画质', this.locale))
            .height(36).fontSize(13).fontColor(Color.White).backgroundColor('#55333333')
            .enabled(this.started && !this.failed && !this.checkingQuality).bindMenu(this.qualityMenu())
          Button(this.rate.toString() + '×').height(36).fontSize(13).fontColor(Color.White)
            .backgroundColor('#55333333').accessibilityText(ui('倍速', this.locale)).bindMenu(this.speedMenu())
        }.width('100%')
      }.width('100%').padding({ left: 16, right: 16, top: 24, bottom: this.bottomInset + 12 })
        .linearGradient({ direction: GradientDirection.Bottom, colors: [['#00000000', 0], ['#CF000000', 1]] })
    }.width('100%').height('100%').hitTestBehavior(HitTestMode.Transparent)
  }

  build() {
    Stack() {
        if (this.ownProbe || !this.sharedWebSource) {
          XWebPage({
            url: X_ORIGIN + '/' + this.post.handle + '/status/' + this.post.id,
            videoPostId: this.post.id,
            videoPoster: this.post.videoPoster,
            videoWebSource: this.sharedWebSource ? undefined : this.localWebSource,
            onVideoSources: (sources: string[]) => this.acceptSources(sources)
          }).opacity(0.01).hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
        }
        Column().width('100%').height('100%').backgroundColor(Color.Black)
          .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
        if (this.localSource) {
          ForEach([this.localSource], (local: string) => {
            XComponent({ id: 'qwitter-video-' + this.post.id, type: XComponentType.SURFACE,
              controller: this.surfaceController })
              .width('100%').height('100%').scale({ x: this.zoom, y: this.zoom })
              .hitTestBehavior(HitTestMode.None).onLoad(() => this.mountNativePlayer(local))
          }, (local: string) => local)
        }
        if (!this.rendered && this.post.videoPoster) {
          Image(this.post.videoPoster).width('100%').height('100%').objectFit(ImageFit.Contain).opacity(0.5)
            .draggable(false).hitTestBehavior(HitTestMode.None)
        }
        Column().width('100%').height('100%').backgroundColor(Color.Transparent)
          .accessibilityLevel('no')
          .gesture(GestureGroup(GestureMode.Exclusive,
            TapGesture({ count: 2 }).onAction(() => this.togglePlayback()),
            TapGesture().onAction(() => this.overlayVisible = !this.overlayVisible),
            PinchGesture({ fingers: 2, distance: 4 })
              .onActionStart(() => this.zoomAtStart = this.zoom)
              .onActionUpdate((event: GestureEvent) => this.zoom = Math.max(1, Math.min(4, this.zoomAtStart * event.scale))),
            PanGesture({ fingers: 1, direction: PanDirection.Vertical, distance: 12 })
              .onActionStart((event: GestureEvent) => this.startVerticalGesture(event))
              .onActionUpdate((event: GestureEvent) => this.adjustLevel(event.offsetY))
              .onActionEnd(() => {
                if (!this.swipeZone) this.onSwipe(Math.abs(this.verticalOffset) >= 48 ? (this.verticalOffset < 0 ? 1 : -1) : 0);
              }).onActionCancel(() => {
                if (!this.swipeZone) this.onSwipe(0);
              })))
        if (this.overlayVisible) this.playerControls()
        if (this.failed) {
          Column({ space: 12 }) {
            Text(ui('暂时无法读取此视频', this.locale)).fontColor(Color.White)
            Button(ui('重试', this.locale)).onClick(() => this.retry())
          }
        } else if (!this.started) {
          LoadingProgress().width(36).height(36).color(Color.White)
            .hitTestBehavior(HitTestMode.None).accessibilityText(ui('正在加载…', this.locale))
        }
        if (this.levelLabel) {
          Text(this.levelLabel + '  ' + Math.round(this.level * 100).toString() + '%')
            .fontSize(15).fontColor(Color.White).padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .backgroundColor('#B0222222').borderRadius(20).hitTestBehavior(HitTestMode.None)
        }
    }.width('100%').height('100%').backgroundColor(Color.Black).clip(true)
      .onSizeChange((_old: SizeOptions, size: SizeOptions) => {
        this.viewportWidth = Number(size.width);
        this.viewportHeight = Number(size.height);
      })
  }
}
