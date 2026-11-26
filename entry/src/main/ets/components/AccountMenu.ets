import { ui } from '../i18n/LanguageSettings';
import { KnownAccount, SidebarEntry } from '../data/ReaderStore';
import { Avatar, INK, MUTED, PAPER, RULE } from './PostCard';
import { Profile } from '../web/XPage';

@Component
export struct AccountMenu {
  @StorageProp('qyxLocale') private locale: string = 'zh-Hans';
  @Prop handle: string = '';
  @Prop persistent: boolean = false;
  @Prop activeTab: number = 0;
  onTab: (index: number) => void = () => {};
  @Prop name: string = '';
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;
  @Prop avatar: string = '';
  @Prop profile: Profile | null = null;
  @Prop entries: SidebarEntry[] = [];
  onProfile: () => void = () => {};
  onSettings: () => void = () => {};
  onWeb: (title: string, path: string) => void = () => {};
  // Accounts used in Qwitter on this device, most recent first; the handle being switched to, if any.
  @Prop accounts: KnownAccount[] = [];
  @Prop switching: string = '';
  onSwitchAccount: (handle: string) => void = () => {};
  onAddAccount: () => void = () => {};
  @State private accountsOpen: boolean = false;

  private otherAccounts(): KnownAccount[] {
    const current = this.handle.toLowerCase();
    return this.accounts.filter((account: KnownAccount) => account.handle !== current);
  }

  @Builder
  accountRow(account: KnownAccount) {
    Row({ space: 12 }) {
      Avatar({ src: account.avatar, diameter: 34 })
      Column({ space: 2 }) {
        if (account.name) {
          Text(account.name).fontSize(15).fontWeight(FontWeight.Bold).fontColor(INK)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Text('@' + account.handle).fontSize(13).fontColor(MUTED).maxLines(1)
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (this.switching === account.handle) {
        LoadingProgress().width(20).height(20)
      } else if (account.handle === this.handle.toLowerCase()) {
        SymbolGlyph($r('sys.symbol.checkmark')).fontSize(18).fontColor([INK])
      }
    }.width('100%').height(52)
      .accessibilityText(ui('切换到', this.locale) + ' @' + account.handle)
      .onClick(() => {
        if (!this.switching) this.onSwitchAccount(account.handle);
      })
  }

  private open(item: SidebarEntry): void {
    if (item.path === 'profile') this.onProfile();
    else if (item.path === 'settings') this.onSettings();
    else this.onWeb(ui(item.label, this.locale), item.path);
  }

  @Builder
  entry(label: string, icon: Resource, action: () => void, primary: boolean = true) {
    Row({ space: this.persistent ? 14 : 20 }) {
      Image(icon).width(primary ? 23 : 18).height(primary ? 23 : 18).draggable(false)
      Text(label).fontSize(primary && !this.persistent ? 20 : 15).fontColor(INK)
        .fontWeight(primary ? FontWeight.Bold : FontWeight.Medium)
    }.width('100%').height(primary ? 48 : 41).accessibilityText(label).onClick(action)
  }

  @Builder
  primaryTab(label: string, icon: Resource, selected: Resource, index: number) {
    Row({ space: 14 }) {
      Image(this.activeTab === index ? selected : icon).width(22).height(22).fillColor(INK).draggable(false)
      Text(ui(label, this.locale)).fontSize(17).fontColor(INK)
        .fontWeight(this.activeTab === index ? FontWeight.Bold : FontWeight.Medium)
    }.width('100%').height(47).accessibilitySelected(this.activeTab === index)
      .accessibilityText(ui(label, this.locale)).onClick(() => this.onTab(index))
  }

  build() {
    Scroll() {
      Column() {
        if (this.persistent) {
          this.primaryTab('首页', $r('app.media.nav_home'), $r('app.media.nav_home_filled'), 0)
          this.primaryTab('搜索', $r('app.media.nav_search'), $r('app.media.nav_search_filled'), 1)
          this.primaryTab('通知', $r('app.media.nav_bell'), $r('app.media.nav_bell_filled'), 2)
          this.primaryTab('聊天', $r('app.media.nav_message'), $r('app.media.nav_message_filled'), 3)
          Divider().color(RULE).margin({ top: 10, bottom: 16 })
        }
        Row({ space: 10 }) {
          Avatar({ src: this.profile?.avatar || this.avatar, diameter: 42 }).onClick(() => this.onProfile())
          Blank()
          ForEach(this.otherAccounts().slice(0, 2), (account: KnownAccount) => {
            Stack() {
              Avatar({ src: account.avatar, diameter: 30 })
              if (this.switching === account.handle) LoadingProgress().width(30).height(30)
            }.accessibilityText(ui('切换到', this.locale) + ' @' + account.handle)
              .onClick(() => {
                if (!this.switching) this.onSwitchAccount(account.handle);
              })
          }, (account: KnownAccount) => account.handle + account.avatar)
          Image($r('app.media.menu_account')).width(24).height(24)
            .accessibilityText(ui('账号', this.locale)).onClick(() => { this.accountsOpen = !this.accountsOpen; })
        }.width('100%').margin({ bottom: 7 })
        if (this.accountsOpen) {
          Column() {
            ForEach(this.accounts, (account: KnownAccount) => {
              this.accountRow(account)
            }, (account: KnownAccount) => account.handle + account.name + account.avatar)
            this.entry(ui('添加账号', this.locale), $r('app.media.menu_account'), () => {
              this.accountsOpen = false;
              this.onAddAccount();
            }, false)
            this.entry(ui('管理账号', this.locale), $r('app.media.menu_account'), () => {
              this.accountsOpen = false;
              this.onWeb(ui('管理账号', this.locale), '/account/switch');
            }, false)
            Divider().color(RULE).margin({ top: 6, bottom: 10 })
          }.width('100%')
        }
        if (this.profile?.name || this.name) {
          Text(this.profile?.name || this.name).fontSize(18).fontWeight(FontWeight.Bold).fontColor(INK)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (this.handle) Text('@' + this.handle).fontSize(14).fontColor(MUTED).margin({ top: 4 })
        Row({ space: 10 }) {
          if (this.profile?.following) {
            Text(this.profile.following).fontSize(13).fontColor(INK)
              .onClick(() => this.onWeb(ui('正在关注', this.locale), '/' + this.handle + '/following'))
          }
          if (this.profile?.followers) {
            Text(this.profile.followers).fontSize(13).fontColor(INK)
              .onClick(() => this.onWeb(ui('关注者', this.locale), '/' + this.handle + '/followers'))
          }
        }.width('100%').margin({ top: 9, bottom: 13 })
        ForEach(this.entries.filter((item: SidebarEntry) => item.primary), (item: SidebarEntry) => {
          this.entry(ui(item.label, this.locale), item.icon, () => this.open(item))
        }, (item: SidebarEntry) => item.path)
        Divider().color(RULE).margin({ top: 15, bottom: 15 })
        ForEach(this.entries.filter((item: SidebarEntry) => !item.primary), (item: SidebarEntry) => {
          this.entry(ui(item.label, this.locale), item.icon, () => this.open(item), false)
        }, (item: SidebarEntry) => item.path)
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: this.persistent ? 18 : 26, right: this.persistent ? 16 : 25, top: this.topInset + 19, bottom: this.bottomInset + 26 })
    }.height('100%').align(Alignment.TopStart).backgroundColor(PAPER).scrollBar(BarState.Off)
  }
}
