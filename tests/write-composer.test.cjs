const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { JSDOM } = require('jsdom');

const script = readFileSync(join(__dirname, '../entry/src/main/resources/rawfile/write-composer.js'), 'utf8');

function fixture(html, path, options) {
  const { window } = new JSDOM(html, { url: 'https://x.com' + path, runScripts: 'outside-only' });
  window.HTMLElement.prototype.getClientRects = () => [{}];
  const run = (step, overrides = {}) => {
    window.qyxComposeRequest = { key: 1, step, ...options, ...overrides };
    window.qyxComposeConversation = overrides.conversation || options.target || '';
    return window.eval(script);
  };
  return { window, run, doc: window.document };
}

test('only sends to the selected chat, clicks once and waits for the matching message', () => {
  const { window, run, doc } = fixture('<main><div role="log"></div><div><textarea></textarea>' +
    '<button aria-label="发送" disabled></button></div></main>', '/i/chat/12-34',
  { mode: 'chat', target: 'c:12-34', text: '第一行\nsecond line' });
  try {
    const editor = doc.querySelector('textarea');
    const button = doc.querySelector('button');
    let sends = 0;
    editor.addEventListener('input', () => { button.disabled = !editor.value; });
    button.addEventListener('click', () => { sends++; });
    assert.equal(run('prepare', { conversation: 'c:98-76' }), 'unavailable');
    assert.equal(editor.value, '');
    assert.equal(run('prepare'), 'prepared');
    assert.equal(editor.value, '第一行\nsecond line');
    assert.equal(run('submit', { conversation: 'c:98-76' }), 'unavailable');
    assert.equal(run('submit'), 'submitted');
    assert.equal(run('submit'), 'submitted');
    assert.equal(sends, 1);
    assert.equal(run('verify'), 'pending');
    editor.value = '';
    const bubble = doc.createElement('article');
    bubble.textContent = '第一行\nsecond line';
    doc.querySelector('[role="log"]').appendChild(bubble);
    assert.equal(run('verify'), 'confirmed');
  } finally {
    window.close();
  }
});

test('uses only the post composer, preserves an existing draft and confirms an X post link', () => {
  const { window, run, doc } = fixture('<main><button data-testid="tweetButtonInline">Unrelated</button>' +
    '<div role="dialog"><div data-testid="tweetTextarea_0" contenteditable="true">Other draft</div>' +
    '<button data-testid="tweetButton" disabled>Post</button></div></main>', '/compose/post',
  { mode: 'post', target: '', text: 'A native draft' });
  try {
    const editor = doc.querySelector('[contenteditable]');
    const button = doc.querySelector('[data-testid="tweetButton"]');
    let sends = 0;
    let otherClicks = 0;
    doc.querySelector('[data-testid="tweetButtonInline"]').addEventListener('click', () => { otherClicks++; });
    doc.execCommand = (_command, _showUI, text) => { editor.textContent = text; button.disabled = false; };
    button.addEventListener('click', () => { sends++; });
    assert.equal(run('prepare'), 'draft-conflict');
    assert.equal(editor.textContent, 'Other draft');
    editor.textContent = '';
    assert.equal(run('prepare'), 'prepared');
    assert.equal(run('submit'), 'submitted');
    assert.equal(sends, 1);
    assert.equal(otherClicks, 0);
    assert.equal(run('verify'), 'pending');
    const toast = doc.createElement('div');
    toast.dataset.testid = 'toast';
    toast.innerHTML = '<a href="/Reader/status/1234">View</a>';
    doc.body.appendChild(toast);
    assert.equal(run('verify'), 'confirmed');
  } finally {
    window.close();
  }
});

