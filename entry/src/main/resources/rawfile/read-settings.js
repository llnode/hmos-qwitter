((action, destination) => {
  const isX = location.origin === 'https://x.com';
  const official = ['https://help.x.com', 'https://privacy.x.com', 'https://legal.x.com'];
  const allowed = (url) => official.includes(url.origin) || (url.origin === 'https://x.com' &&
    /^\/(?:settings(?:\/|$)|i\/(?:premium|verified(?:_orgs)?|flow)(?:\/|$)|(?:[a-z-]+\/)?(?:privacy|tos)(?:\/|$))/.test(url.pathname));
  if (!isX && !official.includes(location.origin)) return '';
  const normalize = (url) => url.origin + url.pathname.replace(/\/$/, '') + url.search;
  const path = location.pathname.replace(/\/$/, '');
  const route = normalize(location);
  if (destination) {
    if (!isX || !/^\/settings(?:\/|$)/.test(path)) return false;
    const expected = new URL(destination, location.origin);
    if (expected.origin !== location.origin || !/^\/settings(?:\/|$)/.test(expected.pathname)) return false;
    const anchor = Array.from(document.querySelectorAll('a[href]')).find((node) => {
      try {
        if (node.closest('[hidden], [aria-hidden="true"], [inert]')) return false;
        const url = new URL(node.getAttribute('href'), location.origin);
        return url.origin === expected.origin && url.pathname.replace(/\/$/, '') === expected.pathname.replace(/\/$/, '') &&
          (!expected.search || url.search === expected.search);
      } catch (_) { return false; }
    });
    if (!anchor) return false;
    anchor.click();
    return true;
  }
  window.__qyxSettingsDocument ||= Date.now().toString(36) + Math.random().toString(36).slice(2);
  const page = { route, path, title: '', rows: [], entries: [], dialog: false, signedOut: false, applied: false,
    documentId: window.__qyxSettingsDocument, notice: '', error: '', busy: false };
  if (isX && /^\/(?:login|i\/flow\/(?:login|challenge|single_sign_on|password_reset)|i\/jf\/onboarding|account\/(?:access|login[-_][a-z_]+))(?:\/|$)/.test(path)) {
    page.signedOut = true;
    return JSON.stringify(page);
  }
  if (!allowed(location)) {
    return JSON.stringify(page);
  }
  const text = (node, length = 400) =>
    (node?.innerText ?? node?.textContent ?? '').trim().replace(/[\t ]+/g, ' ').slice(0, length);
  const visible = (node) => !node.closest('[hidden], [aria-hidden="true"], [inert], template, footer') &&
    !node.closest('[style*="display: none"], [style*="display:none"], [style*="visibility: hidden"]');
  const name = (node) => {
    const labelled = (node.getAttribute('aria-labelledby') || '').split(/\s+/)
      .map((id) => text(document.getElementById(id), 150)).filter(Boolean).join(' ');
    return (node.getAttribute('aria-label') || labelled || text(node.labels?.[0], 150) ||
      text(node, 150) || node.getAttribute('placeholder') || node.getAttribute('title') ||
      (['submit', 'button', 'reset'].includes(node.type) ? node.value : '') || '').trim().split('\n').find(Boolean)?.slice(0, 150) || '';
  };
  const description = (node) => (node.getAttribute('aria-describedby') || '').split(/\s+/)
    .map((id) => text(document.getElementById(id), 300)).filter(Boolean).join(' ').slice(0, 450);
  const dialog = Array.from(document.querySelectorAll('[role="dialog"], [role="alertdialog"], dialog[open]'))
    .filter(visible).pop();
  const main = document.querySelector('[data-testid="primaryColumn"]') ||
    document.querySelector('main, [role="main"], article');
  const scope = dialog || main;
  if (!scope) return JSON.stringify(page);
  page.dialog = !!dialog;
  page.busy = !!Array.from(scope.querySelectorAll('[aria-busy="true"], [role="progressbar"]')).find(visible);
  const signals = Array.from(document.querySelectorAll('[role="alert"], [role="status"], [aria-live="assertive"], [data-testid="toast"]'))
    .filter((node) => visible(node) && !node.closest('nav, header') && text(node, 300));
  for (const signal of signals) {
    const message = text(signal, 300);
    if (/error|failed|could not|couldn.t|something went wrong|错误|錯誤|失败|失敗|无效|無效|有問題|发生问题|發生問題|无法|無法/i.test(message)) {
      page.error = message;
    } else {
      page.notice = message;
    }
  }
  const heading = Array.from(scope.querySelectorAll('h1, h2, [role="heading"]')).find(visible);
  page.title = text(heading, 100);
  const root = '/settings';
  const rootLinks = new Set(['/settings/account', '/settings/security_and_account_access',
    '/settings/privacy_and_safety', '/settings/notifications', '/settings/accessibility_display_and_languages',
    '/settings/premium', '/settings/monetization']);
  const control = 'button, input:not([type="hidden"]), select, textarea, [role="button"], [role="switch"], ' +
    '[role="checkbox"], [role="radio"], [role="option"], [role="combobox"], [role="tab"], [role="slider"], ' +
    '[role="menuitem"], [role="menuitemcheckbox"], [role="menuitemradio"], [role="link"]';
  const nodes = new Map();
  const seenLinks = new Set();
  const seenText = new Set();
  const keys = new Map();
  const saveLabel = /^(?:save(?: changes)?|apply(?: changes)?|update|done|保存(?:更改)?|儲存(?:變更)?|套用|更新|完成)$/i;
  const hasSave = Array.from(scope.querySelectorAll('button, input[type="submit"], [role="button"]')).some((node) =>
    visible(node) && (node.matches('button[type="submit"], input[type="submit"]') || saveLabel.test(name(node))));
  for (const node of scope.querySelectorAll('a[href], ' + control + ', h2, h3, h4, [role="heading"], p, dt, dd, legend, [role="alert"], [role="status"]')) {
    if (!visible(node) || node === heading || node.closest('[role="search"]') || node.type === 'search' ||
      (path === root && node.closest('[role="tablist"]') && node.matches('[role="tab"]:not([href])'))) continue;
    if (node.parentElement?.closest('a[href], ' + control)) continue;
    const role = node.getAttribute('role');
    const label = name(node);
    const row = {
      key: '', kind: '', label, detail: description(node), path: '', value: '',
      checked: false, disabled: !!node.disabled || !!node.closest('[aria-disabled="true"], fieldset[disabled]'),
      group: node.name || node.closest('[role="radiogroup"], [role="tablist"], [role="listbox"]')?.getAttribute('aria-label') || '',
      options: [], min: 0, max: 100, step: 1, deferred: false, inputType: ''
    };
    if (node.matches('a[href]')) {
      try {
        const url = new URL(node.getAttribute('href'), location.href);
        const target = url.pathname.replace(/\/$/, '');
        if (allowed(url) && normalize(url) !== route && (path === root || !rootLinks.has(target) ||
          !!dialog) &&
          !seenLinks.has(normalize(url))) {
          row.kind = 'link';
          row.path = normalize(url);
          if (!row.detail) {
            const all = text(node, 450);
            row.detail = all.startsWith(label) ? all.slice(label.length).trim() : '';
          }
          seenLinks.add(row.path);
        }
      } catch (_) {}
    } else if (node.matches('select')) {
      row.kind = 'select';
      row.value = node.value;
      row.options = Array.from(node.options).slice(0, 300).map((option) =>
        ({ label: text(option, 150), value: option.value, disabled: option.disabled }));
    } else if (node.type === 'checkbox' || ['checkbox', 'switch', 'menuitemcheckbox'].includes(role) ||
      node.hasAttribute('aria-pressed')) {
      row.kind = 'toggle';
      row.checked = node.matches('input') ? node.checked :
        (node.getAttribute('aria-checked') || node.getAttribute('aria-pressed')) === 'true';
    } else if (node.type === 'radio' || ['radio', 'option', 'tab', 'menuitemradio'].includes(role)) {
      row.kind = 'choice';
      row.checked = node.matches('input') ? node.checked :
        node.getAttribute('aria-checked') === 'true' || node.getAttribute('aria-selected') === 'true';
    } else if (node.type === 'range' || role === 'slider') {
      row.kind = 'range';
      row.value = String(node.value || node.getAttribute('aria-valuenow') || 0);
      row.min = Number(node.min || node.getAttribute('aria-valuemin') || 0);
      row.max = Number(node.max || node.getAttribute('aria-valuemax') || 100);
      row.step = Number(node.step || 1) || 1;
    } else if (node.matches('textarea, input:not([type="submit"]):not([type="button"]):not([type="reset"])')) {
      row.kind = node.type === 'password' ? 'password' : node.type === 'file' ? 'unsupported' : 'input';
      row.inputType = node.matches('textarea') ? 'textarea' : node.type || 'text';
      row.value = row.kind === 'input' ? String(node.value || '').slice(0, 600) : '';
      if (!row.label) row.label = row.kind === 'password' ? '密码' : '输入';
    } else if (node.matches(control)) {
      row.kind = 'button';
    } else {
      row.kind = node.matches('h2,h3,h4,[role="heading"],legend') ? 'heading' : 'text';
      row.label = text(node, 1000);
      if (seenText.has(row.label)) continue;
      seenText.add(row.label);
    }
    if (!row.label || !row.kind) continue;
    row.deferred = hasSave && ['select', 'toggle', 'choice', 'range'].includes(row.kind);
    const identity = [row.kind, node.id || node.getAttribute('data-testid') || node.name || '',
      row.label, row.path, row.group].join(':');
    const occurrence = keys.get(identity) || 0;
    keys.set(identity, occurrence + 1);
    row.key = identity + ':' + occurrence;
    page.rows.push(row);
    if (row.kind === 'link') page.entries.push({ label: row.label, path: row.path });
    if (!['link', 'heading', 'text', 'unsupported'].includes(row.kind)) nodes.set(row.key, { node, row });
    if (page.rows.length >= 240) break;
  }

  const setValue = (node, value) => {
    const proto = node.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype :
      node.tagName === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto, 'value')?.set?.call(node, value);
    node.dispatchEvent(new Event('input', { bubbles: true }));
    node.dispatchEvent(new Event('change', { bubbles: true }));
  };
  const resolve = (ref) => {
    const target = nodes.get(ref?.key);
    return target && target.row.kind === ref.kind && target.row.label === ref.label &&
      !target.row.disabled && target.node.isConnected ? target : null;
  };
  if (action && action.route === route) {
    const target = resolve(action);
    const fields = Array.isArray(action.fields) ? action.fields.slice(0, 30) : [];
    const edits = fields.map((field) => ({ field, target: resolve(field) }));
    if (target && edits.every((edit) => edit.target && ['input', 'password'].includes(edit.target.row.kind) &&
      (!target.node.form || !edit.target.node.form || target.node.form === edit.target.node.form))) {
      const { node, row } = target;
      for (const edit of edits) setValue(edit.target.node, String(edit.field.value || '').slice(0, 600));
      if (row.kind === 'select' && row.options.some((option) => option.value === action.value && !option.disabled)) {
        setValue(node, action.value);
        page.applied = true;
      } else if (row.kind === 'range' && Number(action.value) >= row.min && Number(action.value) <= row.max) {
        if (node.matches('input[type="range"]')) {
          setValue(node, action.value);
          page.applied = true;
        } else {
          const difference = Number(action.value) - Number(row.value);
          const steps = Math.min(100, Math.round(Math.abs(difference) / row.step));
          const key = difference >= 0 ? 'ArrowRight' : 'ArrowLeft';
          node.focus({ preventScroll: true });
          for (let step = 0; step < steps; step++) {
            node.dispatchEvent(new KeyboardEvent('keydown', { key, code: key, bubbles: true, cancelable: true }));
            node.dispatchEvent(new KeyboardEvent('keyup', { key, code: key, bubbles: true }));
          }
          page.applied = true;
        }
      } else if (row.kind === 'toggle' && typeof action.checked === 'boolean') {
        if (row.checked !== action.checked) node.click();
        page.applied = true;
      } else if (['button', 'choice'].includes(row.kind)) {
        node.click();
        page.applied = true;
      } else if (['input', 'password'].includes(row.kind) && action.submit) {
        if (node.form) {
          if (node.form.reportValidity()) {
            node.form.requestSubmit();
            page.applied = true;
          } else {
            page.error = Array.from(node.form.elements).find((field) => field.validationMessage)?.validationMessage ||
              'X 表单中还有未填写或格式不正确的项目';
          }
        } else {
          const save = Array.from(scope.querySelectorAll('button, [role="button"]')).find((button) =>
            visible(button) && !button.disabled && button.getAttribute('aria-disabled') !== 'true' && saveLabel.test(name(button)));
          if (save) {
            save.click();
            page.applied = true;
          }
        }
      }
    }
  }
  page.interactive = nodes.size > 0;
  return JSON.stringify(page);
})(typeof qyxSettingAction === 'undefined' ? null : qyxSettingAction,
  typeof qyxSettingsDestination === 'string' ? qyxSettingsDestination : '')
