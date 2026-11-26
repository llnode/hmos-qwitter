import { uiMaterial } from '@kit.ArkUI';
import { accentForeground, DEFAULT_ACCENT, DEFAULT_TAB_MATERIAL, TAB_MATERIAL_STYLES } from '../data/AppearancePreferences';

// One button style for the app: the same immersive system material and accent light effect as the Home tab bar.
// The material is only available on a floating tab bar, so the button draws a one-tab Tabs bar behind its content
// (the same technique as NewPostsButton and ComposeFloatingButton).
// filled: an accent-tinted primary action; its text and icon use accentForeground() for contrast.
// Otherwise the material is clear and the foreground follows the theme (reply_glass_ink), unless tint is given.
@Component
export struct GlassButton {
  @StorageProp('qyxAccent') @Watch('updateMaterial') private accent: string = DEFAULT_ACCENT;
  @StorageProp('qyxTabMaterial') @Watch('updateMaterial') private materialIndex: number = DEFAULT_TAB_MATERIAL;
  @Prop @Watch('updateMaterial') filled: boolean = false;
  @Prop label: string = '';
  @Prop accessibilityLabel: string = '';
  @Prop fixedWidth: number = 0;
  // Stretch to the width the parent gives (for example inside a Row with layoutWeight).
  @Prop fillWidth: boolean = false;
  @Prop buttonHeight: number = 40;
  @Prop fontSize: number = 15;
  @Prop iconSize: number = 18;
  @Prop tint: string = '';
  @Prop enabledState: boolean = true;
  @Prop busy: boolean = false;
  // Either a system symbol (sys.symbol.*) or a media icon; set once when the button is created.
  symbol: Resource | null = null;
  image: Resource | null = null;
  onTap: () => void = () => {};
  @State private measuredWidth: number = 40;
  @State private material: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN, materialColor: Color.Transparent, interactive: true
  });

  aboutToAppear(): void {
    this.measuredWidth = this.fixedWidth > 0 ? this.fixedWidth : this.buttonHeight;
    this.updateMaterial();
  }

  private updateMaterial(): void {
    const style = TAB_MATERIAL_STYLES[this.materialIndex] ?? TAB_MATERIAL_STYLES[DEFAULT_TAB_MATERIAL];
    this.material = new uiMaterial.ImmersiveMaterial({
      style,
      materialColor: this.filled ? this.accent : Color.Transparent,
      interactive: true,
      applyShadow: this.filled,
      lightEffect: { color: this.filled ? Color.White : this.accent }
    });
  }

  private foreground(): ResourceColor {
    if (this.tint) return this.tint;
    return this.filled ? accentForeground(this.accent) : $r('app.color.reply_glass_ink');
  }

  private backdropWidth(): number {
    return this.fixedWidth > 0 ? this.fixedWidth : Math.max(this.buttonHeight, this.measuredWidth);
  }

  private activate(): void {
    if (this.enabledState && !this.busy) this.onTap();
  }

  @Builder
  materialAnchor() {
    Row() {}.height(1).accessibilityLevel('no-hide-descendants')
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Tabs({ barPosition: BarPosition.End }) {
        TabContent() { Column() {}.backgroundColor(Color.Transparent) }
          .backgroundColor(Color.Transparent).tabBar(this.materialAnchor)
      }.width(this.backdropWidth()).height(this.buttonHeight).barHeight(this.buttonHeight)
        .barMode(BarMode.Fixed).barOverlap(true).scrollable(false).fadingEdge(false)
        .backgroundColor(Color.Transparent).barBackgroundColor(Color.Transparent)
        .barFloatingStyle({
          barWidth: { smallBarWidth: this.backdropWidth(), mediumBarWidth: this.backdropWidth(), largeBarWidth: this.backdropWidth() },
          barSideMargin: 0, barBottomMargin: 0, maskHeight: 0, maskColor: Color.Transparent,
          systemMaterial: this.material, adaptToHandedness: false
        }).clip(false).onContentWillChange(() => false).hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no-hide-descendants')
      Button({ type: ButtonType.Capsule }) {
        Row({ space: 6 }) {
          if (this.busy) {
            LoadingProgress().width(this.iconSize + 2).height(this.iconSize + 2).color(this.foreground())
          } else if (this.symbol) {
            SymbolGlyph(this.symbol).fontSize(this.iconSize).fontColor([this.foreground()])
          } else if (this.image) {
            Image(this.image).width(this.iconSize).height(this.iconSize).fillColor(this.foreground()).draggable(false)
          }
          if (this.label) {
            Text(this.label).fontSize(this.fontSize).fontWeight(FontWeight.Medium).fontColor(this.foreground())
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }.justifyContent(FlexAlign.Center)
      }.height(this.buttonHeight).width(this.fixedWidth > 0 ? this.fixedWidth : this.fillWidth ? '100%' : 'auto')
        .constraintSize({ minWidth: this.buttonHeight })
        .padding(this.label ? { left: 16, right: 16 } : 0)
        .backgroundColor(Color.Transparent)
        .accessibilityText(this.accessibilityLabel || this.label)
        .onAreaChange((_old: Area, area: Area) => {
          const width = Number(area.width);
          if (this.fixedWidth <= 0 && Number.isFinite(width) && Math.abs(width - this.measuredWidth) > 0.5) {
            this.measuredWidth = width;
          }
        })
        .onClick(() => this.activate())
    }.width(this.fixedWidth > 0 ? this.fixedWidth : this.fillWidth ? '100%' : 'auto')
      .height(this.buttonHeight).opacity(this.enabledState ? 1 : 0.45)
      .hitTestBehavior(this.enabledState ? HitTestMode.Default : HitTestMode.None)
  }
}
