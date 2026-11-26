import { webview } from '@kit.ArkWeb';
import { X_ORIGIN } from './XPage';

export const VIDEO_CDN: string = 'https://video.twimg.com';
export const VIDEO_BYTE_LIMIT: number = 64 * 1024 * 1024;

export interface VideoResponse {
  status: number;
  headers: Record<string, string>;
  chunks: ArrayBuffer[];
  length: number;
}

export interface VideoStreamSink {
  onHeaders: (status: number, headers: Record<string, string>) => void;
  onChunk: (chunk: ArrayBuffer) => void | Promise<void>;
}

interface VideoMessage {
  id: number;
  status?: number;
  headers?: Record<string, string>;
  done?: boolean;
  error?: boolean;
}

class VideoRequest {
  status: number = 0;
  headers: Record<string, string> = {};
  chunks: ArrayBuffer[] = [];
  length: number = 0;
  timer: number = -1;
  readonly message: string;
  readonly group: string;
  readonly sink?: VideoStreamSink;
  readonly byteLimit: number;
  resolve: (value: VideoResponse) => void;
  reject: (error: Error) => void;

  constructor(message: string, group: string, resolve: (value: VideoResponse) => void, reject: (error: Error) => void,
    sink?: VideoStreamSink, byteLimit: number = VIDEO_BYTE_LIMIT) {
    this.message = message;
    this.group = group;
    this.resolve = resolve;
    this.reject = reject;
    this.sink = sink;
    this.byteLimit = byteLimit;
  }
}

export class VideoWebSource {
  private port: webview.WebMessagePort | null = null;
  private readonly pending: Map<number, VideoRequest> = new Map();
  private sequence: number = 0;
  private ready: boolean = false;

  get available(): boolean {
    return this.ready;
  }

  attach(controller: webview.WebviewController): void {
    if (this.port) return;
    const ports = controller.createWebMessagePorts();
    this.port = ports[0];
    try {
      this.port.onMessageEvent((message: webview.WebMessage) => this.receive(message));
      controller.postMessage('qyx-video-transport', [ports[1]], X_ORIGIN);
    } catch (_) {
      this.close();
      throw new Error('Browser video channel unavailable');
    }
  }

  close(): void {
    for (const id of this.pending.keys()) this.cancel(id, 'Browser disconnected');
    try { this.port?.close(); } catch (_) {}
    this.port = null;
    this.ready = false;
  }

  documentChanging(): void {
    if (this.port) this.close();
  }

  request(remote: string, head: boolean, range: string, sink?: VideoStreamSink, group: string = '',
    byteLimit: number = VIDEO_BYTE_LIMIT): Promise<VideoResponse> {
    if (!remote.startsWith(VIDEO_CDN + '/')) return Promise.reject(new Error('Browser video source unavailable'));
    const id = ++this.sequence;
    return new Promise<VideoResponse>((resolve, reject) => {
      const pending = new VideoRequest(JSON.stringify({ id, remote, head, range, byteLimit, streaming: !!sink }), group, resolve, reject,
        sink, byteLimit);
      this.pending.set(id, pending);
      this.armTimeout(id, pending);
      if (this.ready) this.send(id, pending);
    });
  }

  private armTimeout(id: number, pending: VideoRequest): void {
    clearTimeout(pending.timer);
    pending.timer = setTimeout(() => this.cancel(id, 'Browser video request stalled'), 14000);
  }

  cancelGroup(group: string): void {
    this.pending.forEach((request: VideoRequest, id: number) => {
      if (request.group === group) this.cancel(id, 'Video closed');
    });
  }

  private cancel(id: number, reason: string): void {
    try { this.port?.postMessageEvent(JSON.stringify({ cancel: id })); } catch (_) {}
    this.fail(id, reason);
  }

  stopProbe(): void {
    try { this.port?.postMessageEvent('qyx-stop-video-probe'); } catch (_) {}
  }

  private send(id: number, request: VideoRequest): void {
    try {
      this.port?.postMessageEvent(request.message);
    } catch (_) {
      this.fail(id, 'Browser video request could not be sent');
    }
  }

  private take(id: number): VideoRequest | undefined {
    const pending = this.pending.get(id);
    if (pending) {
      clearTimeout(pending.timer);
      this.pending.delete(id);
    }
    return pending;
  }

  private fail(id: number, reason: string): void {
    this.take(id)?.reject(new Error(reason));
  }

