import { bundleManager } from '@kit.AbilityKit';

export class LauncherIconChoice {
  readonly id: string;
  readonly title: string;
  readonly image: Resource;

  constructor(id: string, title: string, image: Resource) {
    this.id = id;
    this.title = title;
    this.image = image;
  }
}

export const LAUNCHER_ICONS: LauncherIconChoice[] = [
  new LauncherIconChoice('', '暖金', $r('app.media.app_icon')),
  new LauncherIconChoice('qwitter_twitter_blue', '经典蓝', $r('app.media.app_icon_twitter_blue')),
  new LauncherIconChoice('qwitter_sky', '晴空', $r('app.media.app_icon_sky')),
  new LauncherIconChoice('qwitter_midnight', '午夜蓝', $r('app.media.app_icon_midnight')),
  new LauncherIconChoice('qwitter_jade', '青玉', $r('app.media.app_icon_jade')),
  new LauncherIconChoice('qwitter_matcha', '抹茶', $r('app.media.app_icon_matcha')),
  new LauncherIconChoice('qwitter_lavender', '紫雾', $r('app.media.app_icon_lavender')),
  new LauncherIconChoice('qwitter_coral', '珊瑚', $r('app.media.app_icon_coral')),
  new LauncherIconChoice('qwitter_amber', '琥珀', $r('app.media.app_icon_amber')),
  new LauncherIconChoice('qwitter_plum', '莓紫', $r('app.media.app_icon_plum')),
  new LauncherIconChoice('qwitter_silver', '银砂', $r('app.media.app_icon_silver')),
  new LauncherIconChoice('qwitter_ink', '曜石', $r('app.media.app_icon_ink')),
  new LauncherIconChoice('qwitter_ivory', '象牙白', $r('app.media.app_icon_ivory'))
];

export const LAUNCHER_ICON_STORAGE_KEY: string = 'qyxLauncherIcon';

export function launcherIconImage(id: string): Resource {
  return LAUNCHER_ICONS.find((icon: LauncherIconChoice) => icon.id === id)?.image || LAUNCHER_ICONS[0].image;
}

export async function readLauncherIcon(): Promise<string> {
  const icons = await bundleManager.getAlternateIcons();
  return icons.find((icon: bundleManager.AlternateIconInfo) => icon.enabled)?.iconName || '';
}
