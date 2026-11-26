@Component
export struct ZoomablePhoto {
  @Prop @Watch('resetForSource') source: string = '';
  onFlip: (delta: number) => void = () => {};
  onDismiss: (direction: number) => void = () => {};

  @State private zoomScale: number = 1;
  @State private offsetX: number = 0;
  @State private offsetY: number = 0;
  private viewportWidth: number = 0;
  private viewportHeight: number = 0;
  private imageRatio: number = 0;
  private startScale: number = 1;
  private startX: number = 0;
  private startY: number = 0;
  private pinchX: number = 0;
  private pinchY: number = 0;
  private panX: number = 0;
  private panY: number = 0;
  private panStartedZoomed: boolean = false;

  private resetForSource(): void {
    this.imageRatio = 0;
    this.setTransform(1, 0, 0);
  }

  private setTransform(scale: number, x: number, y: number): void {
    const fitWidth = this.imageRatio > 0 ? Math.min(this.viewportWidth, this.viewportHeight * this.imageRatio) : this.viewportWidth;
    const fitHeight = this.imageRatio > 0 ? Math.min(this.viewportHeight, this.viewportWidth / this.imageRatio) : this.viewportHeight;
    const limitX = Math.max(0, (fitWidth * scale - this.viewportWidth) / 2);
    const limitY = Math.max(0, (fitHeight * scale - this.viewportHeight) / 2);
    this.zoomScale = scale;
    this.offsetX = Math.max(-limitX, Math.min(limitX, x));
    this.offsetY = Math.max(-limitY, Math.min(limitY, y));
  }

  build() {
    Stack() {
      Image(this.source)
        .width('100%').height('100%').objectFit(ImageFit.Contain).draggable(false)
        .onComplete((event) => {
          if (event && event.width > 0 && event.height > 0) {
            this.imageRatio = event.width / event.height;
            this.setTransform(this.zoomScale, this.offsetX, this.offsetY);
          }
        })
        .scale({ x: this.zoomScale, y: this.zoomScale })
        .translate({ x: this.offsetX, y: this.offsetY })
    }.width('100%').height('100%').clip(true)
      .onSizeChange((_old: SizeOptions, size: SizeOptions) => {
        this.viewportWidth = Number(size.width);
        this.viewportHeight = Number(size.height);
        this.setTransform(this.zoomScale, this.offsetX, this.offsetY);
      })
      .parallelGesture(
        GestureGroup(GestureMode.Exclusive,
          TapGesture({ count: 2 }).onAction(() => {
            this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
              this.setTransform(this.zoomScale > 1 ? 1 : 2, 0, 0);
            });
          }),
          PinchGesture({ fingers: 2 }).onActionStart((event: GestureEvent) => {
            this.startScale = this.zoomScale;
            this.startX = this.offsetX;
            this.startY = this.offsetY;
            this.pinchX = event.pinchCenterX - this.viewportWidth / 2;
            this.pinchY = event.pinchCenterY - this.viewportHeight / 2;
          }).onActionUpdate((event: GestureEvent) => {
            const nextScale = Math.max(1, Math.min(4, this.startScale * event.scale));
            const factor = nextScale / this.startScale;
            this.setTransform(nextScale,
              event.pinchCenterX - this.viewportWidth / 2 - (this.pinchX - this.startX) * factor,
              event.pinchCenterY - this.viewportHeight / 2 - (this.pinchY - this.startY) * factor);
          }),
          PanGesture({ fingers: 1 }).onActionStart(() => {
            this.startX = this.offsetX;
            this.startY = this.offsetY;
            this.panStartedZoomed = this.zoomScale > 1;
            this.panX = 0;
            this.panY = 0;
          }).onActionUpdate((event: GestureEvent) => {
            this.panX = event.offsetX;
            this.panY = event.offsetY;
            if (this.panStartedZoomed) {
              this.setTransform(this.zoomScale, this.startX + event.offsetX, this.startY + event.offsetY);
            }
          }).onActionEnd(() => {
            if (this.panStartedZoomed || this.zoomScale > 1) return;
            if (Math.abs(this.panX) >= 34 && Math.abs(this.panX) > Math.abs(this.panY) * 1.25) {
              this.onFlip(this.panX < 0 ? 1 : -1);
            } else if (Math.abs(this.panY) >= 48 && Math.abs(this.panY) > Math.abs(this.panX) * 1.25) {
              this.onDismiss(this.panY < 0 ? -1 : 1);
            }
          })
        )
      )
  }
}
