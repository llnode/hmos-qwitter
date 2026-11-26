const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { JSDOM } = require('jsdom');

const index = readFileSync(join(__dirname, '../entry/src/main/ets/pages/Index.ets'), 'utf8');
const trace = index.match(/const LOGIN_PASSWORD_TRACE: string = (`[\s\S]*?`);/)[1];
const html = '<form><input required value="fixture"><button>Continue</button></form>' +
  '<button>Use password</button><a href="#help">Help</a>';

function fixture(savedCooldown) {
  const { window } = new JSDOM(html, {
    url: 'https://x.com/i/jf/onboarding/web?mode=login',
    runScripts: 'outside-only'
  });
  let observer;
  let now = 100000;
  window.Date.now = () => now;
  window.PerformanceObserver = class {
    constructor(callback) { observer = callback; }
    observe() {}
  };
  window.console.info = () => {};
  if (savedCooldown) window.sessionStorage.setItem('qwitter.login.cooldown', savedCooldown);
  window.eval(window.eval(trace));
  return {
    window,
    doc: window.document,
    advance: (ms) => { now += ms; },
    respond: (responseStatus) => observer({
      getEntries: () => [{
        initiatorType: 'fetch',
        name: 'https://api.x.com/1.1/onboarding/task.json',
        responseStatus
      }]
    })
  };
}

test('permits first native submission, blocks repeat, and opens the password action after response', () => {
  const { window, doc, respond } = fixture();
  try {
    let submits = 0;
    let passwordClicks = 0;
    doc.querySelector('form').onsubmit = (event) => { event.preventDefault(); submits++; };
    doc.querySelectorAll('button')[1].onclick = () => { passwordClicks++; };
    doc.querySelector('button').click();
    doc.querySelector('button').click();
    assert.equal(submits, 1);
    respond(200);
    doc.querySelector('button').click();
    assert.equal(submits, 1);
    doc.querySelectorAll('button')[1].click();
    doc.querySelectorAll('button')[1].click();
    assert.equal(passwordClicks, 1);
  } finally {
    window.close();
  }
});

test('blocks login submissions during a 429 cooldown, including after reload, and allows a later retry', () => {
  const { window, doc, respond, advance } = fixture();
  let reloaded;
  try {
    let clicks = 0;
    const password = doc.querySelectorAll('button')[1];
    password.onclick = () => { clicks++; };
    password.click();
    respond(429);
    password.click();
    assert.equal(clicks, 1);
    reloaded = fixture(window.sessionStorage.getItem('qwitter.login.cooldown'));
    let submits = 0;
    const form = reloaded.doc.querySelector('form');
    form.onsubmit = (event) => { event.preventDefault(); submits++; };
    form.requestSubmit();
    assert.equal(submits, 0);
    reloaded.advance(300001);
    form.requestSubmit();
    assert.equal(submits, 1);
  } finally {
    window.close();
    reloaded?.window.close();
  }
});

test('reports passkeys as unavailable so X keeps the password step', async () => {
  const { window } = new JSDOM(html, { url: 'https://x.com/i/flow/login', runScripts: 'outside-only' });
  try {
    const messages = [];
    window.console.info = (message) => { messages.push(message); };
    window.PublicKeyCredential = function PublicKeyCredential() {};
    let nativeCalls = 0;
    Object.defineProperty(window.navigator, 'credentials', {
      value: { get: () => { nativeCalls++; return Promise.resolve(null); } }, configurable: true
    });
    window.eval(window.eval(trace));
    assert.equal(typeof window.PublicKeyCredential, 'undefined');
    await assert.rejects(window.navigator.credentials.get({ publicKey: {} }), (error) => error.name === 'NotAllowedError');
    assert.equal(nativeCalls, 0);
    assert.ok(messages.includes('qwitter-login-trace:passkeys-hidden'));
    assert.ok(messages.includes('qwitter-login-trace:webauthn-blocked'));
  } finally {
    window.close();
  }
});
