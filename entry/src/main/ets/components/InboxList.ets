import { DEFAULT_ACCENT } from '../data/AppearancePreferences';
import { InboxRow } from '../web/InboxPage';
import { ui } from '../i18n/LanguageSettings';
import { Avatar, hasPostTranslation, INK, MUTED, PAPER, postWithTranslation, RULE, SOFT } from './PostCard';
import { imageAtSize, Post } from '../web/XPage';
import { GlassButton } from './GlassButton';

// Lazy data source so the list only builds rows near the screen (a conversation can hold 160 messages).
class InboxRowSource implements IDataSource {
  private rows: InboxRow[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): InboxRow {
    return this.rows[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) this.listeners.push(listener);
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) this.listeners.splice(index, 1);
  }

  replace(rows: InboxRow[]): void {
    this.rows = rows;
    this.listeners.forEach((listener: DataChangeListener) => listener.onDataReloaded());
  }
}

function rowKey(row: InboxRow): string {
  return row.id + '\u0001' + row.time + '\u0001' + row.unread.toString() + '\u0001' + row.outgoing.toString() + '\u0001' +
    row.kind + '\u0001' + row.title + '\u0001' + row.avatar + '\u0001' + row.text;
}

@Component
export struct InboxList {
  @StorageProp('qyxAccent') private accent: string = DEFAULT_ACCENT;
  @StorageProp('qyxAccentInk') private accentInk: string = DEFAULT_ACCENT;
  @StorageProp('qyxLocale') private locale: string = 'zh-Hans';
  @StorageProp('qyxImageQuality') private imageQuality: string = 'orig';
  @StorageProp('qyxTranslationLanguage') private targetLanguage: string = '';
  @Prop @Watch('rowsChanged') rows: InboxRow[] = [];
  private source: InboxRowSource = new InboxRowSource();
  @Prop relatedPosts: Map<string, Post> = new Map();
  @Prop translations: Map<string, Post> = new Map();
  @Prop messages: boolean = false;
  @Prop ownAvatar: string = '';
  @Prop peerAvatar: string = '';
  @Prop loading: boolean = false;
  @Prop locked: boolean = false;
  @Prop canOpenWeb: boolean = false;
  @Prop error: string = '';
  @Prop bottomInset: number = 0;
  scroller: Scroller = new Scroller();
  onOpen: (row: InboxRow) => void = () => {};
  onRetry: () => void = () => {};
  onUnlock: () => void = () => {};
  onNearEnd: () => void = () => {};
  onNearStart: () => void = () => {};
  onVisibleEnd: (end: number) => void = () => {};
  private scrollingToOlder: boolean = false;

  aboutToAppear(): void {
    this.source.replace(this.rows);
  }

  private rowsChanged(): void {
    this.source.replace(this.rows);
  }

  private relatedPost(row: InboxRow): Post | undefined {
    return row.kind.startsWith('notification') ? this.relatedPosts.get(row.path.split('/').pop() || '') : undefined;
  }

  private relatedText(post: Post): string {
    const view = postWithTranslation(post, this.translations.get(post.id), this.targetLanguage);
    return hasPostTranslation(view, this.targetLanguage) ? view.translation : post.body || post.articleTitle;
  }

