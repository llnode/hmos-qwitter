((request, conversation) => {
  const chat = request.mode === 'chat';
  const reply = request.mode === 'reply';
  const origin = location.origin;
  if (window !== window.top || (origin !== 'https://x.com' && !(chat && origin === 'https://chat.x.com'))) {
    return reply ? 'reply-web-not-ready' : 'unavailable';
  }
  const current = window.__qyxComposer;
  const same = current?.key === request.key;
  if (chat && (!conversation || conversation !== request.target)) return 'unavailable';
  const postPath = /^\/compose\/post\/?$/.test(location.pathname);
  if (!chat && !reply && !postPath && !(request.step === 'verify' && same)) {
    return request.step === 'submit' ? 'post-route-left:' + location.pathname.split('/').slice(0, 3).join('/') : 'unavailable';
  }

  const visible = (node) => !node.closest('[hidden], [aria-hidden="true"], [inert]') && !!node.getClientRects().length;
  const statusId = (path) => /^\/(?:[A-Za-z0-9_]{1,15}|i\/web)\/status\/(\d{1,24})(?:\/)?$/.exec(path)?.[1];
  const replyDialogs = () => Array.from(document.querySelectorAll('[role="dialog"], [aria-modal="true"]'))
    .filter((node) => visible(node) && !node.parentElement?.closest('[role="dialog"], [aria-modal="true"]'));
  const postEditorSelector = '[data-testid="tweetTextarea_0"][contenteditable="true"], ' +
    '[data-testid="tweetTextarea_0"] [contenteditable="true"]';
  const replyEditorSelector = postEditorSelector + ', [contenteditable="true"][role="textbox"], ' +
    '[contenteditable="true"][data-lexical-editor]';
  const replyRoute = /^\/(?:compose\/(?:post|tweet|reply)|intent\/(?:tweet|post))\/?$/.test(location.pathname);
  const routeTarget = new URLSearchParams(location.search).get('in_reply_to');
  const opened = reply && window.__qyxReplyOpened === request.key;
  const replyRouteMatches = replyRoute && (!routeTarget || routeTarget === request.target);
  const dialogMatchesTarget = () => replyDialogs().some((dialog) =>
    Array.from(dialog.querySelectorAll('article a[href], [role="article"] a[href]')).some((link) =>
      link.origin === origin && statusId(link.pathname) === request.target &&
      !link.closest('[data-testid="tweetText"], [data-testid="quoteTweet"], [data-testid="card.wrapper"]')));
  const routedReply = reply && replyRouteMatches &&
    (opened || (routeTarget === request.target && dialogMatchesTarget()));
  const inlineEditors = () => Array.from(document.querySelectorAll(opened ? replyEditorSelector : postEditorSelector))
    .filter((node) => visible(node) &&
      (node.closest('main, [data-testid="primaryColumn"]') || routedReply) &&
      !node.closest('[role="dialog"], [aria-modal="true"], aside, [data-testid="tweetText"], [data-testid="quoteTweet"]') &&
      (!node.closest('article, [role="article"]') || opened) &&
      !node.parentElement?.closest(replyEditorSelector));
  const onTarget = reply && statusId(location.pathname) === request.target;
  if (reply) {
    if (request.step === 'verify' ? !same : !onTarget && !routedReply) {
      if (replyRoute) return 'reply-route-unverified';
      if (location.pathname.startsWith('/i/flow/')) return 'reply-x-flow';
      if (statusId(location.pathname)) return 'reply-different-status';
      return 'reply-unexpected-page';
    }
    const dialogs = replyDialogs();
    const direct = (onTarget || routedReply) && !dialogs.length && inlineEditors().length === 1;
    if (request.step === 'prepare' && !dialogs.length && !direct) {
      const articleSelector = 'article, [role="article"]';
      const sources = Array.from(document.querySelectorAll(articleSelector)).filter((article) => {
        const links = Array.from(article.querySelectorAll('a[href]')).filter((link) =>
          link.origin === origin && link.closest(articleSelector) === article &&
          !link.closest('[data-testid="tweetText"], [data-testid="quoteTweet"], [data-testid="card.wrapper"]'));
        return links.some((link) => statusId(link.pathname) === request.target ||
          (statusId(link.pathname.replace(/\/analytics\/?$/, '')) === request.target &&
            /\/analytics\/?$/.test(link.pathname)));
      });
      const source = sources.length === 1 ? sources[0] : null;
      const action = source && Array.from(source.querySelectorAll('[data-testid="reply"]')).find((node) =>
        node.closest(articleSelector) === source && !node.closest('[data-testid="quoteTweet"]'));
      if (action && visible(action) &&
        !action.disabled && action.getAttribute('aria-disabled') !== 'true' && window.__qyxReplyOpened !== request.key) {
        window.__qyxReplyOpened = request.key;
        action.click();
        return 'reply-opening';
      }
      return opened ? 'reply-opened-no-editor' : 'reply-target-unavailable';
    }
    if (request.step !== 'verify' && !opened && !routedReply && !direct) return 'reply-editor-unverified';
  }
  const dialogs = !chat ? replyDialogs() : [];
  const postDialogs = !chat && !reply ? dialogs.filter((dialog) =>
    Array.from(dialog.querySelectorAll(postEditorSelector)).some(visible)) : [];
  const scopes = reply ? dialogs : postDialogs.length ? postDialogs : [document];
  if (chat) {
    for (const frame of document.querySelectorAll('iframe')) {
      try { if (frame.contentDocument) scopes.push(frame.contentDocument); } catch (_) {}
    }
    for (const host of document.querySelectorAll('[id*="chat" i], [data-testid*="chat" i]')) {
      if (host.shadowRoot) scopes.push(host.shadowRoot);
    }
  }
  const editors = scopes.flatMap((scope) => {
    if (chat && !scope.querySelector('[role="log"]')) return [];
    const selector = chat ? 'textarea, [data-testid="dmComposerTextInput"][contenteditable="true"], ' +
      '[contenteditable="true"][role="textbox"], [contenteditable="true"][data-lexical-editor]' :
      reply ? replyEditorSelector : postEditorSelector;
    return Array.from(scope.querySelectorAll(selector)).filter((node) => visible(node) && !node.parentElement?.closest(selector));
  });
  const candidates = reply && !scopes.length && (onTarget || routedReply) ? inlineEditors() : editors;
  const editor = candidates.length === 1 ? candidates[0] : null;
  const normalize = (value) => (value || '').replace(/\r\n?/g, '\n').replace(/\u00a0/g, ' ').trim();
  const valueOf = (node) => {
    if (!node) return '';
    if (!node.isContentEditable && !node.matches('[contenteditable="true"]')) {
      return normalize(node.value ?? node.innerText ?? node.textContent);
    }
    const placeholders = '[data-testid^="tweetTextarea_"][data-testid$="_placeholder"], [data-lexical-placeholder]';
    if (!node.querySelector(placeholders)) return normalize(node.innerText ?? node.textContent);
    const copy = node.cloneNode(true);
    copy.querySelectorAll(placeholders).forEach((placeholder) => placeholder.remove());
    return normalize(copy.textContent);
  };
  const expected = normalize(request.text);
  const uploads = chat ? [] : request.uploads || [];
  const choices = chat || reply ? [] : request.choices || [];
  const thread = chat || reply ? [] : request.thread || [];
  const gif = chat || reply ? '' : request.gif || '';
  if ((!expected && !uploads.length && !gif) || (chat ? expected.length > 10000 : expected.length > 1000) ||
      [uploads.length, choices.length, thread.length, gif.length].filter(Boolean).length > 1) return 'unavailable';

  const setValue = (node, value) => {
    const doc = node.ownerDocument;
    const prototype = node.tagName === 'SELECT' ? doc.defaultView.HTMLSelectElement.prototype :
      node.tagName === 'INPUT' ? doc.defaultView.HTMLInputElement.prototype : doc.defaultView.HTMLTextAreaElement.prototype;
    Object.getOwnPropertyDescriptor(prototype, 'value')?.set?.call(node, value);
    node.dispatchEvent(new doc.defaultView.Event('input', { bubbles: true }));
    node.dispatchEvent(new doc.defaultView.Event('change', { bubbles: true }));
  };
  const replaceEditorText = (node, value) => {
    const doc = node.ownerDocument;
    node.focus();
    if (node.tagName === 'TEXTAREA') {
      setValue(node, value);
    } else {
      const selection = doc.getSelection();
      const range = doc.createRange();
      range.selectNodeContents(node);
      selection?.removeAllRanges();
      selection?.addRange(range);
      // Let X's editor ingest plain text through its paste handler. Direct insertText can
      // race its emoji entity conversion and duplicate emoji in the controlled editor.
      const view = doc.defaultView;
      let handled = false;
      if (typeof view.DataTransfer === 'function' && typeof view.ClipboardEvent === 'function') {
        const clipboard = new view.DataTransfer();
        clipboard.setData('text/plain', value);
        const paste = new view.ClipboardEvent('paste', { bubbles: true, cancelable: true, clipboardData: clipboard });
        handled = !node.dispatchEvent(paste);
      }
      if (!handled) doc.execCommand('insertText', false, value);
    }
  };
  const applyPostExtras = () => {
    const scope = editor.closest('[role="dialog"], [aria-modal="true"]') || (reply && editor.closest('[data-testid="primaryColumn"], main')) || document;
    const attachmentPreviews = () => Array.from(scope.querySelectorAll(
      '[data-testid="attachments"] img, [data-testid="attachments"] video, [data-testid="attachments"] [data-testid="videoPlayer"]'))
      .filter((node) => visible(node) &&
        node.closest('article, [role="article"]') === editor.closest('article, [role="article"]'));
    const hasAttachments = !reply && attachmentPreviews().length > 0;
    const pollFields = Array.from(scope.querySelectorAll('[data-testid^="pollOption"] input, input[data-testid^="pollOption"]')).filter(visible);
    const existingThread = Array.from(scope.querySelectorAll('[data-testid="tweetTextarea_1"]')).find(visible);
    if (!reply && existingThread && (!thread.length || window.__qyxPostThreadKey !== request.key)) {
      return 'draft-conflict';
    }
    if (hasAttachments && (gif ? window.__qyxSelectedGif !== gif :
      !uploads.length || window.__qyxPostMedia?.key !== request.key)) {
      return 'draft-conflict';
    }
    if (!reply && pollFields.length && (!choices.length || (window.__qyxPostPollKey !== request.key &&
      Array.from(pollFields).some((field) => field.value.trim())))) {
      return 'draft-conflict';
    }
    if (gif && (!hasAttachments || window.__qyxSelectedGif !== gif)) return 'pending';
    if (thread.length) {
      if (thread.length > 9 || thread.some((value) => !normalize(value) || value.length > 1000)) return 'unavailable';
      window.__qyxPostThreadKey = request.key;
      for (let index = 0; index < thread.length; index++) {
        const field = scope.querySelector('[data-testid="tweetTextarea_' + (index + 1) + '"]');
        const next = field?.matches('[contenteditable="true"]') ? field : field?.querySelector('[contenteditable="true"]');
        if (!next) {
          const add = Array.from(scope.querySelectorAll('[data-testid="addButton"]')).filter(visible).pop();
          if (add && !add.disabled && add.getAttribute('aria-disabled') !== 'true') add.click();
          return 'pending';
        }
        if (valueOf(next) !== normalize(thread[index])) replaceEditorText(next, thread[index]);
        if (valueOf(next) !== normalize(thread[index])) return 'pending';
      }
      if (scope.querySelector('[data-testid="tweetTextarea_' + (thread.length + 1) + '"]')) return 'draft-conflict';
    }
    if (choices.length) {
      if (choices.length < 2 || choices.length > 4 || choices.some((value) => !value || Array.from(value).length > 25) ||
        request.duration < 5 || request.duration > 10080) return 'unavailable';
      const option = (index) => {
        const node = scope.querySelector('[data-testid="pollOption_' + index + '"], [data-testid="pollOptionTextInput_' +
          index + '"], input[placeholder="Choice ' + (index + 1) + '"], input[placeholder="选项 ' + (index + 1) +
          '"], input[placeholder="選項 ' + (index + 1) + '"]');
        return node?.matches('input') ? node : node?.querySelector('input');
      };
      if (!option(0)) {
        scope.querySelector('[data-testid="pollButton"], [aria-label="Add poll"], [aria-label="添加投票"], [aria-label="新增投票"]')?.click();
        return 'pending';
      }
      window.__qyxPostPollKey = request.key;
      for (let index = 0; index < choices.length; index++) {
        const input = option(index);
        if (!input) {
          scope.querySelector('[data-testid="addPollOption"], [data-testid="addPollOptionButton"], [aria-label="Add a choice"]')?.click();
          return 'pending';
        }
        if (input.value !== choices[index]) setValue(input, choices[index]);
      }
      if (choices.some((value, index) => option(index)?.value !== value)) return 'pending';
      if (request.duration !== 1440) {
        const selector = (unit) => {
          const label = { Days: '天', Hours: '小时', Minutes: '分钟' }[unit];
          const node = scope.querySelector('[data-testid="pollDuration' + unit + '"], select[aria-label="' + unit +
            '"], select[aria-label="' + label + '"]');
          return node?.matches('select') ? node : node?.querySelector('select');
        };
        let fields = ['Days', 'Hours', 'Minutes'].map(selector);
        const selects = Array.from(scope.querySelectorAll('select')).filter(visible);
        if (fields.some((node) => !node) && selects.length === 3 &&
          selects.every((field, index) => Array.from(field.options).some((option) => Number(option.value) === [7, 23, 59][index]))) {
          fields = selects;
        }
        if (fields.some((node) => !node)) {
          scope.querySelector('[data-testid="pollDuration"], [aria-label="Edit poll duration"], [aria-label="投票时长"]')?.click();
          return 'pending';
        }
        const numbers = [Math.floor(request.duration / 1440), Math.floor(request.duration % 1440 / 60), request.duration % 60];
        for (let index = 0; index < fields.length; index++) {
          const field = fields[index];
          const value = Array.from(field.options).find((option) => option.value !== '' && Number(option.value) === numbers[index])?.value;
          if (value === undefined) return 'unavailable';
          if (field.value !== value) setValue(field, value);
        }
        if (fields.some((field, index) => Number(field.value) !== numbers[index])) return 'pending';
      }
    }
    if (uploads.length) {
      const input = scope.querySelector('input[type="file"][data-testid="fileInput"]') ||
        scope.querySelector('input[type="file"][accept*="image"], input[type="file"][accept*="video"]');
      if (!input || (uploads.length > 1 && !input.multiple)) return 'pending';
      const staged = window.__qyxPostMedia;
      if (!staged || staged.key !== request.key) {
        const transfer = { key: request.key, state: 'loading' };
        window.__qyxPostMedia = transfer;
        Promise.all(uploads.map(async (item) => {
          const response = await fetch(item.url, { cache: 'no-store' });
          if (!response.ok) throw new Error('media unavailable');
          const blob = await response.blob();
          if (blob.size !== item.size) throw new Error('media incomplete');
          return new File([blob], item.name, { type: item.type });
        })).then((files) => {
          if (window.__qyxPostMedia !== transfer || !input.isConnected) return;
          const data = new DataTransfer();
          for (const file of files) data.items.add(file);
          input.files = data.files;
          input.dispatchEvent(new Event('change', { bubbles: true }));
          transfer.state = 'applied';
        }).catch(() => { transfer.state = 'failed'; });
        return 'pending';
      }
      if (staged.state === 'failed') return 'attachment-failed';
      const previews = attachmentPreviews();
      const loading = scope.querySelector('[data-testid="attachments"] [role="progressbar"]');
      if (staged.state !== 'applied' || previews.length < uploads.length || loading) return 'pending';
    }
    return 'prepared';
  };

  const matchingMessages = () => {
    const log = editor?.getRootNode().querySelector('[role="log"]');
    if (!log) return 0;
    return Array.from(log.querySelectorAll('article, [role="article"], [data-message-id], [role="listitem"]')).filter((node) => {
      if (node.getAttribute('data-outgoing') === 'false' || node.getAttribute('data-is-sent') === 'false') return false;
      const body = node.querySelector('[data-message-text], [data-testid="message-text"], [data-testid="messageText"]');
      const value = valueOf(body || node);
      return value === expected || (!body && value.startsWith(expected) &&
        /^\s+(?:(?:上午|下午|凌晨|中午)\s*)?\d{1,2}[:：]\d{2}(?:\s*[ap]m)?$/i.test(value.slice(expected.length)));
    }).length;
  };

  const publishedLinks = () => Array.from(document.querySelectorAll('[data-testid="toast"], [role="alert"]'))
    .filter(visible).flatMap((node) => Array.from(node.querySelectorAll('a[href]')))
    .filter((link) => link.origin === origin && statusId(link.pathname)).map((link) => link.pathname);

  if (request.step === 'verify') {
    if (!same || !current.submitted) return 'unavailable';
    if (chat && editor && !valueOf(editor) && matchingMessages() > current.before) return 'confirmed';
    if (reply) {
      const confirmedPath = !valueOf(editor) && publishedLinks().find((path) =>
        !current.previousLinks.includes(path) && statusId(path) !== request.target);
      return confirmedPath ? 'confirmed:' + statusId(confirmedPath) : 'pending';
    }
    if (!chat && publishedLinks().some((path) => !current.previousLinks.includes(path))) return 'confirmed';
    if (!chat && !postPath && Date.now() - (current.submittedAt || 0) > 1500) {
      // X closes the compose page after accepting a post. Its toast can be missed in a hidden page, so also accept
      // the closed composer when no X message is shown and no editor still holds the submitted text.
      const holdsText = Array.from(document.querySelectorAll(postEditorSelector))
        .some((node) => visible(node) && valueOf(node) === expected);
      const message = Array.from(document.querySelectorAll('[data-testid="toast"], [role="alert"]'))
        .some((node) => visible(node) && normalize(node.textContent) && !node.querySelector('a[href*="/status/"]'));
      if (!holdsText && !message) return 'confirmed';
    }
    return 'pending';
  }
  if (reply && same && current.submitted) return 'submitted';
  if (!editor) return reply ? 'reply-editor-unavailable' : request.step === 'submit' ? 'post-editor-missing:' + candidates.length : 'unavailable';

  if (request.step === 'prepare') {
    if (same && current.submitted) return 'submitted';
    const previousText = valueOf(editor);
    const ours = current?.key === request.key && !current.submitted;
    if (!reply && previousText && previousText !== expected && !ours && !(current?.editor === editor &&
      !current.submitted && (previousText === current.text || current.text === expected))) {
      return 'draft-conflict';
    }
    window.__qyxComposer = { key: request.key, editor, text: expected, submitted: false, before: 0 };
    if (previousText === expected) return chat || (reply && !uploads.length) ? 'prepared' : applyPostExtras();
    replaceEditorText(editor, request.text);
    return valueOf(editor) === expected ? (chat || (reply && !uploads.length) ? 'prepared' : applyPostExtras()) :
      reply ? 'reply-input-unavailable' : 'unavailable';
  }

  if (request.step !== 'submit' || !same) {
    return reply ? 'reply-compose-session-changed' : request.step === 'submit' ? 'post-session-missing' : 'unavailable';
  }
  if (current.submitted) return 'submitted';
  if (current.editor !== editor || valueOf(editor) !== expected) {
    if (reply) return 'reply-editor-changed';
    if (chat) return 'unavailable';
    // X can re-draw its editor or drop text it did not register. Put the text back in the editor shown now.
    const shown = valueOf(editor);
    const replaced = current.editor !== editor;
    current.editor = editor;
    current.repairs = (current.repairs || 0) + 1;
    if (current.repairs > 4) {
      return 'post-text-rejected:' + (replaced ? 'node' : 'text') + ':' + shown.length + '/' + expected.length;
    }
    if (shown !== expected) replaceEditorText(editor, request.text);
    return valueOf(editor) === expected ? 'pending' :
      'post-text-rejected:' + (replaced ? 'node' : 'text') + ':' + valueOf(editor).length + '/' + expected.length;
  }
  if (!chat && (!reply || uploads.length)) {
    const extras = applyPostExtras();
    if (extras !== 'prepared') return extras;
  }
  const sendNames = /^(?:send(?: message)?|发送(?:消息|私信)?|傳送(?:訊息)?|發送(?:訊息)?|enviar(?: mensaje)?|envoyer(?: le message)?|送信|전송)$/i;
  const isSend = (node) => chat ? /^(?:sendMessage|send-message|dmComposerSendButton|sendMessageButton)$/i.test(node.getAttribute('data-testid') || '') ||
    sendNames.test((node.getAttribute('aria-label') || node.getAttribute('title') || node.textContent || '').trim()) :
    ['tweetButton', 'tweetButtonInline'].includes(node.getAttribute('data-testid'));
  let buttons = [];
  const replyScope = reply ? editor.closest('[role="dialog"], [aria-modal="true"]') ||
    editor.closest('[data-testid="primaryColumn"], main') || (routedReply ? document.body : null) : null;
  for (let parent = editor.parentElement; parent && (parent !== document.body || parent === replyScope); parent = parent.parentElement) {
    buttons = Array.from(parent.querySelectorAll('button, [role="button"]')).filter((node) => visible(node) && isSend(node));
    if (reply) buttons = buttons.filter((node) => replyScope?.contains(node) && (!node.closest('article, [role="article"]') ||
      node.closest('article, [role="article"]') === editor.closest('article, [role="article"]')));
    if (buttons.length || parent === replyScope) break;
  }
  if (buttons.length !== 1 || buttons[0].disabled || buttons[0].getAttribute('aria-disabled') === 'true') {
    if (reply) return 'reply-button-unavailable';
    if (chat) return 'pending';
    return buttons.length === 1 ? 'post-button-disabled' : 'post-button-count:' + buttons.length;
  }
  if (!chat) current.previousLinks = publishedLinks();
  current.before = chat ? matchingMessages() : 0;
  current.submitted = true;
  current.submittedAt = Date.now();
  buttons[0].click();
  return 'submitted';
})(qyxComposeRequest, qyxComposeConversation)
