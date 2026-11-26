import { ACCENT_CHOICES, accentForeground, AccentChoice, DEFAULT_ACCENT, saveAccent } from '../data/AppearancePreferences';
import { SettingEdit, SettingOption, SettingRow } from '../web/SettingsPage';
import { INK, MUTED, PAPER, RULE, SOFT } from './PostCard';
import { GlassButton } from './GlassButton';
import { bundleManager, common } from '@kit.AbilityKit';
import { LegalSection, legalSections } from '../data/LegalDocuments';
import { APP_LANGUAGES, AppLanguage } from '../i18n/LocalePolicy';
import { saveLanguage, ui } from '../i18n/LanguageSettings';
import { IMAGE_QUALITIES, saveMediaQuality, VIDEO_QUALITIES } from '../data/MediaPreferences';
import { APPEARANCE_ROUTE, LANGUAGE_ROUTE, MEDIA_ROUTE, PRIVACY_ROUTE, TERMS_ROUTE, DEFAULT_TAB_HEIGHT, DEFAULT_TAB_MATERIAL,
  saveComposeGrip, saveTabLayout, saveTabMaterial, TAB_HEIGHTS } from '../data/AppearancePreferences';
import { LauncherIconPicker } from './LauncherIconPicker';

@Component
export struct SettingsPageView {
  @StorageProp('qyxAccent') private accent: string = DEFAULT_ACCENT;
  @StorageProp('qyxAccentInk') private accentInk: string = DEFAULT_ACCENT;
  @Prop title: string = '';
  @Prop root: boolean = false;
  @Prop localRoute: string = '';
  @Prop handle: string = '';
  @Prop rows: SettingRow[] = [];
  @Prop edits: SettingEdit[] = [];
  @Prop loading: boolean = false;
  @Prop failure: string = '';
  @Prop disabled: boolean = false;
  @Prop syncing: boolean = false;
  @Prop controlRevision: number = 0;
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;
  @State private filter: string = '';
  @State private appVersion: string = '';
  @State private savingLanguage: boolean = false;
  @State private savingQuality: boolean = false;
  @State private savingAppearance: boolean = false;
  @StorageProp('qyxLocale') private locale: string = 'zh-Hans';
  @StorageProp('qyxAppLanguage') private appLanguage: string = 'system';
  @StorageProp('qyxTranslationLanguage') private translationLanguage: string = '';
  @StorageProp('qyxImageQuality') private imageQuality: string = 'orig';
  @StorageProp('qyxVideoQuality') private videoQuality: string = '';
  @StorageProp('qyxTabMaterial') private tabMaterial: number = DEFAULT_TAB_MATERIAL;
  @StorageProp('qyxTabHeight') private tabHeight: number = DEFAULT_TAB_HEIGHT;
  @StorageProp('qyxTabLabels') private tabLabels: boolean = false;
  @StorageProp('qyxComposeGripAware') private gripAware: boolean = false;
  onBack: () => void = () => {};
  onRetry: () => void = () => {};
  onOpen: (title: string, route: string) => void = () => {};
  onEdit: (row: SettingRow, value: string) => void = () => {};
  onAction: (row: SettingRow, value: string, checked: boolean, submit: boolean) => void = () => {};
  onLogout: () => void = () => {};

