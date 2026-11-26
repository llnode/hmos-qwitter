import { cacheDownload } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { imageAtSize, Post } from '../web/XPage';

const FILE_BUDGET: number = 64 * 1024 * 1024;
const MEMORY_BUDGET: number = 8 * 1024 * 1024;

interface ImageJob {
  success: () => void;
  failure: (error: cacheDownload.DownloadError) => void;
  timer: number;
}

export class MediaLookahead {
  private queued: string[] = [];
  private readonly active: Map<string, ImageJob> = new Map();
  private readonly recent: Map<string, number> = new Map();
  private configured: boolean = false;
  private reported: boolean = false;

  prepare(posts: Post[], imageQuality: string): void {
    if (!this.configured) {
      this.configured = true;
      try {
        cacheDownload.setFileCacheSize(FILE_BUDGET);
        cacheDownload.setMemoryCacheSize(MEMORY_BUDGET);
      } catch (_) {}
    }
    const urls: string[] = [];
    for (let index = 0; index < posts.length; index++) {
      const post = posts[index];
      urls.push(post.avatar, ...post.photos.map((photo: string) => imageAtSize(photo, 'small')));
      if (post.videoPoster) urls.push(imageAtSize(post.videoPoster, 'small'));
      if (post.articleCover) urls.push(imageAtSize(post.articleCover, 'small'));
      if (post.quotedPost) {
        const quote = post.quotedPost;
        urls.push(quote.avatar, imageAtSize(quote.poster || quote.photo, 'small'));
      }
      if (index < 2 && imageQuality !== 'small') {
        urls.push(...post.photos.map((photo: string) => imageAtSize(photo, imageQuality)));
        if (post.videoPoster) urls.push(imageAtSize(post.videoPoster, imageQuality === 'orig' ? '4096x4096' : imageQuality));
      }
    }
    this.queued = Array.from(new Set(urls)).filter((address: string) =>
      /^https:\/\/pbs\.twimg\.com\/(?:profile_images|default_profile_images|media|ext_tw_video_thumb|amplify_video_thumb|tweet_video_thumb)\//
        .test(address) && Date.now() - (this.recent.get(address) || 0) > 180000).slice(0, 24);
    this.run();
  }

  stop(): void {
    this.queued = [];
  }

  clear(): void {
    this.stop();
    for (const address of Array.from(this.active.keys())) {
      this.finish(address, false);
      try { cacheDownload.cancel(address); } catch (_) {}
    }
    this.recent.clear();
    this.reported = false;
    try { cacheDownload.clearMemoryCache(); } catch (_) {}
    try { cacheDownload.clearFileCache(); } catch (_) {}
  }

  private run(): void {
    while (this.active.size < 2 && this.queued.length) {
      const address = this.queued.shift();
      if (!address || this.active.has(address)) continue;
      const job: ImageJob = {
        success: () => this.finish(address, true),
        failure: (_error: cacheDownload.DownloadError) => this.finish(address, false),
        timer: setTimeout(() => this.finish(address, false), 9000)
      };
      this.active.set(address, job);
      try {
        cacheDownload.onDownloadSuccess(address, job.success);
        cacheDownload.onDownloadError(address, job.failure);
        cacheDownload.download(address, {
          cacheStrategy: cacheDownload.CacheStrategy.LAZY,
          retry: { maxRetryCount: 0 },
          timeout: { httpTotalTimeout: 8 }
        });
      } catch (_) {
        this.finish(address, false);
      }
    }
  }

  private finish(address: string, ready: boolean): void {
    const job = this.active.get(address);
    if (!job) return;
    this.active.delete(address);
    clearTimeout(job.timer);
    try { cacheDownload.offDownloadSuccess(address, job.success); } catch (_) {}
    try { cacheDownload.offDownloadError(address, job.failure); } catch (_) {}
    if (this.recent.size >= 256) this.recent.delete(Array.from(this.recent.keys())[0]);
    this.recent.set(address, Date.now() - (ready ? 0 : 165000));
    if (ready && !this.reported) {
      this.reported = true;
      hilog.info(0x0000, 'QwitterMedia', 'upcoming image cached by system');
    }
    this.run();
  }
}
