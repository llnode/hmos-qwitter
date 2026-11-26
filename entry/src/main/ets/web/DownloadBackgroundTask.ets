import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

export class DownloadBackgroundTask {
  private context: common.UIAbilityContext;
  private name: string;
  private notification: number = -1;
  private started: boolean = false;
  private lastPercent: number = -1;
  private lastUpdate: number = 0;

  constructor(context: common.UIAbilityContext, name: string) {
    this.context = context;
    this.name = name;
  }

  async start(): Promise<void> {
    const agent = await wantAgent.getWantAgent({
      wants: [{ bundleName: this.context.abilityInfo.bundleName, abilityName: this.context.abilityInfo.name }],
      actionType: wantAgent.OperationType.START_ABILITY, requestCode: 101,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
    const task = await backgroundTaskManager.startBackgroundRunning(this.context, ['dataTransfer'], agent);
    this.notification = task.notificationId;
    this.started = true;
    hilog.info(0x0000, 'QwitterDownload', 'background started');
    this.update(0);
  }

  update(fraction: number): void {
    const percent = Math.max(0, Math.min(100, Math.floor(fraction * 100)));
    if (!this.started || percent === this.lastPercent || (percent < 100 && Date.now() - this.lastUpdate < 800)) return;
    this.lastPercent = percent;
    this.lastUpdate = Date.now();
    notificationManager.publish({
      id: this.notification, notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
      content: { notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
        systemLiveView: { typeCode: 8, title: 'Qwitter', text: this.name } },
      template: { name: 'downloadTemplate', data: { title: 'Qwitter', fileName: this.name, progressValue: percent } }
    }).catch(() => { hilog.warn(0x0000, 'QwitterDownload', 'progress notification unavailable'); });
  }

  async stop(): Promise<void> {
    if (!this.started) return;
    this.started = false;
    await backgroundTaskManager.stopBackgroundRunning(this.context).catch(() => {});
    hilog.info(0x0000, 'QwitterDownload', 'background stopped');
  }
}