  @Builder
  relatedPreview(post: Post, showText: boolean = true) {
    Column({ space: 5 }) {
      if (showText && (post.name || post.handle)) {
        Row({ space: 6 }) {
          Text(post.name || '@' + post.handle).fontSize(13).fontWeight(FontWeight.Medium).fontColor(INK).maxLines(1)
          if (post.name && post.handle) Text('@' + post.handle).fontSize(12).fontColor(MUTED).maxLines(1)
        }.width('100%')
      }
      if (showText && this.relatedText(post)) {
        Text(this.relatedText(post)).fontSize(14).fontColor(INK).lineHeight('19fp').width('100%')
          .maxLines(4).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      if (post.videoPoster || post.photos.length || post.articleCover) {
        Stack() {
          Image(imageAtSize(post.videoPoster || post.photos[0] || post.articleCover, this.imageQuality))
            .width('100%').height('100%').objectFit(ImageFit.Cover).draggable(false)
          if (post.video) {
            SymbolGlyph($r('sys.symbol.play_fill')).fontSize(20).fontColor([Color.White])
          }
        }.width('100%').aspectRatio(1.78).borderRadius(6).clip(true)
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(9).borderRadius(12).border({ width: 1, color: RULE })
  }

  private notificationIcon(row: InboxRow): Resource {
    if (row.kind === 'notification-post') return $r('app.media.feed_reply');
    if (/liked|喜欢|喜歡/i.test(row.title)) return $r('app.media.feed_liked');
    if (/reposted|转帖|轉帖|转发|轉發/i.test(row.title)) return $r('app.media.feed_repost');
    return $r('app.media.nav_bell');
  }

  @Builder
  notificationEntry(row: InboxRow) {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Avatar({ src: row.avatar, diameter: 42 })
        Image(this.notificationIcon(row)).width(18).height(18).padding(2)
          .fillColor(this.accentInk).backgroundColor(PAPER).borderRadius(9).draggable(false)
      }.width(44).height(44)
      Column({ space: 5 }) {
        Row({ space: 8 }) {
          Text(row.title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(INK)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          if (row.time) Text(row.time).fontSize(12).fontColor(MUTED)
        }.width('100%').alignItems(VerticalAlign.Top)
        if (row.text) {
          Text(row.text).fontSize(14).lineHeight('19fp').fontColor(row.kind === 'notification-post' ? INK : MUTED)
            .width('100%').maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (this.relatedPost(row) && (row.kind !== 'notification-post' || !row.text ||
          this.relatedPost(row)!.photos.length || this.relatedPost(row)!.video)) {
          this.relatedPreview(this.relatedPost(row)!, row.kind !== 'notification-post' || !row.text)
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').alignItems(VerticalAlign.Top).padding({ left: 14, right: 14, top: 11, bottom: 11 })
      .border({ width: { bottom: 1 }, color: RULE }).onClick(() => this.onOpen(row), 6)
  }

  @Builder
  entry(row: InboxRow) {
    Row({ space: 10 }) {
      if (row.avatar || row.kind === 'chat') {
        Avatar({ src: row.avatar, diameter: 42 })
      } else {
        Image($r('app.media.nav_bell')).width(24).height(24).fillColor(this.accentInk).margin({ left: 8, right: 10 })
      }
      Column({ space: 4 }) {
        Row({ space: 5 }) {
          Text(row.title).fontSize(16).fontWeight(row.unread ? FontWeight.Bold : FontWeight.Medium)
            .fontColor(INK).layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (row.time) Text(row.time).fontSize(12).fontColor(MUTED)
        }.width('100%')
        if (this.relatedPost(row)) {
          this.relatedPreview(this.relatedPost(row)!)
        } else if (row.text) Text(row.text).fontSize(14).fontColor(MUTED).width('100%')
          .maxLines(this.messages ? 40 : 3).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (row.unread) Circle().width(7).height(7).fill(this.accent)
    }.width('100%').padding({ left: 16, right: 16, top: 13, bottom: 13 }).constraintSize({ minHeight: 60 })
      .border({ width: { bottom: 1 }, color: RULE }).onClick(() => this.onOpen(row), 6)
  }

  @Builder
  bubble(row: InboxRow) {
    Row({ space: 8 }) {
      if (row.outgoing) Blank()
      if (!row.outgoing) {
        Row() {
          Avatar({ src: row.avatar || this.peerAvatar, diameter: 32 })
        }.id('chat-avatar-incoming-' + row.id)
      }
      Column({ space: 3 }) {
        if (row.title || row.outgoing) {
          Text(row.outgoing ? ui('我', this.locale) : row.title).fontSize(12).fontColor(MUTED)
        }
        Text(row.text).fontSize(15).fontColor(INK)
        if (row.time) Text(row.time).fontSize(11).fontColor(MUTED)
      }.alignItems(HorizontalAlign.Start).constraintSize({ maxWidth: '76%' })
        .padding({ left: 12, right: 12, top: 8, bottom: 8 }).borderRadius(16)
        .backgroundColor(row.outgoing ? $r('app.color.chat_outgoing') : SOFT)
        .opacity(row.kind === 'pending' ? 0.6 : 1)
      if (row.outgoing) {
        Row() {
          Avatar({ src: this.ownAvatar || row.avatar, diameter: 32 })
        }.id('chat-avatar-outgoing-' + row.id)
      } else {
        Blank()
      }
    }.width('100%').direction(Direction.Ltr).alignItems(VerticalAlign.Bottom)
      .padding({ left: 14, right: 14, top: 4, bottom: 4 })
  }

  build() {
    List({ scroller: this.scroller }) {
      LazyForEach(this.source, (row: InboxRow) => {
        ListItem() {
          if (this.messages) this.bubble(row)
          else if (row.kind.startsWith('notification')) this.notificationEntry(row)
          else this.entry(row)
        }
      }, (row: InboxRow) => rowKey(row))
      if (this.locked || this.error || (!this.rows.length && this.loading)) {
        ListItem() {
          Column({ space: 10 }) {
            if (this.locked) {
              GlassButton({ label: ui('在 X 打开', this.locale), buttonHeight: 36, fontSize: 14, onTap: () => this.onUnlock() })
            } else if (this.error) {
              Text(this.error).fontSize(14).fontColor(MUTED)
              GlassButton({ label: ui('重试', this.locale), filled: true, buttonHeight: 36, fontSize: 14, onTap: () => this.onRetry() })
              if (this.canOpenWeb) {
                GlassButton({ label: ui('在 X 打开', this.locale), buttonHeight: 36, fontSize: 14, onTap: () => this.onUnlock() })
              }
            } else {
              LoadingProgress().width(22).height(22).color(this.accentInk)
              if (this.canOpenWeb) {
                GlassButton({ label: ui('在 X 打开', this.locale), buttonHeight: 36, fontSize: 14, onTap: () => this.onUnlock() })
              }
            }
          }.width('100%').padding(22)
        }
      } else if (!this.rows.length) {
        ListItem() {
          Text(ui('暂无内容', this.locale)).fontSize(14).fontColor(MUTED)
            .width('100%').textAlign(TextAlign.Center).padding(22)
        }
      }
    }.width('100%').layoutWeight(1).cachedCount(6).contentEndOffset(this.bottomInset).backgroundColor(PAPER)
      .onWillScroll((offset: number, _state: ScrollState, source: ScrollSource) => {
        if (this.messages && offset < 0 && (source === ScrollSource.DRAG || source === ScrollSource.OTHER_USER_INPUT)) {
          this.scrollingToOlder = true;
        }
      })
      .onScrollIndex((start: number, end: number) => {
        if (!this.rows.length) return;
        this.onVisibleEnd(end);
        if (this.messages) {
          if (this.scrollingToOlder && start <= 4) this.onNearStart();
        } else if (end >= this.rows.length - 5) {
          this.onNearEnd();
        }
      })
  }
}
