import { hilog } from '@kit.PerformanceAnalysisKit';
import { DEFAULT_ACCENT } from '../data/AppearancePreferences';
import { imageAtSize, isPostWebLink, Post, PostBodyLink, PostLikeState, QuotedPost } from '../web/XPage';
import { ui } from '../i18n/LanguageSettings';

export const INK: Resource = $r('app.color.ink');
export const MUTED: Resource = $r('app.color.muted');
export const PAPER: Resource = $r('app.color.paper');
export const SOFT: Resource = $r('app.color.soft');
export const RULE: Resource = $r('app.color.rule');
const POST_TOKENS: RegExp = /((?:https?:\/\/|www\.)[^\s]+|(?<![\w@.])(?:[a-z0-9-]+\.)+[a-z]{2,}(?:\/[\x21-\x7e]*…?|…)|[#@][\p{L}\p{N}_]+)/iu;
const ADDRESS_START: RegExp = /^(?:https?:\/\/|www\.|(?:[a-z0-9-]+\.)+[a-z]{2,}[\/…])/i;
const POST_TAP_DISTANCE: number = 6;

function compactWebAddress(part: string): string {
  if (!ADDRESS_START.test(part)) return part;
  const display = part.replace(/^https?:\/\//i, '');
  if (display.length <= 34) return display;
  const hostEnd = display.search(/[/?#]/);
  if (hostEnd >= 25 && hostEnd < 34) return display.slice(0, hostEnd) + '…';
  return display.slice(0, 33) + '…';
}

class PostTextPart {
  label: string;
  target: string;

  constructor(label: string, target: string = '') {
    this.label = label;
    this.target = target;
  }
}

function postTextParts(body: string, links: PostBodyLink[]): PostTextPart[] {
  const parts: PostTextPart[] = [];
  const appendPlain = (text: string): void => {
    for (const part of text.split(POST_TOKENS)) {
      if (!part) continue;
      const mention = /^@[A-Za-z0-9_]{1,15}$/.test(part);
      const candidate = part.replace(/[.,!;:，。！？；：]+$/, '');
      const address = ADDRESS_START.test(candidate) && !candidate.includes('…') ?
        (/^https?:/i.test(candidate) ? candidate : 'https://' + candidate) : '';
      if (mention) parts.push(new PostTextPart(part, part));
      else if (isPostWebLink(address)) {
        parts.push(new PostTextPart(candidate, address));
        if (candidate !== part) parts.push(new PostTextPart(part.slice(candidate.length)));
      } else parts.push(new PostTextPart(part));
    }
  };
  let offset = 0;
  for (const link of links) {
    const index = body.indexOf(link.label, offset);
    if (index < 0) continue;
    appendPlain(body.slice(offset, index));
    parts.push(new PostTextPart(link.label, link.target));
    offset = index + link.label.length;
  }
  appendPlain(body.slice(offset));
  return parts;
}

export function hasPostTranslation(post: Post, targetLanguage: string): boolean {
  return !!targetLanguage && targetLanguage === post.translationLanguage && !!post.body &&
    !!post.translation && post.body !== post.translation;
}

export function postWithTranslation(post: Post, cached: Post | null | undefined, target: string): Post {
  return cached && cached.body === post.body && hasPostTranslation(cached, target) ? cached : post;
}

@Component
export struct Avatar {
  @Prop src: string = '';
  @Prop diameter: number = 42;
  @State private failedSource: string = '';

  private avatarSource(): string {
    if (this.src !== this.failedSource) return this.src;
    return this.src.replace(/_(?:normal|bigger|mini|200x200|400x400)(?=\.[a-zA-Z]+(?:[?#]|$))/, '');
  }

  build() {
    Stack() {
      SymbolGlyph($r('sys.symbol.person_fill')).fontSize(this.diameter * 0.49).fontColor([MUTED])
      if (this.src) {
        Image(this.avatarSource())
          .width('100%').height('100%').objectFit(ImageFit.Cover).autoResize(true)
          .draggable(false).onError(() => { this.failedSource = this.src; })
      }
    }
    .width(this.diameter).height(this.diameter).borderRadius(this.diameter / 2)
    .clip(true).backgroundColor(SOFT).accessibilityLevel('no')
  }
}

@Component
export struct PostMenuAvatar {
  @StorageProp('qyxLocale') private locale: string = 'zh-Hans';
  @Prop src: string = '';
  @Prop diameter: number = 40;
  @Prop own: boolean = false;
  @Prop handle: string = '';
  @State private menuOpen: boolean = false;
  onProfile: () => void = () => {};
  onAction: (kind: string) => void = () => {};

  private choose(kind: string): void {
    this.menuOpen = false;
    this.onAction(kind);
  }

  @Builder
  contextMenu() {
    Menu() {
      if (this.own) {
        MenuItem({ content: ui('删除', this.locale) })
          .contentFontColor('#F4212E').onClick(() => this.choose('delete'))
      } else {
        MenuItem({ content: ui('关注 @{0}', this.locale, this.handle) }).onClick(() => this.choose('follow'))
        MenuItem({ content: ui('隐藏 @{0}', this.locale, this.handle) }).onClick(() => this.choose('mute'))
        MenuItem({ content: ui('屏蔽 @{0}', this.locale, this.handle) })
          .contentFontColor('#F4212E').onClick(() => this.choose('block'))
      }
    }.width(224)
  }

  build() {
    Stack() {
      Avatar({ src: this.src, diameter: this.diameter })
    }.width(this.diameter).height(this.diameter)
      .gesture(GestureGroup(GestureMode.Exclusive,
        LongPressGesture({ repeat: false, duration: 500 }).onAction(() => {
          hilog.info(0x0000, 'QwitterMenu', 'avatar long-press');
          this.menuOpen = true;
        }),
        TapGesture().onAction(() => this.onProfile())))
      .bindMenu(this.menuOpen, this.contextMenu, {
        placement: Placement.BottomLeft,
        onAppear: () => { hilog.info(0x0000, 'QwitterMenu', 'avatar menu-open'); },
        onDisappear: () => {
          hilog.info(0x0000, 'QwitterMenu', 'avatar menu-close');
          this.menuOpen = false;
        }
      })
  }
}

@Component
export struct PostText {
  @StorageProp('qyxAccentInk') private accentInk: string = DEFAULT_ACCENT;
  @Prop body: string = '';
  @Prop links: PostBodyLink[] = [];
  @Prop compact: boolean = false;
  @Prop selectable: boolean = false;
  @Prop canToggle: boolean = false;
  @Prop showOriginal: boolean = false;
  @Prop lineHeight: number = 18;
  @StorageProp('qyxLocale') private locale: string = 'zh-Hans';
  onOpen: () => void = () => {};
  onBodyLink: (target: string) => void = () => {};
  onToggle: () => void = () => {};

  build() {
    Column({ space: 4 }) {
      Text() {
        ForEach(postTextParts(this.body, this.links), (part: PostTextPart) => {
          if (part.target) {
            Span(compactWebAddress(part.label)).fontColor(this.accentInk)
              .onClick(() => this.onBodyLink(part.target))
          } else {
            Span(part.label).fontColor(part.label.startsWith('#') ? this.accentInk : this.compact ? MUTED : INK)
          }
        }, (part: PostTextPart, index: number) => index.toString() + ':' + part.label + ':' + part.target)
      }.fontSize(this.compact ? 14 : 15).lineHeight(this.lineHeight.toString() + 'fp').width('100%')
        .maxLines(this.compact ? 5 : 1000).textOverflow({ overflow: TextOverflow.Ellipsis })
        .copyOption(this.selectable ? CopyOptions.LocalDevice : CopyOptions.None)
        .draggable(false)
        .onClick(() => this.onOpen(), POST_TAP_DISTANCE)
      if (this.canToggle) {
        Button(ui(this.showOriginal ? '查看译文' : '查看原文', this.locale))
          .buttonStyle(ButtonStyleMode.TEXTUAL).fontColor(this.accentInk).fontSize(12).height(29)
          .onClick(() => this.onToggle())
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}

@Component
export struct PostLikeButton {
  @StorageProp('qyxLocale') private locale: string = 'zh-Hans';
  @Prop liked: boolean = false;
  @Prop count: string = '';
  @Prop rowHeight: number = 32;
  onToggle: () => void = () => {};

  build() {
    Row({ space: 3 }) {
      Image(this.liked ? $r('app.media.feed_liked') : $r('app.media.feed_like')).width(16).height(16).draggable(false)
      if (this.count) {
        Text(this.count).fontSize(12).fontColor(this.liked ? '#D9233A' : MUTED)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }.height(this.rowHeight).constraintSize({ minWidth: 34 }).justifyContent(FlexAlign.Center)
      .accessibilitySelected(this.liked)
      .accessibilityText(ui(this.liked ? '取消喜欢' : '喜欢', this.locale) + (this.count ? ' ' + this.count : ''))
      .onClick(() => this.onToggle(), POST_TAP_DISTANCE)
  }
}

@Component
export struct PostCard {
  @StorageProp('qyxAccentInk') private accentInk: string = DEFAULT_ACCENT;
  @StorageProp('qyxLocale') private locale: string = 'zh-Hans';
  @StorageProp('qyxImageQuality') private imageQuality: string = 'orig';
  @StorageProp('qyxTranslationLanguage') @Watch('resetOriginal') private targetLanguage: string = '';
  @Prop post: Post = new Post();
  @Prop separated: boolean = false;
  @Prop selectableText: boolean = false;
  @Prop highQuality: boolean = true;
  @Prop translatedPost: Post | null = null;
  @Prop translatedQuote: Post | null = null;
  @Prop likeState: PostLikeState | null = null;
  @Prop repostState: PostLikeState | null = null;
  @Prop bookmarkState: PostLikeState | null = null;
  @Prop videoDuration: string | null = null;
  @State private showOriginal: boolean = false;
  @State private previewFallbacks: string[] = [];
  @State private readyPreviews: string[] = [];
  @State private galleryWidth: number = 0;
  onReply: () => void = () => {};
  onPost: () => void = () => {};
  onProfile: () => void = () => {};
  onBodyLink: (target: string) => void = () => {};
  onPhoto: (index: number) => void = () => {};
  onGalleryTouch: (active: boolean) => void = () => {};
  onArticle: () => void = () => {};
  onQuote: (quote: QuotedPost) => void = () => {};
  onDownloadQuote: (quote: QuotedPost) => void = () => {};
  onPlayVideo: () => void = () => {};
  onDownloadVideo: () => void = () => {};
  onDownloadPhoto: (index: number) => void = () => {};
  onShare: () => void = () => {};
  onLike: () => void = () => {};
  onRepost: () => void = () => {};
  onBookmark: () => void = () => {};
  @Prop ownHandle: string = '';
  onMore: (kind: string) => void = () => {};

  private resetOriginal(): void {
    this.showOriginal = false;
  }

  private textPost(): Post {
    return postWithTranslation(this.post, this.translatedPost, this.targetLanguage);
  }

  private quoteBody(quote: QuotedPost): string {
    const translated = this.translatedQuote;
    return translated && translated.body === quote.body && hasPostTranslation(translated, this.targetLanguage) ?
      translated.translation : quote.body;
  }

  private canToggleTranslation(): boolean {
    return hasPostTranslation(this.textPost(), this.targetLanguage);
  }

  private previewSize(poster: boolean): string {
    return poster && this.imageQuality === 'orig' ? '4096x4096' : this.imageQuality;
  }

  @Builder
  preview(src: string, poster: boolean = false) {
    Stack() {
      // Feed previews are shown at card size: decode at that size (autoResize) instead of the source size, and drop
      // the low-resolution layer once the opaque high-quality layer above it has finished loading.
      if (!(this.highQuality && this.imageQuality !== 'small' &&
        this.readyPreviews.includes(imageAtSize(src, this.previewSize(poster))))) {
        Image(this.previewFallbacks.includes(src) ? src : imageAtSize(src, 'small'))
          .width('100%').height('100%').objectFit(ImageFit.Cover).autoResize(true).draggable(false)
          .onError(() => {
            if (!this.previewFallbacks.includes(src)) this.previewFallbacks.push(src);
          })
      }
      if (this.highQuality && this.imageQuality !== 'small') {
        Image(imageAtSize(src, this.previewSize(poster)))
          .width('100%').height('100%').objectFit(ImageFit.Cover).autoResize(true).draggable(false)
          .opacity(this.readyPreviews.includes(imageAtSize(src, this.previewSize(poster))) ? 1 : 0)
          .onComplete(() => {
            const url = imageAtSize(src, this.previewSize(poster));
            if (!this.readyPreviews.includes(url)) this.readyPreviews.push(url);
          })
      }
    }.width('100%').height('100%').backgroundColor(SOFT)
  }

  @Builder
  metric(icon: Resource, value: string, label: string, action: () => void, active: boolean = false) {
    Row({ space: 3 }) {
      Image(icon).width(16).height(16).draggable(false).fillColor(active ? this.accentInk : INK)
      if (value) {
        Text(value).fontSize(12).fontColor(active ? this.accentInk : MUTED).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }.height(32).accessibilityText(label + (value ? ' ' + value : '')).onClick(action)
  }

  @Builder
  downloadButton(action: () => void) {
    Row() {
      SaveButton({ icon: SaveIconStyle.LINES, buttonType: ButtonType.Circle })
        .width(36).height(36).padding(9).iconSize(18).iconColor(Color.White).backgroundColor('#77505C69')
        .borderWidth(1).borderColor('#55FFFFFF')
        .onClick((_event: ClickEvent, result: SaveButtonOnClickResult) => {
          if (result === SaveButtonOnClickResult.SUCCESS) action();
          else hilog.info(0x0000, 'QwitterDownload', 'save authorization result=%{public}d', result);
        })
    }.width(36).height(36).margin({ top: 8, right: 8 })
  }

  @Builder
  photo(index: number, ratio: number, inRow: boolean = false, tileWidth: number = 0) {
    Stack({ alignContent: Alignment.TopEnd }) {
      this.preview(this.post.photos[index])
      Button({ type: ButtonType.Normal }) {
        Text('')
      }.width('100%').height('100%').backgroundColor(Color.Transparent)
        .accessibilityText(ui('查看第 {0} 张图片', this.locale, (index + 1).toString()))
        .onClick(() => this.onPhoto(index))
      this.downloadButton(() => this.onDownloadPhoto(index))
    }.width(tileWidth > 0 ? tileWidth : inRow ? undefined : '100%').layoutWeight(inRow ? 1 : 0)
      .aspectRatio(ratio).borderRadius(5).clip(true)
  }

  @Builder
  videoPreview() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Stack({ alignContent: Alignment.Center }) {
        if (this.post.videoPoster) {
          this.preview(this.post.videoPoster, true)
        }
        Column() {
          SymbolGlyph($r('sys.symbol.play_fill')).fontSize(24).fontColor([Color.White])
        }.width(45).height(45).justifyContent(FlexAlign.Center).borderRadius(23).backgroundColor('#64000000')
        Column() {
          Blank()
          Row() {
            if (this.post.views) Text(ui('{0} 次观看', this.locale, this.post.views)).fontSize(12).fontColor(Color.White).maxLines(1)
            Blank()
            if (this.videoDuration ?? this.post.videoDuration) {
              Text(this.videoDuration ?? this.post.videoDuration).fontSize(12).fontColor(Color.White)
            }
          }.width('100%').height(43).alignItems(VerticalAlign.Bottom)
            .padding({ left: 9, right: 9, bottom: 8 })
            .linearGradient({ angle: 180, colors: [[Color.Transparent, 0], ['#A6000000', 1]] })
        }.width('100%').height('100%')
      }.width('100%').height('100%')
      Button({ type: ButtonType.Normal }) {
        Text('')
      }.width('100%').height('100%').backgroundColor(Color.Transparent)
        .accessibilityText(ui('播放视频', this.locale)).onClick(() => this.onPlayVideo())
      this.downloadButton(() => this.onDownloadVideo())
    }.width(this.post.videoRatio < 1 ? '66%' : '100%').aspectRatio(this.post.videoRatio || 1.78)
      .borderRadius(6).clip(true).backgroundColor('#202327').margin({ top: 4 })
  }

  @Builder
  quotePreview(quote: QuotedPost) {
    Stack({ alignContent: Alignment.TopStart }) {
      this.quoteContent(quote)
      Path({ width: 52, height: 24, commands: 'M0 0 L26 24 L52 0 Z' })
        .fill(PAPER).strokeWidth(0).position({ x: 22, y: 0 })
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
    }.width('100%').onClick(() => this.onQuote(quote), POST_TAP_DISTANCE)
  }

  @Builder
  quoteContent(quote: QuotedPost) {
    Column({ space: 8 }) {
      if (quote.name || quote.handle) {
        Row({ space: 7 }) {
          Avatar({ src: quote.avatar, diameter: 29 })
          Column({ space: 1 }) {
            Text(quote.name || '@' + quote.handle).fontSize(13).fontWeight(FontWeight.Bold).fontColor(INK)
              .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Row({ space: 4 }) {
              if (quote.handle) {
                Text('@' + quote.handle).fontSize(12).fontColor(MUTED).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
              }
              Blank()
              if (quote.time) Text(quote.time).fontSize(12).fontColor(MUTED).maxLines(1).flexShrink(0)
            }.width('100%')
          }.layoutWeight(1)
        }.width('100%')
      }
      if (quote.body) {
        PostText({
          body: this.quoteBody(quote),
          links: quote.bodyLinks || [],
          compact: true,
          selectable: true,
          onOpen: () => this.onQuote(quote),
          onBodyLink: (target: string) => this.onBodyLink(target)
        })
      }
      if (quote.photo || quote.poster || quote.video) {
        Stack({ alignContent: Alignment.TopEnd }) {
          Stack({ alignContent: Alignment.Center }) {
            if (quote.poster || quote.photo) {
              this.preview(quote.poster || quote.photo, !!quote.poster)
            }
            if (quote.video) {
              Column() {
                SymbolGlyph($r('sys.symbol.play_fill')).fontSize(21).fontColor([Color.White])
              }.width(40).height(40).justifyContent(FlexAlign.Center).borderRadius(20).backgroundColor('#64000000')
            }
          }.width('100%').height('100%')
          if (quote.photo || (quote.video && quote.path)) {
            this.downloadButton(() => this.onDownloadQuote(quote))
          }
        }.width(quote.ratio > 0 && quote.ratio < 1 ? '66%' : '100%')
          .aspectRatio(quote.ratio || 1.78).borderRadius(5).clip(true).backgroundColor('#202327')
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 14, right: 14, top: 28, bottom: 10 })
      .backgroundColor($r('app.color.quote_paper'))
  }

  @Builder
  articlePreview() {
    Stack({ alignContent: Alignment.BottomStart }) {
      if (this.post.articleCover) {
        this.preview(this.post.articleCover)
      }
      Column() {
        Row() {
          Blank()
          Text(ui('文章', this.locale)).fontSize(12).fontColor(Color.White).padding({ left: 7, right: 7, top: 4, bottom: 4 })
            .borderRadius(4).backgroundColor('#85000000')
        }.width('100%').padding({ left: 10, right: 10, top: 10 })
        Blank()
        Text(this.post.articleTitle || ui('阅读原文', this.locale)).fontSize(17).fontColor(Color.White)
          .fontWeight(FontWeight.Medium).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%').padding({ left: 12, right: 12, top: 27, bottom: 11 })
          .linearGradient({ angle: 180, colors: [[Color.Transparent, 0], ['#BE000000', 1]] })
      }.width('100%').height('100%')
    }.width('100%').aspectRatio(this.post.articleCover ? 1.78 : 3.5).borderRadius(6).clip(true)
      .backgroundColor('#202327').margin({ top: 4 })
      .accessibilityText(ui('阅读文章 {0}', this.locale, this.post.articleTitle)).onClick(() => this.onArticle())
  }

  private galleryTileWidth(): number {
    return this.galleryWidth > 8 ? (this.galleryWidth - 8) / 3 : 110;
  }

  @Builder
  gallery() {
    Stack({ alignContent: Alignment.TopEnd }) {
      if (this.post.photos.length === 1) {
        this.photo(0, this.post.photoRatios[0] || 1.33)
      } else if (this.post.photos.length <= 3) {
        Row({ space: 4 }) {
          ForEach(this.post.photos, (src: string, index: number) => {
            this.photo(index, 1, true)
          }, (src: string, index: number) => src + index.toString())
        }.width('100%')
      } else {
        Scroll() {
          Row({ space: 4 }) {
            ForEach(this.post.photos, (src: string, index: number) => {
              this.photo(index, 1, false, this.galleryTileWidth())
            }, (src: string, index: number) => src + index.toString())
          }
        }.width('100%').height(this.galleryTileWidth()).align(Alignment.Start)
          .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
          .onSizeChange((_old: SizeOptions, size: SizeOptions) => {
            const width = Number(size.width);
            if (width > 8 && width !== this.galleryWidth) this.galleryWidth = width;
          })
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) this.onGalleryTouch(true);
            else if (event.type === TouchType.Up || event.type === TouchType.Cancel) this.onGalleryTouch(false);
          })
          .onDisAppear(() => this.onGalleryTouch(false))
      }
    }.width('100%').margin({ top: 4 })
  }

  build() {
    Column({ space: 5 }) {
      Column({ space: 5 }) {
        if (this.post.context) {
          Text(this.post.context).fontSize(12).fontWeight(FontWeight.Medium).fontColor(MUTED)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Row({ space: 8 }) {
          PostMenuAvatar({ src: this.post.avatar, diameter: 40,
            own: this.post.handle.toLowerCase() === this.ownHandle.toLowerCase(), handle: this.post.handle,
            onProfile: () => this.onProfile(), onAction: (kind: string) => this.onMore(kind) })
          Column({ space: 2 }) {
            Row({ space: 4 }) {
              Text(this.post.name || (this.post.handle ? '@' + this.post.handle : ui('帖子', this.locale)))
                .fontSize(15).fontWeight(FontWeight.Bold).fontColor(INK)
                .flexShrink(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              if (this.post.verified) {
                Image($r('app.media.menu_verified')).width(13).height(13).flexShrink(0)
              }
              if (this.canToggleTranslation() && !this.showOriginal) {
                Blank()
                Text(ui('由 X 翻译', this.locale)).fontSize(12).fontColor(MUTED)
                  .maxLines(1).constraintSize({ maxWidth: '55%' })
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }.width('100%').onClick(() => this.onProfile())
            Row({ space: 4 }) {
              if (this.post.handle) {
                Text('@' + this.post.handle).fontSize(13).fontColor(MUTED).flexShrink(1).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              Blank()
              if (this.post.time) Text(this.post.time).fontSize(12).fontColor(MUTED).flexShrink(0).maxLines(1)
            }.width('100%').onClick(() => this.onPost())
          }.layoutWeight(1)
        }.width('100%').alignItems(VerticalAlign.Center)
        if (this.post.body) {
          PostText({
            body: this.canToggleTranslation() && !this.showOriginal ? this.textPost().translation : this.textPost().body,
            links: this.post.bodyLinks || [],
            selectable: true,
            onBodyLink: (target: string) => this.onBodyLink(target),
            canToggle: this.canToggleTranslation(),
            showOriginal: this.showOriginal,
            onOpen: () => this.onPost(),
            onToggle: () => { this.showOriginal = !this.showOriginal; }
          })
        }
        if (this.post.photos.length) this.gallery()
        if (this.post.video) this.videoPreview()
        if (this.post.articlePath) this.articlePreview()
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 14, right: 14 })
        .onClick(() => this.onPost(), POST_TAP_DISTANCE)
      if (this.post.quotedPost) {
        this.quotePreview(this.post.quotedPost)
      } else if (this.post.quote) {
        Text(ui('查看引用帖子', this.locale)).fontSize(13).fontColor(this.accentInk).padding({ top: 4, bottom: 4 })
          .margin({ left: 14 })
          .onClick(() => this.onQuote(new QuotedPost()), POST_TAP_DISTANCE)
      }
      if (this.separated) {
        Row() {
          Divider().strokeWidth(1).color(RULE).opacity(0.62)
        }.width('100%').padding({ left: 14, right: 14 }).margin({ top: 7 })
          .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      }
      if (!this.selectableText) Row() {
        this.metric($r('app.media.feed_reply'), this.post.replies, ui('回复', this.locale), () => this.onReply())
        this.metric($r('app.media.feed_repost'), this.repostState?.count ?? this.post.reposts,
          ui((this.repostState?.liked ?? this.post.reposted) ? '取消转帖' : '转帖', this.locale),
          () => this.onRepost(), this.repostState?.liked ?? this.post.reposted)
        PostLikeButton({ liked: this.likeState?.liked ?? this.post.liked, count: this.likeState?.count ?? this.post.likes,
          onToggle: () => this.onLike() })
        this.metric($r('app.media.feed_views'), this.post.views, ui('浏览', this.locale), () => this.onPost())
        this.metric($r('app.media.nav_bookmark'), '',
          ui((this.bookmarkState?.liked ?? this.post.bookmarked) ? '取消收藏' : '收藏', this.locale),
          () => this.onBookmark(), this.bookmarkState?.liked ?? this.post.bookmarked)
        this.metric($r('app.media.feed_share'), '', ui('复制帖子链接', this.locale), () => this.onShare())
      }.width('100%').padding({ left: 14, right: 14 }).justifyContent(FlexAlign.SpaceBetween)
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 10, bottom: 3 })
      .backgroundColor(PAPER).border({ width: { bottom: this.separated ? 0 : 1 }, color: RULE })
  }
}