  aboutToAppear(): void {
    if (!this.root) return;
    try {
      this.appVersion = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).versionName;
    } catch (_) {}
  }

  private icon(path: string): Resource {
    if (/privacy|safety|personalization/.test(path)) return $r('app.media.settings_shield');
    if (/security|password|session/.test(path)) return $r('app.media.settings_lock');
    if (/notifications|mute|block/.test(path)) return $r('app.media.nav_bell');
    if (/subscription|premium|verification/.test(path)) return $r('app.media.menu_premium');
    if (/content|appearance|display/.test(path)) return $r('app.media.settings_look');
    if (/accessibility/.test(path)) return $r('app.media.settings_access');
    if (/language/.test(path)) return $r('app.media.settings_language');
    if (/data|storage/.test(path)) return $r('app.media.settings_storage');
    if (/audience|tagging/.test(path)) return $r('app.media.menu_people');
    if (/account|profile|contact/.test(path)) return $r('app.media.menu_profile');
    return $r('app.media.menu_settings');
  }

  private filteredRows(): SettingRow[] {
    const query = this.filter.trim().toLowerCase();
    return query ? this.rows.filter((row: SettingRow) => row.label.toLowerCase().includes(query)) : this.rows;
  }

  private languageOptions(forPosts: boolean): SelectOption[] {
    const first = forPosts ? ui('关闭翻译', this.locale) : ui('自动（跟随设备语言）', this.locale);
    return [{ value: first },
      ...APP_LANGUAGES.slice(1).map((language: AppLanguage): SelectOption => ({ value: language.name }))];
  }

  private selectedLanguage(forPosts: boolean): number {
    const value = forPosts ? this.translationLanguage : this.appLanguage;
    return Math.max(0, APP_LANGUAGES.findIndex((language: AppLanguage) => language.tag === value));
  }

  private async chooseLanguage(forPosts: boolean, index: number): Promise<void> {
    if (this.savingLanguage || !APP_LANGUAGES[index] || index === this.selectedLanguage(forPosts)) return;
    this.savingLanguage = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await saveLanguage(context, forPosts, forPosts && index === 0 ? '' : APP_LANGUAGES[index].tag);
    } catch (_) {
      this.getUIContext().getPromptAction().showToast({ message: ui('暂时无法保存语言设置', this.locale) });
    } finally {
      this.savingLanguage = false;
    }
  }

  private showLocalSetting(labels: string[]): boolean {
    const query = this.filter.trim().toLowerCase();
    return this.root && (!query || labels.some((label: string) => ui(label, this.locale).toLowerCase().includes(query)));
  }

  @Builder
  sectionLabel(label: string) {
    Text(ui(label, this.locale)).fontSize(13).fontWeight(FontWeight.Medium).fontColor(MUTED)
      .width('100%').padding({ left: 22, right: 18, top: 16, bottom: 4 })
  }

  @Builder
  localLink(label: string, route: string, icon: Resource) {
    Row({ space: 14 }) {
      Image(icon).width(21).height(21).draggable(false)
      Text(ui(label, this.locale)).fontSize(16).fontColor(INK).fontWeight(FontWeight.Medium).layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(15).fontColor([MUTED]).opacity(0.65)
    }.width('100%').constraintSize({ minHeight: 52 }).padding({ left: 22, right: 18 })
      .accessibilityText(ui(label, this.locale)).onClick(() => this.onOpen(ui(label, this.locale), route))
  }

  private qualityOptions(video: boolean): SelectOption[] {
    const labels = video ? ['自动', '1080p', '720p', '480p', '360p'] : ['原图', '高清', '标准', '省流'];
    return labels.map((label: string): SelectOption => ({ value: ui(label, this.locale) }));
  }

  private selectedQuality(video: boolean): number {
    return Math.max(0, video ? VIDEO_QUALITIES.indexOf(this.videoQuality) : IMAGE_QUALITIES.indexOf(this.imageQuality));
  }

  private async chooseQuality(video: boolean, index: number): Promise<void> {
    if (this.savingQuality || index === this.selectedQuality(video)) return;
    this.savingQuality = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await saveMediaQuality(context, video, index);
    } catch (_) {
      this.getUIContext().getPromptAction().showToast({ message: ui('暂时无法保存画质设置', this.locale) });
    } finally {
      this.savingQuality = false;
    }
  }

  private materialOptions(): SelectOption[] {
    return ['超薄', '薄', '标准', '厚', '超厚'].map((label: string): SelectOption => ({ value: ui(label, this.locale) }));
  }

  private async chooseAccent(color: string): Promise<void> {
    if (this.savingAppearance || color === this.accent) return;
    this.savingAppearance = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await saveAccent(context, color);
    } catch (_) {
      this.getUIContext().getPromptAction().showToast({ message: ui('暂时无法保存外观设置', this.locale) });
    } finally {
      this.savingAppearance = false;
    }
  }

  @Builder
  accentPicker() {
    Column({ space: 8 }) {
      Text(ui('主题色', this.locale)).fontSize(16).fontColor(INK)
      GridRow({ columns: 2, gutter: 8 }) {
        ForEach(ACCENT_CHOICES, (choice: AccentChoice) => {
          GridCol() {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 8 }) {
                Stack({ alignContent: Alignment.Center }) {
                  Circle().width(30).height(30).fill(choice.color)
                  if (this.accent === choice.color) {
                    SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([accentForeground(choice.color)])
                  }
                }.width(30).height(30)
                Text(ui(choice.name, this.locale)).fontSize(14).fontColor(INK).layoutWeight(1)
              }.width('100%').padding({ left: 4, right: 4 })
            }.width('100%').constraintSize({ minHeight: 44 }).padding(0).backgroundColor(Color.Transparent)
              .enabled(!this.savingAppearance).accessibilityText(ui(choice.name, this.locale))
              .accessibilitySelected(this.accent === choice.color).onClick(() => this.chooseAccent(choice.color))
          }
        }, (choice: AccentChoice) => choice.color)
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 22, right: 18, top: 10, bottom: 10 })
  }

  private heightOptions(): SelectOption[] {
    return TAB_HEIGHTS.map((height: number): SelectOption => ({ value: height.toString() + ' vp' }));
  }

  private async chooseTabLayout(height: number, labels: boolean): Promise<void> {
    if (this.savingAppearance || (height === this.tabHeight && labels === this.tabLabels)) return;
    this.savingAppearance = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await saveTabLayout(context, height, labels);
    } catch (_) {
      this.getUIContext().getPromptAction().showToast({ message: ui('暂时无法保存外观设置', this.locale) });
    } finally {
      this.savingAppearance = false;
    }
  }

  private async chooseComposeGrip(enabled: boolean): Promise<void> {
    if (this.savingAppearance || enabled === this.gripAware) return;
    this.savingAppearance = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await saveComposeGrip(context, enabled);
    } catch (_) {
      this.getUIContext().getPromptAction().showToast({ message: ui('暂时无法保存外观设置', this.locale) });
    } finally {
      this.savingAppearance = false;
    }
  }

  private async chooseMaterial(index: number): Promise<void> {
    if (this.savingAppearance || index === this.tabMaterial) return;
    this.savingAppearance = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await saveTabMaterial(context, index);
    } catch (_) {
      this.getUIContext().getPromptAction().showToast({ message: ui('暂时无法保存外观设置', this.locale) });
    } finally {
      this.savingAppearance = false;
    }
  }

  @Builder
  qualityRow(label: string, video: boolean) {
    Column({ space: 6 }) {
      Text(ui(label, this.locale)).fontSize(16).fontColor(INK)
      Select(this.qualityOptions(video)).selected(this.selectedQuality(video)).width('100%')
        .value(this.qualityOptions(video)[this.selectedQuality(video)].value)
        .enabled(!this.savingQuality).accessibilityText(ui(label, this.locale))
        .onSelect((index: number) => this.chooseQuality(video, index))
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 22, right: 18, top: 10, bottom: 10 })
  }

  @Builder
  languageRow(label: string, forPosts: boolean) {
    Column({ space: 6 }) {
      Text(ui(label, this.locale)).fontSize(16).fontColor(INK)
      Select(this.languageOptions(forPosts)).selected(this.selectedLanguage(forPosts)).width('100%')
        .value(this.languageOptions(forPosts)[this.selectedLanguage(forPosts)].value)
        .enabled(!this.savingLanguage).accessibilityText(ui(label, this.locale))
        .onSelect((index: number) => this.chooseLanguage(forPosts, index))
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 22, right: 18, top: 10, bottom: 10 })
  }

  private textType(row: SettingRow): InputType {
    if (row.kind === 'password') return InputType.Password;
    if (row.inputType === 'email') return InputType.Email;
    if (row.inputType === 'tel') return InputType.PhoneNumber;
    if (row.inputType === 'number') return InputType.NUMBER_DECIMAL;
    return InputType.Normal;
  }

  private fieldValue(row: SettingRow): string {
    return this.edits.find((edit: SettingEdit) => edit.key === row.key && edit.label === row.label)?.value ?? row.value;
  }

  @Builder
  label(row: SettingRow) {
    Column({ space: 4 }) {
      Text(row.label).fontSize(16).fontColor(INK).fontWeight(FontWeight.Medium)
      if (row.detail) Text(row.detail).fontSize(13).fontColor(MUTED)
    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
  }

  @Builder
  link(row: SettingRow) {
    Row({ space: 14 }) {
      if (row.path.startsWith('https://x.com/settings')) {
        Image(this.icon(row.path)).width(21).height(21).draggable(false)
      }
      this.label(row)
      if (this.root && row.path === 'https://x.com/settings/account' && this.handle) {
        Text('@' + this.handle).fontSize(13).fontColor(MUTED)
      }
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(15).fontColor([MUTED]).opacity(0.65)
    }.width('100%').constraintSize({ minHeight: 52 }).padding({ left: 22, right: 18, top: 10, bottom: 10 })
      .accessibilityText(row.label).onClick(() => this.onOpen(row.label, row.path))
  }

  @Builder
  control(row: SettingRow) {
    if (row.kind === 'toggle' || row.kind === 'choice') {
      Row({ space: 14 }) {
        this.label(row)
        if (row.kind === 'toggle') {
          Toggle({ type: ToggleType.Switch, isOn: row.checked }).selectedColor(this.accent)
            .enabled(!this.disabled && !row.disabled).accessibilityText(row.label)
            .onChange((checked: boolean) => this.onAction(row, '', checked, false))
        } else {
          Radio({ value: row.key, group: this.title + ':' + (row.group || row.key) })
            .checked(row.checked).enabled(!this.disabled && !row.disabled)
            .accessibilityText(row.label).onChange((checked: boolean) => {
              if (checked) this.onAction(row, '', true, false);
            })
        }
      }.width('100%').constraintSize({ minHeight: 52 }).padding({ left: 22, right: 18, top: 10, bottom: 10 })
    } else if (row.kind === 'select') {
      Column({ space: 8 }) {
        Text(row.label).fontSize(15).fontColor(INK)
        Select(row.options.map((option: SettingOption): SelectOption => ({ value: option.label })))
          .selected(row.options.findIndex((option: SettingOption) => option.value === row.value))
          .enabled(!this.disabled && !row.disabled).width('100%')
          .onSelect((index: number) => {
            const option = row.options[index];
            if (option && !option.disabled) this.onAction(row, option.value, false, false);
          })
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 22, right: 18, top: 10, bottom: 10 })
    } else if (row.kind === 'input' || row.kind === 'password') {
      Column({ space: 7 }) {
        Text(row.label).fontSize(15).fontColor(INK)
        if (row.inputType === 'textarea') {
          TextArea({ text: this.fieldValue(row), placeholder: row.label }).constraintSize({ minHeight: 92 })
            .enabled(!this.disabled && !row.disabled).onChange((value: string) => this.onEdit(row, value))
        } else {
          TextInput({ text: this.fieldValue(row), placeholder: row.label }).type(this.textType(row))
            .enabled(!this.disabled && !row.disabled).onChange((value: string) => this.onEdit(row, value))
            .onSubmit(() => this.onAction(row, '', false, true))
        }
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 22, right: 18, top: 8, bottom: 8 })
    } else if (row.kind === 'range') {
      Column({ space: 5 }) {
        Text(row.label).fontSize(15).fontColor(INK)
        Slider({ value: Number(row.value), min: row.min, max: row.max, step: row.step })
          .enabled(!this.disabled && !row.disabled).onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.onAction(row, value.toString(), false, false);
            }
          })
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 22, right: 18, top: 8, bottom: 8 })
    } else if (row.kind === 'button' || row.kind === 'unsupported') {
      GlassButton({ label: row.label, fillWidth: true, buttonHeight: 42,
        enabledState: row.kind !== 'unsupported' && !row.disabled && !this.disabled,
        onTap: () => this.onAction(row, '', false, false) })
        .margin({ top: 6, bottom: 6 })
    } else {
      Text(row.label).width('100%').fontSize(row.kind === 'heading' ? 16 : 14)
        .fontWeight(row.kind === 'heading' ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(row.kind === 'heading' ? INK : MUTED)
        .padding({ left: 22, right: 18, top: 8, bottom: 8 })
    }
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        Text(ui(this.title, this.locale)).fontSize(18).fontWeight(FontWeight.Bold).fontColor(INK).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: '75%' })
        Row() {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(21).fontColor([INK])
          }.width(44).height(44).backgroundColor(Color.Transparent).accessibilityText(ui('返回', this.locale))
            .onClick(() => this.onBack())
          Blank()
        }.width('100%').padding({ left: 5 })
      }.width('100%').height(50).backgroundColor(PAPER)
      if (this.root) {
        Search({ value: this.filter, placeholder: ui('搜索设置', this.locale) }).height(38).width('100%')
          .backgroundColor(SOFT).onChange((value: string) => { this.filter = value; })
          .margin({ top: 4, bottom: 8 }).constraintSize({ maxWidth: '91%' })
      }
      List() {
        if (this.localRoute === PRIVACY_ROUTE || this.localRoute === TERMS_ROUTE) {
          ForEach(legalSections(this.localRoute === PRIVACY_ROUTE, this.locale), (section: LegalSection) => {
            ListItem() {
              Column({ space: 8 }) {
                Text(section.title).fontSize(17).fontWeight(FontWeight.Medium).fontColor(INK)
                Text(section.body).fontSize(15).fontColor(INK)
              }.width('100%').alignItems(HorizontalAlign.Start)
                .padding({ left: 22, right: 22, top: 12, bottom: 12 })
            }
          }, (section: LegalSection) => section.title)
        }
        if (this.localRoute === APPEARANCE_ROUTE) {
          ListItem() {
            Column({ space: 6 }) {
              Text(ui('底部栏沉浸材质', this.locale)).fontSize(16).fontColor(INK)
              Select(this.materialOptions()).selected(this.tabMaterial).width('100%')
                .value(this.materialOptions()[this.tabMaterial].value)
                .enabled(!this.savingAppearance).accessibilityText(ui('底部栏沉浸材质', this.locale))
                .onSelect((index: number) => this.chooseMaterial(index))
            }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 22, right: 18, top: 10, bottom: 10 })
          }
          ListItem() {
            Column({ space: 6 }) {
              Text(ui('底部栏高度', this.locale)).fontSize(16).fontColor(INK)
              Select(this.heightOptions()).selected(TAB_HEIGHTS.indexOf(this.tabHeight))
                .value(this.tabHeight.toString() + ' vp').width('100%').enabled(!this.savingAppearance)
                .accessibilityText(ui('底部栏高度', this.locale))
                .onSelect((index: number) => this.chooseTabLayout(TAB_HEIGHTS[index], this.tabLabels))
            }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 22, right: 18, top: 10, bottom: 10 })
          }
          ListItem() {
            Row({ space: 12 }) {
              Text(ui('显示页面名称', this.locale)).fontSize(16).fontColor(INK).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.tabLabels }).selectedColor(this.accent).enabled(!this.savingAppearance)
                .accessibilityText(ui('显示页面名称', this.locale))
                .onChange((checked: boolean) => this.chooseTabLayout(this.tabHeight, checked))
            }.width('100%').constraintSize({ minHeight: 52 }).padding({ left: 22, right: 18 })
          }
          ListItem() {
            Row({ space: 12 }) {
              Column({ space: 4 }) {
                Text(ui('智感握姿', this.locale)).fontSize(16).fontColor(INK)
                Text(ui('发帖按钮随左手或右手握持换边', this.locale)).fontSize(13).fontColor(MUTED)
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              Toggle({ type: ToggleType.Switch, isOn: this.gripAware }).selectedColor(this.accent)
                .enabled(!this.savingAppearance).accessibilityText(ui('智感握姿', this.locale))
                .onChange((enabled: boolean) => this.chooseComposeGrip(enabled))
            }.width('100%').constraintSize({ minHeight: 60 }).padding({ left: 22, right: 18 })
          }
          ListItem() { this.accentPicker() }
          ListItem() {
            LauncherIconPicker({ locale: this.locale })
              .padding({ left: 22, right: 18, top: 12, bottom: 18 })
          }
        }
        if (this.showLocalSetting(['外观', '应用图标', '主题色', '底部栏沉浸材质', '底部栏高度', '显示页面名称',
          '智感握姿', '语言与翻译', '应用语言', '帖子翻译语言',
          '媒体清晰度', '默认图片清晰度', '默认视频清晰度'])) {
          ListItem() { this.sectionLabel('应用偏好') }
        }
        if (this.showLocalSetting(['外观', '应用图标', '主题色', '底部栏沉浸材质', '底部栏高度', '显示页面名称', '智感握姿'])) {
          ListItem() {
            this.localLink('外观', APPEARANCE_ROUTE, $r('app.media.settings_look'))
          }
        }
        if (this.showLocalSetting(['语言与翻译', '应用语言', '帖子翻译语言'])) {
          ListItem() {
            this.localLink('语言与翻译', LANGUAGE_ROUTE, $r('app.media.settings_language'))
          }
        }
        if (this.showLocalSetting(['媒体清晰度', '默认图片清晰度', '默认视频清晰度'])) {
          ListItem() {
            this.localLink('媒体清晰度', MEDIA_ROUTE, $r('app.media.settings_storage'))
          }
        }
        if (this.localRoute === LANGUAGE_ROUTE) {
          ListItem() { this.languageRow('应用语言', false) }
          ListItem() { this.languageRow('帖子翻译语言', true) }
        }
        if (this.localRoute === MEDIA_ROUTE) {
          ListItem() { this.qualityRow('默认图片清晰度', false) }
          ListItem() { this.qualityRow('默认视频清晰度', true) }
        }
        if (this.root && (this.filteredRows().length || this.loading || this.failure)) {
          ListItem() { this.sectionLabel('X 账号设置') }
        }
        ForEach(this.filteredRows(), (row: SettingRow) => {
          ListItem() {
            if (row.kind === 'link') {
              this.link(row)
            } else if (row.kind === 'button' || row.kind === 'unsupported') {
              Column() { this.control(row) }.width('100%').padding({ left: 22, right: 18 })
            } else {
              this.control(row)
            }
          }
        }, (row: SettingRow) => row.key + ':' + row.label + ':' + row.path +
          (['toggle', 'choice', 'select', 'range'].includes(row.kind) ?
            ':' + row.checked + ':' + row.value + ':' + this.controlRevision : ''))
        if (this.loading || this.syncing) {
          ListItem() {
            Row({ space: 8 }) {
              LoadingProgress().width(22).height(22).color(this.accentInk)
              Text(this.syncing ? ui('正在与 X 同步…', this.locale) : ui('正在读取 X 设置…', this.locale)).fontSize(14).fontColor(MUTED)
            }.width('100%').height(66).justifyContent(FlexAlign.Center)
          }
        }
        if (this.failure) {
          ListItem() {
            Column({ space: 9 }) {
              Text(this.failure).fontSize(14).fontColor(MUTED).textAlign(TextAlign.Center)
              Button(ui('重试', this.locale)).buttonStyle(ButtonStyleMode.TEXTUAL).fontColor(this.accentInk).onClick(() => this.onRetry())
            }.width('100%').padding({ top: 22, bottom: 22, left: 20, right: 20 })
          }
        }
        if (this.showLocalSetting(['关于 Qwitter', '版本号', this.appVersion, '隐私协议', '使用条款'])) {
          ListItem() { this.sectionLabel('关于 Qwitter') }
        }
        if (this.showLocalSetting(['关于 Qwitter', '隐私协议'])) {
          ListItem() { this.localLink('隐私协议', PRIVACY_ROUTE, $r('app.media.settings_shield')) }
        }
        if (this.showLocalSetting(['关于 Qwitter', '使用条款'])) {
          ListItem() { this.localLink('使用条款', TERMS_ROUTE, $r('app.media.menu_help')) }
        }
        if (this.appVersion && this.showLocalSetting(['关于 Qwitter', '版本号', this.appVersion])) {
          ListItem() {
            Row({ space: 12 }) {
              Text(ui('版本号', this.locale)).fontSize(16).fontColor(INK).layoutWeight(1)
              Text(this.appVersion).fontSize(14).fontColor(MUTED)
            }.width('100%').constraintSize({ minHeight: 52 }).padding({ left: 22, right: 18 })
          }
        }
        if (this.root && (!this.filter.trim() || ui('退出登录', this.locale).includes(this.filter.trim()))) {
          ListItem() {
            Column() {
              Divider().color(RULE)
              Button(ui('退出登录', this.locale)).buttonStyle(ButtonStyleMode.TEXTUAL).fontColor('#C54A50')
                .width('100%').height(51).onClick(() => this.onLogout())
            }.width('100%').padding({ left: 22, right: 18, top: 7 })
          }
        }
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off).contentEndOffset(this.bottomInset + 14)
    }.width('100%').height('100%').padding({ top: this.topInset }).backgroundColor(PAPER)
  }
}
