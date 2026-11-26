import { util } from '@kit.ArkTS';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { X_ORIGIN } from './XPage';

const MEDIA_PREFIX: string = X_ORIGIN + '/.qwitter-local-media/';
const FORMATS: Map<string, string> = new Map([
  ['jpg', 'image/jpeg'], ['jpeg', 'image/jpeg'], ['png', 'image/png'], ['webp', 'image/webp'], ['gif', 'image/gif'],
  ['mp4', 'video/mp4'], ['mov', 'video/quicktime'], ['m4v', 'video/mp4'], ['webm', 'video/webm']
]);

export interface PostAttachment {
  uri: string;
  name: string;
  type: string;
  size: number;
}

export interface PostUpload {
  url: string;
  name: string;
  type: string;
  size: number;
}

export async function selectPostAttachments(): Promise<PostAttachment[]> {
  const options = new photoAccessHelper.PhotoSelectOptions();
  options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE;
  options.maxSelectNumber = 4;
  const result = await new photoAccessHelper.PhotoViewPicker().select(options);
  const attachments: PostAttachment[] = [];
  for (const uri of result.photoUris.slice(0, options.maxSelectNumber)) {
    const name = new fileUri.FileUri(uri).name;
    const ext = name.split('.').pop()?.toLowerCase() || '';
    const type = FORMATS.get(ext);
    if (!type) throw new Error('unsupported attachment');
    const file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const size = (await fileIo.stat(file.fd)).size;
      if (!size) throw new Error('empty attachment');
      attachments.push({ uri, name, type, size });
    } finally {
      await fileIo.close(file);
    }
  }
  return attachments;
}

export class PostMediaBridge {
  private readonly sources: Map<string, PostAttachment> = new Map();
  private readonly openFiles: fileIo.File[] = [];

  prepare(attachments: PostAttachment[]): PostUpload[] {
    const key = util.generateRandomUUID();
    return attachments.map((item: PostAttachment, index: number): PostUpload => {
      const url = MEDIA_PREFIX + key + '/' + index.toString();
      this.sources.set(url, item);
      return { url, name: item.name, type: item.type, size: item.size };
    });
  }

  respond(request: WebResourceRequest): WebResourceResponse | null {
    const url = request.getRequestUrl();
    if (!url.startsWith(MEDIA_PREFIX)) return null;
    const response = new WebResourceResponse();
    const source = this.sources.get(url);
    if (source && !request.isMainFrame() && request.getRequestMethod() === 'GET') {
      try {
        const file = fileIo.openSync(source.uri, fileIo.OpenMode.READ_ONLY);
        this.openFiles.push(file);
        response.setResponseMimeType(source.type);
        response.setResponseHeader([{ headerKey: 'Cache-Control', headerValue: 'no-store' },
          { headerKey: 'Content-Length', headerValue: source.size.toString() }]);
        response.setResponseData(file.fd);
        response.setResponseCode(200);
        response.setReasonMessage('OK');
        return response;
      } catch (_) {}
    }
    response.setResponseMimeType('text/plain');
    response.setResponseData('');
    response.setResponseCode(404);
    response.setReasonMessage('Not Found');
    return response;
  }

  clear(): void {
    this.sources.clear();
    for (const file of this.openFiles.splice(0)) {
      try { fileIo.closeSync(file); } catch (_) {}
    }
  }
}
