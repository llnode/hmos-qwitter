((request) => {
  const result = { ready: false, selected: false, items: [] };
  const pickerPath = /^\/i\/foundmedia(?:\/search)?\/?$/.test(location.pathname);
  if (window !== window.top || location.origin !== 'https://x.com' ||
    (!/^\/compose\/post\/?$/.test(location.pathname) && !pickerPath)) {
    return result;
  }
  const visible = (node) => !node.closest('[hidden], [aria-hidden="true"], [inert]') && !!node.getClientRects().length;
  const inputs = Array.from(document.querySelectorAll('input'));
  const search = inputs.find((node) => visible(node) && (node.matches('[data-testid="gifSearchInput"], [data-testid="giphySearch"]') ||
    /gif|动图|動圖|动态图|動態圖/i.test((node.placeholder || '') + ' ' + (node.getAttribute('aria-label') || '')))) ||
    (pickerPath ? inputs.find((node) => visible(node) && node.matches('[type="search"], [role="searchbox"], [type="text"]')) : null);
  const dialog = search?.closest('[role="dialog"]') || (search ? document.body : null);
  if (!dialog) {
    if (request.step === 'open') {
      const toolbar = Array.from(document.querySelectorAll('[data-testid="gifyButton"], [data-testid="gifButton"], button[aria-label*="GIF" i], ' +
        '[role="button"][aria-label*="GIF" i], [aria-label*="动图"], [aria-label*="動圖"]'))
        .find(visible);
      toolbar?.click();
    }
    return result;
  }
  if (request.step === 'search' && search.value !== request.query) {
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
    setter?.call(search, request.query);
    search.dispatchEvent(new Event('input', { bubbles: true }));
    return result;
  }
  result.ready = true;
  const seen = new Set();
  for (const media of dialog.querySelectorAll('img[src], video[poster], [style*="background-image"]')) {
    const control = media.closest('[data-testid="gif"], [data-testid="gifResult"], [role="button"], button, [role="option"]');
    if (!control || !visible(control)) continue;
    const background = media.style.backgroundImage.match(/url\(["']?(https:\/\/[^"')]+)["']?\)/i)?.[1];
    const url = media.poster || media.currentSrc || media.src || background || '';
    if (!/^https:\/\/(?:[a-z0-9-]+\.)?(?:tenor\.com|giphy\.com)\/|^https:\/\/pbs\.twimg\.com\//i.test(url) ||
      seen.has(url)) continue;
    seen.add(url);
    if (request.step === 'select' && url === request.url) {
      window.__qyxSelectedGif = url;
      control.click();
      result.selected = true;
      return result;
    }
    result.items.push({ url, label: (media.alt || control.getAttribute('aria-label') || 'GIF').trim().slice(0, 100) });
    if (result.items.length >= 40 && request.step !== 'select') break;
  }
  return result;
})(qyxGifRequest)
