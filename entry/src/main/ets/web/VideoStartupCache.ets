import { url, util } from '@kit.ArkTS';
import { hlsResolutions, preferredVideoResolution, selectHlsResolution } from './VideoQuality';
import { VIDEO_CDN, VideoResponse, VideoWebSource } from './VideoWebSource';

const STARTUP_LIMIT: number = 2 * 1024 * 1024;
const MP4_PREFIX: string = 'bytes=0-1048575';
const STARTUP_TTL: number = 120000;

interface StartupEntry {
  request: Promise<VideoResponse>;
  expires: number;
  response?: VideoResponse;
}

export class VideoStartupCache {
  private readonly entries: Map<string, StartupEntry> = new Map();
  private readonly web: VideoWebSource;
  private group: string = util.generateRandomUUID();

  constructor(web: VideoWebSource) {
    this.web = web;
  }

  clear(): void {
    this.web.cancelGroup(this.group);
    this.group = util.generateRandomUUID();
    this.entries.clear();
  }

  get(source: string): Promise<VideoResponse> | undefined {
    const entry = this.entries.get(source);
    if (entry && entry.expires > Date.now()) return entry.request;
    this.entries.delete(source);
    return undefined;
  }

  ready(source: string): VideoResponse | undefined {
    const entry = this.entries.get(source);
    return entry && entry.expires > Date.now() ? entry.response : undefined;
  }

  prefix(source: string): VideoResponse | undefined {
    return this.ready(source + '\n' + MP4_PREFIX);
  }

  private fetch(source: string, range: string = ''): Promise<VideoResponse> {
    const key = range ? source + '\n' + range : source;
    const cached = this.get(key);
    if (cached) return cached;
    if (this.entries.size >= 12) {
      const oldest = Array.from(this.entries.keys())[0];
      this.entries.delete(oldest);
    }
    const request = this.web.request(source, false, range, undefined, this.group, STARTUP_LIMIT).then((response) => {
      if (response.status !== (range ? 206 : 200) || !response.length) throw new Error('Video startup data unavailable');
      return response;
    });
    const entry: StartupEntry = { request, expires: Date.now() + STARTUP_TTL };
    this.entries.set(key, entry);
    request.then((response: VideoResponse) => { entry.response = response; }).catch(() => {
      if (this.entries.get(key)?.request === request) this.entries.delete(key);
    });
    return request;
  }

  private remote(reference: string, base: string): string {
    const absolute = url.URL.parseURL(reference, base);
    return absolute.origin === VIDEO_CDN ? absolute.href : '';
  }

  private async playlist(source: string): Promise<string[]> {
    const response = await this.fetch(source);
    const bytes = new Uint8Array(response.length);
    let offset = 0;
    for (const chunk of response.chunks) {
      bytes.set(new Uint8Array(chunk), offset);
      offset += chunk.byteLength;
    }
    const content = util.TextDecoder.create('utf-8').decodeToString(bytes);
    if (!content.startsWith('#EXTM3U')) throw new Error('Video playlist unavailable');
    return content.split(/\r?\n/).map((line: string) => line.trim());
  }

  private async firstMedia(source: string, lines: string[], verify: boolean): Promise<void> {
    if (lines.some((line: string) => line.includes('BYTERANGE'))) return;
    const init = lines.find((line: string) => line.startsWith('#EXT-X-MAP:'))?.match(/URI="([^"]+)"/)?.[1] || '';
    const segments = lines.filter((line: string) => !!line && !line.startsWith('#')).slice(0, verify ? 1 : 2);
    const requests: Promise<VideoResponse>[] = [];
    for (const reference of [init, ...segments]) {
      const address = reference ? this.remote(reference, source) : '';
      if (!address) continue;
      const request = this.fetch(address);
      requests.push(verify ? request.catch(async () => {
        const response = await this.web.request(address, true, '', undefined, this.group);
        if (response.status !== 200 && response.status !== 206) throw new Error('Video segment unavailable');
        return response;
      }) : request);
    }
    await Promise.all(requests);
  }

  async warm(source: string, resolution: string = ''): Promise<void> {
    if (!this.web.available) return;
    const group = this.group;
    if (!/\.m3u8(?:\?|$)/i.test(source)) {
      await this.fetch(source, MP4_PREFIX);
      return;
    }
    const playlist = await this.playlist(source);
    const selected = resolution.startsWith('p') ? preferredVideoResolution(hlsResolutions(playlist), resolution) : resolution;
    const lines = selectHlsResolution(playlist, selected);
    if (group !== this.group) return;
    const variant = lines.findIndex((line: string) => line.startsWith('#EXT-X-STREAM-INF:'));
    if (variant < 0) {
      if (selected) throw new Error('Requested video resolution is unavailable');
      await this.firstMedia(source, lines, false);
      return;
    }
    const video = this.remote(lines.slice(variant + 1).find((line: string) => !!line && !line.startsWith('#')) || '', source);
    const audioGroup = lines[variant].match(/[:,]AUDIO="([^"]+)"/)?.[1];
    const audioTracks = lines.filter((line: string) => line.startsWith('#EXT-X-MEDIA:') &&
      /(?:[:,])TYPE=AUDIO(?:,|$)/.test(line) &&
      !!audioGroup && line.includes('GROUP-ID="' + audioGroup + '"'));
    const audio = (audioTracks.find((line: string) => line.includes('DEFAULT=YES')) || audioTracks[0])?.match(/URI="([^"]+)"/)?.[1];
    if (!video || video === source) throw new Error('Video variant unavailable');
    const verify = !!selected && !resolution.startsWith('p');
    const tracks: Promise<void>[] = [this.warmTrack(video, group, verify)];
    const audioAddress = audio ? this.remote(audio, source) : '';
    if (audioAddress) tracks.push(this.warmTrack(audioAddress, group, verify));
    await Promise.all(tracks);
  }

  private async warmTrack(source: string, group: string, verify: boolean): Promise<void> {
    const lines = await this.playlist(source);
    if (group === this.group) await this.firstMedia(source, lines, verify);
  }
}
