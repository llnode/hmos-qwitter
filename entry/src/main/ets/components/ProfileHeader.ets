import { DEFAULT_ACCENT } from '../data/AppearancePreferences';
import { ui } from '../i18n/LanguageSettings';
import { LengthMetrics } from '@kit.ArkUI';
import { Profile } from '../web/XPage';
import { Avatar, INK, MUTED, PAPER, RULE, SOFT } from './PostCard';
import { GlassButton } from './GlassButton';

@Component
export struct ProfileHeader {
  @StorageProp('qyxAccentInk') private accentInk: string = DEFAULT_ACCENT;
  @StorageProp('qyxLocale') private locale: string = 'zh-Hans';
  @Prop profile: Profile = new Profile();
  @Prop own: boolean = false;
  @Prop selectedTab: string = '';
  @Prop mediaFilter: number = 0;
  onShare: () => void = () => {};
  onWeb: (title: string, path: string) => void = () => {};
  onWebsite: (url: string) => void = () => {};
  onTab: (tab: string) => void = () => {};
  onMediaFilter: (filter: number) => void = () => {};

  @Builder
  metadata(icon: Resource, label: string, color: ResourceColor, action: () => void) {
    Row({ space: 4 }) {
      Image(icon).width(16).height(16).draggable(false)
      Text(label).fontSize(13).fontColor(color).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }.constraintSize({ maxWidth: '100%' }).onClick(action)
  }

  @Builder
  action(label: string, action: () => void) {
    Row() {
      GlassButton({ label, fillWidth: true, buttonHeight: 36, fontSize: 14, onTap: action })
    }.layoutWeight(1).height(36)
  }

  @Builder
  tab(label: string, tab: string, icon: Resource) {
    Column({ space: 7 }) {
      Row({ space: 5 }) {
        if (tab === 'media') {
          SymbolGlyph(icon).fontSize(18).fontColor([this.selectedTab === tab ? INK : MUTED])
        } else {
          Image(icon).width(18).height(18).draggable(false).opacity(this.selectedTab === tab ? 1 : 0.62)
        }
        Text(label).fontSize(14).fontColor(this.selectedTab === tab ? INK : MUTED)
          .fontWeight(this.selectedTab === tab ? FontWeight.Bold : FontWeight.Medium)
      }.height(25)
      Row().width(48).height(2).borderRadius(1).backgroundColor(this.selectedTab === tab ? INK : Color.Transparent)
    }.height(44).padding({ left: 13, right: 13 }).justifyContent(FlexAlign.End)
      .accessibilityText(label + (this.selectedTab === tab ? ui('，已选择', this.locale) : '')).onClick(() => this.onTab(tab))
  }

