import { CircleShape, uiMaterial } from '@kit.ArkUI';
import { motion } from '@kit.MultimodalAwarenessKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DEFAULT_ACCENT, DEFAULT_TAB_HEIGHT, DEFAULT_TAB_MATERIAL, TAB_MATERIAL_STYLES } from '../data/AppearancePreferences';

@Component
export struct ComposeFloatingButton {
  @Prop label: string = '';
  @Prop @Watch('updateGripTracking') trackGrip: boolean = false;
  @StorageProp('qyxComposeGripAware') @Watch('updateGripTracking') private gripAware: boolean = false;
  @StorageProp('qyxTabHeight') private diameter: number = DEFAULT_TAB_HEIGHT;
  @StorageProp('qyxTabMaterial') private materialIndex: number = DEFAULT_TAB_MATERIAL;
  @StorageProp('qyxAccent') private accent: string = DEFAULT_ACCENT;
  @StorageProp('qyxAccentInk') private accentInk: string = DEFAULT_ACCENT;
  @State private leftHand: boolean = false;
  private mounted: boolean = false;
  private tracking: boolean = false;
  private holdingChanged: (status: motion.HoldingHandStatus) => void = (status: motion.HoldingHandStatus) => {
    if (!this.mounted || !this.trackGrip || !this.gripAware) return;
    if (status === motion.HoldingHandStatus.LEFT_HAND_HELD) this.leftHand = true;
    else if (status === motion.HoldingHandStatus.RIGHT_HAND_HELD) this.leftHand = false;
  };
  onOpen: () => void = () => {};

  aboutToAppear(): void {
    this.mounted = true;
    this.updateGripTracking();
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.updateGripTracking();
  }

  private updateGripTracking(): void {
    if (!this.gripAware) this.leftHand = false;
    const enabled = this.mounted && this.trackGrip && this.gripAware;
    if (enabled === this.tracking) return;
    try {
      if (enabled) motion.on('holdingHandChanged', this.holdingChanged);
      else motion.off('holdingHandChanged', this.holdingChanged);
      this.tracking = enabled;
      if (enabled) this.seedGripPosition();
    } catch (error) {
      hilog.warn(0x0000, 'QwitterGrip', 'Holding hand subscription failed: %{public}d', (error as BusinessError).code);
    }
  }

  private seedGripPosition(): void {
    try {
      const status = motion.getRecentOperatingHandStatus();
      if (status === motion.OperatingHandStatus.LEFT_HAND_OPERATED) this.leftHand = true;
      else if (status === motion.OperatingHandStatus.RIGHT_HAND_OPERATED) this.leftHand = false;
    } catch (_) {}
  }

  @Builder
  materialAnchor() {
    Row() {}.height(1).accessibilityLevel('no-hide-descendants')
  }

  @Builder
  button() {
    Stack({ alignContent: Alignment.Center }) {
      Tabs({ barPosition: BarPosition.End }) {
        TabContent() {}.backgroundColor(Color.Transparent).tabBar(this.materialAnchor)
      }.width(this.diameter).height(this.diameter).barHeight(this.diameter)
        .barMode(BarMode.Fixed).barOverlap(true).scrollable(false).fadingEdge(false)
        .backgroundColor(Color.Transparent).barBackgroundColor(Color.Transparent)
        .barFloatingStyle({
          barWidth: { smallBarWidth: this.diameter, mediumBarWidth: this.diameter, largeBarWidth: this.diameter },
          barSideMargin: 0, barBottomMargin: 0, maskHeight: 0, maskColor: Color.Transparent,
          systemMaterial: new uiMaterial.ImmersiveMaterial({
            style: TAB_MATERIAL_STYLES[this.materialIndex], materialColor: Color.Transparent,
            interactive: true, applyShadow: false, lightEffect: { color: this.accent }
          }),
          adaptToHandedness: false
        })
        .onContentWillChange(() => false).onTabBarClick(() => this.onOpen())
        .id('qwitter-compose-floating-button').accessibilityRole(AccessibilityRoleType.BUTTON)
        .accessibilityText(this.label)
      Image($r('app.media.compose_plus')).width(this.diameter / 2).height(this.diameter / 2)
        .fillColor(this.accentInk).draggable(false).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
    }.width(this.diameter).height(this.diameter)
      .clipShape(new CircleShape({ width: this.diameter, height: this.diameter }))
  }

  build() {
    Row() {
      this.button()
    }.width('100%').height(this.diameter).padding({ left: 13, right: 13 })
      .justifyContent(this.gripAware && this.leftHand ? FlexAlign.Start : FlexAlign.End)
      .hitTestBehavior(HitTestMode.Transparent)
  }
}
