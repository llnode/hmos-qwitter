import { DEFAULT_ACCENT } from '../data/AppearancePreferences';
import { ui } from '../i18n/LanguageSettings';
import { imageAtSize, Post, PostLikeState } from '../web/XPage';
import { PostMenuAvatar, hasPostTranslation, INK, MUTED, PAPER, PostLikeButton, PostText, postWithTranslation, RULE, SOFT } from './PostCard';

export interface InlineReplies {
  id: string;
  replies: Post[];
  expanded: boolean;
  loading: boolean;
  finished: boolean;
  error: boolean;
  limit: number;
}

export class ReplyGroup {
  readonly post: Post;
  readonly replies: Post[] = [];

  constructor(post: Post) {
    this.post = post;
  }
}

class ReplyRow {
  readonly post: Post;
  readonly depth: number;
  readonly control: boolean;

  constructor(post: Post, depth: number, control: boolean = false) {
    this.post = post;
    this.depth = depth;
    this.control = control;
  }
}

@Component
export struct ReplyThread {
  @StorageProp('qyxAccentInk') private accentInk: string = DEFAULT_ACCENT;
  @StorageProp('qyxLocale') private locale: string = 'zh-Hans';
  @StorageProp('qyxImageQuality') private imageQuality: string = 'orig';
  @StorageProp('qyxTranslationLanguage') @Watch('resetOriginals') private targetLanguage: string = '';
  @Prop group: ReplyGroup = new ReplyGroup(new Post());
  @Prop inline: InlineReplies[] = [];
  @Prop translations: Map<string, Post> = new Map();
  @Prop likes: Map<string, PostLikeState> = new Map();
  @State private originals: string[] = [];
  onExpand: (post: Post, force: boolean) => void = () => {};
  onCollapse: (post: Post) => void = () => {};
  onPhotos: (photos: string[], index: number) => void = () => {};
  onVideo: (post: Post) => void = () => {};
  onProfile: (post: Post) => void = () => {};
  onReply: (post: Post) => void = () => {};
  onBodyLink: (target: string) => void = () => {};
  onLike: (post: Post) => void = () => {};
  @Prop ownHandle: string = '';
  onMore: (post: Post, kind: string) => void = () => {};

  private resetOriginals(): void {
    this.originals = [];
  }

  private toggleOriginal(id: string): void {
    this.originals = this.originals.includes(id) ?
      this.originals.filter((current: string) => current !== id) : [...this.originals, id];
  }

  private textPost(post: Post): Post {
    return postWithTranslation(post, this.translations.get(post.id), this.targetLanguage);
  }