test('does not mistake placeholder text, an underlying composer, or hidden previews for a post draft', () => {
  const { window, run, doc } = fixture('<main><div data-testid="tweetTextarea_0" contenteditable="true">Inline draft</div>' +
    '<button data-testid="tweetButtonInline">Inline post</button></main><div role="dialog">' +
    '<div data-testid="tweetTextarea_0" contenteditable="true">' +
    '<span data-testid="tweetTextarea_0_placeholder">What is happening?</span></div>' +
    '<div hidden><div data-testid="attachments"><img></div><div data-testid="tweetTextarea_1"></div></div>' +
    '<button data-testid="tweetButton">Post</button></div>' +
    '<div data-testid="toast"><a href="/reader/status/10">Earlier post</a></div>', '/compose/post',
  { mode: 'post', text: 'New post' });
  try {
    doc.execCommand = (_command, _showUI, text) => {
      doc.querySelector('[role="dialog"] [contenteditable]').textContent = text;
    };
    doc.querySelector('[data-testid="tweetButtonInline"]').onclick = () => assert.fail('Submitted the inline composer');
    let sends = 0;
    doc.querySelector('[data-testid="tweetButton"]').onclick = () => { sends++; };
    assert.equal(run('prepare'), 'prepared');
    assert.equal(run('submit'), 'submitted');
    assert.equal(sends, 1);
    assert.equal(run('verify'), 'pending');
    doc.querySelector('[data-testid="toast"] a').href = '/reader/status/11';
    assert.equal(run('verify'), 'confirmed');
  } finally {
    window.close();
  }
});

test('sets all poll choices and the requested duration before enabling submission', () => {
  const { window, run, doc } = fixture('<div role="dialog">' +
    '<div data-testid="tweetTextarea_0" contenteditable="true"></div><button data-testid="pollButton"></button>' +
    '<button data-testid="tweetButton">Post</button></div>', '/compose/post',
  { mode: 'post', target: '', text: 'Which option?', choices: ['First', 'Second', 'Third'], duration: 1505 });
  try {
    const editor = doc.querySelector('[contenteditable]');
    doc.execCommand = (_command, _showUI, text) => { editor.textContent = text; };
    const scope = editor.parentElement;
    const appendOption = (index) => {
      const input = doc.createElement('input');
      input.dataset.testid = 'pollOption_' + index;
      scope.appendChild(input);
    };
    doc.querySelector('[data-testid="pollButton"]').onclick = () => {
      appendOption(0);
      appendOption(1);
      const more = doc.createElement('button');
      more.dataset.testid = 'addPollOption';
      more.onclick = () => appendOption(2);
      scope.appendChild(more);
      for (const [unit, value] of [['Days', '1'], ['Hours', '1'], ['Minutes', '5']]) {
        const select = doc.createElement('select');
        select.dataset.testid = 'pollDuration' + unit;
        select.innerHTML = '<option value="0">0</option><option value="' + value + '">' + value + '</option>';
        scope.appendChild(select);
      }
    };
    let sends = 0;
    doc.querySelector('[data-testid="tweetButton"]').onclick = () => { sends++; };
    assert.equal(run('prepare'), 'pending');
    assert.equal(run('submit'), 'pending');
    assert.equal(sends, 0);
    assert.equal(run('prepare'), 'prepared');
    assert.deepEqual([...scope.querySelectorAll('input')].map((input) => input.value), ['First', 'Second', 'Third']);
    assert.deepEqual([...scope.querySelectorAll('select')].map((select) => select.value), ['1', '1', '5']);
    assert.equal(run('submit'), 'submitted');
    assert.equal(sends, 1);
  } finally {
    window.close();
  }
});

