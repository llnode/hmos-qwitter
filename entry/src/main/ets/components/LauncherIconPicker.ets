import { accentForeground, DEFAULT_ACCENT } from '../data/AppearancePreferences';
import { bundleManager } from '@kit.AbilityKit';
import { LAUNCHER_ICONS, LAUNCHER_ICON_STORAGE_KEY, LauncherIconChoice, readLauncherIcon } from '../data/LauncherIconChoices';
import { ui } from '../i18n/LanguageSettings';
import { INK, MUTED } from './PostCard';

@Component
export struct LauncherIconPicker {
  @StorageProp('qyxAccent') private accent: string = DEFAULT_ACCENT;
  @Prop locale: string = 'zh-Hans';
  @State private selected: string = '';
  @State private ready: boolean = false;
  @State private busy: boolean = false;
  @State private failed: boolean = false;

  aboutToAppear(): void {
    this.readSelection();
  }

  private async readSelection(): Promise<void> {
    this.failed = false;
    try {
      this.selected = await readLauncherIcon();
      AppStorage.setOrCreate(LAUNCHER_ICON_STORAGE_KEY, this.selected);
      this.ready = true;
    } catch (_) {
      this.ready = false;
      this.failed = true;
    }
  }

  private async select(id: string): Promise<void> {
    if (!this.ready || this.busy || this.selected === id) return;
    this.busy = true;
    this.failed = false;
    try {
      await bundleManager.setAlternateIcon(id);
      this.selected = id;
      AppStorage.setOrCreate(LAUNCHER_ICON_STORAGE_KEY, id);
    } catch (_) {
      this.failed = true;
    } finally {
      this.busy = false;
    }
  }

  build() {
    Column({ space: 10 }) {
      Text(ui('应用图标', this.locale)).fontSize(16).fontColor(INK)
      GridRow({ columns: { xs: 3, sm: 4, md: 5, lg: 6 }, gutter: 8 }) {
        ForEach(LAUNCHER_ICONS, (choice: LauncherIconChoice) => {
          GridCol() {
            Button({ type: ButtonType.Normal }) {
              Column({ space: 6 }) {
                Stack({ alignContent: Alignment.BottomEnd }) {
                  Image(choice.image).width(54).height(54).draggable(false).accessibilityLevel('no')
                  if (this.ready && this.selected === choice.id) {
                    SymbolGlyph($r('sys.symbol.checkmark')).fontSize(12).fontColor([accentForeground(this.accent)])
                      .width(19).height(19).backgroundColor(this.accent).borderRadius(10)
                      .accessibilityLevel('no')
                  }
                }.width(54).height(54)
                Text(ui(choice.title, this.locale)).fontSize(12).fontColor(INK).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }.width('100%')
            }.width('100%').constraintSize({ minHeight: 88 }).padding(5)
              .borderRadius(12)
              .backgroundColor(Color.Transparent).enabled(this.ready && !this.busy)
              .accessibilityText(ui(choice.title, this.locale))
              .accessibilitySelected(this.ready && this.selected === choice.id)
              .onClick(() => this.select(choice.id))
          }
        }, (choice: LauncherIconChoice) => choice.id)
      }.width('100%')
      if (this.failed) {
        Text(ui('暂时无法更换应用图标', this.locale)).fontSize(13).fontColor(MUTED)
        if (!this.ready) {
          Button(ui('重试', this.locale)).buttonStyle(ButtonStyleMode.TEXTUAL)
            .onClick(() => this.readSelection())
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