  @Builder
  author(post: Post) {
    Row({ space: 5 }) {
      Text(post.name || '@' + post.handle).fontSize(14).fontWeight(FontWeight.Medium)
        .fontColor(INK).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
      if (post.verified) {
        Image($r('app.media.menu_verified')).width(13).height(13).draggable(false).flexShrink(0)
      }
      if (post.name && post.name !== '@' + post.handle) {
        Text('@' + post.handle).fontSize(12).fontColor(MUTED).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
      }
      if (hasPostTranslation(this.textPost(post), this.targetLanguage) && !this.originals.includes(post.id)) {
        Blank()
        Text(ui('由 X 翻译', this.locale)).fontSize(12).fontColor(MUTED)
          .maxLines(1).constraintSize({ maxWidth: '55%' }).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }.width('100%').onClick(() => this.onProfile(post))
  }

  @Builder
  body(post: Post) {
    if (post.body) {
      PostText({
        body: hasPostTranslation(this.textPost(post), this.targetLanguage) && !this.originals.includes(post.id) ?
          this.textPost(post).translation : post.body,
        links: post.bodyLinks || [],
        selectable: true,
        onBodyLink: (target: string) => this.onBodyLink(target),
        canToggle: hasPostTranslation(this.textPost(post), this.targetLanguage),
        showOriginal: this.originals.includes(post.id),
        lineHeight: 19,
        onOpen: () => { if (this.hasReplies(post)) this.onExpand(post, false); },
        onToggle: () => this.toggleOriginal(post.id)
      })
    }
    if (post.photos.length || post.articleCover) {
      Scroll() {
        Row({ space: 4 }) {
          ForEach(this.mediaPhotos(post), (photo: string, index: number) => {
            Image(imageAtSize(photo, this.imageQuality))
              .width(80).height(80).objectFit(ImageFit.Cover).draggable(false).borderRadius(5)
              .backgroundColor(SOFT).accessibilityText(ui('查看回复图片 {0}', this.locale, (index + 1).toString()))
              .onClick(() => this.onPhotos(this.mediaPhotos(post), index))
          }, (photo: string) => photo)
        }
      }.width('100%').align(Alignment.Start).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
    }
    if (post.video) {
      Stack() {
        if (post.videoPoster) {
          Image(imageAtSize(post.videoPoster, 'small'))
            .width('100%').height('100%').objectFit(ImageFit.Cover).draggable(false)
        }
        SymbolGlyph($r('sys.symbol.play_fill')).fontSize(19).fontColor([Color.White])
      }.width(118).height(77).borderRadius(5).clip(true).backgroundColor(SOFT)
        .accessibilityText(ui('播放回复视频', this.locale)).onClick(() => this.onVideo(post))
    }
  }

  @Builder
  metadata(post: Post) {
    Row({ space: 13 }) {
      if (post.time) Text(post.time).fontSize(12).fontColor(MUTED).maxLines(1)
      Blank()
      Row({ space: 4 }) {
        Image($r('app.media.feed_reply')).width(15).height(15).draggable(false).opacity(0.67)
        if (post.replies) Text(post.replies).fontSize(12).fontColor(MUTED)
      }.height(29).constraintSize({ minWidth: 32 }).justifyContent(FlexAlign.Center)
        .accessibilityText(ui('回复', this.locale)).onClick(() => this.onReply(post))
      PostLikeButton({ liked: this.likes.get('like:' + post.id)?.liked ?? post.liked,
        count: this.likes.get('like:' + post.id)?.count ?? post.likes,
        rowHeight: 29, onToggle: () => this.onLike(post) })
    }.width('100%')
  }

  @Builder
  nested(post: Post) {
    Row({ space: 8 }) {
      PostMenuAvatar({ src: post.avatar, diameter: 25,
        own: post.handle.toLowerCase() === this.ownHandle.toLowerCase(), handle: post.handle,
        onProfile: () => this.onProfile(post), onAction: (kind: string) => this.onMore(post, kind) })
      Column({ space: 4 }) {
        this.author(post)
        this.body(post)
        this.metadata(post)
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').alignItems(VerticalAlign.Top)
  }

  private mediaPhotos(post: Post): string[] {
    return post.photos.length ? post.photos : post.articleCover ? [post.articleCover] : [];
  }

  private stateFor(post: Post): InlineReplies | undefined {
    return this.inline.find((item: InlineReplies) => item.id === post.id);
  }

  private knownChildren(post: Post): Post[] {
    const byId = new Map<string, Post>();
    for (const item of this.group.replies) {
      if (item.replyToId === post.id) byId.set(item.id, item);
    }
    for (const state of this.inline) {
      for (const item of state.replies) {
        if (item.replyToId === post.id) byId.set(item.id, item);
      }
    }
    return Array.from(byId.values());
  }

  private hasReplies(post: Post): boolean {
    return (post.replies !== '' && post.replies !== '0') || this.knownChildren(post).length > 0 ||
      (this.stateFor(post)?.replies.length || 0) > 0;
  }

  private hasMore(post: Post, state?: InlineReplies): boolean {
    const direct = this.knownChildren(post).length;
    const limit = state?.limit || 10;
    if (direct > limit) return true;
    if (state?.finished) return false;
    const expected = /^\d[\d,]*$/.test(post.replies) ? Number(post.replies.replace(/,/g, '')) : 0;
    return expected > Math.min(direct, limit) || (!expected && !!post.replies && post.replies !== '0');
  }

  private rows(): ReplyRow[] {
    const result: ReplyRow[] = [];
    const seen = new Set<string>([this.group.post.id]);
    this.appendChildren(this.group.post, 0, result, seen);
    return result;
  }

  private appendChildren(post: Post, depth: number, rows: ReplyRow[], seen: Set<string>): void {
    const state = this.stateFor(post);
    const children = state?.expanded || depth === 0 ? this.knownChildren(post).slice(0, state?.limit || 10) : [];
    for (const child of children) {
      if (seen.has(child.id)) continue;
      seen.add(child.id);
      rows.push(new ReplyRow(child, depth + 1));
      this.appendChildren(child, depth + 1, rows, seen);
    }
    const empty = !this.knownChildren(post).length && (post.replies.trim() === '0' || state?.finished === true);
    if (!empty && (state?.loading || state?.error || this.hasMore(post, state) ||
      (depth > 0 && !state && this.hasReplies(post)))) {
      rows.push(new ReplyRow(post, depth, true));
    }
  }

  @Builder
  replyControl(post: Post) {
    if (this.stateFor(post)?.expanded) {
      Row({ space: 13 }) {
        if (this.stateFor(post)?.loading) {
          LoadingProgress().width(16).height(16).color(this.accentInk)
          Text(ui('正在加载回复…', this.locale)).fontSize(13).fontColor(MUTED)
        } else if (this.stateFor(post)?.error) {
          Text(ui('暂未读到回复，重试', this.locale)).fontSize(13).fontColor(this.accentInk).onClick(() => this.onExpand(post, true))
        } else if (this.hasMore(post, this.stateFor(post))) {
          Text(ui('继续加载回复', this.locale)).fontSize(13).fontColor(this.accentInk).onClick(() => this.onExpand(post, true))
        } else if (!this.stateFor(post)?.replies.length) {
          Text(ui('暂无回复', this.locale)).fontSize(13).fontColor(MUTED)
        }
        Text(ui('收起回复', this.locale)).fontSize(13).fontColor(this.accentInk).onClick(() => this.onCollapse(post))
      }.width('100%').padding({ top: 5, bottom: 4 })
    } else {
      Row({ space: 8 }) {
        Text('·····').fontSize(13).fontColor(MUTED)
        Text(ui('继续加载回复', this.locale))
          .fontSize(13).fontColor(this.accentInk)
      }.padding({ top: 5, bottom: 4 }).onClick(() => this.onExpand(post, true))
    }
  }

  build() {
    Row({ space: 10 }) {
      PostMenuAvatar({ src: this.group.post.avatar, diameter: 38,
        own: this.group.post.handle.toLowerCase() === this.ownHandle.toLowerCase(), handle: this.group.post.handle,
        onProfile: () => this.onProfile(this.group.post),
        onAction: (kind: string) => this.onMore(this.group.post, kind) })
      Column({ space: 5 }) {
        this.author(this.group.post)
        this.body(this.group.post)
        this.metadata(this.group.post)
        ForEach(this.rows(), (row: ReplyRow) => {
          Column() {
            if (row.control) this.replyControl(row.post)
            else this.nested(row.post)
          }.width('100%').alignItems(HorizontalAlign.Start)
            .padding({ left: Math.min(2, Math.max(0, row.depth - (row.control ? 0 : 1))) * 16 })
        }, (row: ReplyRow) => row.post.id + (row.control ? ':control' : ':reply'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').padding({ left: 14, right: 14, top: 12, bottom: 9 })
      .alignItems(VerticalAlign.Top).backgroundColor(PAPER).border({ width: { bottom: 1 }, color: RULE })
  }
}
