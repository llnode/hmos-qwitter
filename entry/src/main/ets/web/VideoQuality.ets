export class VideoQuality {
  readonly resolution: string;
  readonly source: string;
  readonly hls: boolean;

  constructor(resolution: string, source: string, hls: boolean) {
    this.resolution = resolution;
    this.source = source;
    this.hls = hls;
  }

  get label(): string {
    return shortEdge(this.resolution).toString() + 'p';
  }
}

function shortEdge(resolution: string): number {
  const parts = resolution.split('x').map((part: string) => Number(part));
  return Math.min(parts[0], parts[1]) || 0;
}

export function preferredVideoResolution(resolutions: string[], preference: string): string {
  const limit = Number(preference.slice(1));
  const ordered = resolutions.filter((resolution: string) => shortEdge(resolution) > 0)
    .sort((a: string, b: string) => shortEdge(b) - shortEdge(a));
  return ordered.find((resolution: string) => shortEdge(resolution) <= limit) || ordered[ordered.length - 1] || '';
}

export function videoSourceOrder(sources: string[], previous: string, preference: string): string[] {
  const variants = sources.filter((source: string) => isStandaloneVideoPlaylist(source) && !isAudioVideoSource(source))
    .sort((a: string, b: string) => Number(!!matchingHlsAudio(b, sources)) - Number(!!matchingHlsAudio(a, sources)));
  const masters = sources.filter((source: string) => /\.m3u8(?:\?|$)/i.test(source) && !isAudioVideoSource(source) &&
    !isStandaloneVideoPlaylist(source));
  const files = sources.filter((source: string) => /\.mp4(?:\?|$)/i.test(source) && !isAudioVideoSource(source));
  const orderedMasters = masters.includes(previous) ?
    [previous, ...masters.filter((source: string) => source !== previous)] : masters;
  if (!preference) {
    const orderedFiles = files.includes(previous) ?
      [previous, ...files.filter((source: string) => source !== previous)] : files;
    return [...orderedMasters, ...orderedFiles, ...variants];
  }
  const limit = Number(preference.slice(1));
  const edge = (source: string): number => shortEdge(/\/(\d{2,5}x\d{2,5})\//.exec(source)?.[1] || '');
  const withinLimit = files.filter((source: string) => edge(source) > 0 && edge(source) <= limit)
    .sort((a: string, b: string) => edge(b) - edge(a));
  const aboveLimit = files.filter((source: string) => edge(source) > limit)
    .sort((a: string, b: string) => edge(a) - edge(b));
  return Array.from(new Set([...orderedMasters, ...withinLimit, ...aboveLimit, ...files, ...variants]));
}

export function isAudioVideoSource(source: string): boolean {
  return /\/(?:aud|audio|mp4a)\//i.test(source.split('?')[0]);
}

export function matchingHlsAudio(video: string, sources: string[]): string {
  if (!isStandaloneVideoPlaylist(video)) return '';
  const asset = /^https:\/\/video\.twimg\.com\/(?:ext_tw_video|amplify_video)\/\d+\/[^?]*?\/pl\//i.exec(video)?.[0];
  if (!asset) return '';
  return sources.find((source: string) => source.startsWith(asset) && isAudioVideoSource(source) &&
    /\.m3u8(?:\?|$)/i.test(source)) || '';
}

export function isStandaloneVideoPlaylist(source: string): boolean {
  return /\/pl\/(?:(?:avc1|hvc1|hev1|av01|vp09)\/|\d{2,5}x\d{2,5}\/)[^?]+\.m3u8(?:\?|$)/i.test(source);
}

export function hlsResolutions(lines: string[]): string[] {
  const audioVariants = lines.filter((line: string) => hlsVariantHasAudio(line));
  const resolutions: string[] = [];
  for (const line of audioVariants.length ? audioVariants : lines) {
    const resolution = hlsResolution(line);
    if (resolution && !resolutions.includes(resolution)) resolutions.push(resolution);
  }
  return resolutions;
}

function hlsResolution(line: string): string {
  if (!line.startsWith('#EXT-X-STREAM-INF:')) return '';
  return /(?:^|,)RESOLUTION=(\d{2,5}x\d{2,5})(?:,|$)/.exec(line.slice(18))?.[1] || '';
}

function hlsVariantHasAudio(line: string): boolean {
  return line.startsWith('#EXT-X-STREAM-INF:') &&
    (/[:,]AUDIO="[^"]+"/.test(line) || /[:,]CODECS="[^"]*(?:mp4a|ac-3|ec-3|opus)[^"]*"/i.test(line));
}

export function selectHlsResolution(lines: string[], resolution: string): string[] {
  const useAudio = lines.some((line: string) => hlsVariantHasAudio(line) &&
    (!resolution || hlsResolution(line) === resolution));
  if (!resolution && !useAudio) return lines;
  const output: string[] = [];
  let omitVariantUri = false;
  for (const line of lines) {
    if (line.startsWith('#EXT-X-STREAM-INF:')) {
      omitVariantUri = (!!resolution && hlsResolution(line) !== resolution) || (useAudio && !hlsVariantHasAudio(line));
      if (!omitVariantUri) output.push(line);
    } else if (line && !line.startsWith('#') && omitVariantUri) {
      omitVariantUri = false;
    } else {
      output.push(line);
    }
  }
  return output;
}
