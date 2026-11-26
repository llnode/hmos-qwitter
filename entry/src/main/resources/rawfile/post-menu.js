(action) => {
  // Runs in a hidden X page opened at one post. Opens that post's "More" menu, picks the requested item
  // (delete for the user's own post; follow, mute or block the author otherwise), confirms X's sheet when
  // X asks, and then checks that X applied it. Each call does one step and returns the current stage.
  if (location.origin !== 'https://x.com' || !action || !/^\d{1,24}$/.test(action.id || '') ||
    !/^[A-Za-z0-9_]{1,15}$/.test(action.handle || '') || !['delete', 'follow', 'mute', 'block'].includes(action.kind)) {
    return 'invalid';
  }
  if (window.__qyxMenuAction?.token !== action.token) {
    window.__qyxMenuAction = { token: action.token, phase: 'start', at: 0, opens: 0 };
  }
  const state = window.__qyxMenuAction;
  const now = Date.now();
  const handle = '@' + action.handle.toLowerCase();
  const visible = (node) => !!node && !node.closest('[hidden], [aria-hidden="true"]') && node.getClientRects().length > 0;
  const statusId = (path) => /^\/(?:[A-Za-z0-9_]{1,15}|i\/web)\/status\/(\d{1,24})\/?$/.exec(path)?.[1];
  const articleSelector = 'article, [role="article"]';
  const target = Array.from(document.querySelectorAll(articleSelector))
    .filter((article) => !article.parentElement?.closest(articleSelector))
    .find((article) => Array.from(article.querySelectorAll('a[href] time')).some((time) => {
      const link = time.closest('a[href]');
      return link && link.origin === location.origin && !link.closest('[data-testid="quoteTweet"]') &&
        statusId(link.pathname) === action.id;
    }));
  const caret = target && Array.from(target.querySelectorAll('[data-testid="caret"]'))
    .find((node) => node.closest(articleSelector) === target && !node.closest('[data-testid="quoteTweet"]'));
  const menu = Array.from(document.querySelectorAll('[role="menu"]')).find(visible);
  const sheet = Array.from(document.querySelectorAll('[data-testid="confirmationSheetConfirm"]')).find(visible);
  const label = (node) => (node.innerText || node.textContent || '').replace(/\s+/g, ' ').trim().toLowerCase();
  // Undo forms first: "Unfollow" contains "follow" and "取消关注" contains "关注".
  const undo = {
    follow: /unfollow|取消关注|取消跟隨|取消跟随|フォロー解除|언팔로우|팔로우 취소|dejar de seguir|ne plus suivre|entfolgen|deixar de seguir|smetti di seguire|ontvolgen|berhenti mengikuti/,
    mute: /unmute|取消隐藏|取消靜音|取消静音|ミュート解除|뮤트 해제|dejar de silenciar|réactiver|stummschaltung aufheben|ativar som|riattiva|dempen opheffen|bunyikan/,
    block: /unblock|取消屏蔽|解除封鎖|取消封鎖|ブロック解除|차단 해제|desbloquear|débloquer|blockierung aufheben|sblocca|deblokkeren|buka blokir/
  };
  const apply = {
    follow: /follow|关注|跟隨|跟随|フォロー|팔로우|seguir|suivre|folgen|segui|volgen|ikuti/,
    mute: /mute|隐藏|靜音|静音|ミュート|뮤트|silenciar|masquer|stummschalten|silenciar|silenzia|dempen|bisukan/,
    block: /block|屏蔽|封鎖|ブロック|차단|bloquear|bloquer|blockieren|blocca|blokkeren|blokir/
  };
  const deleteWords = /^(?:delete|删除|刪除|削除|삭제|eliminar|supprimer|löschen|excluir|apagar|elimina|verwijderen|hapus|удалить)$/;
  const items = menu ? Array.from(menu.querySelectorAll('[role="menuitem"]')).filter(visible) : [];
  const forAuthor = (pattern) => items.find((item) => label(item).includes(handle) && pattern.test(label(item)));
  const undoItem = action.kind === 'delete' ? null : forAuthor(undo[action.kind]);
  const applyItem = action.kind === 'delete' ? items.find((item) => deleteWords.test(label(item))) :
    items.find((item) => item !== undoItem && label(item).includes(handle) && apply[action.kind].test(label(item)) &&
      !undo[action.kind].test(label(item)));
  const closeMenu = () => {
    const options = { key: 'Escape', code: 'Escape', keyCode: 27, bubbles: true };
    (document.activeElement || document.body).dispatchEvent(new KeyboardEvent('keydown', options));
    document.querySelector('[data-testid="mask"]')?.click();
  };

  if (sheet) {
    if (state.phase !== 'clicked') return 'waiting-sheet';
    sheet.click();
    state.phase = 'applied';
    state.at = now;
    return 'confirming';
  }
  if (menu) {
    if (!items.length) return 'menu-loading';
    if (state.phase === 'verify') {
      closeMenu();
      if (undoItem) return 'done';
      return applyItem ? 'not-applied' : 'no-item';
    }
    if (state.phase === 'start' || state.phase === 'opening') {
      if (undoItem) {
        closeMenu();
        return 'already';
      }
      if (!applyItem) {
        if (now - state.at < 1500) return 'menu-loading';
        closeMenu();
        return action.kind === 'delete' ? 'no-delete' : 'no-item';
      }
      applyItem.click();
      state.phase = 'clicked';
      state.at = now;
      return 'clicked';
    }
    return 'menu-open';
  }
  if (state.phase === 'clicked' || state.phase === 'applied') {
    // No confirmation sheet came (mute, follow), or X has closed it. Give X a moment, then check.
    if (now - state.at < 1200) return 'applying';
    if (action.kind === 'delete') {
      if (!target) return 'done';
      const toast = Array.from(document.querySelectorAll('[data-testid="toast"], [role="alert"]')).some(visible);
      if (toast) return 'done';
      return now - state.at > 8000 ? 'not-applied' : 'applying';
    }
    if (!target || !caret) {
      // X hides a blocked or muted author's post in place; that is the change it shows for these actions.
      return action.kind === 'follow' ? 'applying' : 'done';
    }
    state.phase = 'verify';
    state.at = now;
    caret.click();
    return 'verifying';
  }
  if (state.phase === 'verify') {
    if (now - state.at > 2500) {
      if (!caret) return 'done';
      state.at = now;
      caret.click();
    }
    return 'verifying';
  }
  if (!target || !caret) return 'loading';
  if (state.phase === 'start' || now - state.at > 2500) {
    if (++state.opens > 4) return 'no-menu';
    state.phase = 'opening';
    state.at = now;
    caret.click();
    return 'opening';
  }
  return 'opening';
}