  @Builder
  mediaChoice(label: string, filter: number) {
    Button(label).buttonStyle(ButtonStyleMode.TEXTUAL).fontSize(13)
      .fontColor(this.mediaFilter === filter ? this.accentInk : MUTED)
      .accessibilitySelected(this.mediaFilter === filter).onClick(() => this.onMediaFilter(filter))
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.BottomStart }) {
        Column() {
          if (this.profile.banner) {
            Image(this.profile.banner).width('100%').height(146).objectFit(ImageFit.Cover).draggable(false)
          } else {
            Row().width('100%').height(146).backgroundColor(SOFT)
          }
          Row().height(34)
        }.width('100%')
        Stack() {
          Avatar({ src: this.profile.avatar, diameter: 72 })
        }.width(78).height(78).backgroundColor(PAPER).borderRadius(39)
          .margin({ left: 14 }).accessibilityLevel('no')
      }.width('100%')
      Column({ space: 7 }) {
        Column({ space: 2 }) {
          Row({ space: 6 }) {
            Text(this.profile.name || '@' + this.profile.handle).fontSize(23).fontWeight(FontWeight.Bold)
              .fontColor(INK).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
            if (this.profile.verified) {
              Row({ space: 4 }) {
                Image($r('app.media.menu_verified')).width(14).height(14).draggable(false)
                Text(ui('通过认证', this.locale)).fontSize(12).fontWeight(FontWeight.Medium).fontColor(INK)
              }.height(22).padding({ left: 6, right: 6 }).borderRadius(11)
                .border({ width: 1, color: RULE }).flexShrink(0)
            }
          }.width('100%')
          Text('@' + this.profile.handle).fontColor(MUTED).fontSize(14)
        }.width('100%').alignItems(HorizontalAlign.Start)
        if (this.profile.bio) Text(this.profile.bio).fontColor(INK).fontSize(15).lineHeight('20fp')
        Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(12), cross: LengthMetrics.vp(5) } }) {
          if (this.profile.location) {
            this.metadata($r('app.media.profile_location'), this.profile.location, MUTED, () => {})
          }
          if (this.profile.website) {
            this.metadata($r('app.media.profile_link'), this.profile.website, this.accentInk,
              () => this.onWebsite(this.profile.websiteUrl))
          }
          if (this.profile.birthday) {
            this.metadata($r('app.media.profile_birthday'), this.profile.birthday, MUTED, () => {})
          }
          if (this.profile.joined) {
            this.metadata($r('app.media.profile_joined'), this.profile.joined, MUTED, () => {
              if (this.profile.aboutPath) this.onWeb(ui('关于此账号', this.locale), this.profile.aboutPath);
            })
          }
        }.width('100%')
        if (this.profile.following || this.profile.followers) {
          Row({ space: 12 }) {
            if (this.profile.following) {
              Text(this.profile.following).fontColor(INK).fontSize(13)
                .onClick(() => this.onWeb(ui('正在关注', this.locale), '/' + this.profile.handle + '/following'))
            }
            if (this.profile.followers) {
              Text(this.profile.followers).fontColor(INK).fontSize(13)
                .onClick(() => this.onWeb(ui('关注者', this.locale), this.profile.followersPath))
            }
          }
        }
        Row({ space: 8 }) {
          this.action(ui('分享个人资料', this.locale), () => this.onShare())
          if (this.own) {
            this.action(ui('编辑个人资料', this.locale), () => this.onWeb(ui('编辑个人资料', this.locale), this.profile.editPath || '/settings/profile'))
          } else {
            this.action(ui('在 X 查看', this.locale), () => this.onWeb(ui('个人资料', this.locale), '/' + this.profile.handle))
          }
        }.width('100%').margin({ top: 3 })
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 14, right: 14, top: 6, bottom: 4 })
      Scroll() {
        Row() {
          this.tab(ui('帖子', this.locale), '', $r('app.media.menu_lists'))
          if (this.profile.tabs.includes('with_replies')) this.tab(ui('回复', this.locale), 'with_replies', $r('app.media.feed_reply'))
          if (this.profile.tabs.includes('reposts')) this.tab(ui('转帖', this.locale), 'reposts', $r('app.media.feed_repost'))
          if (!this.own && this.profile.tabs.includes('likes')) this.tab(ui('喜欢', this.locale), 'likes', $r('app.media.feed_like'))
          if (this.profile.tabs.includes('media')) this.tab(ui('媒体', this.locale), 'media', $r('sys.symbol.video'))
          if (this.profile.tabs.includes('photos')) this.tab(ui('图片', this.locale), 'photos', $r('app.media.menu_lists'))
          if (this.profile.tabs.includes('videos')) this.tab(ui('视频', this.locale), 'videos', $r('app.media.menu_lists'))
          if (this.profile.tabs.includes('articles')) this.tab(ui('文章', this.locale), 'articles', $r('app.media.menu_lists'))
          if (this.profile.tabs.includes('highlights')) this.tab(ui('精选', this.locale), 'highlights', $r('app.media.menu_lists'))
          if (this.profile.tabs.includes('subs')) this.tab(ui('订阅', this.locale), 'subs', $r('app.media.menu_lists'))
        }
      }.width('100%').align(Alignment.Start).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
        .border({ width: { bottom: 1 }, color: RULE })
      if (this.selectedTab === 'media' && !this.profile.tabs.includes('photos') && !this.profile.tabs.includes('videos')) {
        Row({ space: 4 }) {
          this.mediaChoice(ui('全部', this.locale), 0)
          this.mediaChoice(ui('图片', this.locale), 1)
          this.mediaChoice(ui('视频', this.locale), 2)
        }.width('100%').padding({ left: 9 })
      }
    }.width('100%').backgroundColor(PAPER)
  }
}