  private receive(message: webview.WebMessage): void {
    if (typeof message === 'string') {
      let data: VideoMessage;
      try { data = JSON.parse(message) as VideoMessage; } catch (_) { return; }
      if (!data) return;
      if (data.id === 0 && data.done && !this.ready) {
        this.ready = true;
        this.pending.forEach((request: VideoRequest, id: number) => this.send(id, request));
        return;
      }
      const pending = this.pending.get(data.id);
      if (!pending) return;
      if (data.error) this.fail(data.id, 'Browser CDN request failed');
      else if (data.done) {
        this.take(data.id);
        pending.resolve({ status: pending.status, headers: pending.headers, chunks: pending.chunks, length: pending.length });
      } else if (data.status && data.headers) {
        this.armTimeout(data.id, pending);
        pending.status = data.status;
        pending.headers = data.headers;
        pending.sink?.onHeaders(data.status, data.headers);
      }
      return;
    }
    if (message.byteLength < 4) return;
    const id = new DataView(message).getUint32(0);
    const pending = this.pending.get(id);
    if (!pending) return;
    this.armTimeout(id, pending);
    pending.length += message.byteLength - 4;
    if (pending.length > pending.byteLimit) {
      this.cancel(id, 'Browser video response too large');
    } else if (pending.sink) {
      Promise.resolve(pending.sink.onChunk(message.slice(4))).then(() => {
        if (this.pending.get(id) === pending) this.port?.postMessageEvent(JSON.stringify({ ack: id }));
      }).catch(() => {
        if (this.pending.get(id) === pending) this.cancel(id, 'Local video connection closed');
      });
    } else {
      pending.chunks.push(message.slice(4));
    }
  }
}

export const VIDEO_TRANSPORT_SCRIPT: string = `(() => {
  if (window !== window.top || location.origin !== '${X_ORIGIN}') return;
  const fetchMedia = window.fetch.bind(window);
  let activePort;
  window.addEventListener('message', ({ data, ports }) => {
    if (data !== 'qyx-video-transport' || ports.length !== 1) return;
    if (activePort) activePort.close();
    const port = activePort = ports[0];
    const requests = new Map();
    const acknowledgements = new Map();
    port.onmessage = async (event) => {
      if (event.data === 'qyx-stop-video-probe') {
        window.dispatchEvent(new Event('qyx-stop-video-probe'));
        for (const video of document.querySelectorAll('video')) video.pause();
        return;
      }
      let id;
      let timeout;
      try {
        const request = JSON.parse(event.data);
        if (request.cancel) {
          requests.get(request.cancel)?.abort();
          return;
        }
        if (request.ack) {
          acknowledgements.get(request.ack)?.();
          return;
        }
        id = request.id;
        const remote = new URL(request.remote);
        if (remote.origin !== '${VIDEO_CDN}') throw new Error();
        const headers = request.range ? { Range: request.range } : {};
        const abort = new AbortController();
        requests.set(id, abort);
        const armTimeout = () => {
          clearTimeout(timeout);
          timeout = setTimeout(() => abort.abort(), 12000);
        };
        armTimeout();
        const response = await fetchMedia(remote.href, {
          method: request.head ? 'HEAD' : 'GET', headers, credentials: 'omit', redirect: 'error',
          signal: abort.signal
        });
        armTimeout();
        const limit = Math.min(request.byteLimit || ${VIDEO_BYTE_LIMIT}, ${VIDEO_BYTE_LIMIT});
        if (!request.head && Number(response.headers.get('content-length')) > limit) {
          abort.abort();
          throw new Error();
        }
        port.postMessage(JSON.stringify({ id, status: response.status, headers: Object.fromEntries(response.headers) }));
        if (response.body && response.ok) {
          const reader = response.body.getReader();
          let total = 0;
          try {
            while (true) {
              const { done, value } = await reader.read();
              if (done) break;
              armTimeout();
              total += value.byteLength;
              if (total > limit) throw new Error();
              for (let start = 0; start < value.byteLength; start += 262144) {
                const chunk = value.subarray(start, start + 262144);
                const packet = new Uint8Array(4 + chunk.byteLength);
                new DataView(packet.buffer).setUint32(0, id);
                packet.set(chunk, 4);
                if (request.streaming) {
                  await new Promise((resolve, reject) => {
                    if (abort.signal.aborted) {
                      reject(new Error());
                      return;
                    }
                    const cancel = () => reject(new Error());
                    abort.signal.addEventListener('abort', cancel, { once: true });
                    acknowledgements.set(id, () => {
                      abort.signal.removeEventListener('abort', cancel);
                      resolve();
                    });
                    port.postMessage(packet.buffer);
                  });
                  acknowledgements.delete(id);
                  armTimeout();
                } else {
                  port.postMessage(packet.buffer);
                }
              }
            }
          } finally {
            await reader.cancel().catch(() => {});
          }
        }
        port.postMessage(JSON.stringify({ id, done: true }));
      } catch (_) {
        port.postMessage(JSON.stringify({ id, error: true }));
      } finally {
        clearTimeout(timeout);
        if (id) {
          requests.delete(id);
          acknowledgements.delete(id);
        }
      }
    };
    port.postMessage(JSON.stringify({ id: 0, done: true }));
  });
})()`;
