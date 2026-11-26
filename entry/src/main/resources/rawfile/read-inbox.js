((openKey, notificationCategory) => {
  const chatOrigin = location.origin === 'https://chat.x.com';
  if ((!chatOrigin && location.origin !== 'https://x.com') || window !== window.top) return null;
  const path = location.pathname.replace(/\/$/, '');
  const notificationPage = /^\/notifications(?:\/|$)/.test(path);
  const chatPage = chatOrigin || /^\/(?:i\/chat|messages)(?:\/|$)/.test(path);
  if (!notificationPage && !chatPage) return null;
  let root = document.querySelector('[data-testid="primaryColumn"], main, [role="main"]') || document.body;
  const scopes = [document.body];
  if (chatPage) {
    // X can put the inbox under an open shadow root or a same-origin frame.
    // Walk nested scopes too; the outer host need not have a chat-specific ID.
    for (let i = 0; i < scopes.length && i < 24; i++) {
      for (const host of scopes[i].querySelectorAll('*')) {
        if (scopes.length >= 24) break;
        if (host.shadowRoot) scopes.push(host.shadowRoot);
        if (host.localName === 'iframe') {
          try {
            const body = host.contentDocument?.body;
            if (body) scopes.push(body);
          } catch (_) {}
        }
      }
    }
    const score = (scope) =>
      100 * scope.querySelectorAll('[role="log"], [role="option"], [data-conversation-id], [data-testid*="conversation" i]').length +
      scope.querySelectorAll('img, [role="listitem"], button, [role="button"]').length;
    root = scopes.map((scope) => ({ scope, score: score(scope) }))
      .reduce((best, candidate) => candidate.score > best.score ? candidate : best).scope;
  }
  const text = (node, max = 2000) => (node?.innerText ?? node?.textContent ?? '').trim().slice(0, max);
  const page = { rows: [], messages: [], conversation: '', title: '', locked: false, empty: false, opened: false,
    embeddedChat: !chatOrigin && chatPage && Array.from(document.querySelectorAll('iframe[src]')).some((frame) => {
      try { return new URL(frame.src).origin === 'https://chat.x.com'; } catch (_) { return false; }
    }) };
  const visible = (node) => !node.closest('[hidden], [aria-hidden="true"], [inert]');
  const hash = (value) => {
    let result = 2166136261;
    for (let i = 0; i < value.length; i++) result = Math.imul(result ^ value.charCodeAt(i), 16777619);
    return (result >>> 0).toString(36);
  };
  const href = (node) => {
    try {
      const value = node.getAttribute('href');
      if (!value) return '';
      const link = new URL(value, node.ownerDocument.baseURI);
      const pathname = link.pathname.replace(/\/$/, '');
      if (chatPage && link.origin === 'https://chat.x.com' && /^\/(?:i\/chat\/|messages\/|chat\/|conversation\/)?[A-Za-z0-9_-]*\d[A-Za-z0-9_-]*$/.test(pathname)) {
        return link.origin + pathname;
      }
      return link.origin === location.origin ? pathname : '';
    } catch (_) { return ''; }
  };
  const avatar = (node) => Array.from(node.querySelectorAll('img')).map((image) => image.currentSrc || image.src)
    .find((src) => /^https:\/\/pbs\.twimg\.com\/(?:profile_images|default_profile_images)\//.test(src)) || '';
  const clock = (node) => text(node.querySelector('time, [data-testid="timestamp"]'), 80);
  const cleanId = (value) => /^[A-Za-z0-9:_-]{1,160}$/.test(value || '') ? value : '';
  const nodes = (scope, selector) => Array.from(scope.querySelectorAll(selector))
    .filter((node) => visible(node) && !node.parentElement?.closest(selector));
  const heading = root.querySelector('h1, [role="heading"][aria-level="1"], h2');
  page.title = text(heading, 160);

  if (notificationPage) {
    const timeline = Array.from(document.querySelectorAll('[role="tablist"]')).find((list) =>
      visible(list) && (list.querySelector('[role="tab"][href^="/notifications"]') ||
        /notifications|通知/i.test(list.getAttribute('aria-label') || '')));
    if (notificationCategory) {
      const categories = {
        '/notifications': /^(?:all|全部|所有)$/i,
        '/notifications/verified': /^(?:verified|priority|已认证|已認證|优先|優先)$/i,
        '/notifications/mentions': /^(?:mentions|提及)$/i
      };
      const tabs = Array.from(timeline?.querySelectorAll('[role="tab"]') || []).filter(visible);
      const tab = tabs.find((item) => (href(item) || href(item.querySelector('a[href]') || item)) === notificationCategory) ||
        tabs.find((item) => categories[notificationCategory]?.test(item.getAttribute('aria-label') || text(item, 80))) ||
        (tabs.length === 3 ? tabs[Object.keys(categories).indexOf(notificationCategory)] : null);
      if (tab && tab.getAttribute('aria-selected') !== 'true') {
        const previous = window.__qwitterNotificationSelection;
        if (!previous || previous.tab !== tab || Date.now() - previous.at > 3500) {
          window.__qwitterNotificationSelection = { tab, at: Date.now() };
          tab.click();
        }
        return null;
      }
      if (!tab && path !== notificationCategory) return null;
      if (tab && window.__qwitterNotificationSelection?.tab === tab) {
        delete window.__qwitterNotificationSelection;
        return null;
      }
    }
    root = document.querySelector('[data-testid="primaryColumn"]') || root;
    const candidates = nodes(root, '[data-testid="notification"], [data-testid="notification-cell"], article, [role="article"], [data-testid="cellInnerDiv"]');
    const seen = new Set();
    for (const node of candidates.slice(0, 90)) {
      const itemSelector = '[data-testid="notification"], [data-testid="notification-cell"], article, [role="article"]';
      const item = node.matches(itemSelector) ? node : node.querySelector(itemSelector);
      if (!item) continue;
      const titleNode = item.querySelector('[data-testid="notificationText"], [data-testid="notification-text"], [data-testid="User-Name"]');
      const note = text(titleNode || item, 1500) || (item.getAttribute('aria-label') || '').slice(0, 1500);
      if (!note) continue;
      const links = [node, ...node.querySelectorAll('a[href]')].map(href);
      const status = links.map((value) => value.match(/^(\/(?:[A-Za-z0-9_]{1,15}|i\/web)\/status\/\d{1,24})(?:\/(?:photo|video)\/\d+)?$/)?.[1])
        .find(Boolean);
      const target = status ||
        links.find((value) => /^\/[A-Za-z0-9_]{1,15}$/.test(value) && !/^\/(?:home|explore|settings|notifications)$/i.test(value)) || '';
      const isPost = item.matches('article, [role="article"]');
      if (isPost && !status && !item.hasAttribute('data-notification-id') && !item.querySelector('[data-testid="tweetText"]')) continue;
      const time = clock(node);
      const notificationId = cleanId(item.getAttribute('data-notification-id'));
      const id = isPost && status && !notificationId ? 'n:post:' + status.split('/').pop() :
        'n:' + (notificationId || hash([target, note, time].join('\n')));
      if (seen.has(id)) continue;
      seen.add(id);
      const excerpt = text(item.querySelector('[data-testid="tweetText"]'), 1500);
      page.rows.push({ id, title: note.split('\n')[0].slice(0, 160), text: excerpt && excerpt !== note ? excerpt :
        note.includes('\n') ? note.split('\n').slice(1).join('\n') : '',
        path: target, avatar: avatar(item), time, unread: item.getAttribute('data-unread') === 'true',
        kind: isPost ? 'notification-post' : 'notification' });
    }
    page.empty = !page.rows.length && !!root.querySelector('[data-testid="emptyState"], [data-testid="empty_state_header_text"]');
    return page;
  }

  const gate = Array.from(root.querySelectorAll(
    'input[type="password"], input[autocomplete="one-time-code"], input[data-testid*="passcode" i], [data-testid*="passcode" i] input'
  )).find(visible);
  const pinFields = [...root.querySelectorAll('input[inputmode="numeric"][maxlength="1"]')].filter(visible);
  const gateLabel = text(root.querySelector('[role="dialog"] h1, [role="dialog"] h2, h1, h2'), 160);
  if ((gate && visible(gate)) || pinFields.length >= 4 ||
    /(?:enter|create|set up|forgot).{0,20}(?:pin|passcode)|(?:输入|輸入|設定|设置).{0,10}(?:PIN|密码|密碼|通行碼)/i.test(gateLabel)) {
    page.locked = true;
    return page;
  }
  const conversationPath = /^(?:\/(?:i\/chat|messages)\/|https:\/\/chat\.x\.com\/(?:i\/chat\/|messages\/|chat\/|conversation\/)?)(?=[A-Za-z0-9_-]{0,127}\d)[A-Za-z0-9_-]{1,128}$/i;
  const optionSelector = '[role="option"], [data-testid="conversation"], [data-testid="conversation-item"], ' +
    '[data-testid="conversationItem"], [data-testid="conversationEntry"], [data-testid="dmConversationEntry"], ' +
    '[data-testid="xchat-conversation-item"], [data-conversation-id], a[href*="/messages/"], a[href*="/i/chat/"], a[href^="https://chat.x.com/"]' +
    (chatOrigin ? ', a[href^="/"]' : '');
  const conversations = nodes(root, optionSelector).filter((node) =>
    !node.closest('[role="log"], nav, [role="navigation"]') &&
    (!node.matches('a[href]') || conversationPath.test(href(node))));
  if (!conversations.length && !conversationPath.test(chatOrigin ? location.origin + path : path)) {
    const candidates = Array.from(root.querySelectorAll('[role="listitem"], [role="button"], button, [tabindex="0"]'))
      .filter((node) => {
        if (!visible(node) || node.closest('nav, [role="navigation"], [role="log"], form, header')) return false;
        const lines = text(node, 1200).split(/\n+/).filter(Boolean);
        const identity = avatar(node) || node.querySelector('img, [role="img"], [data-testid*="avatar" i]');
        return !!identity && lines.length >= 2 && lines.length <= 6;
      });
    const matches = new Set(candidates);
    for (const node of candidates) {
      let nested = false;
      for (let parent = node.parentElement; parent; parent = parent.parentElement) {
        if (matches.has(parent)) {
          nested = true;
          break;
        }
      }
      if (!nested) conversations.push(node);
    }
  }
  const known = new Set();
  for (const node of conversations.slice(0, 100)) {
    const links = [node, ...node.querySelectorAll('a[href]')].map(href);
    const target = links.find((value) => conversationPath.test(value)) || '';
    const lines = text(node, 1200).split(/\n+/).map((value) => value.trim()).filter(Boolean);
    const explicitName = node.querySelector('[data-testid="User-Name"], [data-testid="conversation-name"], ' +
      '[data-testid="conversationName"], [data-testid="conversationTitle"], [data-testid="dmConversationName"]');
    const title = text(explicitName, 150) || lines[0] || (node.getAttribute('aria-label') || '').slice(0, 150);
    const picture = avatar(node);
    if (!title) continue;
    const key = 'c:' + (cleanId(target.split('/').pop()) || cleanId(node.getAttribute('data-conversation-id')) || hash(title + '\n' + picture));
    if (known.has(key)) continue;
    known.add(key);
    if (openKey && key === openKey) {
      window.__qyxChatOpened = { key, from: path, to: '' };
      node.click();
      page.opened = true;
      return page;
    }
    if (node.getAttribute('aria-selected') === 'true' || node.getAttribute('data-selected') === 'true') page.conversation = key;
    page.rows.push({ id: key, title, text: lines.slice(1).join('\n').slice(0, 600), time: clock(node),
      avatar: picture, path: target, unread: node.getAttribute('data-unread') === 'true', kind: 'chat' });
  }
  const messageLog = scopes.map((scope) => scope.querySelector('[role="log"]'))
    .find((log) => log && visible(log) && log.querySelector('article, [role="article"], [role="listitem"]'));
  const messages = nodes(messageLog || root, '[data-message-id], [data-testid="messageEntry"], [data-testid="message-entry"], ' +
    '[data-testid="chat-message"], [data-testid="message-bubble"], [data-testid="chatMessage"], ' +
    '[data-testid="dmMessageEntry"], [data-testid="xchat-message"], [role="log"] [role="listitem"], ' +
    '[role="log"] article, [role="log"] [role="article"]');
  const messagePath = messageLog?.ownerDocument.location?.pathname.replace(/\/$/, '') || path;
  const qualify = (pathname) => chatOrigin ? location.origin + pathname : pathname;
  const conversationRoute = conversationPath.test(qualify(messagePath)) ? messagePath : path;
  const routeKey = conversationPath.test(qualify(conversationRoute)) ? conversationRoute.split('/').pop() : '';
  const shape = [document.querySelectorAll('iframe').length, root.querySelectorAll('img').length,
    root.querySelectorAll('[role="button"], button').length, conversations.length, messages.length].join(':');
  if (window.__qyxChatShape !== shape) {
    window.__qyxChatShape = shape;
    console.info('qyx-chat-dom:' + shape);
  }
  if (!page.conversation && routeKey) page.conversation = 'c:' + routeKey;
  const opened = window.__qyxChatOpened;
  if (opened && routeKey && conversationRoute !== opened.from) {
    if (!opened.to) opened.to = conversationRoute;
    if (opened.to === conversationRoute) page.conversation = opened.key;
  }
  const clockLabel = /^(?:(?:上午|下午|凌晨|中午)\s*)?\d{1,2}[:：]\d{2}(?::\d{2})?(?:\s*[ap]\.?m\.?)?$/i;
  const clockSuffix = /(?:^|\s)(?:(?:上午|下午|凌晨|中午)\s*)?\d{1,2}[:：]\d{2}(?::\d{2})?(?:\s*[ap]\.?m\.?)?$/i;
  const calendarLabel = /(?:\d{1,2}\s*月\s*\d{1,2}\s*[日号號]|^\d{1,4}[./-]\d{1,2}[./-]\d{1,4}\b|\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d{1,2}\b)/i;
  const senderSelector = '[data-testid="message-sender"], [data-sender-name]';
  const messageBox = messageLog || root.host || root;
  const messageBounds = messageBox.getBoundingClientRect();
  const rtl = messageBox.ownerDocument.defaultView?.getComputedStyle(messageBox).direction === 'rtl';
  const fromSelf = (node) => {
    const flag = node.getAttribute('data-outgoing') ?? node.getAttribute('data-is-sent');
    if (flag === 'true' || flag === 'false') return flag === 'true';
    const rect = node.getBoundingClientRect();
    if (!rect.width || !messageBounds.width) return undefined;
    const difference = rect.left - messageBounds.left - (messageBounds.right - rect.right);
    if (Math.abs(difference) < messageBounds.width * 0.05) return undefined;
    return rtl ? difference < 0 : difference > 0;
  };
  const precedingLabels = (node) => {
    const result = { sender: '', date: '' };
    const rect = node.getBoundingClientRect();
    for (let branch = node; branch && branch !== messageLog && branch !== root; branch = branch.parentElement) {
      let sibling = branch.previousElementSibling;
      for (let count = 0; sibling && count < 4; count++, sibling = sibling.previousElementSibling) {
        if (!visible(sibling)) continue;
        if (sibling.matches('article, [role="article"], [data-message-id]') ||
          sibling.querySelector('article, [role="article"], [data-message-id]')) break;
        const label = text(sibling, 161);
        if (!label || label.length > 160 || label.includes('\n')) continue;
        if (calendarLabel.test(label)) {
          if (!result.date) result.date = label.replace(/[，,]?\s*(?:上午|下午|凌晨|中午)?\s*\d{1,2}[:：]\d{2}(?:\s*[ap]\.?m\.?)?$/i, '').trim();
          break;
        }
        const named = sibling.matches(senderSelector) ? sibling : sibling.querySelector(senderSelector);
        const leaf = Array.from(sibling.querySelectorAll('span, div, p, bdi')).find((child) =>
          !child.childElementCount && text(child, 161) === label) || sibling;
        const labelRect = leaf.getBoundingClientRect();
        const aligned = rect.width > 0 && labelRect.width > 0 && labelRect.bottom <= rect.top + 3 &&
          rect.top - labelRect.bottom < 84 && Math.abs(labelRect.left - rect.left) < messageBounds.width * 0.15;
        if (!result.sender && (named || (aligned && !clockLabel.test(label) && !sibling.querySelector('button, input, img, [role="group"]')))) {
          result.sender = named ? (named.getAttribute('data-sender-name') || text(named, 150)) : label;
        }
      }
    }
    return result;
  };
  const seen = new Set();
  const messageAvatar = (node, bodyNode) => {
    for (let parent = node, depth = 0; parent && parent !== messageLog && parent !== root && depth < 4;
      parent = parent.parentElement, depth++) {
      if (parent !== node && messages.some((other) => other !== node && parent.contains(other))) break;
      const images = Array.from(parent.querySelectorAll('img')).filter((image) => !bodyNode?.contains(image) &&
        !image.closest('[data-testid*="quote" i], [data-testid*="attachment" i]'));
      const pictures = new Set(images.map((image) => image.currentSrc || image.src)
        .filter((src) => /^https:\/\/pbs\.twimg\.com\/(?:profile_images|default_profile_images)\//.test(src)));
      if (pictures.size === 1) return pictures.values().next().value;
      if (pictures.size > 1) break;
    }
    return '';
  };
  let senderInGroup = '';
  let currentDate = '';
  for (const node of messages.slice(-120)) {
    const bodyNode = node.querySelector('[data-testid="message-text"], [data-testid="messageText"], [data-message-text]');
    const original = text(bodyNode || node, 4000);
    if (!original) continue;
    const senderNode = node.querySelector(senderSelector);
    const oldSender = text(senderNode, 150);
    const oldTime = clock(node);
    const labels = precedingLabels(node);
    if (labels.date && labels.date !== currentDate) {
      currentDate = labels.date;
      senderInGroup = '';
    }
    const fullText = (node.textContent || '').trim();
    const tailClock = Array.from(node.querySelectorAll('*')).reverse().find((child) => {
      const label = text(child, 80);
      return !child.childElementCount && !bodyNode?.contains(child) && clockLabel.test(label) &&
        fullText.endsWith(label) && fullText !== label;
    });
    const referencedLabel = (attribute) => (node.getAttribute(attribute) || '').split(/\s+/)
      .map((id) => text(node.getRootNode().getElementById?.(id), 4200)).join(' ').trim();
    const accessibleLabels = [node.getAttribute('aria-label'), referencedLabel('aria-labelledby'),
      referencedLabel('aria-describedby'), node.getAttribute('title')];
    const accessibleLabel = accessibleLabels.find((label) => label && clockSuffix.test(label.trim()))?.trim() || '';
    const accessibleClock = accessibleLabel.match(clockSuffix);
    const clockText = oldTime || text(tailClock, 80) || accessibleClock?.[0].trim() || '';
    const time = clockText && currentDate ? currentDate + ' ' + clockText : clockText;
    const body = !bodyNode && clockText && original !== clockText && original.endsWith(clockText) ?
      original.slice(0, -clockText.length).trimEnd() : original;
    const prefix = accessibleClock ? accessibleLabel.slice(0, accessibleClock.index).trim() : '';
    const normalizedBody = body.replace(/\s+/g, ' ');
    const namedByLabel = prefix && prefix.length <= 150 && !prefix.includes('\n') &&
      !normalizedBody.includes(prefix) && !prefix.includes(normalizedBody) ? prefix : '';
    const self = fromSelf(node);
    const outgoing = self ?? /^(?:我|你|you)$/i.test(namedByLabel);
    if (outgoing) senderInGroup = '';
    const sender = senderNode?.getAttribute('data-sender-name') || oldSender || labels.sender || namedByLabel || senderInGroup;
    if (!outgoing) senderInGroup = sender;
    // Use the previous ID inputs so old cached rows are enriched in place.
    const id = 'm:' + (cleanId(node.getAttribute('data-message-id')) || hash([oldSender, oldTime, original].join('\n')));
    if (seen.has(id)) continue;
    seen.add(id);
    page.messages.push({ id, title: sender, text: body, time, avatar: messageAvatar(node, bodyNode), path: '', kind: 'message',
      outgoing });
  }
  page.messages = page.messages.slice(-100);
  page.empty = !page.rows.length && !!root.querySelector('[data-testid="emptyState"], [data-testid="empty_state_header_text"]');
  return page;
})(typeof qyxNotificationCategory === 'string' ? '' : (typeof qyxInboxOpenKey === 'string' ? qyxInboxOpenKey : ''),
  typeof qyxNotificationCategory === 'string' ? qyxNotificationCategory : '')
