((discoverAccount = false, requestedHomeTab = -1, translationTarget = '', translationLabel = '', openQuoteOf = '',
  likeAction = null, translationPostId = '', knownTranslationIds = []) => {
  // This script reads rendered elements and handles explicit actions from the reader.
  if (location.origin !== 'https://x.com' &&
    !(location.origin === 'https://chat.x.com' && typeof qyxInboxResult === 'object' && qyxInboxResult)) return '';
  const find = (root, id) => root.querySelector('[data-testid="' + id + '"]');
  const text = (node, max = 4000) => (node?.innerText ?? node?.textContent ?? '').trim().slice(0, max);
  const bodyText = (root, max = 4000) => {
    if (!root) return '';
    const chunks = [];
    const read = (node) => {
      if (node.nodeType === 3) { chunks.push(node.nodeValue); return; }
      if (node.nodeType !== 1 || node.matches('[hidden], [aria-hidden="true"], script, style')) return;
      if (node.matches('br')) { chunks.push('\n'); return; }
      if (node.matches('img[alt]')) { chunks.push(node.alt); return; }
      if (node.matches('a[href]')) {
        const label = (node.innerText ?? node.textContent ?? '').trim().replace(/[\u200b\u2060]/g, '');
        const compact = label.replace(/[ \t]*\r?\n[ \t]*/g, '');
        const looksLikeAddress = /^(?:https?:\/\/|www\.|[\w.-]+\.[a-z]{2,}(?:[/:?#…]|$))/i.test(compact);
        if (looksLikeAddress) {
          chunks.push(compact);
          return;
        }
        chunks.push(label.replace(/[ \t]*\r?\n[ \t]*/g, ' '));
        return;
      }
      const paragraph = node !== root && node.matches('p, blockquote, li, div');
      if (paragraph && chunks.length && !chunks.at(-1).endsWith('\n')) chunks.push('\n');
      for (const child of node.childNodes) read(child);
      if (paragraph && chunks.length && !chunks.at(-1).endsWith('\n')) chunks.push('\n');
    };
    read(root);
    return chunks.join('').replace(/(https?:\/\/)[ \t]*\r?\n[ \t]*(?=[\w.-]+\.[a-z])/gi, '$1').trim().slice(0, max);
  };
  const bodyLinks = (root) => {
    const links = [];
    for (const anchor of root?.querySelectorAll?.('a[href]') || []) {
      if (links.length >= 32 || anchor.closest('[hidden], [aria-hidden="true"]')) continue;
      const label = bodyText(anchor, 400);
      if (!label) continue;
      try {
        const url = new URL(anchor.getAttribute('href'), location.origin);
        if (!/^https?:$/.test(url.protocol) || url.username || url.password || url.href.length > 2000) continue;
        const handle = /^@([A-Za-z0-9_]{1,15})$/.exec(label)?.[1];
        if (handle && /^(?:x\.com|(?:www\.)?twitter\.com)$/i.test(url.hostname) &&
          url.pathname.replace(/\/$/, '').toLowerCase() === '/' + handle.toLowerCase()) {
          links.push({ label, target: '@' + handle });
        } else if (!label.startsWith('#')) {
          links.push({ label, target: url.href });
        }
      } catch (_) {}
    }
    return links.length ? links : undefined;
  };
  const pathOf = (anchor) => {
    if (!anchor) return '';
    try {
      const url = new URL(anchor.getAttribute('href'), location.origin);
      return url.origin === location.origin ? url.pathname.replace(/\/$/, '') || '/' : '';
    } catch (_) {
      return '';
    }
  };
  const profileCdn = /^https:\/\/pbs\.twimg\.com\/(?:profile_images|default_profile_images)\//;
  const profileSource = (node) => {
    const background = node.style?.backgroundImage || getComputedStyle(node).backgroundImage;
    const inline = background?.match(/url\(\s*['"]?(https:\/\/pbs\.twimg\.com\/[^'"()\s]+)['"]?\s*\)/)?.[1];
    return inline?.slice(0, 600) || '';
  };
  const imageUrl = (img, folder) => {
    if (!img) return '';
    const candidates = [img.currentSrc, img.src, img.getAttribute('data-src'), img.getAttribute('data-lazy-src'),
      ...['srcset', 'data-srcset'].flatMap((attr) =>
        (img.getAttribute(attr) || '').split(',').map((candidate) => candidate.trim().split(/\s+/)[0]))];
    return candidates.find((src) => folder === 'profile_images' ? profileCdn.test(src || '') :
      src?.startsWith('https://pbs.twimg.com/' + folder + '/'))?.slice(0, 600) || '';
  };
  const avatarIn = (root, allow) => {
    if (!root) return '';
    const nodes = Array.from(root.querySelectorAll('img, [style*="background-image"], [role="img"]'));
    for (const node of nodes) {
      if (!allow(node)) continue;
      const src = imageUrl(node, 'profile_images') || profileSource(node);
      if (profileCdn.test(src)) return src;
    }
    return '';
  };
  const immersiveVideo = /^\/(?:[A-Za-z0-9_]{1,15}|i\/web)\/status\/\d{1,24}\/mediaViewer\/?$/.test(location.pathname);
  const videoTab = /^\/i\/video\/?$/.test(location.pathname);
  const legacyPrimary = find(document, 'primaryColumn');
  const primary = immersiveVideo ? document.querySelector('[data-testid="vss-scroll-view"]:has([data-testid^="cellInnerDiv-tweet-"])') ||
    find(document, 'modalContainer') ||
    document.querySelector('[role="dialog"]:has([data-testid^="cellInnerDiv-tweet-"])') :
    legacyPrimary || document.querySelector('main, [role="main"]');
  const chromeLinks = Array.from(document.querySelectorAll('nav a, [role="navigation"] a, header a, [role="banner"] a'))
    .filter((anchor) => !anchor.closest('article'));
  const chromePaths = new Set(chromeLinks.map(pathOf));
  const tabs = Array.from(document.querySelectorAll('[role="tab"]'))
    .filter((tab) => !tab.closest('article, [hidden]'));
  const tabLabel = (tab) => (tab.getAttribute('aria-label') || text(tab, 100)).replace(/\s+/g, '').toLowerCase();
  const matchesTab = (tab, labels) => labels.some((label) => {
    const actual = tabLabel(tab);
    return actual === label || actual === label + label;
  });
  const home = /^\/home\/?$/.test(location.pathname) ||
    (location.pathname === '/' && chromePaths.has('/home'));
  const search = /^\/search\/?$/.test(location.pathname);
  const peopleSearch = search && new URLSearchParams(location.search).get('f') === 'user';
  const profilePath = home || search || /^\/(?:explore|notifications|settings|login|logout|i)\/?$/.test(location.pathname) ?
    null : location.pathname.match(/^\/([A-Za-z0-9_]{1,15})(?:\/(with_replies|reposts|media(?:\/grid)?|likes|articles|highlights|subs|photos|videos))?\/?$/);
  const accountMenuLabel = /^(?:account menu|profile menu|个人资料菜单|个人资料选单|個人資料選單|個人檔案選單|帐号菜单|账号菜单|帳戶選單|帳號選單)(?:[ :：]|$)/i;
  const isAccountMenu = (node) => accountMenuLabel.test(node.getAttribute('aria-label') || '');
  const accountTrigger = Array.from(document.querySelectorAll('header [aria-label], [role="banner"] [aria-label], [aria-haspopup][aria-label]'))
    .find(isAccountMenu);
  const accountDialogs = Array.from(document.querySelectorAll('[role="dialog"], [role="menu"], dialog, aside[aria-label]'));
  const accountMenu = accountDialogs.find(isAccountMenu) || accountDialogs.find((node) =>
    node.querySelector('a[href="/account/switch"]') || node.querySelector('a[href$="/following"] img'));
  const accountLinks = accountMenu ? Array.from(accountMenu.querySelectorAll('a[href]')) : [];
  const accountName = (accountTrigger?.getAttribute('aria-label') || '').replace(accountMenuLabel, '').trim().slice(0, 80);
  const isProfileLink = (link) => /^\/[A-Za-z0-9_]{1,15}$/.test(pathOf(link));
  const accountProfile = accountLinks.find((link) => isProfileLink(link) && (link.querySelector('img[src*="/profile_images/"]') ||
      text(link, 180).toLowerCase().includes('@' + pathOf(link).slice(1).toLowerCase())));
  const inboxPage = typeof qyxInboxResult === 'object' && !!qyxInboxResult;
  const profileLink = find(document, 'AppTabBar_Profile_Link') || accountProfile || (!inboxPage ? chromeLinks.find((anchor) =>
    /^(profile|my profile|个人资料|個人資料|個人檔案|个人主页)$/i.test(anchor.getAttribute('aria-label') || text(anchor, 80))) : null);
  const ownPath = pathOf(profileLink);
  const followingPath = accountLinks.map(pathOf).find((path) =>
    /^\/[A-Za-z0-9_]{1,15}\/(?:following|followers|verified_followers)$/.test(path));
  const accountAvatarHandle = accountTrigger?.querySelector('img[alt^="@"]')?.alt.match(/^@([A-Za-z0-9_]{1,15})$/)?.[1];
  const ownHandle = isProfileLink(profileLink) ? ownPath.slice(1) : (followingPath?.split('/')[1] || accountAvatarHandle || '');
  const onboarding = '/i/jf/onboarding/web';
  const loginRoute = /^\/(?:i\/jf\/onboarding|login|logout)(?:\/|$)/.test(location.pathname) ||
    /^\/i\/flow\/(?:login|signup|challenge|single_sign_on|password_reset)(?:\/|$)/.test(location.pathname) ||
    /^\/account\/(?:access|login[-_][a-z_]+|begin_password_reset|confirm_email)(?:\/|$)/.test(location.pathname);
  const hasReaderNav = chromePaths.has('/home') && chromePaths.has('/notifications') &&
    (chromePaths.has('/messages') || chromePaths.has('/i/chat') || chromePaths.has('/compose/post'));
  const hasLoginLink = Array.from(document.querySelectorAll('a[href*="/i/jf/onboarding/web"][href*="mode=login"]'))
    .some((anchor) => pathOf(anchor) === onboarding);
  const inbox = typeof qyxInboxResult === 'object' ? qyxInboxResult : null;
  const authenticated = !loginRoute && !hasLoginLink && !!(ownHandle || inbox?.rows?.length || inbox?.messages?.length || inbox?.locked ||
    inbox?.empty ||
    find(document, 'SideNav_AccountSwitcher_Button') ||
    find(document, 'SideNav_NewTweet_Button') || find(document, 'tweetButtonInline') || accountTrigger ||
    (primary && (hasReaderNav || (home && tabs.length >= 2 && primary.querySelector('article')) ||
      (immersiveVideo && primary.querySelector('[data-testid^="cellInnerDiv-tweet-"] video')))));
  const signedOut = !authenticated && (loginRoute || hasLoginLink ||
    !!document.querySelector('[data-testid="loginButton"], [data-testid="BottomBar"] a[href^="/i/flow/login"]'));
  const accountButton = find(document, 'SideNav_AccountSwitcher_Button');
  const accountImage = accountButton?.querySelector('img[src*="/profile_images/"]') ||
    profileLink?.querySelector('img[src*="/profile_images/"]') ||
    accountTrigger?.querySelector('img[src*="/profile_images/"]') ||
    (ownHandle && Array.from(document.querySelectorAll('header img[src*="/profile_images/"]'))
      .find((img) => img.alt.toLowerCase() === '@' + ownHandle.toLowerCase()));
  let accountMenuPending = false;
  if (discoverAccount && authenticated && home) {
    if (!ownHandle && !accountMenu && accountTrigger && !window.__qyxAccountProbe) {
      window.__qyxAccountProbe = Date.now();
      accountTrigger.click();
      accountMenuPending = true;
    } else if (window.__qyxAccountProbe && window.__qyxAccountProbe !== -1) {
      accountMenuPending = !ownHandle && Date.now() - window.__qyxAccountProbe < 2200;
      if (!accountMenuPending) {
        window.__qyxAccountProbe = -1;
        accountMenu?.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
        if (accountMenu?.isConnected) {
          accountMenu.dispatchEvent(new KeyboardEvent('keyup', { key: 'Escape', bubbles: true }));
        }
      }
    }
  }
  const discovery = [];
  if (authenticated && (home || peopleSearch || location.pathname.startsWith('/explore'))) {
    const sidebar = find(document, 'sidebarColumn');
    const sources = peopleSearch ? [primary].filter(Boolean) : home ? [sidebar].filter(Boolean) : [primary, sidebar].filter(Boolean);
    const sponsored = (node) => !!node.querySelector('[data-testid="placementTracking"], [data-testid="promotedIndicator"]') ||
      Array.from(node.querySelectorAll('span')).some((label) =>
        /^(?:promoted(?: by .+)?|sponsored|ad|广告|廣告|推广|推廣|已推广|已推廣)$/i.test(text(label, 100)));
    const rows = [];
    const seen = new Set();
    for (const trend of sources.flatMap((source) => Array.from(source.querySelectorAll('[data-testid="trend"], [data-testid="trendItem"]')))) {
      if (rows.length >= 10 || sponsored(trend)) continue;
      const lines = (trend.innerText ?? trend.textContent ?? '').split(/\n+/).map((line) => line.trim()).filter(Boolean);
      const title = text(trend.querySelector('[data-testid="trendName"], [dir="ltr"]'), 160) ||
        (lines.length > 1 ? lines[1] : lines[0]);
      if (!title || seen.has(title)) continue;
      seen.add(title);
      rows.push({ title, subtitle: lines.filter((line) => line !== title).join(' · ').slice(0, 180), query: title });
    }
    const isUS = (row) => /^(?:united states|u\.?s\.?a?\.?|美国|美國)(?:\s|$)|(?:in the united states|in united states|美国的趋势|美國的趨勢)/i.test(row.subtitle);
    const local = rows.filter((row) => !isUS(row));
    const us = rows.filter(isUS);
    if (local.length) discovery.push({ kind: 'trends', title: '', rows: local });
    if (us.length) discovery.push({ kind: 'us', title: '', rows: us });
    const accounts = [];
    for (const cell of sources.flatMap((source) => Array.from(source.querySelectorAll('[data-testid="UserCell"]')))) {
      if (accounts.length >= (peopleSearch ? 64 : 5) || sponsored(cell)) continue;
      const path = Array.from(cell.querySelectorAll('a[href]')).map(pathOf)
        .find((path) => /^\/[A-Za-z0-9_]{1,15}$/.test(path));
      if (!path || seen.has(path)) continue;
      const nameLink = Array.from(cell.querySelectorAll('a[href]')).find((link) => pathOf(link) === path &&
        text(link, 160) && !text(link, 160).startsWith('@'));
      const title = (text(cell.querySelector('[data-testid="User-Name"]') || nameLink, 160)
        .split('\n')[0].replace(new RegExp('@' + path.slice(1) + '$', 'i'), '').trim()) || path.slice(1);
      const description = peopleSearch ? text(cell.querySelector('[data-testid="UserDescription"]') ||
        Array.from(cell.querySelectorAll('div[dir="auto"]')).find((node) =>
          !node.closest('a, button') && node.getAttribute('role') !== 'button' && text(node, 300) !== title), 280) : '';
      seen.add(path);
      accounts.push({ title, subtitle: '@' + path.slice(1) + (description ? '\n' + description : ''), path,
        avatar: avatarIn(cell, () => true), verified: !!cell.querySelector('[data-testid="icon-verified"]') });
    }
    if (accounts.length) discovery.push({ kind: 'people', title: '', rows: accounts });
    if (/^\/explore\/tabs\/sports\/?$/i.test(location.pathname) && rows.length) {
      discovery.length = 0;
      discovery.push({ kind: 'sports', title: '', rows });
    }
    for (const section of sources.flatMap((source) => Array.from(source.querySelectorAll('section, [role="region"], aside, [data-testid="sportsWidget"]')))) {
      if (discovery.length >= 7 || section.querySelector('[data-testid="trend"], [data-testid="trendItem"], [data-testid="UserCell"]') ||
        sponsored(section)) continue;
      const title = text(section.querySelector('h1,h2,h3,[role="heading"]'), 120);
      if (!title || seen.has(title)) continue;
      const items = [];
      for (const anchor of section.querySelectorAll('a[href]')) {
        if (items.length >= 5) break;
        const path = pathOf(anchor);
        const label = text(anchor, 160);
        if (!label || !/^\/(?:i\/(?:premium_sign_up|verified-choose|spaces\/[A-Za-z0-9_-]+|events\/\d+|topics\/\d+)|premium|explore\/tabs\/[A-Za-z0-9_-]+|[A-Za-z0-9_]{1,15}\/status\/\d+)$/.test(path) ||
          items.some((item) => item.path === path)) continue;
        items.push({ title: label, path });
      }
      const sport = /sports|nfl|nba|mlb|nhl|体育|體育/i.test(title);
      if (sport && !items.length) {
        for (const event of section.querySelectorAll('li, [role="listitem"], [data-testid="sportsGame"]')) {
          if (items.length >= 5) break;
          const label = text(event, 160).replace(/\n+/g, ' · ');
          if (label && !items.some((item) => item.title === label)) items.push({ title: label });
        }
      }
      if (!items.length) continue;
      seen.add(title);
      discovery.push({ kind: sport ? 'sports' : 'other', title, rows: items });
    }
  }
  const params = new URLSearchParams(location.search);
  const snapshot = {
    path: home ? '/home' : location.pathname,
    query: params.get('q') || '',
    latestSearch: search && params.get('f') === 'live',
    searchMode: ({ live: 'latest', user: 'people', video: 'videos', image: 'photos' })[params.get('f')] || 'top',
    documentLanguage: document.documentElement.lang || '',
    documentTime: search ? performance.timeOrigin : 0,
    authenticated,
    signedOut,
    ownHandle,
    ownName: accountName,
    accountMenuPending,
    ownAvatar: imageUrl(accountImage, 'profile_images'),
    homeTab: -1,
    empty: !!(primary && (find(primary, 'emptyState') || (search && find(primary, 'empty_state_header_text')))),
    pageError: !!(primary && find(primary, 'error-detail')),
    posts: [],
    profile: null,
    inbox,
    discovery
  };
  if (inbox) return JSON.stringify(snapshot);
  if (!authenticated || !primary) return JSON.stringify(snapshot);

  if (home) {
    const labels = [
      ['foryou', '为你推荐', '為你推薦', '推荐', '推薦', '为您推荐', '為您推薦'],
      ['following', '正在关注', '正在關注', '关注中', '關注中', '关注中的', '關注中的', '关注', '關注']
    ];
    const namedTabs = labels.map((names) => tabs.find((tab) => matchesTab(tab, names)));
    const selected = namedTabs.find((tab) => tab?.getAttribute('aria-selected') === 'true') ||
      tabs.find((tab) => tab.getAttribute('aria-selected') === 'true');
    const group = selected?.closest('[role="tablist"]');
    const groupTabs = group ? tabs.filter((tab) => group.contains(tab)) : [];
    if (selected) {
      const namedIndex = namedTabs.indexOf(selected);
      snapshot.homeTab = namedIndex >= 0 ? namedIndex : groupTabs.indexOf(selected);
    }
    if (requestedHomeTab >= 0 && requestedHomeTab !== snapshot.homeTab &&
      (requestedHomeTab !== 0 || !!selected || namedTabs.some(Boolean))) {
      const target = namedTabs[requestedHomeTab] || groupTabs[requestedHomeTab];
      const now = Date.now();
      if (target && (window.__qyxHomeTarget !== requestedHomeTab || now - window.__qyxHomeClick > 1800)) {
        window.__qyxHomeTarget = requestedHomeTab;
        window.__qyxHomeClick = now;
        target.focus({ preventScroll: true });
        target.click();
      }
      return JSON.stringify(snapshot);
    }
  }

  const statusPattern = /^\/([A-Za-z0-9_]{1,15})\/status\/(\d{1,24})$/;
  const detailId = location.pathname.match(/^\/(?:[A-Za-z0-9_]{1,15}|i\/web)\/status\/(\d{1,24})\/?$/)?.[1];
  const postNode = 'article, [role="article"]';
  const articles = Array.from(primary.querySelectorAll(legacyPrimary && !search && !profilePath && !videoTab && !immersiveVideo ?
    'article[data-testid="tweet"]' : postNode)).filter((article) => !article.parentElement?.closest(postNode));
  if (immersiveVideo) {
    const cards = Array.from(primary.querySelectorAll('[data-testid^="cellInnerDiv-tweet-"]'));
    if (cards.length) articles.splice(0, articles.length, ...cards.map((card) => card.querySelector(postNode) || card));
  }
  if (search && !articles.length) {
    snapshot.empty ||= Array.from(primary.querySelectorAll(
      '[data-testid="empty_state_header_text"], h1, h2, h3, [role="heading"], [role="status"]'))
      .some((node) => /^(?:no (?:post |search )?results\b|we couldn.t find|没有找到|找不到|未找到|沒有找到|沒有搜尋結果|無搜尋結果)/i
        .test(text(node, 200)));
  }
  const firstVisible = articles.length > 32 ? articles.findIndex((article) =>
    article.getBoundingClientRect().bottom > 0) : 0;
  const first = Math.max(0, firstVisible - 3);
  const quoteSelector = '[data-testid="quoteTweet"], [role="link"]:not(a):has([data-testid="tweetText"]), ' +
    '[role="link"]:not(a):has([data-testid="User-Name"]), ' +
    'a[href*="/status/"]:has([data-testid="User-Name"]), article article, ' +
    '[role="link"]:not(a):has([dir="auto"].whitespace-pre-wrap), ' +
    '[role="link"]:not(a):has(a[href*="/status/"]):has(div[dir="auto"])';
  const ownElement = (article, node) => {
    if (!node || !article.contains(node)) return false;
    const owner = node.closest(postNode);
    if (owner !== article && (!immersiveVideo || owner && article.contains(owner))) return false;
    const quote = node.closest(quoteSelector);
    return !quote || !article.contains(quote) || quote === article;
  };
  const owned = (article, id) => Array.from(article.querySelectorAll('[data-testid="' + id + '"]'))
    .find((node) => ownElement(article, node));
  const isAdvertisement = (container, owns) => {
    const badge = /^(?:ads?|advertisements?|promoted(?: post| tweet)?|sponsored(?: post)?|广告|廣告|推广|推廣|已推广|已推廣)$/i;
    const content = '[data-testid="tweetText"], [dir="auto"].whitespace-pre-wrap, [data-article-part="body"]';
    for (const node of container.querySelectorAll(
      '[data-testid="placementTracking"], [data-testid="promotedIndicator"], [data-testid="adBadge"], [aria-label], span, div')) {
      if (!owns(node) || node.closest(content) || node.closest('a, button, [role="button"], [role="group"]')) continue;
      if (node.matches('[data-testid="placementTracking"], [data-testid="promotedIndicator"], [data-testid="adBadge"]')) return true;
      const label = node.getAttribute('aria-label') || (!node.childElementCount ? text(node, 40) : '');
      if (badge.test(label.trim())) return true;
    }
    return false;
  };
  const likeControl = (article) => {
    const unlike = owned(article, 'unlike');
    const like = owned(article, 'like');
    if (unlike || like) return { node: unlike || like, liked: !!unlike };
    for (const node of article.querySelectorAll('button[aria-label], [role="button"][aria-label]')) {
      if (!ownElement(article, node)) continue;
      const label = node.getAttribute('aria-label').trim().toLowerCase();
      const action = label.split(/[.。]/).at(-1).trim();
      if (/^(?:unlike(?: post)?|取消喜欢|取消喜歡|取消点赞|收回讚|いいねを取り消す|좋아요 취소|je n’aime plus|gefällt mir nicht mehr)$/.test(action)) {
        return { node, liked: true };
      }
      if (/^(?:like(?: post)?|喜欢|喜歡|点赞|讚|いいね|좋아요|j’aime|gefällt mir)$/.test(action)) {
        return { node, liked: node.getAttribute('aria-pressed') === 'true' };
      }
    }
    return null;
  };
  const likeCount = (control) => {
    if (!control) return '';
    const visible = text(control.node, 20);
    return /^[\d.,]+\s?[KMB万萬亿億]?$/.test(visible) ? visible :
      (control.node.getAttribute('aria-label') || '').match(/^\s*([\d.,]+\s?[KMB万萬亿億]?)/i)?.[1]?.trim() || '';
  };
  const postControl = (article, kind) => {
    if (kind === 'like') return likeControl(article);
    const repost = kind === 'repost';
    const active = owned(article, repost ? 'unretweet' : 'removeBookmark');
    const inactive = owned(article, repost ? 'retweet' : 'bookmark');
    if (active || inactive) return { node: active || inactive, liked: !!active };
    for (const node of article.querySelectorAll('button[aria-label], [role="button"][aria-label]')) {
      if (!ownElement(article, node)) continue;
      const label = node.getAttribute('aria-label').trim().toLowerCase().split(/[.。]/).filter(Boolean).at(-1)?.trim() || '';
      const off = repost ? /^(?:undo repost|undo retweet|取消转帖|取消转推|取消轉發|取消轉貼)$/ :
        /^(?:remove (?:from )?bookmarks?|已加入书签|移除书签|删除书签|從書籤移除|移除書籤|取消收藏)$/;
      const on = repost ? /^(?:repost|retweet|转帖|转推|轉發|轉貼)$/ :
        /^(?:bookmark|(?:add|save) (?:to )?bookmarks?|书签|加入书签|添加书签|書籤|加入書籤|收藏)$/;
      if (off.test(label)) return { node, liked: true };
      if (on.test(label)) return { node, liked: node.getAttribute('aria-pressed') === 'true' };
    }
    return null;
  };
  const repostMenuItem = (desired) => {
    const testId = desired ? 'retweetConfirm' : 'unretweetConfirm';
    const exact = desired ? /^(?:repost|retweet|转帖|转推|轉發|轉貼)$/i :
      /^(?:undo repost|undo retweet|取消转帖|取消转推|取消轉發|取消轉貼)$/i;
    return document.querySelector('[data-testid="' + testId + '"]') ||
      Array.from(document.querySelectorAll('[role="menuitem"]')).find((item) => exact.test(text(item, 60)));
  };
  const languageKey = (value) => {
    const tag = (value || '').toLowerCase().replace(/_/g, '-');
    if (/^zh(?:-|$)/.test(tag)) return /hant|-(?:tw|hk|mo)\b/.test(tag) ? 'zh-hant' : 'zh-hans';
    return tag === 'tl' ? 'fil' : tag.split('-')[0];
  };
  const targetLanguage = languageKey(translationTarget);
  const translateHere = !!targetLanguage && languageKey(document.documentElement.lang) === targetLanguage;
  const translationAttempts = window.__qyxTranslationAttempts ||= new WeakMap();
  const knownTranslations = new Set(knownTranslationIds);
  let translationBudget = 3;
  const translatedPost = (article, id, originalNode) => {
    const displayed = bodyText(originalNode);
    const sourceLanguage = originalNode?.getAttribute?.('lang') || '';
    if (!translateHere || !displayed || (translationPostId && translationPostId !== id)) return { body: displayed, sourceLanguage };
    const attempt = translationAttempts.get(article);
    const previous = attempt?.id === id && attempt.target === translationTarget ? attempt : null;
    const body = previous?.original || displayed;
    const controls = Array.from(article.querySelectorAll(
      'button, a, [role="button"], [role="link"], [data-testid="translateTweet"], [data-testid="translatePost"]'))
      .filter((node) => ownElement(article, node));
    const labelOf = (node) => (node.getAttribute('aria-label') || text(node, 90)).trim().toLowerCase();
    if (previous?.translated && displayed !== previous.translated) {
      return { body: displayed, translation: previous.translated, translationLanguage: translationTarget, sourceLanguage };
    }
    const showOriginal = controls.find((node) =>
      /^(?:show original(?: post)?|view original|查看原文|显示原文|檢視原文|顯示原文|查看原始貼文|原文を表示|원문 보기)$/
        .test(labelOf(node)));
    if (showOriginal && !previous) {
      if (translationBudget > 0) {
        translationBudget--;
        translationAttempts.set(article, { id, target: translationTarget, translated: displayed });
        showOriginal.click();
      }
      return { body: displayed, sourceLanguage };
    }
    if (previous?.translated) return { body: displayed, sourceLanguage };
    const candidates = Array.from(article.querySelectorAll(
      '[data-testid="tweetTranslation"], [data-testid="translationText"], [data-testid="translatedTweetText"], ' +
      '[data-testid="tweetText"], div[dir="auto"].whitespace-pre-wrap'))
      .filter((node) => ownElement(article, node));
    const translated = candidates.find((node) => {
      const value = bodyText(node);
      if (!value || value === body) return false;
      const language = languageKey(node.getAttribute('lang') || node.closest('[lang]')?.getAttribute('lang'));
      if (language && language !== targetLanguage) return false;
      if (!previous && !node.matches('[data-testid="tweetTranslation"], [data-testid="translationText"], ' +
        '[data-testid="translatedTweetText"]')) return false;
      return node !== originalNode || !!previous;
    });
    if (translated) return { body, translation: bodyText(translated), translationLanguage: translationTarget };
    const trigger = controls.find((node) => {
      const label = labelOf(node);
      return ['translatetweet', 'translatepost'].includes((node.dataset.testid || '').toLowerCase()) ||
        (!!translationLabel && label === translationLabel.toLowerCase()) ||
        /^(?:translate (?:post|tweet)|show translation|翻译帖子|翻译贴文|翻譯貼文|翻譯推文|顯示翻譯|显示翻译)$/.test(label);
    });
    if (trigger && translationBudget > 0 && !knownTranslations.has(id) && !previous && !trigger.disabled &&
      trigger.getAttribute('aria-disabled') !== 'true') {
      translationBudget--;
      translationAttempts.set(article, { id, target: translationTarget, original: body });
      trigger.click();
    }
    return { body, sourceLanguage };
  };
  const identity = (article) => {
    let time;
    let match;
    const links = Array.from(article.querySelectorAll('a[href]')).filter((a) => ownElement(article, a));
    for (const candidate of article.querySelectorAll('time')) {
      if (!ownElement(article, candidate)) continue;
      const status = pathOf(candidate.closest('a')).match(statusPattern);
      if (status) {
        time = candidate;
        match = status;
        break;
      }
    }
    if (!match && (!legacyPrimary || detailId || search || profilePath || immersiveVideo || videoTab)) {
      const permalink = links.find((a) => statusPattern.test(pathOf(a)) ||
        (immersiveVideo && statusPattern.test(pathOf(a).replace(/\/mediaViewer$/, ''))));
      match = pathOf(permalink).replace(immersiveVideo ? /\/mediaViewer$/ : /$^/, '').match(statusPattern);
      time = permalink;
    }
    if (!match && detailId) {
      const analytics = links.find((link) => pathOf(link).endsWith('/status/' + detailId + '/analytics'));
      match = pathOf(analytics).replace(/\/analytics$/, '').match(statusPattern);
      time = Array.from(article.querySelectorAll('time')).find((node) => ownElement(article, node));
    }
    if (!match && immersiveVideo) {
      const id = article.closest('[data-testid^="cellInnerDiv-tweet-"]')
        ?.getAttribute('data-testid')?.match(/^cellInnerDiv-tweet-(\d{1,24})$/)?.[1];
      const profile = links.find((link) => /^\/[A-Za-z0-9_]{1,15}$/.test(pathOf(link)) &&
        (link.closest('[data-testid="User-Name"], [data-testid="Tweet-User-Avatar"]') ||
        /^@[A-Za-z0-9_]{1,15}$/.test(text(link, 20))));
      const handle = pathOf(profile).slice(1) ||
        text(owned(article, 'User-Name'), 180).match(/@([A-Za-z0-9_]{1,15})\b/)?.[1];
      if (id && handle) match = ('/' + handle + '/status/' + id).match(statusPattern);
    }
    return { time, match, links };
  };
  if (likeAction && /^\d{1,24}$/.test(likeAction.id) && typeof likeAction.desired === 'boolean') {
    const kind = likeAction.kind || 'like';
    if (!['like', 'repost', 'bookmark'].includes(kind)) return JSON.stringify({ status: 'missing' });
    const target = articles.find((article) => identity(article).match?.[2] === likeAction.id);
    const control = target && postControl(target, kind);
    if (!control) return JSON.stringify({ status: 'missing' });
    if (control.liked === likeAction.desired) {
      return JSON.stringify({ status: 'confirmed', liked: control.liked, count: likeCount(control) });
    }
    if (likeAction.click && !control.node.disabled && control.node.getAttribute('aria-disabled') !== 'true') {
      if (kind === 'repost') {
        if (window.__qyxRepostOperation === likeAction.token) {
          const item = repostMenuItem(likeAction.desired);
          if (!item) return JSON.stringify({ status: 'menu' });
          delete window.__qyxRepostOperation;
          item.click();
          return JSON.stringify({ status: 'clicked' });
        }
        window.__qyxRepostOperation = likeAction.token;
        control.node.click();
        return JSON.stringify({ status: 'menu' });
      }
      control.node.click();
      return JSON.stringify({ status: 'clicked' });
    }
    return JSON.stringify({ status: 'waiting' });
  }
  let candidates = articles.slice(first, first + 32);
  if (detailId) {
    const focus = articles.findIndex((article) => identity(article).match?.[2] === detailId);
    if (focus < 0) {
      const previous = window.__qyxDetailRegion;
      if (previous?.id !== detailId || !previous.region.isConnected) return JSON.stringify(snapshot);
      candidates = candidates.filter((article) => previous.region.contains(article) &&
        !previous.ancestors.has(identity(article).match?.[2]));
    } else {
      const region = articles[focus].closest('[role="region"], section[aria-label]') || primary;
      window.__qyxDetailRegion = {
        id: detailId,
        region,
        ancestors: new Set(articles.slice(0, focus).map((article) => identity(article).match?.[2]))
      };
      const start = Math.max(focus + 1, first);
      candidates = [articles[focus], ...articles.slice(start, start + 31)];
    }
  }
  const readReplyParents = () => {
    const count = document.scripts.length;
    if (window.__qyxReplyParents?.count === count) return window.__qyxReplyParents.parents;
    const parents = new Map();
    for (const script of document.scripts) {
      const content = script.textContent || '';
      if (!content.includes('threaded_conversation_with_injections_v2')) continue;
      for (const match of content.matchAll(/value:("(?:\\.|[^"\\])*")/g)) {
        if (!match[1].includes('threaded_conversation_with_injections_v2')) continue;
        try {
          const data = JSON.parse(JSON.parse(match[1])).data;
          const instructions = data?.threaded_conversation_with_injections_v2?.instructions || [];
          for (const instruction of instructions) {
            for (const entry of instruction.entries || []) {
              const items = entry.content?.items?.map((row) => row.item?.content) || [entry.content?.content];
              for (const item of items) {
                const result = item?.tweet_results?.result;
                const post = result?.tweet || result;
                const parent = post?.reply_to_results?.rest_id || post?.legacy?.in_reply_to_status_id_str;
                if (/^\d{1,24}$/.test(post?.rest_id || '') && /^\d{1,24}$/.test(parent || '')) {
                  parents.set(post.rest_id, parent);
                }
              }
            }
          }
        } catch (_) {}
      }
    }
    window.__qyxReplyParents = { count, parents };
    return parents;
  };
  const replyParents = detailId ? readReplyParents() : null;
  const readQuotePaths = () => {
    const count = document.scripts.length;
    if (window.__qyxQuotePaths?.count === count) return window.__qyxQuotePaths.paths;
    const paths = new Map();
    for (const script of document.scripts) {
      const content = script.textContent || '';
      if (!content.includes('quoted_status')) continue;
      const values = script.type === 'application/json' ? [content] :
        Array.from(content.matchAll(/value:("(?:\\.|[^"\\])*")/g), (match) => match[1]);
      for (const value of values) {
        if (!value.includes('quoted_status')) continue;
        try {
          const stack = [JSON.parse(script.type === 'application/json' ? value : JSON.parse(value))];
          for (let scanned = 0; stack.length && scanned < 30000; scanned++) {
            const node = stack.pop();
            if (!node || typeof node !== 'object') continue;
            const quoted = node.quoted_status_result?.result;
            const post = quoted?.tweet || quoted;
            const id = post?.rest_id || node.legacy?.quoted_status_id_str || node.quoted_status_id_str;
            const outerId = node.rest_id || node.legacy?.id_str || node.id_str;
            if (/^\d{1,24}$/.test(outerId || '') && /^\d{1,24}$/.test(id || '')) {
              const account = post?.core?.user_results?.result;
              const handle = account?.core?.screen_name || account?.legacy?.screen_name;
              paths.set(outerId, '/' + (/^[A-Za-z0-9_]{1,15}$/.test(handle || '') ? handle : 'i/web') +
                '/status/' + id);
            }
            for (const child of Object.values(node)) {
              if (child && typeof child === 'object') stack.push(child);
            }
          }
        } catch (_) {}
      }
    }
    window.__qyxQuotePaths = { count, paths };
    return paths;
  };
  const ids = new Set();
  let embeddedVideos;
  const videoTimeLabel = (value) => {
    if (!Number.isFinite(value) || value <= 0) return '';
    const total = Math.ceil(value);
    const hours = Math.floor(total / 3600);
    const minutes = Math.floor(total / 60) % 60;
    const seconds = String(total % 60).padStart(2, '0');
    return hours ? hours + ':' + String(minutes).padStart(2, '0') + ':' + seconds : minutes + ':' + seconds;
  };
  const clockSeconds = (value) => /^(?:\d{1,3}:)?\d{1,3}:[0-5]\d$/.test(value) ?
    value.split(':').reduce((seconds, part) => seconds * 60 + Number(part), 0) : 0;
  const videoMetadata = () => {
    if (window.__qyxVideoMetadata?.count === document.scripts.length) return window.__qyxVideoMetadata.durations;
    const durations = new Map();
    for (const script of document.scripts) {
      const content = script.textContent || '';
      if (!content.includes('duration_millis')) continue;
      const payloads = script.type === 'application/json' ? [content] :
        Array.from(content.matchAll(/value:("(?:\\.|[^"\\])*")/g), (match) => match[1]);
      for (const payload of payloads) {
        if (!payload.includes('duration_millis')) continue;
        try {
          const pending = [JSON.parse(script.type === 'application/json' ? payload : JSON.parse(payload))];
          for (let scanned = 0; pending.length && scanned < 30000; scanned++) {
            const value = pending.pop();
            if (!value || typeof value !== 'object') continue;
            const info = value.video_info;
            const poster = value.media_url_https;
            const key = typeof poster === 'string' &&
              /\/(?:ext_tw_video_thumb|amplify_video_thumb|tweet_video_thumb)\/([\w-]+)/.exec(poster)?.[1];
            if (key && Number.isFinite(info?.duration_millis) && info.duration_millis > 0) {
              durations.set(key, info.duration_millis / 1000);
            }
            for (const child of Object.values(value)) if (child && typeof child === 'object') pending.push(child);
          }
        } catch (_) {}
      }
    }
    window.__qyxVideoMetadata = { count: document.scripts.length, durations };
    return durations;
  };
  for (const article of candidates) {
    const { time, match, links } = identity(article);
    if (!match || ids.has(match[2])) continue;
    if (article.closest('[data-testid="placementTracking"]') ||
      isAdvertisement(article, (node) => ownElement(article, node))) continue;
    const thread = detailId && article.closest('[data-entry-id^="conversationthread-"], [id^="conversationthread-"]');
    const threadId = thread && (thread.getAttribute('data-entry-id') || thread.id).match(/^conversationthread-(\d+)$/)?.[1];
    const explicitParent = detailId && article.closest('[data-in-reply-to-status-id]')
      ?.getAttribute('data-in-reply-to-status-id');
    const replyToId = explicitParent || replyParents?.get(match[2]) || (threadId !== match[2] ? threadId : '') || '';
    const nameBox = owned(article, 'User-Name');
    const author = (nameBox ? Array.from(nameBox.querySelectorAll('a')) : links)
      .find((a) => pathOf(a).toLowerCase() === '/' + match[1].toLowerCase() &&
        text(a) && text(a).toLowerCase() !== '@' + match[1].toLowerCase());
    const thumbnail = (value) => /^https:\/\/pbs\.twimg\.com\/(?:ext_tw_video_thumb|amplify_video_thumb|tweet_video_thumb|media)\//
      .test(value || '') ? value.slice(0, 600) : '';
    const videoNode = Array.from(article.querySelectorAll('video')).find((node) => ownElement(article, node));
    const videoLink = links.find((link) => pathOf(link).startsWith(match[0] + '/video/'));
    const labeledVideo = Array.from(article.querySelectorAll('[aria-label]')).find((node) =>
      ownElement(article, node) && /^(?:embedded video|video player|嵌入式视频|嵌入式影片|嵌入式視訊)$/i
        .test(node.getAttribute('aria-label') || ''));
    const posterUrl = (img) => [img.currentSrc, img.src, img.getAttribute('data-src'),
      ...(img.getAttribute('srcset') || '').split(',').map((candidate) => candidate.trim().split(/\s+/)[0])]
      .map(thumbnail).find(Boolean) || '';
    const videoThumb = Array.from(article.querySelectorAll('img')).find((img) =>
      ownElement(article, img) && /^https:\/\/pbs\.twimg\.com\/(?:ext_tw_video_thumb|amplify_video_thumb|tweet_video_thumb)\//
        .test(posterUrl(img)));
    const videoBox = owned(article, 'videoPlayer') || owned(article, 'videoComponent') ||
      videoNode?.parentElement || videoLink || labeledVideo || videoThumb?.parentElement;
    const posterImage = videoThumb || (videoBox && Array.from(videoBox.querySelectorAll('img')).find(posterUrl));
    const videoPoster = thumbnail(videoNode?.poster) || (posterImage ? posterUrl(posterImage) : '') ||
      thumbnail(videoBox ? profileSource(videoBox) : '');
    const videoKey = videoPoster.match(/\/(?:ext_tw_video_thumb|amplify_video_thumb|tweet_video_thumb)\/([\w-]+)/)?.[1];
    const videoSources = [];
    if (videoBox || videoNode) {
      const playable = /^https:\/\/video\.twimg\.com\/[\w/.-]+\.(?:mp4|m3u8)(?:\?[^\s"'<>]*)?$/;
      videoSources.push(videoNode?.currentSrc || '', videoNode?.src || '');
      for (const source of videoBox?.querySelectorAll('source[src]') || []) videoSources.push(source.src);
      if (videoKey) {
        if (!embeddedVideos) {
          embeddedVideos = Array.from(document.scripts).flatMap((script) =>
            script.textContent.match(/https:\/\/video\.twimg\.com\/[\w/.-]+\.(?:mp4|m3u8)(?:\?[\w=&.%+-]+)?/g) || []);
          embeddedVideos.push(...(performance.getEntriesByType?.('resource') || []).map((entry) => entry.name));
        }
        videoSources.push(...embeddedVideos.filter((source) =>
          source.includes('/' + videoKey + '/') || source.includes('/tweet_video/' + videoKey + '.mp4')));
      }
      for (let i = videoSources.length - 1; i >= 0; i--) {
        if (!playable.test(videoSources[i])) videoSources.splice(i, 1);
      }
    }
    const videoWidth = videoNode?.videoWidth || posterImage?.naturalWidth || 0;
    const videoHeight = videoNode?.videoHeight || posterImage?.naturalHeight || 0;
    const playerText = text(videoBox, 600);
    const elapsedAndTotal = /(?:^|\s)(?:\d{1,3}:)?\d{1,3}:[0-5]\d\s*\/\s*((?:\d{1,3}:)?\d{1,3}:[0-5]\d)(?:\s|$)/
      .exec(playerText);
    const millis = Number(videoNode?.getAttribute('data-duration-ms') || videoBox?.getAttribute('data-duration-ms'));
    const timeLabel = (videoKey ? videoTimeLabel(videoMetadata().get(videoKey)) : '') ||
      videoTimeLabel(millis / 1000) || videoTimeLabel(clockSeconds(elapsedAndTotal?.[1] || '')) || videoTimeLabel(videoNode?.duration);
    const articlePathPattern = /^\/(?:i|[A-Za-z0-9_]{1,15})\/article\/\d{1,24}$/;
    const articleLink = links.find((link) => articlePathPattern.test(pathOf(link)));
    const articleHeading = Array.from(article.querySelectorAll('[data-article-part="title"], [data-testid="article-title"]'))
      .find((node) => ownElement(article, node)) || articleLink?.querySelector('h1, h2, h3, [role="heading"]');
    const articleTitle = text(articleHeading, 140) || text(articleLink, 140);
    const articlePath = articleLink ? pathOf(articleLink) :
      articleHeading ? '/' + match[1] + '/article/' + match[2] : '';
    const coverNodes = articleLink ? Array.from(articleLink.querySelectorAll('img')) : articleHeading ?
      Array.from(article.querySelectorAll('img')).filter((img) => !img.closest('[data-article-part="body"]')) : [];
    const cover = coverNodes.find((img) => ownElement(article, img) && imageUrl(img, 'media'));
    const photoNodes = Array.from(article.querySelectorAll('img'))
      .filter((img) => img !== posterImage && ownElement(article, img) && imageUrl(img, 'media') &&
        (videoBox === article || !videoBox?.contains(img)) && img !== cover &&
        !img.closest('[data-article-part="body"]')).slice(0, 12);
    const isAuthor = (node) => pathOf(node.closest('a')).toLowerCase() === '/' + match[1].toLowerCase();
    const avatar = avatarIn(article, (node) => ownElement(article, node) && isAuthor(node)) ||
      avatarIn(article, (node) => ownElement(article, node) &&
        !!node.closest('[data-testid="Tweet-User-Avatar"], [data-testid^="UserAvatar-Container"]') &&
        !node.closest('[data-testid="socialContext"]')) ||
      avatarIn(article, (node) => ownElement(article, node) &&
        !node.closest('[data-testid="tweetText"], [data-testid="socialContext"]'));
    const metric = (id) => text(owned(article, id), 20);
    const controls = legacyPrimary && !search && !profilePath ? [] : Array.from(article.querySelectorAll('[role="group"] [aria-label]'))
      .filter((node) => ownElement(article, node));
    const modernMetric = (pattern) => {
      const label = controls.map((control) => control.getAttribute('aria-label') || '')
        .find((value) => pattern.test(value));
      return label?.match(/^\s*([\d.,]+\s?[KMB万萬亿億]?)/i)?.[1]?.trim() || '';
    };
    const views = Array.from(article.querySelectorAll('a[href$="/analytics"]'))
      .find((anchor) => ownElement(article, anchor) && pathOf(anchor) === match[0] + '/analytics');
    const body = owned(article, 'tweetText') || ((!legacyPrimary || search || profilePath || immersiveVideo || videoTab) && Array.from(
      article.querySelectorAll('div[dir="auto"].whitespace-pre-wrap'))
      .find((node) => ownElement(article, node) && !node.closest('[data-article-part="body"]') &&
        !articleLink?.contains(node)));
    const candidateQuote = article.querySelector(quoteSelector);
    const quote = candidateQuote && !isAdvertisement(candidateQuote, (node) => candidateQuote.contains(node)) ?
      candidateQuote : null;
    let quotedPost = null;
    if (quote) {
      const quoteLinks = Array.from(quote.querySelectorAll('a[href]'));
      const quoteTime = quote.querySelector('time');
      const quoteBody = quote.querySelector('[data-testid="tweetText"], [dir="auto"].whitespace-pre-wrap');
      const quotedStatus = (href) => {
        try {
          const url = new URL(href || '', location.origin);
          if (url.origin !== location.origin) return '';
          const status = url.pathname.match(/^(\/(?:[A-Za-z0-9_]{1,15}|i\/web)\/status\/(\d{1,24}))(?:\/(?:analytics|(?:photo|video)\/\d+))?\/?$/);
          return status && status[2] !== match[2] ? status[1] : '';
        } catch (_) {
          return '';
        }
      };
      const timeLink = quoteTime?.closest('a');
      const quotePermalink = quotedStatus(pathOf(timeLink)) ? timeLink : quoteLinks.find((link) =>
        !quoteBody?.contains(link) && quotedStatus(pathOf(link)));
      const quotePath = quotedStatus(pathOf(timeLink)) ||
        quotedStatus(quote.getAttribute('href') || quote.getAttribute('data-href') || quote.getAttribute('data-url')) ||
        quotedStatus(pathOf(quotePermalink)) ||
        quotedStatus(quote.getAttribute('data-permalink') || quote.closest('a[href]')?.getAttribute('href')) ||
        quotedStatus(readQuotePaths().get(match[2]));
      const quoteHandle = quotePath.match(statusPattern)?.[1] ||
        text(quote.querySelector('[data-testid="User-Name"]'), 180).match(/@([A-Za-z0-9_]{1,15})\b/)?.[1] ||
        quoteLinks.map((link) => text(link, 20).match(/^@([A-Za-z0-9_]{1,15})$/)?.[1]).find(Boolean) || '';
      const quoteAuthor = quoteHandle && quoteLinks.find((link) => pathOf(link).toLowerCase() === '/' +
        quoteHandle.toLowerCase() && text(link).toLowerCase() !== '@' + quoteHandle.toLowerCase());
      const quoteImages = Array.from(quote.querySelectorAll('img'));
      const quotePhoto = quoteImages.find((img) => imageUrl(img, 'media'));
      const quoteAvatar = quoteImages.find((img) => imageUrl(img, 'profile_images'));
      const quoteVideo = quote.querySelector('video');
      const quoteVideoBox = quote.querySelector('[data-testid="videoPlayer"]') || quoteVideo?.parentElement;
      const quotePoster = thumbnail(quoteVideo?.poster) || quoteImages.map((img) =>
        thumbnail(img.currentSrc || img.src)).find((src) => src && !src.includes('/media/')) || '';
      const mediaWidth = quoteVideo?.videoWidth || quotePhoto?.naturalWidth || 0;
      const mediaHeight = quoteVideo?.videoHeight || quotePhoto?.naturalHeight || 0;
      if (quotePath || quoteHandle || quoteBody || quotePhoto || quotePoster) {
        quotedPost = {
          path: quotePath,
          handle: quoteHandle,
          name: text(quoteAuthor, 80) || text(quote.querySelector('[data-testid="User-Name"] [dir="ltr"]'), 80),
          avatar: imageUrl(quoteAvatar, 'profile_images'),
          time: text(quoteTime || quotePermalink, 40),
          body: bodyText(quoteBody, 600),
          bodyLinks: bodyLinks(quoteBody),
          photo: imageUrl(quotePhoto, 'media'),
          video: !!quoteVideoBox,
          poster: quotePoster,
          ratio: mediaWidth && mediaHeight ? mediaWidth / mediaHeight : 0
        };
      }
    }
    if (openQuoteOf === match[2] && quote && !quotedPost?.path) {
      // Click the quote surface, not links or controls inside the quoted text.
      const control = quote.matches('[role="link"], a[href]') ? quote :
        quote.querySelector('[role="link"]:not(a)') || quote;
      control.click();
      return JSON.stringify(snapshot);
    }
    const postText = translatedPost(article, match[2], body);
    const heart = likeControl(article);
    const repost = postControl(article, 'repost');
    const bookmark = postControl(article, 'bookmark');
    snapshot.posts.push({
      id: match[2],
      replyToId,
      handle: match[1],
      name: text(author, 80) || '@' + match[1],
      avatar,
      time: text(time, 40),
      ...postText,
      bodyLinks: bodyLinks(body),
      articlePath,
      articleTitle,
      articleCover: imageUrl(cover, 'media'),
      photos: photoNodes.map((img) => imageUrl(img, 'media')),
      photoRatios: photoNodes.map((img) => img.naturalHeight ? img.naturalWidth / img.naturalHeight : 0),
      verified: !!owned(article, 'icon-verified') ||
        !!nameBox?.querySelector('[aria-label*="Verified"], [aria-label*="已认证"], [aria-label*="已驗證"]'),
      video: !!videoBox || !!videoNode,
      videoPoster,
      videoSources: Array.from(new Set(videoSources)).slice(0, 12),
      videoRatio: videoWidth && videoHeight ? videoWidth / videoHeight : 0,
      videoDuration: timeLabel,
      videoDurationVerified: !!timeLabel,
      quote: !!quote,
      quotedPost,
      context: text(owned(article, 'socialContext'), 100),
      replies: metric('reply') || modernMetric(/\brepl(?:y|ies)\b|回复|回覆|回應/i),
      reposts: likeCount(repost) || modernMetric(/\breposts?\b|转帖|轉發|轉貼/i),
      reposted: repost?.liked || false,
      likes: likeCount(heart) || modernMetric(/\blikes?\b|喜欢|喜歡|讚/i),
      liked: heart?.liked || false,
      bookmarked: bookmark?.liked || false,
      bookmarks: likeCount(bookmark) || modernMetric(/\bbookmarks?\b|收藏|书签|書籤/i) || undefined,
      views: text(views, 20) || modernMetric(/\bviews?\b|观看|觀看|瀏覽/i)
    });
    ids.add(match[2]);
    if (snapshot.posts.length >= 32) break;
  }

  if (profilePath && /^(?:media(?:\/grid)?|photos|videos)$/.test(profilePath[2] || '')) {
    const grid = new Map();
    for (const link of primary.querySelectorAll('a[href*="/status/"]')) {
      if (link.closest(postNode)) continue;
      const status = pathOf(link).match(/^\/([A-Za-z0-9_]{1,15})\/status\/(\d{1,24})(?:\/(photo|video)\/\d+)?$/);
      if (!status || ids.has(status[2])) continue;
      const images = Array.from(link.querySelectorAll('img'));
      const photos = images.map((img) => imageUrl(img, 'media')).filter(Boolean);
      const poster = images.map((img) => img.currentSrc || img.src).find((url) =>
        /^https:\/\/pbs\.twimg\.com\/(?:ext_tw_video_thumb|amplify_video_thumb|tweet_video_thumb)\//.test(url));
      if (!photos.length && !poster) continue;
      const old = grid.get(status[2]);
      if (old) {
        old.photos = Array.from(new Set([...old.photos, ...photos]));
        old.video = old.video || status[3] === 'video' || !!poster;
        old.videoPoster ||= poster || '';
      } else {
        grid.set(status[2], { id: status[2], handle: status[1], name: status[1], body: '', avatar: '',
          photos, photoRatios: [], video: status[3] === 'video' || !!poster, videoPoster: poster || '' });
      }
    }
    snapshot.posts.push(...Array.from(grid.values()).slice(0, Math.max(0, 32 - snapshot.posts.length)));
  }
  if (profilePath) {
    const nonPost = (selector) => Array.from(primary.querySelectorAll(selector))
      .find((node) => !node.closest('article, [role="article"], aside, [role="complementary"]'));
    const handle = profilePath[1];
    const header = nonPost('[data-testid="UserName"], [data-testid="User-Name"]');
    const heading = nonPost('h1, h2[role="heading"], [role="heading"][aria-level="1"]');
    const profileAvatar = Array.from(primary.querySelectorAll('img[src*="/profile_images/"]'))
      .find((img) => !img.closest('article') && (img.alt.toLowerCase() === '@' + handle.toLowerCase() ||
        pathOf(img.closest('a')).toLowerCase() === '/' + handle.toLowerCase() + '/photo'));
    const hasMatchingHeader = header && text(header).toLowerCase().includes('@' + handle.toLowerCase());
    const matchingProfileLink = Array.from(primary.querySelectorAll('a[href]')).some((link) =>
      !link.closest(postNode) && pathOf(link).toLowerCase() === '/' + handle.toLowerCase() + '/following');
    if (hasMatchingHeader || (heading && (profileAvatar || matchingProfileLink))) {
      const profileLink = (suffix) => Array.from(primary.querySelectorAll('a[href]')).find((anchor) =>
        !anchor.closest('article') && pathOf(anchor).toLowerCase() === '/' + handle.toLowerCase() + '/' + suffix);
      const iconRow = (icon) => nonPost('[data-icon="icon-' + icon + '"]')?.parentElement;
      const website = nonPost('a[data-testid="UserUrl"], [data-testid="UserUrl"] a[href]') ||
        iconRow('link')?.querySelector('a[href]');
      const followers = profileLink('followers') || profileLink('verified_followers');
      const profileControls = Array.from(document.querySelectorAll('[role="tab"], [role="tablist"] button'))
        .filter((node) => !node.closest(postNode));
      const hasProfilePath = (tab) => Array.from(document.querySelectorAll('a[href]')).some((link) =>
        !link.closest(postNode) && pathOf(link).toLowerCase() === '/' + handle.toLowerCase() + '/' + tab);
      const profileTabs = [
        ['with_replies', ['replies', '回复', '回覆', '回應']],
        ['reposts', ['reposts', '转帖', '轉貼', '轉發']],
        ['likes', ['likes', '喜欢', '喜歡', '讚']],
        ['media', ['media', '媒体', '媒體']],
        ['photos', ['photos', '图片', '圖片', '相片']],
        ['videos', ['videos', '视频', '影片']],
        ['articles', ['articles', '文章']],
        ['highlights', ['highlights', '亮点', '精選']],
        ['subs', ['subscriptions', '订阅', '訂閱']]
      ].filter(([tab, names]) => hasProfilePath(tab) || (tab === 'media' && hasProfilePath('media/grid')) ||
        profileControls.some((node) => matchesTab(node, names)))
        .map(([tab]) => tab);
      if (profilePath[2] && !profileTabs.includes(profilePath[2].split('/')[0])) {
        profileTabs.push(profilePath[2].split('/')[0]);
      }
      if (ownHandle.toLowerCase() === handle.toLowerCase() && !profileTabs.includes('likes')) profileTabs.push('likes');
      snapshot.profile = {
        handle,
        name: text(header?.querySelector('[dir="ltr"], [dir="auto"]') || heading, 80).split('\n')[0],
        bio: bodyText(nonPost('[data-testid="UserDescription"], [data-testid="UserProfileBio"]') ||
          nonPost('div[dir="auto"].whitespace-pre-wrap'), 800),
        avatar: imageUrl(profileAvatar, 'profile_images') ||
          avatarIn(primary, (node) => !node.closest(postNode) &&
            pathOf(node.closest('a')).toLowerCase() === '/' + handle.toLowerCase() + '/photo') ||
          (ownHandle.toLowerCase() === handle.toLowerCase() ? snapshot.ownAvatar : ''),
        banner: imageUrl(profileLink('header_photo')?.querySelector('img') ||
          nonPost('img[src^="https://pbs.twimg.com/profile_banners/"]'), 'profile_banners'),
        verified: !!(header || heading?.parentElement)?.querySelector('[data-testid="icon-verified"], ' +
          '[aria-label*="Verified"], [aria-label*="已认证"], [aria-label*="已驗證"], use[href*="icon-verified"]'),
        location: text(nonPost('[data-testid="UserLocation"]') || iconRow('location-pin'), 100),
        website: text(website, 120),
        websiteUrl: website?.href || '',
        birthday: text(nonPost('[data-testid="UserBirthdate"]') || iconRow('balloon'), 100),
        joined: text(nonPost('[data-testid="UserJoinDate"]') || profileLink('about') || iconRow('calendar'), 100),
        aboutPath: pathOf(profileLink('about')),
        following: text(profileLink('following'), 70),
        followers: text(followers, 70),
        followersPath: pathOf(followers),
        editPath: pathOf(nonPost('a[href="/settings/profile"]')),
        tabs: profileTabs
      };
      if (!snapshot.posts.length) {
        snapshot.empty ||= Array.from(primary.querySelectorAll('h2, h3, [role="heading"], [data-testid="empty_state_header_text"]'))
          .filter((node) => !node.closest(postNode))
          .some((node) => /(?:\bno (?:posts|likes|media|replies|reposts)\b|haven.t (?:liked|posted|replied|reposted)|hasn.t (?:posted|liked|replied|reposted)|暂无(?:帖子|喜欢|回复|转帖|媒体)|尚未(?:發佈|發表|喜歡|回覆|轉發)|还没有(?:发帖|发布|喜欢|回复|转帖))/i.test(text(node, 140)));
      }
      if (snapshot.posts.length) snapshot.pageError = false;
    }
  }
  // Tab links on X's History page and on the signed-in account's own profile. Qwitter builds its native History tabs
  // from these and logs them, because X rolls these sections out differently per account and platform.
  const historyPage = /^\/i\/(?:history|bookmarks)(?:\/|$)/.test(location.pathname);
  const ownProfilePage = !!profilePath && ((!!ownHandle && profilePath[1].toLowerCase() === ownHandle.toLowerCase()) ||
    !!Array.from(document.querySelectorAll('a[href="/settings/profile"]')).find((link) => !link.closest(postNode)));
  if (historyPage || ownProfilePage) {
    const pageTabs = [];
    const seenTabs = new Set();
    const addTab = (tab) => {
      if (pageTabs.length >= 12 || tab.closest(postNode) || tab.closest('[data-testid="sidebarColumn"]')) return;
      const link = tab.matches('a[href]') ? tab : tab.closest('a[href]') || tab.querySelector('a[href]');
      const tabPath = link ? pathOf(link) : '';
      const label = (tab.getAttribute('aria-label') || text(tab, 60)).replace(/\s+/g, ' ').trim().slice(0, 40);
      const key = tabPath || label;
      if (!label || seenTabs.has(key)) return;
      seenTabs.add(key);
      pageTabs.push({ label, path: tabPath, selected: tab.getAttribute('aria-selected') === 'true' });
    };
    const tablists = Array.from(document.querySelectorAll('[role="tablist"]'));
    const roleTabs = Array.from(document.querySelectorAll('[role="tab"]'));
    for (const list of tablists) for (const tab of list.querySelectorAll('[role="tab"], a[href]')) addTab(tab);
    for (const tab of roleTabs) addTab(tab);
    if (!pageTabs.length) {
      const own = profilePath ? profilePath[1].toLowerCase() : '';
      for (const link of document.querySelectorAll('a[href]')) {
        const linkPath = pathOf(link).toLowerCase();
        if (/^\/i\/(?:history|bookmarks)(?:\/[a-z_]+)?$/.test(linkPath) ||
          (own && new RegExp('^/' + own + '/(?:likes|reposts|with_replies|media)$').test(linkPath))) addTab(link);
      }
    }
    snapshot.pageTabs = pageTabs;
    snapshot.pageTabsProbe = (historyPage ? 'history' : 'own-profile') + ' path=' + location.pathname.slice(0, 80) +
      ' tablists=' + tablists.length + ' roleTabs=' + roleTabs.length + ' found=' + pageTabs.length;
  }
  return JSON.stringify(snapshot);
})(typeof qyxDiscoverAccount !== 'undefined' && qyxDiscoverAccount,
  typeof qyxHomeTarget === 'number' ? qyxHomeTarget : -1,
  typeof qyxTranslationLocale === 'string' ? qyxTranslationLocale : '',
  typeof qyxTranslationLabel === 'string' ? qyxTranslationLabel : '',
  typeof qyxOpenQuote === 'string' ? qyxOpenQuote : '',
  typeof qyxLikeAction === 'object' ? qyxLikeAction : null,
  typeof qyxTranslationPostId === 'string' ? qyxTranslationPostId : '',
  typeof qyxKnownTranslationIds !== 'undefined' && Array.isArray(qyxKnownTranslationIds) ? qyxKnownTranslationIds : [])
