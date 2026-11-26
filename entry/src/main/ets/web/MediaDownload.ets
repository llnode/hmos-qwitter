import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { http } from '@kit.NetworkKit';
import { imageAtSize, videoDimensions } from './XPage';
import { isAudioVideoSource, isStandaloneVideoPlaylist } from './VideoQuality';
import { VideoWebSource } from './VideoWebSource';
import { downloadVideoFile } from './HlsDownload';
import { hilog } from '@kit.PerformanceAnalysisKit';

export class MediaQuality {
  readonly title: string;
  readonly url: string;
  readonly extension: string;
  readonly size: number;

  constructor(title: string, url: string, extension: string, size: number = 0) {
    this.title = title;
    this.url = url;
    this.extension = extension;
    this.size = size;
  }
}

export interface MediaSaveTarget {
  uri: string;
  extension: string;
  file: fileIo.File;
}

// Called immediately by a successful system SaveButton, before any network operation.
export async function createMediaSaveTarget(context: common.UIAbilityContext, name: string,
  photo: string): Promise<MediaSaveTarget> {
  const format = photo ? /[?&]format=(jpg|jpeg|png|webp|gif|avif)(?:&|$)/i.exec(photo)?.[1] ||
    /\.(jpg|jpeg|png|webp|gif|avif)(?:[?:]|$)/i.exec(photo)?.[1] || 'jpg' : 'mp4';
  const extension = format.toLowerCase() === 'jpeg' ? 'jpg' : format.toLowerCase();
  const helper = photoAccessHelper.getPhotoAccessHelper(context);
  const uri = await helper.createAsset(photo ? photoAccessHelper.PhotoType.IMAGE : photoAccessHelper.PhotoType.VIDEO,
    extension, { title: name });
  if (!uri) throw new Error('Save authorization unavailable');
  try {
    const file = await fileIo.open(uri, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    hilog.info(0x0000, 'QwitterDownload', 'destination authorized and opened');
    return { uri, extension, file };
  } catch (error) {
    fileIo.unlink(uri).catch(() => {});
    throw new Error((error as Error).message || 'Cannot open saved asset');
  }
}

export async function savePhoto(context: common.UIAbilityContext, src: string, name: string, target: MediaSaveTarget): Promise<boolean> {
  if (!/^https:\/\/pbs\.twimg\.com\/(?:media|card_img|ext_tw_video_thumb|amplify_video_thumb|tweet_video_thumb)\//.test(src)) {
    throw new Error('Invalid X photo URL');
  }
  const client = http.createHttp();
  let temp = '';
  try {
    for (const url of new Set([imageAtSize(src), imageAtSize(src, 'large'), src])) {
      const response = await client.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        maxLimit: 32 * 1024 * 1024,
        connectTimeout: 8000,
        readTimeout: 15000
      }).catch(() => null);
      if (response?.responseCode !== 200 || !(response.result instanceof ArrayBuffer) ||
        !response.result.byteLength) continue;
      const headers = response.header as Record<string, string>;
      const contentType = headers['content-type'] || headers['Content-Type'] || '';
      const format = /^image\/(jpeg|png|webp|gif|avif)\b/i.exec(contentType)?.[1]?.toLowerCase();
      if (!format) continue;
      const extension = format === 'jpeg' ? 'jpg' : format;
      temp = context.cacheDir + '/' + name + '-' + Date.now().toString() + '.' + extension;
      const file = await fileIo.open(temp, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        await fileIo.write(file.fd, response.result);
      } finally {
        await fileIo.close(file);
      }
      if (extension !== target.extension) throw new Error('Downloaded image format changed');
      await fileIo.copyFile(temp, target.file.fd);
      return true;
    }
    throw new Error('X photo download failed');
  } finally {
    client.destroy();
    if (temp) await fileIo.unlink(temp).catch(() => {});
  }
}

// MP4 files for a video, largest first (X lists them in page order, which is often smallest first).
export function videoQualities(sources: string[]): MediaQuality[] {
  const labels = new Set<string>();
  const qualities: MediaQuality[] = [];
  for (const src of sources) {
    if (!/\.mp4(?:\?|$)/.test(src) || isAudioVideoSource(src)) continue;
    const dimensions = videoDimensions(src);
    const label = dimensions ? dimensions[1] + ' × ' + dimensions[2] : '网页提供的画质';
    if (labels.has(label)) continue;
    labels.add(label);
    const pixels = dimensions ? Number(dimensions[1]) * Number(dimensions[2]) : 0;
    qualities.push(new MediaQuality(label, src, 'mp4', pixels));
  }
  return qualities.sort((a: MediaQuality, b: MediaQuality) => b.size - a.size);
}

export async function saveVideo(context: common.UIAbilityContext, sources: string[], web: VideoWebSource,
  name: string, active: () => boolean, target: MediaSaveTarget,
  progress: (fraction: number) => void): Promise<boolean> {
  const master = sources.find((source: string) => /\.m3u8(?:\?|$)/i.test(source) &&
    !isAudioVideoSource(source) && !isStandaloneVideoPlaylist(source));
  const source = master || videoQualities(sources)[0]?.url || sources.find((source: string) =>
    /\.m3u8(?:\?|$)/i.test(source) && !isAudioVideoSource(source));
  if (!source) throw new Error('Video source unavailable');
  const temp = await downloadVideoFile(context, source, sources, web, name, active, progress);
  try {
    if (!active()) throw new Error('Video download cancelled');
    hilog.info(0x0000, 'QwitterDownload', 'gallery write begin');
    await fileIo.copyFile(temp, target.file.fd);
    progress(1);
    return true;
  } finally {
    try { await fileIo.unlink(temp); } catch (_) {}
  }
}
