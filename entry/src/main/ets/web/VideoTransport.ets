import { url, util } from '@kit.ArkTS';
import { socket } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { VIDEO_CDN, VideoResponse, VideoWebSource } from './VideoWebSource';
import { hlsResolutions, matchingHlsAudio, preferredVideoResolution, selectHlsResolution } from './VideoQuality';
import { VideoStartupCache } from './VideoStartupCache';

export class VideoTransport {
  private readonly token: string = util.generateRandomUUID();
  private readonly server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
  private readonly connections: Set<socket.TCPSocketConnection> = new Set();
  private readonly pendingPlaylists: Map<string, Promise<VideoResponse>> = new Map();
  private base: string = '';
  private readonly pairedPlaylists: Map<string, string> = new Map();
  private closed: boolean = false;
  private reportedStartupHit: boolean = false;
  private readonly webSource: VideoWebSource;
  private readonly onResolutions: (remote: string, resolutions: string[]) => void;
  private readonly startup?: VideoStartupCache;

  constructor(webSource: VideoWebSource, onResolutions: (remote: string, resolutions: string[]) => void = () => {},
    startup?: VideoStartupCache) {
    this.webSource = webSource;
    this.onResolutions = onResolutions;
    this.startup = startup;
  }

  async open(): Promise<void> {
    this.server.on('connect', (connection: socket.TCPSocketConnection) => this.receive(connection));
    await this.server.listen({ address: '127.0.0.1', port: 0, family: 1 });
    if (this.closed) {
      await this.server.close();
      return;
    }
    const address = await this.server.getLocalAddress();
    if (!address.port) throw new Error('Local video port unavailable');
    this.base = 'http://127.0.0.1:' + address.port.toString() + '/' + this.token;
  }

  source(remote: string, resolution: string = ''): string {
    if (!this.base || !remote.startsWith(VIDEO_CDN + '/')) return '';
    const variant = /^(?:\d{2,5}x\d{2,5}|p\d{3,4})$/.test(resolution) ? '/q/' + resolution : '';
    return this.base + variant + remote.slice(VIDEO_CDN.length);
  }

  pairedSource(video: string, audio: string): string {
    if (!matchingHlsAudio(video, [audio])) return '';
    const videoUrl = this.source(video);
    const audioUrl = this.source(audio);
    if (!videoUrl || !audioUrl) return '';
    const path = '/paired/' + (this.pairedPlaylists.size + 1).toString() + '.m3u8';
    this.pairedPlaylists.set(path, [
      '#EXTM3U',
      '#EXT-X-VERSION:6',
      '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Audio",DEFAULT=YES,AUTOSELECT=YES,URI="' + audioUrl + '"',
      '#EXT-X-STREAM-INF:BANDWIDTH=8000000,AUDIO="audio"',
      videoUrl,
      ''
    ].join('\n'));
    return this.base + path;
  }

  prefetchPlaylist(remote: string): void {
    if (!/\.m3u8(?:\?|$)/i.test(remote) || this.pendingPlaylists.has(remote)) return;
    const request = this.readPlaylist(remote);
    this.pendingPlaylists.set(remote, request);
    request.catch(() => {});
  }

  private async readPlaylist(remote: string): Promise<VideoResponse> {
    const ready = this.startup?.ready(remote);
    if (ready) return ready;
    const pending = this.startup?.get(remote);
    if (pending) {
      const cached = await Promise.race([
        pending.catch((): VideoResponse | undefined => undefined),
        new Promise<undefined>((resolve) => { setTimeout(() => resolve(undefined), 650); })
      ]);
      if (cached) return cached;
    }
    return this.webSource.request(remote, false, '', undefined, this.token);
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.webSource.cancelGroup(this.token);
    this.pendingPlaylists.clear();
    this.pairedPlaylists.clear();
    for (const connection of this.connections) connection.close().catch(() => {});
    this.connections.clear();
    this.server.close().catch(() => {});
  }

