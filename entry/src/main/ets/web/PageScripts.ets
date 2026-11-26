import { webview } from '@kit.ArkWeb';

// The page adapters are 20-60 KB each. Sending their source on every poll makes ArkWeb transfer, parse and
// compile the whole adapter again, because each request embeds different arguments. Install the adapters once
// per document as functions, then send a short call. A navigation that replaces the document clears the
// registry, the call reports MISSING, and run() installs again.
const MISSING: string = '__qyx_script_missing__';

function fingerprint(value: string): string {
  let hash = 2166136261;
  for (let index = 0; index < value.length; index++) {
    hash = Math.imul(hash ^ value.charCodeAt(index), 16777619);
  }
  return (hash >>> 0).toString(36);
}

export class PageScript {
  readonly key: string;
  readonly definition: string;

  constructor(name: string, body: string, params: string[]) {
    const source = body.trim().replace(/;+$/, '');
    this.key = 'qyx_' + name + '_' + fingerprint(source) + '_' + source.length.toString(36);
    let declarations = '';
    for (const param of params) {
      declarations += 'const ' + param + ' = __qyxArgs.' + param + '; ';
    }
    this.definition = '__qyxRun[' + JSON.stringify(this.key) + '] = (__qyxArgs) => { ' + declarations +
      'return (\n' + source + '\n); };';
  }

  // A JavaScript expression for use inside PageScripts.wrap(). args is an object literal expression.
  call(args: string = '{}'): string {
    return '__qyxRun[' + JSON.stringify(this.key) + '](' + args + ')';
  }
}

export class PageScripts {
  read: PageScript = new PageScript('read', '""', []);
  inbox: PageScript = new PageScript('inbox', 'null', []);
  composer: PageScript = new PageScript('composer', '"unavailable"', []);
  gif: PageScript = new PageScript('gif', 'null', []);
  private install: string = '';

  configure(read: string, inbox: string, composer: string, gif: string): void {
    this.read = new PageScript('read', read, ['qyxDiscoverAccount', 'qyxHomeTarget', 'qyxTranslationLocale',
      'qyxTranslationLabel', 'qyxOpenQuote', 'qyxLikeAction', 'qyxTranslationPostId', 'qyxKnownTranslationIds',
      'qyxInboxResult']);
    this.inbox = new PageScript('inbox', inbox, ['qyxInboxOpenKey', 'qyxNotificationCategory']);
    this.composer = new PageScript('composer', composer, ['qyxComposeRequest', 'qyxComposeConversation']);
    this.gif = new PageScript('gif', gif, ['qyxGifRequest']);
    this.install = '(() => { const __qyxRun = window.__qyxRun || (window.__qyxRun = Object.create(null)); ' +
      this.read.definition + '\n' + this.inbox.definition + '\n' + this.composer.definition + '\n' +
      this.gif.definition + '\nreturn true; })()';
  }

  // Wraps an expression built from call() so it reports MISSING when this document lacks a required adapter.
  wrap(expression: string, required: PageScript[]): string {
    const checks = required.map((script: PageScript) =>
      'typeof __qyxRun[' + JSON.stringify(script.key) + '] !== "function"').join(' || ');
    return '(() => { const __qyxRun = window.__qyxRun; if (!__qyxRun' + (checks ? ' || ' + checks : '') +
      ') return "' + MISSING + '"; return ' + expression + '; })()';
  }

  async run(controller: webview.WebviewController, script: string): Promise<string> {
    const first = await controller.runJavaScript(script);
    if (!PageScripts.missing(first)) return first;
    if (!this.install) return '';
    await controller.runJavaScript(this.install);
    const second = await controller.runJavaScript(script);
    return PageScripts.missing(second) ? '' : second;
  }

  private static missing(raw: string): boolean {
    return raw === MISSING || raw === '"' + MISSING + '"';
  }
}