test('keeps a media-only post pending until the attachment is rendered in X', async () => {
  const { window, run, doc } = fixture('<div role="dialog"><div data-testid="tweetTextarea_0" contenteditable="true"></div>' +
    '<input data-testid="fileInput" type="file" multiple><button data-testid="tweetButton">Post</button></div>', '/compose/post',
  { mode: 'post', target: '', text: '', uploads: [{ url: 'https://x.com/.qwitter-local-media/test/0',
    name: 'picked.png', type: 'image/png', size: 3 }] });
  try {
    const input = doc.querySelector('input');
    const selected = [];
    window.fetch = async () => ({ ok: true, blob: async () => new window.Blob(['abc']) });
    window.DataTransfer = class {
      files = [];
      items = { add: (file) => this.files.push(file) };
    };
    Object.defineProperty(input, 'files', { writable: true, value: [] });
    input.addEventListener('change', () => { selected.push(...input.files); });
    let sends = 0;
    doc.querySelector('button').onclick = () => { sends++; };
    assert.equal(run('prepare'), 'pending');
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(selected.length, 1);
    assert.equal(selected[0].name, 'picked.png');
    assert.equal(run('submit'), 'pending');
    assert.equal(sends, 0);
    input.parentElement.insertAdjacentHTML('afterbegin', '<div data-testid="attachments"><img alt=""></div>');
    assert.equal(run('prepare'), 'prepared');
    assert.equal(run('submit'), 'submitted');
    assert.equal(sends, 1);
  } finally {
    window.close();
  }
});

test('keeps a thread pending until every segment is present in the X editor', () => {
  const { window, run, doc } = fixture('<div role="dialog"><div data-testid="tweetTextarea_0" contenteditable="true"></div>' +
    '<button data-testid="addButton"></button><button data-testid="tweetButton">Post all</button></div>', '/compose/post',
  { mode: 'post', target: '', text: 'First post', thread: ['Second post', 'Third post'] });
  try {
    const dialog = doc.querySelector('[role="dialog"]');
    doc.execCommand = (_command, _showUI, text) => {
      doc.getSelection().anchorNode.textContent = text;
    };
    let next = 1;
    doc.querySelector('[data-testid="addButton"]').onclick = () => {
      const field = doc.createElement('div');
      field.dataset.testid = 'tweetTextarea_' + next++;
      field.setAttribute('contenteditable', 'true');
      dialog.appendChild(field);
    };
    let published = 0;
    doc.querySelector('[data-testid="tweetButton"]').onclick = () => { published++; };
    assert.equal(run('prepare'), 'pending');
    assert.equal(run('submit'), 'pending');
    assert.equal(published, 0);
    assert.equal(run('prepare'), 'prepared');
    assert.deepEqual([...doc.querySelectorAll('[contenteditable]')].map((field) => field.textContent),
      ['First post', 'Second post', 'Third post']);
    assert.equal(run('submit'), 'submitted');
    assert.equal(published, 1);
  } finally {
    window.close();
  }
});

test('reads and selects a GIF from the X library without clicking publish', () => {
  const gifScript = readFileSync(join(__dirname, '../entry/src/main/resources/rawfile/read-post-gifs.js'), 'utf8');
  const { window, doc } = fixture('<div role="dialog"><input placeholder="Search GIFs"><button data-testid="gif">' +
    '<img alt="Applause" src="https://media.tenor.com/example.gif"></button><button data-testid="gif">' +
    '<img src="https://untrusted.example/image.gif"></button><button data-testid="tweetButton">Post</button></div>',
  '/i/foundmedia/search', {});
  try {
    let selected = 0;
    let published = 0;
    doc.querySelector('[data-testid="gif"]').onclick = () => { selected++; };
    doc.querySelector('[data-testid="tweetButton"]').onclick = () => { published++; };
    const call = (step, url = '') => {
      window.qyxGifRequest = { step, query: 'applause', url };
      return JSON.parse(JSON.stringify(window.eval(gifScript)));
    };
    assert.equal(call('search').ready, false);
    assert.equal(doc.querySelector('input').value, 'applause');
    const items = call('list').items;
    assert.deepEqual(items, [{ url: 'https://media.tenor.com/example.gif', label: 'Applause' }]);
    assert.equal(call('select', items[0].url).selected, true);
    assert.equal(selected, 1);
    assert.equal(published, 0);
  } finally {
    window.close();
  }
});