  private receive(connection: socket.TCPSocketConnection): void {
    if (this.closed || this.connections.size >= 12) {
      connection.close().catch(() => {});
      return;
    }
    this.connections.add(connection);
    let incoming = '';
    const timeout = setTimeout(() => connection.close().catch(() => {}), 5000);
    connection.on('close', () => {
      clearTimeout(timeout);
      this.connections.delete(connection);
    });
    connection.on('message', (event: socket.SocketMessageInfo) => {
      incoming += util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(event.message));
      if (incoming.length > 8192 || incoming.includes('\r\n\r\n')) {
        clearTimeout(timeout);
        connection.off('message');
        this.serve(connection, incoming).finally(() => connection.close().catch(() => {})).catch(() => {});
      }
    });
  }

  private header(headers: Record<string, string>, name: string): string {
    const key = Object.keys(headers).find((candidate: string) => candidate.toLowerCase() === name);
    const value = key ? headers[key] : '';
    return typeof value === 'string' && !/[\r\n]/.test(value) ? value : '';
  }

  private responseHeader(code: number, contentType: string, length: string, range: string): string {
    const status = code === 206 ? '206 Partial Content' : code === 416 ? '416 Range Not Satisfiable' : '200 OK';
    return 'HTTP/1.1 ' + status + '\r\nContent-Type: ' + contentType +
      (length ? '\r\nContent-Length: ' + length : '\r\nTransfer-Encoding: chunked') +
      '\r\nAccept-Ranges: bytes\r\nConnection: close\r\n' +
      (range ? 'Content-Range: ' + range + '\r\n' : '') + '\r\n';
  }

  private async forwardPrefix(connection: socket.TCPSocketConnection, upstream: string, head: boolean,
    range: string): Promise<boolean> {
    const cached = this.startup?.prefix(upstream);
    if (!cached || this.closed) return false;
    const cachedRange = /^bytes 0-(\d+)\/(\d+)$/.exec(this.header(cached.headers, 'content-range'));
    const request = range ? /^bytes=(\d+)-(\d*)$/.exec(range) : null;
    if (!cachedRange || (range && !request)) return false;
    const total = Number(cachedRange[2]);
    const prefixLength = Number(cachedRange[1]) + 1;
    const start = request ? Number(request[1]) : 0;
    const end = request?.[2] ? Math.min(Number(request[2]), total - 1) : total - 1;
    if (!Number.isSafeInteger(total) || prefixLength !== cached.length || prefixLength > total ||
      start > end || end >= total) return false;

    let sentHeaders = false;
    let sending = Promise.resolve();
    const enqueue = (data: string | ArrayBuffer): void => {
      sending = sending.then(async () => {
        if (!this.closed) await connection.send({ data });
      });
      sending.catch(() => {});
    };
    const headers = (): void => {
      sentHeaders = true;
      enqueue(this.responseHeader(range ? 206 : 200,
        this.header(cached.headers, 'content-type') || 'video/mp4', (end - start + 1).toString(),
        range ? 'bytes ' + start.toString() + '-' + end.toString() + '/' + total.toString() : ''));
      if (head) return;
      let position = 0;
      for (const chunk of cached.chunks) {
        const begin = Math.max(0, start - position);
        const finish = Math.min(chunk.byteLength, end + 1 - position);
        if (begin < finish) enqueue(chunk.slice(begin, finish));
        position += chunk.byteLength;
      }
      if (!this.reportedStartupHit) {
        this.reportedStartupHit = true;
        hilog.info(0x0000, 'QyxVideo', 'used preloaded MP4 range');
      }
    };
    if (head || end < prefixLength) {
      headers();
      await sending;
      return true;
    }
    let position = Math.max(prefixLength, start);
    let retry = 0;
    while (!this.closed && this.connections.has(connection) && position <= end) {
      const last = Math.min(end, position + 8 * 1024 * 1024 - 1);
      const remainder = position.toString() + '-' + last.toString();
      let matched = false;
      try {
        await this.webSource.request(upstream, false, 'bytes=' + remainder, {
          onHeaders: (code: number, values: Record<string, string>) => {
            if (code !== 206 || this.header(values, 'content-range') !== 'bytes ' + remainder + '/' + total.toString()) return;
            const etag = this.header(cached.headers, 'etag');
            const nextEtag = this.header(values, 'etag');
            if (etag && nextEtag && etag !== nextEtag) return;
            matched = true;
            if (!sentHeaders) headers();
          },
          onChunk: (chunk: ArrayBuffer) => {
            if (!matched || position + chunk.byteLength > last + 1) return;
            position += chunk.byteLength;
            enqueue(chunk);
            return sending;
          }
        }, this.token);
      } catch (_) {}
      if (!matched && !sentHeaders) return false;
      await sending;
      if (position > last) retry = 0;
      else if (++retry > 2) break;
    }
    await sending;
    return sentHeaders;
  }

  private async forwardMedia(connection: socket.TCPSocketConnection, upstream: string, head: boolean,
    range: string): Promise<void> {
    if (await this.forwardPrefix(connection, upstream, head, range)) return;
    const cached = !range || range === 'bytes=0-' ? this.startup?.ready(upstream) : undefined;
    if (cached && !this.closed) {
      if (!head && !this.reportedStartupHit) {
        this.reportedStartupHit = true;
        hilog.info(0x0000, 'QyxVideo', 'used preloaded media bytes');
      }
      const contentRange = range ? 'bytes 0-' + (cached.length - 1).toString() + '/' + cached.length.toString() : '';
      await connection.send({ data: this.responseHeader(range ? 206 : 200,
        this.header(cached.headers, 'content-type') || 'application/octet-stream',
        cached.length.toString(), contentRange) });
      if (!head) {
        for (const chunk of cached.chunks) await connection.send({ data: chunk });
      }
      return;
    }
    let started = false;
    let chunked = false;
    let disconnected = false;
    let sending = Promise.resolve();
    const enqueue = (data: string | ArrayBuffer): void => {
      sending = sending.then(async () => {
        if (!disconnected && !this.closed) await connection.send({ data });
      }).catch(() => { disconnected = true; });
    };
    try {
      const response = await this.webSource.request(upstream, head, range, {
        onHeaders: (code: number, headers: Record<string, string>) => {
          if (code !== 200 && code !== 206 && code !== 416) return;
          const upstreamLength = this.header(headers, 'content-length');
          const encoded = this.header(headers, 'content-encoding');
          const length = code === 416 ? '0' : head ? upstreamLength || '0' : !encoded ? upstreamLength : '';
          chunked = !length;
          started = true;
          enqueue(this.responseHeader(code, this.header(headers, 'content-type') || 'application/octet-stream',
            length, this.header(headers, 'content-range')));
        },
        onChunk: (chunk: ArrayBuffer) => {
          if (disconnected) return Promise.reject(new Error('Local video connection closed'));
          if (!started || !chunk.byteLength || head) return;
          if (chunked) enqueue(chunk.byteLength.toString(16) + '\r\n');
          enqueue(chunk);
          if (chunked) enqueue('\r\n');
          return sending;
        }
      }, this.token);
      if (!started) throw new Error('CDN HTTP ' + response.status.toString());
      if (chunked) enqueue('0\r\n\r\n');
      await sending;
    } catch (error) {
      if (!started) throw new Error(error instanceof Error ? error.message : 'Browser media request failed');
      await sending;
    }
  }

  private playlist(body: ArrayBuffer, upstream: string, resolution: string): ArrayBuffer {
    const original = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(body));
    if (!original.startsWith('#EXTM3U')) throw new Error('Invalid X video playlist');
    const location = (reference: string): string => {
      const parsed = url.URL.parseURL(reference, upstream);
      const local = this.source(parsed.href);
      if (!local) throw new Error('Unexpected playlist host');
      return local;
    };
    const lines = original.split(/\r?\n/);
    const resolutions = hlsResolutions(lines);
    if (resolutions.length) this.onResolutions(upstream, resolutions);
    const selected = resolution.startsWith('p') ? preferredVideoResolution(resolutions, resolution) : resolution;
    if (selected && !resolutions.includes(selected)) throw new Error('Requested video resolution is unavailable');
    const rewritten = selectHlsResolution(lines, selected).map((line: string) => {
      if (!line) return line;
      if (!line.startsWith('#')) return location(line.trim());
      return line.replace(/URI="([^"]+)"/g, (_attribute: string, reference: string) => 'URI="' + location(reference) + '"');
    }).join('\n');
    return new util.TextEncoder().encodeInto(rewritten).buffer as ArrayBuffer;
  }

  private async serve(connection: socket.TCPSocketConnection, incoming: string): Promise<void> {
    const match = /^(GET|HEAD) (\/[\w/.%?=&+~!$'()*,:;@-]+) HTTP\/1\.[01]\r\n/.exec(incoming);
    const prefix = '/' + this.token + '/';
    if (incoming.length > 8192 || !match || !match[2].startsWith(prefix)) {
      await connection.send({ data: 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' });
      return;
    }
    const target = match[2].slice(prefix.length - 1);
    const paired = this.pairedPlaylists.get(target);
    if (paired) {
      const body = new util.TextEncoder().encodeInto(paired);
      await connection.send({ data: this.responseHeader(200, 'application/vnd.apple.mpegurl', body.byteLength.toString(), '') });
      if (match[1] === 'GET') await connection.send({ data: body.buffer as ArrayBuffer });
      return;
    }
    const fixed = /^\/q\/(\d{2,5}x\d{2,5}|p\d{3,4})(\/.*)$/.exec(target);
    const upstream = VIDEO_CDN + (fixed ? fixed[2] : target);
    const playlist = /\.m3u8(?:\?|$)/i.test(upstream);
    const head = match[1] === 'HEAD';
    const range = playlist ? '' : /\r\nrange:\s*(bytes=\d*-\d*)\r\n/i.exec(incoming)?.[1] || '';
    try {
      if (!playlist) {
        await this.forwardMedia(connection, upstream, head, range);
        return;
      }
      const prefetched = head ? undefined : this.pendingPlaylists.get(upstream);
      if (prefetched) this.pendingPlaylists.delete(upstream);
      const response = await (head ? this.webSource.request(upstream, true, '', undefined, this.token) :
        prefetched || this.readPlaylist(upstream));
      const code = response.status;
      if (code !== 200 && code !== 206 && code !== 416) throw new Error('CDN HTTP ' + code.toString());
      const responseHeaders = response.headers;
      let chunks = response.chunks;
      let length = response.length;
      if (!head && code === 200) {
        if (length > 1024 * 1024) throw new Error('X video playlist too large');
        const body = new Uint8Array(length);
        let offset = 0;
        for (const chunk of chunks) {
          body.set(new Uint8Array(chunk), offset);
          offset += chunk.byteLength;
        }
        const rewritten = this.playlist(body.buffer as ArrayBuffer, upstream, fixed?.[1] || '');
        chunks = [rewritten];
        length = rewritten.byteLength;
      }
      const contentLength = head ? this.header(responseHeaders, 'content-length') || '0' : length.toString();
      const contentRange = this.header(responseHeaders, 'content-range');
      await connection.send({ data: this.responseHeader(code, 'application/vnd.apple.mpegurl', contentLength, contentRange) });
      if (!head) {
        for (const chunk of chunks) await connection.send({ data: chunk });
      }
    } catch (error) {
      if (!this.closed) {
        hilog.warn(0x0000, 'QyxVideo', 'transport failed %{public}s', error instanceof Error ? error.message : 'socket error');
        await connection.send({ data: 'HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' })
          .catch(() => {});
      }
    }
  }
}
