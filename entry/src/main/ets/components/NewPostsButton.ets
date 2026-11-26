import { uiMaterial } from '@kit.ArkUI';
import { DEFAULT_TAB_MATERIAL, TAB_MATERIAL_STYLES } from '../data/AppearancePreferences';
import { INK } from './PostCard';

const HEIGHT: number = 40;

@Component
export struct NewPostsButton {
  @Prop @Watch('measureLabel') label: string = '';
  @StorageProp('qyxTabMaterial') @Watch('updateMaterial') private materialIndex: number = DEFAULT_TAB_MATERIAL;
  @State private measuredWidth: number = 116;
  @State private material: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN, materialColor: Color.Transparent,
    interactive: true, applyShadow: true, lightEffect: { color: Color.White }
  });
  private lastTap: number = 0;
  onOpen: () => void = () => {};

  aboutToAppear(): void {
    this.updateMaterial();
    this.measureLabel();
  }

  private updateMaterial(): void {
    this.material = new uiMaterial.ImmersiveMaterial({
      style: TAB_MATERIAL_STYLES[this.materialIndex], materialColor: Color.Transparent,
      interactive: true, applyShadow: true, lightEffect: { color: Color.White }
    });
  }

  private measureLabel(): void {
    try {
      const context = this.getUIContext();
      const size = context.getMeasureUtils().measureTextSize({ textContent: this.label, fontSize: $r('sys.float.Body_M') });
      this.measuredWidth = Math.max(88, Math.min(260, Math.ceil(context.px2vp(Number(size.width))) + 32));
    } catch (_) {}
  }

  private activate(): void {
    const now = Date.now();
    if (now - this.lastTap < 400) return;
    this.lastTap = now;
    this.onOpen();
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
      }.width(this.measuredWidth).height(HEIGHT).barHeight(HEIGHT).barMode(BarMode.Fixed).barOverlap(true)
        .scrollable(false).fadingEdge(false).backgroundColor(Color.Transparent).barBackgroundColor(Color.Transparent)
        .barFloatingStyle({
          barWidth: { smallBarWidth: this.measuredWidth, mediumBarWidth: this.measuredWidth, largeBarWidth: this.measuredWidth },
          barSideMargin: 0, barBottomMargin: 0, maskHeight: 0, maskColor: Color.Transparent,
          systemMaterial: this.material, adaptToHandedness: false
        }).clip(false).onContentWillChange(() => false).onTabBarClick(() => this.activate())
        .accessibilityLevel('no-hide-descendants')
      Button({ type: ButtonType.Capsule }) {
        Text(this.label).fontSize($r('sys.float.Body_M')).fontColor(INK).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.Center).width('100%')
      }.width(this.measuredWidth).height(HEIGHT).padding({ left: 16, right: 16 })
        .backgroundColor(Color.Transparent).hitTestBehavior(HitTestMode.Block)
        .id('qwitter-new-posts-button').accessibilityText(this.label).onClick(() => this.activate())
    }.width(this.measuredWidth).height(HEIGHT)
      .priorityGesture(TapGesture().onAction(() => this.activate()), GestureMask.IgnoreInternal)
  }
}
