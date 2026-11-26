const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { JSDOM } = require('jsdom');

const source = readFileSync(join(__dirname, '../entry/src/main/resources/rawfile/post-menu.js'), 'utf8').trim();

// A small X stand-in: one post with a More button, a menu, and a confirmation sheet, all synchronous.
function fixture(xState) {
  const { window } = new JSDOM('<main></main><div id="layers"></div>', {
    url: 'https://x.com/alice/status/111', runScripts: 'outside-only'
  });
  window.HTMLElement.prototype.getClientRects = () => [{}];
  let now = 1000;
  window.Date.now = () => now;
  const doc = window.document;
  const layers = doc.getElementById('layers');
  const render = () => {
    doc.querySelector('main').innerHTML = xState.deleted ? '' :
      '<article><a href="/alice/status/111"><time>1h</time></a><button data-testid="caret">More</button></article>';
    doc.querySelector('[data-testid="caret"]')?.addEventListener('click', openMenu);
  };
  const item = (label, action) => {
    const node = doc.createElement('div');
    node.setAttribute('role', 'menuitem');
    node.textContent = label;
    node.addEventListener('click', () => { layers.innerHTML = ''; action(); });
    return node;
  };
  const sheet = (action) => {
    const node = doc.createElement('button');
    node.dataset.testid = 'confirmationSheetConfirm';
    node.addEventListener('click', () => { layers.innerHTML = ''; action(); render(); });
    layers.appendChild(node);
  };
  function openMenu() {
    const menu = doc.createElement('div');
    menu.setAttribute('role', 'menu');
    if (xState.own) menu.appendChild(item('Delete', () => sheet(() => { xState.deleted = true; })));
    else menu.appendChild(item(xState.following ? 'Unfollow @alice' : 'Follow @alice', () => { xState.following = !xState.following; }));
    layers.appendChild(menu);
  }
  doc.addEventListener('keydown', (event) => { if (event.key === 'Escape') layers.innerHTML = ''; });
  render();
  const step = (kind) => {
    now += 1300;
    return window.eval('(' + source + ')')({ id: '111', handle: 'alice', kind, token: 7 });
  };
  return { window, step };
}

function runUntilFinal(step, kind) {
  const stages = [];
  for (let i = 0; i < 20; i++) {
    const stage = step(kind);
    stages.push(stage);
    if (['done', 'already', 'not-applied', 'no-item', 'no-delete', 'no-menu', 'invalid'].includes(stage)) break;
  }
  return stages;
}

test('deletes the user\'s own post through the More menu and confirms it is gone', () => {
  const xState = { own: true };
  const { window, step } = fixture(xState);
  try {
    const stages = runUntilFinal(step, 'delete');
    assert.equal(stages.at(-1), 'done');
    assert.ok(stages.includes('confirming'));
    assert.equal(xState.deleted, true);
  } finally {
    window.close();
  }
});

test('refuses to delete someone else\'s post and follows them only once', () => {
  const other = fixture({ own: false });
  try {
    assert.equal(runUntilFinal(other.step, 'delete').at(-1), 'no-delete');
  } finally {
    other.window.close();
  }
  const xState = { own: false };
  const follow = fixture(xState);
  try {
    assert.equal(runUntilFinal(follow.step, 'follow').at(-1), 'done');
    assert.equal(xState.following, true);
  } finally {
    follow.window.close();
  }
  const again = fixture({ own: false, following: true });
  try {
    assert.equal(runUntilFinal(again.step, 'follow').at(-1), 'already');
  } finally {
    again.window.close();
  }
});