test('opens only the requested reply composer and confirms a new status after submitting once', () => {
  const { window, run, doc } = fixture(
    '<article><a href="/other/status/123"><time>1h</time></a><button data-testid="reply"></button></article>' +
    '<article><time>2h</time><a href="/author/status/456/analytics">Views</a><button data-testid="reply"></button></article>' +
    '<div data-testid="toast"><a href="/reader/status/789">Old confirmation</a></div>',
    '/author/status/456', { mode: 'reply', target: '456', text: 'Native reply' });
  try {
    const [other, target] = doc.querySelectorAll('button');
    let sends = 0;
    other.addEventListener('click', () => assert.fail('Opened an unrelated reply'));
    target.addEventListener('click', () => {
      const dialog = doc.createElement('div');
      dialog.setAttribute('aria-modal', 'true');
      dialog.innerHTML = '<div role="textbox" contenteditable="true"></div>' +
        '<button data-testid="tweetButton">Reply</button>';
      doc.body.appendChild(dialog);
      window.history.replaceState(null, '', '/compose/tweet');
      dialog.querySelector('button').addEventListener('click', () => {
        sends++;
        dialog.remove();
        window.history.replaceState(null, '', '/author/status/456');
      });
    });
    doc.execCommand = (_command, _showUI, text) => { doc.querySelector('[contenteditable]').textContent = text; };
    assert.equal(run('prepare', { target: '123' }), 'reply-different-status');
    assert.equal(run('prepare'), 'reply-opening');
    window.history.replaceState(null, '', '/compose/tweet?in_reply_to=123');
    assert.equal(run('prepare'), 'reply-route-unverified');
    window.history.replaceState(null, '', '/compose/tweet?in_reply_to=456');
    assert.equal(run('prepare'), 'prepared');
    assert.equal(run('submit'), 'submitted');
    assert.equal(run('submit'), 'submitted');
    assert.equal(sends, 1);
    assert.equal(run('verify'), 'pending');
    doc.querySelector('[data-testid="toast"] a').href = '/reader/status/790';
    assert.equal(run('verify'), 'confirmed:790');
  } finally {
    window.close();
  }
});

test('uses the inline reply editor only on the requested status and confirms with the editor still mounted', () => {
  const { window, run, doc } = fixture(
    '<main><article><button data-testid="reply"></button><div data-testid="attachments"><img></div></article>' +
    '<div><div data-testid="tweetTextarea_0" contenteditable="true">Stale editor value</div>' +
    '<button data-testid="tweetButtonInline">Reply</button></div>' +
    '<div data-testid="tweetTextarea_1"></div><input data-testid="pollOption_0"></main>',
    '/author/status/456', { mode: 'reply', target: '456', text: 'Inline reply' });
  try {
    const editor = doc.querySelector('[contenteditable]');
    let sends = 0;
    let opens = 0;
    doc.querySelector('[data-testid="reply"]').onclick = () => { opens++; };
    doc.execCommand = (_command, _showUI, text) => { editor.textContent = text; };
    doc.querySelector('[data-testid="tweetButtonInline"]').onclick = () => {
      sends++;
      const toast = doc.createElement('div');
      toast.setAttribute('role', 'alert');
      toast.innerHTML = '<a href="/reader/status/790">View</a>';
      doc.body.appendChild(toast);
      editor.textContent = '';
    };
    assert.equal(run('prepare', { target: '123' }), 'reply-different-status');
    assert.equal(run('prepare'), 'prepared');
    assert.equal(run('submit'), 'submitted');
    assert.equal(run('submit'), 'submitted');
    assert.equal(run('verify'), 'confirmed:790');
    assert.equal(sends, 1);
    assert.equal(opens, 0);
  } finally {
    window.close();
  }
});

