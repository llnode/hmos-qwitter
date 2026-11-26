import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { url, util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { remux } from 'libqwitter_media.so';
import { hlsAudioPath, highestHlsVariant, hlsLines, hlsParts } from './HlsPlaylist';
import { matchingHlsAudio } from './VideoQuality';
import { VIDEO_CDN, VideoWebSource } from './VideoWebSource';

const PLAYLIST_LIMIT: number = 2 * 1024 * 1024;
const RANGE_SIZE: number = 4 * 1024 * 1024;

function remote(path: string, base: string): string {
  const address = url.URL.parseURL(path, base);
  if (address.origin !== VIDEO_CDN || address.username || address.password) throw new Error('Invalid video CDN URL');
  return address.href;
}

function ensureActive(active: () => boolean): void {
  if (!active()) throw new Error('Video download cancelled');
}

async function writeChunk(fd: number, chunk: ArrayBuffer): Promise<void> {
  let written = 0;
  while (written < chunk.byteLength) {
    const count = await fileIo.write(fd, written ? chunk.slice(written) : chunk);
    if (count <= 0) throw new Error('Video file write failed');
    written += count;
  }
}

async function playlist(web: VideoWebSource, source: string, group: string): Promise<string[]> {
  const response = await web.request(remote(source, source), false, '', undefined, group, PLAYLIST_LIMIT);
  if (response.status !== 200 || !response.length) throw new Error('Video playlist request failed');
  const bytes = new Uint8Array(response.length);
  let offset = 0;
  for (const chunk of response.chunks) { bytes.set(new Uint8Array(chunk), offset); offset += chunk.byteLength; }
  return hlsLines(util.TextDecoder.create('utf-8').decodeToString(bytes));
}

async function append(web: VideoWebSource, source: string, range: string, fd: number,
  group: string, active: () => boolean): Promise<void> {
  ensureActive(active);
  let accepted = false;
  let expected = 0;
  let received = 0;
  await web.request(source, false, range, {
    onHeaders: (status: number, headers: Record<string, string>) => {
      expected = Number(headers['content-length'] || '0');
      if (range) {
        const requested = /^bytes=(\d+)-(\d+)$/.exec(range);
        const actual = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(headers['content-range'] || '');
        accepted = status === 206 && !!requested && !!actual && requested[1] === actual[1] && requested[2] === actual[2];
        if (requested) expected = Number(requested[2]) - Number(requested[1]) + 1;
      } else { accepted = status === 200; }
    },
    onChunk: async (chunk: ArrayBuffer): Promise<void> => {
      ensureActive(active);
      if (!accepted) throw new Error('Video segment request failed');
      await writeChunk(fd, chunk);
      received += chunk.byteLength;
    }
  }, group);
  if (!accepted || !received || (expected > 0 && received !== expected)) throw new Error('Incomplete video segment');
}

async function track(web: VideoWebSource, source: string, destination: string,
  group: string, active: () => boolean, progress: (fraction: number) => void): Promise<void> {
  const parts = hlsParts(await playlist(web, source, group));
  const file = await fileIo.open(destination, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  try {
    for (let index = 0; index < parts.length; index++) {
      const part = parts[index];
      await append(web, remote(part.path, source), part.range, file.fd, group, active);
      progress((index + 1) / parts.length);
      if (index === 0 || index === parts.length - 1 || index % 20 === 0) {
        hilog.info(0x0000, 'QwitterDownload', 'track segments=%{public}d/%{public}d', index + 1, parts.length);
      }
    }
  } finally { await fileIo.close(file); }
}

async function progressive(web: VideoWebSource, source: string, destination: string,
  group: string, active: () => boolean, progress: (fraction: number) => void): Promise<void> {
  const head = await web.request(source, true, '', undefined, group);
  const total = Number(head.headers['content-length']);
  if (head.status !== 200 || !Number.isSafeInteger(total) || total < 1) throw new Error('Video length unavailable');
  const file = await fileIo.open(destination, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  try {
    for (let offset = 0; offset < total; offset += RANGE_SIZE) {
      const range = 'bytes=' + offset.toString() + '-' + Math.min(total - 1, offset + RANGE_SIZE - 1).toString();
      await append(web, source, range, file.fd, group, active);
      progress(Math.min(total, offset + RANGE_SIZE) / total * 0.98);
    }
  } finally { await fileIo.close(file); }
}

// Streams bytes through the existing ArkWeb transport and remuxes on a native worker, preserving the original codecs.
export async function downloadVideoFile(context: common.UIAbilityContext, source: string, sources: string[],
  web: VideoWebSource, name: string, active: () => boolean, progress: (fraction: number) => void): Promise<string> {
  const group = 'download-' + util.generateRandomUUID();
  const prefix = context.cacheDir + '/' + name + '-' + util.generateRandomUUID();
  const output = prefix + '.mp4';
  const video = prefix + '-video';
  const audio = prefix + '-audio';
  let completed = false;
  try {
    ensureActive(active);
    if (!web.available) throw new Error('Video download channel unavailable');
    const address = remote(source, source);
    if (/\.m3u8(?:\?|$)/i.test(address)) {
      const lines = await playlist(web, address, group);
      const variant = highestHlsVariant(lines);
      const videoSource = variant ? remote(variant.path, address) : address;
      const audioReference = variant ? hlsAudioPath(lines, variant.audioGroup) : '';
      const audioSource = audioReference ? remote(audioReference, address) : matchingHlsAudio(videoSource, sources);
      hilog.info(0x0000, 'QwitterDownload', 'hls pixels=%{public}d separateAudio=%{public}s',
        variant?.pixels || 0, audioSource ? 'yes' : 'no');
      await track(web, videoSource, video, group, active,
        (value: number) => progress(value * (audioSource ? 0.45 : 0.9)));
      if (audioSource) await track(web, audioSource, audio, group, active,
        (value: number) => progress(0.45 + value * 0.45));
      ensureActive(active);
      hilog.info(0x0000, 'QwitterDownload', 'remux begin');
      await remux(video, audioSource ? audio : '', output, !!audioSource || variant?.audioExpected === true);
      hilog.info(0x0000, 'QwitterDownload', 'remux complete');
      progress(0.98);
    } else {
      await progressive(web, address, output, group, active, progress);
    }
    ensureActive(active);
    if (fileIo.statSync(output).size <= 0) throw new Error('Empty downloaded video');
    completed = true;
    return output;
  } finally {
    web.cancelGroup(group);
    for (const path of [video, audio, ...(completed ? [] : [output])]) {
      try { await fileIo.unlink(path); } catch (_) {}
    }
  }
}
