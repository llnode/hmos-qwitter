import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const STORE: string = 'qyx-media-quality';
export const IMAGE_QUALITIES: string[] = ['orig', 'large', 'medium', 'small'];
export const VIDEO_QUALITIES: string[] = ['', 'p1080', 'p720', 'p480', 'p360'];

export function initializeMediaPreferences(context: common.UIAbilityContext): void {
  let image = IMAGE_QUALITIES[0];
  let video = VIDEO_QUALITIES[0];
  try {
    const store = preferences.getPreferencesSync(context, { name: STORE });
    const savedImage = store.getSync('image', image);
    const savedVideo = store.getSync('video', video);
    if (typeof savedImage === 'string' && IMAGE_QUALITIES.includes(savedImage)) image = savedImage;
    if (typeof savedVideo === 'string' && VIDEO_QUALITIES.includes(savedVideo)) video = savedVideo;
  } catch (_) {}
  AppStorage.setOrCreate('qyxImageQuality', image);
  AppStorage.setOrCreate('qyxVideoQuality', video);
}

export async function saveMediaQuality(context: common.UIAbilityContext, video: boolean, index: number): Promise<void> {
  const value = (video ? VIDEO_QUALITIES : IMAGE_QUALITIES)[index];
  if (value === undefined) return;
  const store = await preferences.getPreferences(context, { name: STORE });
  await store.put(video ? 'video' : 'image', value);
  await store.flush();
  AppStorage.setOrCreate(video ? 'qyxVideoQuality' : 'qyxImageQuality', value);
}