test('confirms a new post when X closes the compose page without an error, but not while an error or the text remains', () => {
  const { window, run, doc } = fixture('<main></main><div role="dialog"><div data-testid="tweetTextarea_0" contenteditable="true"></div>' +
    '<button data-testid="tweetButton">Post</button></div>', '/compose/post',
  { mode: 'post', target: '', text: 'Closed composer' });
  try {
    let now = 50000;
    window.Date.now = () => now;
    const editor = doc.querySelector('[contenteditable]');
    doc.execCommand = (_command, _showUI, text) => { editor.textContent = text; };
    assert.equal(run('prepare'), 'prepared');
    assert.equal(run('submit'), 'submitted');
    window.history.pushState(null, '', '/home');
    doc.querySelector('[role="dialog"]').remove();
    assert.equal(run('verify'), 'pending');
    now += 1600;
    const alert = doc.createElement('div');
    alert.setAttribute('role', 'alert');
    alert.textContent = 'Something went wrong';
    doc.body.appendChild(alert);
    assert.equal(run('verify'), 'pending');
    alert.remove();
    const inline = doc.createElement('div');
    inline.dataset.testid = 'tweetTextarea_0';
    inline.setAttribute('contenteditable', 'true');
    inline.textContent = 'Closed composer';
    doc.querySelector('main').appendChild(inline);
    assert.equal(run('verify'), 'pending');
    inline.remove();
    assert.equal(run('verify'), 'confirmed');
  } finally {
    window.close();
  }
});

test('restores post text after X re-draws its editor and names a disabled Post button', () => {
  const html = '<div role="dialog"><div data-testid="tweetTextarea_0" contenteditable="true"></div>' +
    '<button data-testid="tweetButton">Post</button></div>';
  const { window, run, doc } = fixture(html, '/compose/post', { mode: 'post', target: '', text: 'Redrawn editor' });
  try {
    const install = () => {
      const editor = doc.querySelector('[contenteditable]');
      doc.execCommand = (_command, _showUI, text) => { editor.textContent = text; };
      return doc.querySelector('[data-testid="tweetButton"]');
    };
    install();
    assert.equal(run('prepare'), 'prepared');
    doc.body.innerHTML = html;
    let sends = 0;
    const button = install();
    button.addEventListener('click', () => { sends++; });
    assert.equal(run('submit'), 'pending');
    assert.equal(doc.querySelector('[contenteditable]').textContent, 'Redrawn editor');
    button.disabled = true;
    assert.equal(run('submit'), 'post-button-disabled');
    button.disabled = false;
    assert.equal(run('submit'), 'submitted');
    assert.equal(sends, 1);
  } finally {
    window.close();
  }
});

test('uses the controlled paste handler for emoji and repairs its own failed draft on a new attempt', () => {
  const { window, run, doc } = fixture('<div role="dialog"><div data-testid="tweetTextarea_0" contenteditable="true"></div>' +
    '<button data-testid="tweetButton">Post</button></div>', '/compose/post',
  { mode: 'post', text: '冬天到了😂😂😂' });
  try {
    const editor = doc.querySelector('[contenteditable]');
    window.DataTransfer = class {
      setData(_type, value) { this.text = value; }
      getData() { return this.text; }
    };
    window.ClipboardEvent = class extends window.Event {
      constructor(type, options) { super(type, options); this.clipboardData = options.clipboardData; }
    };
    let pastes = 0;
    editor.addEventListener('paste', (event) => {
      event.preventDefault();
      editor.textContent = event.clipboardData.getData('text/plain');
      pastes++;
    });
    doc.execCommand = () => assert.fail('Must use X paste handler for controlled text');
    assert.equal(run('prepare'), 'prepared');
    assert.equal(editor.textContent, '冬天到了😂😂😂');
    editor.textContent += '😂😂😂';
    assert.equal(run('prepare', { key: 2 }), 'prepared');
    assert.equal(editor.textContent, '冬天到了😂😂😂');
    assert.equal(pastes, 2);
    let sends = 0;
    doc.querySelector('button').onclick = () => { sends++; };
    assert.equal(run('submit', { key: 2 }), 'submitted');
    assert.equal(run('submit', { key: 2 }), 'submitted');
    assert.equal(sends, 1);
  } finally { window.close(); }
});
