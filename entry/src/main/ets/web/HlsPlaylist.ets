export interface HlsVariant {
  path: string;
  pixels: number;
  bandwidth: number;
  audioGroup: string;
  audioExpected: boolean;
}

export interface HlsPart {
  path: string;
  range: string;
}

function attribute(line: string, key: string): string {
  return new RegExp('(?:^|,)' + key + '=(?:"([^"]*)"|([^,]*))').exec(line.slice(line.indexOf(':') + 1))
    ?.slice(1).find((value: string) => value !== undefined) || '';
}

export function hlsLines(text: string): string[] {
  const lines = text.replace(/^\uFEFF/, '').split(/\r?\n/).map((line: string) => line.trim());
  if (lines[0] !== '#EXTM3U') throw new Error('Invalid video playlist');
  return lines;
}

export function highestHlsVariant(lines: string[]): HlsVariant | undefined {
  const variants: HlsVariant[] = [];
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index];
    if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
    const path = lines.slice(index + 1).find((next: string) => !!next && !next.startsWith('#')) || '';
    const dimensions = attribute(line, 'RESOLUTION').split('x').map((value: string) => Number(value));
    if (path) variants.push({ path, pixels: (dimensions[0] || 0) * (dimensions[1] || 0),
      bandwidth: Number(attribute(line, 'BANDWIDTH')) || 0, audioGroup: attribute(line, 'AUDIO'),
      audioExpected: !!attribute(line, 'AUDIO') || /mp4a|ac-3|ec-3|opus/i.test(attribute(line, 'CODECS')) });
  }
  return variants.sort((left: HlsVariant, right: HlsVariant) =>
    right.pixels - left.pixels || right.bandwidth - left.bandwidth)[0];
}

export function hlsAudioPath(lines: string[], group: string): string {
  if (!group) return '';
  const tracks = lines.filter((line: string) => line.startsWith('#EXT-X-MEDIA:') &&
    attribute(line, 'TYPE') === 'AUDIO' && attribute(line, 'GROUP-ID') === group && !!attribute(line, 'URI'));
  const selected = tracks.find((line: string) => attribute(line, 'DEFAULT') === 'YES') || tracks[0];
  return selected ? attribute(selected, 'URI') : '';
}

export function hlsParts(lines: string[]): HlsPart[] {
  if (!lines.includes('#EXT-X-ENDLIST')) throw new Error('Video is still live');
  const parts: HlsPart[] = [];
  let range = '';
  let offset = 0;
  let previous = '';
  const part = (path: string, value: string): HlsPart => {
    if (!value) { previous = path; offset = 0; return { path, range: '' }; }
    const match = /^(\d+)(?:@(\d+))?$/.exec(value);
    if (!match) throw new Error('Invalid video byte range');
    const length = Number(match[1]);
    const start = match[2] !== undefined ? Number(match[2]) : path === previous ? offset : NaN;
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(length) || start < 0 || length < 1 ||
      !Number.isSafeInteger(start + length)) throw new Error('Invalid video byte range');
    previous = path;
    offset = start + length;
    return { path, range: 'bytes=' + start.toString() + '-' + (offset - 1).toString() };
  };
  for (const line of lines) {
    if (line.startsWith('#EXT-X-KEY:') && attribute(line, 'METHOD') !== 'NONE') {
      throw new Error('Encrypted video is unsupported');
    }
    if (line.startsWith('#EXT-X-MAP:')) {
      if (parts.length) throw new Error('Video initialization changed');
      const path = attribute(line, 'URI');
      if (!path) throw new Error('Missing video initialization');
      parts.push(part(path, attribute(line, 'BYTERANGE')));
    } else if (line.startsWith('#EXT-X-BYTERANGE:')) {
      range = line.slice(17);
    } else if (line && !line.startsWith('#')) {
      parts.push(part(line, range));
      range = '';
    }
  }
  if (!parts.length) throw new Error('Empty video playlist');
  return parts;
}
