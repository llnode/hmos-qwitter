const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { JSDOM } = require('jsdom');

const script = readFileSync(join(__dirname, '../entry/src/main/resources/rawfile/read-page.js'), 'utf8');
const inboxScript = readFileSync(join(__dirname, '../entry/src/main/resources/rawfile/read-inbox.js'), 'utf8');

test('recognizes an official cross-origin Chat frame without reading its contents', () => {
  for (const [host, expected] of [['chat.x.com', true], ['chat.x.com.example.test', false]]) {
    const { window } = new JSDOM('<main><iframe src="https://' + host + '/"></iframe></main>',
      { url: 'https://x.com/i/chat', runScripts: 'outside-only' });
    try {
      const page = window.eval(inboxScript);
      assert.equal(page.embeddedChat, expected);
      assert.equal(page.messages.length, 0);
    } finally {
      window.close();
    }
  }
});

test('reads inbox inside nested open scopes before avatar images resolve', () => {
  const { window } = new JSDOM('<main><div id="container"></div><button>Outside</button></main>',
    { url: 'https://x.com/i/chat', runScripts: 'outside-only' });
  try {
    const outer = window.document.querySelector('#container').attachShadow({ mode: 'open' });
    outer.innerHTML = '<div id="mount"></div>';
    const inbox = outer.querySelector('#mount').attachShadow({ mode: 'open' });
    inbox.innerHTML = '<div role="button" tabindex="0"><div role="button"><span role="img"></span>' +
      'Alice\nLatest message</div></div>';
    let clicks = 0;
    inbox.firstElementChild.addEventListener('click', () => clicks++);
    const result = window.eval(inboxScript);
    assert.equal(result.rows.length, 1);
    assert.equal(result.rows[0].title, 'Alice');
    assert.equal(result.rows[0].text, 'Latest message');
    assert.equal(result.rows[0].avatar, '');
    assert.equal(window.eval('const qyxInboxOpenKey = ' + JSON.stringify(result.rows[0].id) + ';' + inboxScript).opened, true);
    assert.equal(clicks, 1);
  } finally {
    window.close();
  }
});

test('keeps the official Chat host when opening a conversation from its inbox', () => {
  const { window } = new JSDOM('<main><a href="/chat/12-34">Alice</a></main>',
    { url: 'https://chat.x.com/', runScripts: 'outside-only' });
  try {
    const page = window.eval(inboxScript);
    assert.equal(page.rows[0].path, 'https://chat.x.com/chat/12-34');
    assert.equal(page.rows[0].id, 'c:12-34');
    window.history.replaceState(null, '', '/chat/12-34');
    assert.equal(window.eval(inboxScript).conversation, 'c:12-34');
  } finally {
    window.close();
  }
});

test('reads an avatar beside its message without using it for another sender', () => {
  const avatar = 'https://pbs.twimg.com/profile_images/123/chat.jpg';
  const { window } = new JSDOM('<main><div role="log">' +
    '<div><img src="' + avatar + '"><div data-message-id="1" data-outgoing="false">First message</div></div>' +
    '<div data-message-id="2" data-outgoing="false">Second message</div></div></main>',
  { url: 'https://x.com/i/chat/12-34', runScripts: 'outside-only' });
  try {
    const page = window.eval(inboxScript);
    assert.deepEqual(Array.from(page.messages, (message) => message.avatar), [avatar, '']);
  } finally {
    window.close();
  }
});

function evaluate(html, url) {
  const { window } = new JSDOM(html, { url, runScripts: 'outside-only' });
  try {
    const value = window.eval(script);
    return value ? JSON.parse(value) : null;
  } finally {
    window.close();
  }
}

test('reads notifications in web order and keeps only same-origin navigation targets', () => {
  const { window } = new JSDOM('<main><article data-notification-id="1">' +
    '<span data-testid="notificationText">A reply</span><a href="/Reader/status/101/photo/1"><time>5m</time></a>' +
    '<div data-testid="tweetText">Original text</div></article>' +
    '<article data-notification-id="2"><span data-testid="notificationText">External</span>' +
    '<a href="https://x.com.example.org/Reader/status/202">Outside</a></article></main>',
  { url: 'https://x.com/notifications', runScripts: 'outside-only' });
  try {
    const inbox = JSON.parse(JSON.stringify(window.eval(inboxScript)));
    assert.deepEqual(inbox.rows.map(({ id, path }) => [id, path]), [['n:1', '/Reader/status/101'], ['n:2', '']]);
    assert.equal(inbox.rows[0].text, 'Original text');
  } finally {
    window.close();
  }
});

test('reads article messages inside the X Chat log and excludes articles outside it', () => {
  const { window } = new JSDOM('<nav><article>Outside chat</article></nav><main>' +
    '<div role="log"><article><div data-message-text>First message</div><time>10:00</time></article>' +
    '<div role="article"><span data-message-text>Second message</span></div>' +
    '<article hidden>Hidden message</article></div></main>', {
      url: 'https://x.com/i/chat/12-34', runScripts: 'outside-only'
    });
  try {
    const inbox = JSON.parse(JSON.stringify(window.eval(inboxScript)));
    assert.equal(inbox.conversation, 'c:12-34');
    assert.deepEqual(inbox.messages.map(({ text, time }) => [text, time]), [['First message', '10:00'], ['Second message', '']]);
  } finally {
    window.close();
  }
});

test('reads sender groups, date headers and trailing bubble clocks without changing cached IDs', () => {
  const { window } = new JSDOM('<div role="log"><div>11月10日，下午 4:30</div>' +
    '<div><div id="alice">Alice</div><div><article id="one"><span>Hello</span> <span>16:30</span></article></div></div>' +
    '<div><article id="two"><span data-message-text>See you at 17:00</span> <small>16:31</small></article></div>' +
    '<div><article id="mine" data-message-id="3" aria-label="Sure 16:32"><span>Sure</span></article></div>' +
    '<div><article id="four" aria-label="Bob 16:33"><span>Goodbye</span></article></div></div>',
    { url: 'https://x.com/i/chat/12-34', runScripts: 'outside-only' });
  try {
    const box = (selector, left, top, width, height) => {
      window.document.querySelector(selector).getBoundingClientRect = () =>
        ({ left, top, width, height, right: left + width, bottom: top + height });
    };
    box('[role="log"]', 0, 0, 420, 800);
    box('#alice', 65, 60, 50, 15);
    box('#one', 55, 80, 110, 30);
    box('#two', 55, 115, 155, 30);
    box('#mine', 285, 150, 120, 30);
    box('#four', 55, 205, 125, 30);
    const inbox = JSON.parse(JSON.stringify(window.eval(inboxScript)));
    assert.deepEqual(inbox.messages.map(({ title, text, time, outgoing }) => [title, text, time, outgoing]), [
      ['Alice', 'Hello', '11月10日 16:30', false],
      ['Alice', 'See you at 17:00', '11月10日 16:31', false],
      ['', 'Sure', '11月10日 16:32', true],
      ['Bob', 'Goodbye', '11月10日 16:33', false]
    ]);
    let previousHash = 2166136261;
    for (const char of '\n\nHello 16:30') previousHash = Math.imul(previousHash ^ char.charCodeAt(0), 16777619);
    assert.equal(inbox.messages[0].id, 'm:' + (previousHash >>> 0).toString(36));
  } finally {
    window.close();
  }
});

test('identifies the selected X Chat conversation and keeps the PIN screen out of message snapshots', () => {
  const html = '<main><div role="option" data-conversation-id="alpha" aria-selected="true">Alice</div>' +
    '<div role="option" data-conversation-id="beta">Bob</div>' +
    '<div role="log"><div data-message-id="1" data-outgoing="true">' +
    '<span data-message-text>Test message</span><time>10:00</time></div></div></main>';
  const { window } = new JSDOM(html, { url: 'https://x.com/i/chat', runScripts: 'outside-only' });
  try {
    const inbox = JSON.parse(JSON.stringify(window.eval(inboxScript)));
    assert.deepEqual(inbox.rows.map((row) => row.id), ['c:alpha', 'c:beta']);
    assert.equal(inbox.conversation, 'c:alpha');
    assert.equal(inbox.messages[0].text, 'Test message');
    assert.equal(inbox.messages[0].outgoing, true);
    window.document.querySelector('main').insertAdjacentHTML('afterbegin', '<input type="password" value="0000">');
    const locked = JSON.parse(JSON.stringify(window.eval(inboxScript)));
    assert.equal(locked.locked, true);
    assert.deepEqual(locked.messages, []);
    assert.ok(!JSON.stringify(locked).includes('0000'));
    window.document.querySelector('input').remove();
    window.document.querySelector('main').insertAdjacentHTML('afterbegin',
      '<button data-testid="change-passcode">Change passcode</button>');
    const unlocked = window.eval(inboxScript);
    assert.equal(unlocked.locked, false);
    assert.equal(unlocked.messages.length, 1);
  } finally {
    window.close();
  }
});

test('detects a segmented PIN prompt on the official chat host without exporting field values', () => {
  const html = '<main><h1>恢复聊天</h1>' + '<input inputmode="numeric" maxlength="1" value="7">'.repeat(4) + '</main>';
  const { window } = new JSDOM(html, { url: 'https://chat.x.com/', runScripts: 'outside-only' });
  try {
    const inbox = window.eval(inboxScript);
    assert.equal(inbox.locked, true);
    assert.equal(inbox.rows.length, 0);
    assert.equal(inbox.messages.length, 0);
    assert.ok(!JSON.stringify(inbox).includes('7'));
  } finally {
    window.close();
  }
});

test('reads chat rows rendered beside the primary X column and skips X tab links', () => {
  const html = '<main data-testid="primaryColumn"></main><nav><a href="/i/chat/requests">Requests</a></nav>' +
    '<section id="chat-root"><button data-testid="dmConversationEntry" data-conversation-id="12-34">' +
    '<span data-testid="dmConversationName">Writer</span>\n<span>Last message</span></button></section>';
  const { window } = new JSDOM(html, { url: 'https://x.com/i/chat', runScripts: 'outside-only' });
  try {
    const inbox = window.eval(inboxScript);
    assert.deepEqual(Array.from(inbox.rows, (row) => row.id), ['c:12-34']);
    assert.equal(inbox.rows[0].text, 'Last message');
  } finally {
    window.close();
  }
});

test('recognizes the current signed-out homepage and legacy login route', () => {
  const loginLink = '<a href="/i/jf/onboarding/web?mode=login&amp;redirect_after_login=%2F">Sign in</a>';
  const home = evaluate(loginLink, 'https://x.com/');
  assert.equal(home.signedOut, true);
  assert.equal(home.authenticated, false);
  assert.deepEqual(home.posts, []);
  assert.equal(evaluate('', 'https://x.com/i/flow/login').signedOut, true);
  assert.equal(evaluate('', 'https://x.com/i/jf/onboarding/web?mode=login').signedOut, true);
  assert.equal(evaluate(loginLink, 'https://x.com.example.org/'), null);
  assert.equal(evaluate('', 'https://x.com/home').signedOut, false);
});

test('reads a signed-in timeline without mixing quoted posts or foreign media', () => {
  const post = [
    '<article data-testid="tweet">',
    '<div data-testid="User-Name"><a role="link" href="/Alicia">Alicia</a><a href="/Alicia">@Alicia</a>',
    '<a role="link" href="/Alicia/status/123"><time>3h</time></a></div>',
    '<div data-testid="tweetText">The actual post</div>',
    '<div data-testid="tweetPhoto"><img src="https://pbs.twimg.com/media/sample.jpg">',
    '<img src="data:image/gif;base64,R0lGODlh" srcset="https://pbs.twimg.com/media/next.jpg 680w">',
    '<img src="https://pbs.twimg.com.example.org/media/fake.jpg"></div>',
    '<div role="link"><article data-testid="tweet">',
    '<a role="link" href="/someone/status/456"><time>4h</time></a>',
    '<div data-testid="tweetText">Quoted text</div>' +
    '<img src="https://pbs.twimg.com/media/quoted.jpg"></article></div>',
    '<button data-testid="like">12</button>',
    '</article>'
  ].join('');
  const home = evaluate([
    '<a data-testid="AppTabBar_Profile_Link" href="/Reader">Profile</a>',
    '<main data-testid="primaryColumn">',
    '<div role="tablist"><button role="tab" aria-selected="false">For you</button>',
    '<button role="tab" aria-selected="true">Following</button></div>',
    post, post, '</main>'
  ].join(''), 'https://x.com/home');
  assert.equal(home.authenticated, true);
  assert.equal(home.signedOut, false);
  assert.equal(home.ownHandle, 'Reader');
  assert.equal(home.homeTab, 1);
  assert.deepEqual(home.posts.map(({ id, name, body, photos, quote, likes }) =>
    ({ id, name, body, photos, quote, likes })), [{
    id: '123', name: 'Alicia', body: 'The actual post',
    photos: ['https://pbs.twimg.com/media/sample.jpg', 'https://pbs.twimg.com/media/next.jpg'], quote: true, likes: '12'
  }]);
  assert.deepEqual(home.posts[0].quotedPost, {
    path: '/someone/status/456', handle: 'someone', name: '', avatar: '', time: '4h',
    body: 'Quoted text', photo: 'https://pbs.twimg.com/media/quoted.jpg', video: false, poster: '', ratio: 0
  });
});

test('keeps the real destination of wrapped links and routes X mentions by handle', () => {
  const html = '<nav><a data-testid="AppTabBar_Profile_Link" href="/Reader">Profile</a></nav>' +
    '<main><article><a href="/Author/status/101"><time>2h</time></a>' +
    '<div data-testid="tweetText"><p>Read <a href="https://t.co/example">https://<br>\n example.org/path</a>' +
    ' by <a href="/Alice">@Alice</a> <a href="/hashtag/News">#News</a></p>' +
    '<p>Next paragraph<br>Next line</p></div></article></main>';
  const post = evaluate(html, 'https://x.com/home').posts[0];
  assert.equal(post.body, 'Read https://example.org/path by @Alice #News\nNext paragraph\nNext line');
  assert.deepEqual(post.bodyLinks, [
    { label: 'https://example.org/path', target: 'https://t.co/example' },
    { label: '@Alice', target: '@Alice' }
  ]);
});

test('hides X ad placements and visible ad badges in home and replies without matching post text', () => {
  const post = (id, content, badge = '') => '<article><a href="/Author/status/' + id + '"><time>2h</time></a>' +
    badge + '<div data-testid="tweetText"><span>' + content + '</span></div></article>';
  const html = '<nav><a data-testid="AppTabBar_Profile_Link" href="/Reader">Profile</a></nav><main>' +
    post('101', 'Discussion') + post('102', 'Product', '<span>Ads</span>') +
    post('103', 'Product', '<span aria-label="Advertisement"></span>') +
    post('104', 'Product', '<span>广告</span>') +
    '<div data-testid="placementTracking">' + post('105', 'Product') + '</div>' +
    post('106', 'Ads') + '</main>';
  for (const url of ['https://x.com/home', 'https://x.com/Author/status/101']) {
    assert.deepEqual(evaluate(html, url).posts.map((entry) => entry.id), ['101', '106']);
  }
});

test('reads replies after the focused post even when its timestamp has no permalink', () => {
  const post = (handle, id, body) => '<article data-testid="tweet">' +
    '<a href="/' + handle + '">' + handle + '</a><a href="/' + handle + '/status/' + id + '"><time>3h</time></a>' +
    '<div data-testid="tweetText">' + body + '</div></article>';
  const replyEntry = (id, parent) => ({ item: { content: { tweet_results: { result: {
    rest_id: id, reply_to_results: { rest_id: parent }
  } } } } });
  const thread = { data: { threaded_conversation_with_injections_v2: { instructions: [
    { entries: [{ content: { items: [replyEntry('456', '123'), replyEntry('789', '456')] } }] }
  ] } } };
  const html = '<a data-testid="AppTabBar_Profile_Link" href="/Reader">Profile</a>' +
    '<main data-testid="primaryColumn">' + post('Parent', '100', 'Earlier in the thread') +
    '<article data-testid="tweet"><a href="/Author">Author</a><time>10:30 AM</time>' +
    '<a href="/Author/status/123/analytics">100 views</a><div data-testid="tweetText">Focused post</div>' +
    '<div data-testid="quoteTweet"><a href="/Quoted/status/200"><time>4h</time></a></div></article>' +
    post('Reply', '456', 'A reply') + post('Nested', '789', 'A nested reply') + '</main>' +
    '<script>({value:' + JSON.stringify(JSON.stringify(thread)) + '})</script>';

  const result = evaluate(html, 'https://x.com/i/web/status/123');
  assert.deepEqual(result.posts.map(({ id, replyToId, time, body }) => ({ id, replyToId, time, body })), [
    { id: '123', replyToId: '', time: '10:30 AM', body: 'Focused post' },
    { id: '456', replyToId: '123', time: '3h', body: 'A reply' },
    { id: '789', replyToId: '456', time: '3h', body: 'A nested reply' }
  ]);
});

test('switches the signed-in home timeline when X puts its tabs outside the primary column', () => {
  const html = '<a data-testid="AppTabBar_Profile_Link" href="/Reader">Profile</a>' +
    '<header role="tablist"><button role="tab" aria-selected="true">为你推荐</button>' +
    '<button role="tab" aria-selected="false">正在关注正在关注</button></header>' +
    '<main data-testid="primaryColumn"><article data-testid="tweet">' +
    '<a href="/Author/status/123"><time>1h</time></a></article></main>';
  const { window } = new JSDOM(html, { url: 'https://x.com/home', runScripts: 'outside-only' });
  try {
    const [recommended, following] = window.document.querySelectorAll('[role="tab"]');
    following.addEventListener('click', () => {
      recommended.setAttribute('aria-selected', 'false');
      following.setAttribute('aria-selected', 'true');
    });
    const select = () => JSON.parse(window.eval('(() => { const qyxHomeTarget = 1; return ' + script + '; })()'));
    assert.deepEqual(select().posts, []);
    assert.equal(select().homeTab, 1);
    assert.equal(select().posts[0].id, '123');
  } finally {
    window.close();
  }
});

test('reads the current X layout without legacy test IDs and keeps public previews signed out', () => {
  const article = [
    '<article><a href="/Alicia">Alicia</a><a href="/Alicia">@Alicia</a>',
    '<a href="/Alicia/status/123">3h</a>',
    '<div dir="auto" class="text-body whitespace-pre-wrap">Rendered timeline post</div>',
    '<div role="link"><a href="/other/status/456"><time>4h</time></a>',
    '<div dir="auto" class="whitespace-pre-wrap">Quoted text</div></div>',
    '<a href="/Alicia/status/123/photo/1"><img src="https://pbs.twimg.com/media/sample.jpg"></a>',
    '<div role="group"><button aria-label="23 喜欢"></button></div></article>'
  ].join('');
  const timeline = '<main><section aria-label="Timeline">' + article + '</section></main>';
  const home = evaluate([
    '<header><nav><div><button role="tab" aria-selected="true">为你推荐</button>',
    '<button role="tab" aria-selected="false">正在关注</button></div></nav></header>',
    timeline,
    '<nav><a href="/home">主页</a><a href="/notifications">通知</a><a href="/i/chat">私信</a></nav>'
  ].join(''), 'https://x.com/home');
  assert.equal(home.authenticated, true);
  assert.equal(home.homeTab, 0);
  assert.deepEqual(home.posts.map(({ id, name, body, time, likes, photos, quote }) =>
    ({ id, name, body, time, likes, photos, quote })), [{
    id: '123', name: 'Alicia', body: 'Rendered timeline post', time: '3h',
    likes: '23', photos: ['https://pbs.twimg.com/media/sample.jpg'], quote: true
  }]);
  const preview = evaluate(timeline +
    '<a href="/i/jf/onboarding/web?mode=login">Sign in</a>', 'https://x.com/Alicia/status/123');
  assert.equal(preview.authenticated, false);
  assert.equal(preview.signedOut, true);
  assert.deepEqual(preview.posts, []);
});

test('reads the current viewport after the first 32 posts are already in the DOM', () => {
  const nav = '<nav><a href="/home">Home</a><a href="/notifications">Notifications</a><a href="/i/chat">Chat</a></nav>';
  const articles = Array.from({ length: 60 }, (_, index) =>
    '<article data-index="' + index + '"><a href="/Alicia/status/' + (index + 1) + '">1h</a></article>').join('');
  const { window } = new JSDOM(nav + '<main>' + articles + '</main>', {
    url: 'https://x.com/home', runScripts: 'outside-only'
  });
  try {
    window.HTMLElement.prototype.getBoundingClientRect = function () {
      return { bottom: Number(this.dataset.index) >= 37 ? 100 : -100 };
    };
    const snapshot = JSON.parse(window.eval(script));
    assert.equal(snapshot.posts[0].id, '35');
    assert.equal(snapshot.posts.at(-1).id, '60');
  } finally {
    window.close();
  }
});

test('reads profile fields outside posts and preserves the decoded search query', () => {
  const nav = '<a data-testid="AppTabBar_Profile_Link" href="/Reader">Profile</a>';
  const profile = evaluate(nav + [
    '<main data-testid="primaryColumn">',
    '<div data-testid="UserName"><span dir="auto">Alicia</span><span>@Alicia</span></div>',
    '<div data-testid="UserDescription">Writing on the web</div>',
    '<a href="/Alicia/following">32 Following</a>',
    '<a href="/Alicia/followers">99 Followers</a></main>'
  ].join(''), 'https://x.com/Alicia');
  assert.equal(profile.profile.name, 'Alicia');
  assert.equal(profile.profile.followers, '99 Followers');
  assert.equal(evaluate(nav, 'https://x.com/search?q=HarmonyOS+%F0%9F%91%8B').query, 'HarmonyOS 👋');
});

test('keeps an X challenge and a guest shell with stale navigation out of the reader', () => {
  const nav = '<a data-testid="AppTabBar_Profile_Link" href="/Reader">Profile</a>';
  const login = '<a href="/i/jf/onboarding/web?mode=login">Sign in</a>';
  const guest = evaluate(nav + login, 'https://x.com/home');
  assert.equal(guest.authenticated, false);
  assert.equal(guest.signedOut, true);
  for (const path of ['/i/flow/challenge', '/i/flow/single_sign_on', '/i/jf/onboarding/web/sso',
    '/account/access', '/account/login-token', '/login/check']) {
    const challenge = evaluate(nav, 'https://x.com' + path);
    assert.equal(challenge.authenticated, false);
    assert.equal(challenge.signedOut, true);
  }
});

test('reads account avatars and modern profile details without mistaking a post avatar for the account', () => {
  const avatar = 'https://pbs.twimg.com/profile_images/123/reader.jpg';
  const banner = 'https://pbs.twimg.com/profile_banners/123/456/600x200';
  const nav = '<nav><a href="/Reader"><img src="' + avatar + '">個人檔案</a></nav>';
  const result = evaluate(nav + '<main><a href="/Reader/header_photo"><img src="' + banner + '"></a>' +
    '<div><h1>Reader</h1><svg aria-label="Verified account"></svg></div><img alt="@Reader" src="' + avatar + '">' +
    '<div><svg data-icon="icon-location-pin"></svg>Claymont</div>' +
    '<div><svg data-icon="icon-link"></svg><a href="https://t.co/sample">example.org</a></div>' +
    '<div><svg data-icon="icon-balloon"></svg>Born April 5</div>' +
    '<a href="/Reader/about">Joined March 2013</a>' +
    '<a href="/Reader/following">535 Following</a>' +
    '<a href="/Reader/verified_followers">2,191 Followers</a><a href="/Reader/media">Media</a></main>',
  'https://x.com/Reader/media');
  assert.equal(result.ownHandle, 'Reader');
  assert.equal(result.ownAvatar, avatar);
  assert.equal(result.profile.name, 'Reader');
  assert.equal(result.profile.banner, banner);
  assert.equal(result.profile.verified, true);
  assert.equal(result.profile.location, 'Claymont');
  assert.equal(result.profile.websiteUrl, 'https://t.co/sample');
  assert.equal(result.profile.birthday, 'Born April 5');
  assert.equal(result.profile.joined, 'Joined March 2013');
  assert.equal(result.profile.followers, '2,191 Followers');
  assert.deepEqual(result.profile.tabs, ['media', 'likes']);
  const other = evaluate(nav + '<main><h1>Other</h1><a href="/Other/following">12 Following</a>' +
    '<a href="/Other/media">Media</a></main>', 'https://x.com/Other/media');
  assert.deepEqual(other.profile.tabs, ['media']);
});

test('recognizes the signed-in handle on the mobile profile menu avatar', () => {
  const result = evaluate('<header><div role="button" aria-haspopup="true" aria-label="个人资料菜单 Reader">' +
    '<img alt="@Reader" src="https://pbs.twimg.com/profile_images/123/reader.jpg"></div></header><main></main>',
  'https://x.com/home');
  assert.equal(result.authenticated, true);
  assert.equal(result.ownHandle, 'Reader');
  assert.match(result.ownAvatar, /reader\.jpg$/);
});

test('follows the visible X settings link when a child needs to open through its parent page', () => {
  const source = readFileSync(join(__dirname, '../entry/src/main/resources/rawfile/read-settings.js'), 'utf8');
  const { window } = new JSDOM('<main><a hidden href="/settings/privacy_and_safety">Hidden</a>' +
    '<a href="https://x.com.example.org/settings/privacy_and_safety">External</a>' +
    '<a href="/settings/privacy_and_safety">Privacy and safety</a></main>',
  { url: 'https://x.com/settings', runScripts: 'outside-only' });
  try {
    const clicked = [];
    for (const link of window.document.querySelectorAll('a')) {
      link.addEventListener('click', (event) => { event.preventDefault(); clicked.push(link.textContent); });
    }
    window.qyxSettingsDestination = 'https://x.com/settings/privacy_and_safety';
    assert.equal(window.eval(source), true);
    assert.deepEqual(clicked, ['Privacy and safety']);
    window.qyxSettingsDestination = 'https://x.com.example.org/settings/privacy_and_safety';
    assert.equal(window.eval(source), false);
    assert.deepEqual(clicked, ['Privacy and safety']);
  } finally {
    window.close();
  }
});

test('finds the signed-in identity behind the mobile account menu and dismisses the probe', () => {
  const avatar = 'https://pbs.twimg.com/profile_images/123/reader.jpg';
  const { window } = new JSDOM('<header><button aria-label="个人资料菜单 Reader">' +
    '<img src="' + avatar + '"></button></header><main></main>', {
    url: 'https://x.com/home', runScripts: 'outside-only'
  });
  try {
    const { document } = window;
    const trigger = document.querySelector('button');
    let opens = 0;
    trigger.addEventListener('click', () => {
      opens++;
      document.body.insertAdjacentHTML('beforeend', '<div role="dialog" aria-label="个人资料菜单">' +
        '<a href="/account/switch">View all accounts</a><a href="/Reader"><img src="' + avatar + '"></a></div>');
      const menu = document.querySelector('[role="dialog"]');
      menu.addEventListener('keyup', (event) => { if (event.key === 'Escape') menu.remove(); });
    });
    const discover = () => JSON.parse(window.eval('(() => { const qyxDiscoverAccount = true; return ' + script + '; })()'));
    const initial = discover();
    assert.equal(initial.accountMenuPending, true);
    assert.equal(initial.ownAvatar, avatar);
    assert.equal(discover().ownHandle, 'Reader');
    assert.equal(document.querySelector('[role="dialog"]'), null);
    discover();
    assert.equal(opens, 1);
  } finally {
    window.close();
  }
});

test('collects video preview data separately from the post gallery', () => {
  const poster = 'https://pbs.twimg.com/ext_tw_video_thumb/1000/pu/img/poster.jpg';
  const source = 'https://video.twimg.com/ext_tw_video/1000/pu/vid/1280x720/sample.mp4?tag=14';
  const other = 'https://video.twimg.com/ext_tw_video/10000/pu/vid/640x360/other.mp4';
  const result = evaluate('<a data-testid="AppTabBar_Profile_Link" href="/Reader">Profile</a>' +
    '<main data-testid="primaryColumn"><article data-testid="tweet">' +
    '<a href="/Alicia/status/123"><time>2h</time></a>' +
    '<div data-testid="videoPlayer"><video poster="' + poster + '"></video>' +
    '<div data-testid="tweetPhoto"><img src="https://pbs.twimg.com/media/video-placeholder.jpg"></div> 0:08 </div>' +
    '<div data-testid="tweetPhoto"><img src="https://pbs.twimg.com/media/attachment.jpg"></div>' +
    '</article></main><script type="application/json">' +
    JSON.stringify([source, other, { media_url_https: poster, video_info: { duration_millis: 64000 } }]) + '</script>',
  'https://x.com/home');
  const [post] = result.posts;
  assert.equal(post.videoPoster, poster);
  assert.equal(post.videoDuration, '1:04');
  assert.deepEqual(post.videoSources, [source]);
  assert.deepEqual(post.photos, ['https://pbs.twimg.com/media/attachment.jpg']);
});

test('does not report the preview countdown as the full video duration', () => {
  const html = '<a data-testid="AppTabBar_Profile_Link" href="/Reader">Profile</a>' +
    '<main data-testid="primaryColumn"><article data-testid="tweet">' +
    '<a href="/Alicia/status/123"><time>2h</time></a>' +
    '<div data-testid="videoPlayer"><video></video> {time} </div></article></main>';
  assert.equal(evaluate(html.replace('{time}', '0:09'), 'https://x.com/home').posts[0].videoDuration, '');
  assert.equal(evaluate(html.replace('{time}', '0:09 / 2:38'), 'https://x.com/home').posts[0].videoDuration, '2:38');
});

test('targets the post heart, verifies the resulting state, and does not click the quoted post', () => {
  const html = '<a data-testid="AppTabBar_Profile_Link" href="/Reader">Profile</a>' +
    '<main><article><a href="/Alicia/status/123"><time>2h</time></a>' +
    '<div data-testid="quoteTweet"><button data-testid="unlike">7</button></div>' +
    '<button aria-label="12 喜欢次数。喜欢">12</button></article></main>';
  const { window } = new JSDOM(html, { url: 'https://x.com/home', runScripts: 'outside-only' });
  try {
    const button = window.document.querySelector('button[aria-label]');
    let clicks = 0;
    button.addEventListener('click', () => {
      clicks++;
      button.textContent = clicks === 1 ? '13' : '12';
      button.setAttribute('aria-label', clicks === 1 ? '13 喜欢次数。取消喜欢' : '12 喜欢次数。喜欢');
    });
    window.document.querySelector('[data-testid="unlike"]').addEventListener('click', () => assert.fail('clicked quote'));
    const act = (desired, click) => {
      window.qyxLikeAction = { id: '123', desired, click };
      return JSON.parse(window.eval(script));
    };
    assert.deepEqual(act(true, true), { status: 'clicked' });
    assert.deepEqual(act(true, true), { status: 'confirmed', liked: true, count: '13' });
    assert.deepEqual(act(false, false), { status: 'waiting' });
    assert.deepEqual(act(false, true), { status: 'clicked' });
    assert.deepEqual(act(false, false), { status: 'confirmed', liked: false, count: '12' });
    assert.equal(clicks, 2);
  } finally {
    window.close();
  }
});

test('confirms a repost using its own menu item and reads bookmark state', () => {
  const html = '<nav><a data-testid="AppTabBar_Profile_Link" href="/Reader">Profile</a></nav>' +
    '<main><article><a href="/Author/status/101"><time>2h</time></a>' +
    '<button data-testid="retweet">4</button><button data-testid="removeBookmark">Remove bookmark</button>' +
    '</article></main>';
  assert.equal(evaluate(html, 'https://x.com/home').posts[0].bookmarked, true);
  const { window } = new JSDOM(html, { url: 'https://x.com/home', runScripts: 'outside-only' });
  try {
    const document = window.document;
    const button = document.querySelector('[data-testid="retweet"]');
    button.addEventListener('click', () => {
      const menu = document.createElement('div');
      menu.innerHTML = '<button role="menuitem">Quote</button><button role="menuitem">Repost</button>';
      menu.children[0].addEventListener('click', () => assert.fail('clicked Quote'));
      menu.children[1].addEventListener('click', () => {
        button.dataset.testid = 'unretweet';
        button.textContent = '5';
        menu.remove();
      });
      document.body.append(menu);
    });
    window.qyxLikeAction = { id: '101', kind: 'repost', token: 1, desired: true, click: true };
    const act = () => JSON.parse(window.eval(script));
    assert.deepEqual(act(), { status: 'menu' });
    assert.deepEqual(act(), { status: 'clicked' });
    assert.deepEqual(act(), { status: 'confirmed', liked: true, count: '5' });
  } finally {
    window.close();
  }
});

test('extracts an X article preview without adding its cover to the photo grid', () => {
  const cover = 'https://pbs.twimg.com/media/article-cover.jpg';
  const result = evaluate('<nav><a aria-label="Profile" href="/Reader">Profile</a></nav>' +
    '<main><article><a href="/Alicia/status/123"><time>2h</time></a>' +
    '<div dir="auto" class="whitespace-pre-wrap">Read the article</div>' +
    '<a href="/Alicia/article/123"><img src="' + cover + '"><h2>The title</h2></a>' +
    '</article></main>', 'https://x.com/home');
  const [post] = result.posts;
  assert.equal(post.body, 'Read the article');
  assert.equal(post.articleTitle, 'The title');
  assert.equal(post.articlePath, '/Alicia/article/123');
  assert.equal(post.articleCover, cover);
  assert.deepEqual(post.photos, []);
});

test('reads nested settings links and controls for native rendering', () => {
  const settingsScript = readFileSync(join(__dirname, '../entry/src/main/resources/rawfile/read-settings.js'), 'utf8');
  const settings = (path, html) => {
    const { window } = new JSDOM(html, { url: 'https://x.com' + path, runScripts: 'outside-only' });
    try {
      return JSON.parse(window.eval(settingsScript));
    } finally {
      window.close();
    }
  };
  const privacy = settings('/settings/privacy_and_safety', '<main>' +
    '<a href="/settings/account">Account</a>' +
    '<a href="/settings/audience_and_tagging">Audience and tagging</a>' +
    '<a href="/settings/content_you_see">Content you see</a>' +
    '<a href="/settings/content_you_see">Duplicate</a>' +
    '<a href="https://help.x.com/zh-cn">帮助中心</a>' +
    '<a href="https://x.com.example.org/settings/account">External</a></main>');
  assert.deepEqual(privacy.entries.map(({path}) => path), [
    'https://x.com/settings/audience_and_tagging', 'https://x.com/settings/content_you_see', 'https://help.x.com/zh-cn'
  ]);
  assert.equal(privacy.interactive, false);
  const audience = settings('/settings/audience_and_tagging',
    '<main><button role="switch">Protect your posts</button>' +
    '<a href="/settings/tagging">Photo tagging</a></main>');
  assert.equal(audience.interactive, true);
  assert.equal(audience.entries[0].path, 'https://x.com/settings/tagging');
  assert.deepEqual(audience.rows.map(({kind}) => kind), ['toggle', 'link']);
  const root = settings('/settings', '<main><a href="/settings/account">Account</a>' +
    '<a href="/settings/privacy_and_safety">Privacy and safety</a></main>');
  assert.deepEqual(root.entries.map(({label}) => label), ['Account', 'Privacy and safety']);
});

test('uses the same X control for native settings changes and rejects a stale action', () => {
  const settingsScript = readFileSync(join(__dirname, '../entry/src/main/resources/rawfile/read-settings.js'), 'utf8');
  const { window } = new JSDOM('<main><h1>Account</h1><form>' +
    '<label>Protect posts <input type="checkbox"></label>' +
    '<label>Language <select><option value="en">English</option><option value="zh">中文</option></select></label>' +
    '<label>Password <input type="password" value="stored"></label><button>Save</button></form></main>',
  { url: 'https://x.com/settings/account', runScripts: 'outside-only' });
  try {
    const read = () => JSON.parse(window.eval(settingsScript));
    const apply = (action) => JSON.parse(window.eval('(() => {const qyxSettingAction = ' +
      JSON.stringify(action) + '; return ' + settingsScript + ';})()'));
    const page = read();
    const [toggle, select, password, save] = page.rows;
    assert.equal(password.value, '');
    assert.equal(apply({ ...toggle, route: page.route, label: 'wrong control', checked: true }).applied, false);
    assert.equal(apply({ ...toggle, route: page.route, checked: true }).applied, true);
    assert.equal(read().rows[0].checked, true);
    assert.equal(apply({ ...select, route: page.route, value: 'zh' }).applied, true);
    assert.equal(read().rows[1].value, 'zh');
    let submitted = '';
    window.document.querySelector('form').addEventListener('submit', (event) => {
      event.preventDefault();
      submitted = window.document.querySelector('input[type="password"]').value;
    });
    assert.equal(apply({ ...save, route: page.route, fields: [{ ...password, value: 'typed' }] }).applied, true);
    assert.equal(submitted, 'typed');
    assert.equal(read().rows[2].value, '');
  } finally {
    window.close();
  }
});

test('reads lazy, CSS, and default post avatars without inheriting a quoted avatar', () => {
  const css = 'https://pbs.twimg.com/profile_images/123/real_normal.jpg';
  const lazy = 'https://pbs.twimg.com/profile_images/456/lazy_normal.jpg';
  const fallback = 'https://pbs.twimg.com/default_profile_images/default_profile_normal.png';
  const post = (handle, id, avatar) => '<article><a href="/' + handle + '">' + avatar + '</a>' +
    '<a href="/' + handle + '/status/' + id + '"><time>1h</time></a>' +
    '<div data-testid="tweetText">Body</div><div data-testid="quoteTweet">' +
    '<img src="https://pbs.twimg.com/profile_images/999/other.jpg"></div></article>';
  const snapshot = evaluate('<nav><a href="/home">Home</a><a href="/notifications">Notifications</a>' +
    '<a href="/i/chat">Chat</a></nav><main>' +
    post('Css', 11, '<div style="background-image: url(' + css + ')"></div>') +
    post('Lazy', 12, '<img data-srcset="' + lazy + ' 100w">') +
    post('Default', 13, '<img src="' + fallback + '">') +
    post('Missing', 14, '<img src="https://pbs.twimg.com.example.org/profile_images/1/fake.jpg">') +
    '</main>', 'https://x.com/home');
  assert.deepEqual(snapshot.posts.map((item) => item.avatar), [css, lazy, fallback, '']);
});

test('keeps reading the same conversation when later reply pages unmount the focused post', () => {
  const nav = '<a data-testid="AppTabBar_Profile_Link" href="/Reader">Profile</a>';
  const post = (id, parent) => '<article' + (parent ? ' data-in-reply-to-status-id="' + parent + '"' : '') +
    '><a href="/Alicia/status/' + id + '"><time>1h</time></a></article>';
  const { window } = new JSDOM(nav + '<main>' + post(40) + post(100) + post(101, 100) + '</main>', {
    url: 'https://x.com/Alicia/status/100', runScripts: 'outside-only'
  });
  try {
    const read = () => JSON.parse(window.eval(script)).posts;
    const replies = new Set(read().filter((item) => item.replyToId === '100').map((item) => item.id));
    assert.deepEqual([...replies], ['101']);
    for (const start of [102, 132, 162, 192]) {
      const next = Array.from({ length: Math.min(30, 201 - start) }, (_, i) => post(start + i, 100)).join('');
      window.document.querySelector('main').innerHTML = post(40) + next;
      const items = read();
      assert.ok(items.every((item) => item.replyToId === '100'));
      for (const item of items) replies.add(item.id);
    }
    assert.equal(replies.size, 100);
  } finally {
    window.close();
  }
});

test('settings keep a control addressable across DOM updates and report what X actually displays', () => {
  const js = readFileSync(join(__dirname, '../entry/src/main/resources/rawfile/read-settings.js'), 'utf8');
  const { window } = new JSDOM('<main><h1>Accessibility</h1><button aria-pressed="false">Reduce motion</button></main>',
    { url: 'https://x.com/settings/accessibility', runScripts: 'outside-only' });
  try {
    const read = () => JSON.parse(window.eval(js));
    const apply = (action) => JSON.parse(window.eval('(() => {const qyxSettingAction = ' +
      JSON.stringify(action) + '; return ' + js + ';})()'));
    const first = read();
    const action = { ...first.rows[0], route: first.route, checked: true };
    const toggle = window.document.querySelector('button');
    toggle.before(window.document.createElement('p'));
    toggle.previousSibling.textContent = 'New web copy added before the setting';
    toggle.addEventListener('click', () => {
      toggle.setAttribute('aria-pressed', 'true');
      const status = window.document.createElement('div');
      status.setAttribute('role', 'status');
      status.textContent = 'Saved';
      toggle.after(status);
    });
    assert.equal(apply(action).applied, true);
    const confirmed = read();
    assert.equal(confirmed.documentId, first.documentId);
    assert.equal(confirmed.rows.find((item) => item.key === action.key).checked, true);
    assert.equal(confirmed.notice, 'Saved');
    assert.equal(apply({ ...action, route: 'https://x.com/settings/display' }).applied, false);
  } finally {
    window.close();
  }
});

test('keeps changes requiring Save in the X form and reports invalid input before submitting', () => {
  const js = readFileSync(join(__dirname, '../entry/src/main/resources/rawfile/read-settings.js'), 'utf8');
  const { window } = new JSDOM('<main><h1>Account</h1><form>' +
    '<label>Email <input type="email" required></label><label>Option <input type="checkbox"></label>' +
    '<button type="submit">Save changes</button></form></main>',
    { url: 'https://x.com/settings/email', runScripts: 'outside-only' });
  try {
    const read = () => JSON.parse(window.eval(js));
    const apply = (action) => JSON.parse(window.eval('(() => {const qyxSettingAction = ' +
      JSON.stringify(action) + '; return ' + js + ';})()'));
    const page = read();
    const [email, toggle] = page.rows;
    let submissions = 0;
    window.document.querySelector('form').addEventListener('submit', (event) => {
      event.preventDefault();
      submissions++;
    });
    assert.equal(email.inputType, 'email');
    assert.equal(toggle.deferred, true);
    assert.equal(apply({ ...toggle, route: page.route, checked: true }).applied, true);
    assert.equal(submissions, 0);
    const invalid = apply({ ...email, route: page.route, submit: true, fields: [{ ...email, value: 'bad' }] });
    assert.equal(invalid.applied, false);
    assert.ok(invalid.error);
    assert.equal(submissions, 0);
    assert.equal(apply({ ...email, route: page.route, submit: true,
      fields: [{ ...email, value: 'reader@example.com' }] }).applied, true);
    assert.equal(submissions, 1);
  } finally {
    window.close();
  }
});

test('reads X search posts from a mixed layout and distinguishes no results from loading', () => {
  const nav = '<a data-testid="AppTabBar_Profile_Link" href="/Reader">Profile</a>';
  const term = '#鸿蒙 from:OpenHarmony';
  const url = 'https://x.com/search?q=' + encodeURIComponent(term) + '&src=typed_query';
  const result = evaluate(nav + '<main data-testid="primaryColumn"><article>' +
    '<a href="/OpenHarmony">OpenHarmony</a><a href="/OpenHarmony/status/123">1h</a>' +
    '<div dir="auto" class="whitespace-pre-wrap">A matching post</div>' +
    '</article></main>', url);
  assert.equal(result.query, term);
  assert.deepEqual(result.posts.map(({ id, body }) => ({ id, body })), [{ id: '123', body: 'A matching post' }]);
  assert.equal(result.empty, false);
  assert.equal(evaluate(nav + '<main><div role="status">Loading</div></main>', url).empty, false);
  assert.equal(evaluate(nav + '<main><h2>沒有找到相關結果</h2></main>', url).empty, true);
});

test('uses the X translation control only in the selected language and preserves the original', () => {
  const html = '<html lang="ja"><nav><a data-testid="AppTabBar_Profile_Link" href="/Reader">Profile</a></nav>' +
    '<main data-testid="primaryColumn"><article data-testid="tweet">' +
    '<a href="/Writer/status/123"><time>1h</time></a><div data-testid="tweetText" lang="en">Hello</div>' +
    '<button data-testid="translateTweet">ポストを翻訳</button></article></main></html>';
  const { window } = new JSDOM(html, { url: 'https://x.com/home', runScripts: 'outside-only' });
  try {
    let clicks = 0;
    const article = window.document.querySelector('article');
    article.querySelector('button').addEventListener('click', () => {
      clicks++;
      article.insertAdjacentHTML('beforeend', '<div data-testid="tweetText" lang="ja">こんにちは</div>');
    });
    const read = (locale, cached = [], targetId = '') => JSON.parse(window.eval('(() => {const qyxTranslationLocale = ' +
      JSON.stringify(locale) + '; const qyxKnownTranslationIds = ' + JSON.stringify(cached) +
      '; const qyxTranslationPostId = ' + JSON.stringify(targetId) + '; return ' + script + ';})()')).posts[0];
    assert.equal(read('fr-FR').translation, undefined);
    assert.equal(read('ja-JP', ['123']).body, 'Hello');
    assert.equal(read('ja-JP', [], '456').body, 'Hello');
    assert.equal(clicks, 0);
    assert.equal(read('ja-JP', [], '123').body, 'Hello');
    const translated = read('ja-JP');
    assert.equal(translated.body, 'Hello');
    assert.equal(translated.translation, 'こんにちは');
    assert.equal(translated.translationLanguage, 'ja-JP');
    assert.equal(clicks, 1);
  } finally {
    window.close();
  }
});

test('recovers the original when X initially displays a translated post', () => {
  const html = '<html lang="zh-CN"><nav><a data-testid="AppTabBar_Profile_Link" href="/Reader">Profile</a></nav>' +
    '<main data-testid="primaryColumn"><article data-testid="tweet">' +
    '<a href="/Writer/status/123"><time>1h</time></a><div data-testid="tweetText" lang="zh-CN">早上好</div>' +
    '<button>查看原文</button></article></main></html>';
  const { window } = new JSDOM(html, { url: 'https://x.com/home', runScripts: 'outside-only' });
  try {
    const article = window.document.querySelector('article');
    const body = article.querySelector('[data-testid="tweetText"]');
    const button = article.querySelector('button');
    let clicks = 0;
    button.addEventListener('click', () => { clicks++; });
    const read = () => JSON.parse(window.eval('(() => {const qyxTranslationLocale = "zh-CN"; return ' +
      script + ';})()')).posts[0];

    assert.equal(read().translation, undefined);
    assert.equal(read().translation, undefined);
    assert.equal(clicks, 1);
    button.textContent = '翻译帖子';
    body.textContent = 'おはよう';
    body.lang = 'ja';
    const result = read();
    assert.equal(result.body, 'おはよう');
    assert.equal(result.translation, '早上好');
    assert.equal(result.translationLanguage, 'zh-CN');
    assert.equal(result.sourceLanguage, 'ja');
  } finally {
    window.close();
  }
});

test('restores a quoted post address when X renders the quote as a link with no href', () => {
  const pageData = {
    result: {
      rest_id: '100',
      quoted_status_result: { result: { rest_id: '200', core: {
        user_results: { result: { core: { screen_name: 'Original' } } }
      } } }
    }
  };
  const html = '<a data-testid="AppTabBar_Profile_Link" href="/Reader">Profile</a>' +
    '<main><article><a href="/Writer/status/100"><time>1h</time></a>' +
    '<div data-testid="tweetText">Comment</div><div role="link">' +
    '<div dir="auto" class="whitespace-pre-wrap">Original post</div></div></article></main>' +
    '<script type="application/json">' + JSON.stringify(pageData) + '</script>';
  const result = evaluate(html, 'https://x.com/home');
  assert.equal(result.posts[0].quotedPost.path, '/Original/status/200');
  assert.equal(result.posts[0].quotedPost.body, 'Original post');
});

test('recognizes a video in search before X mounts its player', () => {
  const nav = '<a data-testid="AppTabBar_Profile_Link" href="/Reader">Profile</a>';
  const result = evaluate(nav + '<main data-testid="primaryColumn"><article>' +
    '<a href="/Writer/status/123"><time>1h</time></a><div data-testid="tweetText">A clip</div>' +
    '<a href="/Writer/status/123/video/1"><img data-src="https://pbs.twimg.com/ext_tw_video_thumb/321/pu/img/clip.jpg"></a>' +
    '<img src="https://pbs.twimg.com/media/photo.jpg"></article></main>',
    'https://x.com/search?q=video&f=live');
  assert.equal(result.latestSearch, true);
  assert.equal(result.posts[0].video, true);
  assert.equal(result.posts[0].videoPoster, 'https://pbs.twimg.com/ext_tw_video_thumb/321/pu/img/clip.jpg');
  assert.deepEqual(result.posts[0].photos, ['https://pbs.twimg.com/media/photo.jpg']);
});

test('reads media tiles and profile tabs even when X puts tabs outside the post list', () => {
  const nav = '<a data-testid="AppTabBar_Profile_Link" href="/Reader">Profile</a>' +
    '<nav><a href="/Reader/with_replies">Replies</a><a href="/Reader/reposts">Reposts</a>' +
    '<a href="/Reader/media/grid">Media</a><a href="/Reader/likes">Likes</a></nav>';
  const result = evaluate(nav + '<main><h1>Reader</h1><img alt="@Reader" src="https://pbs.twimg.com/profile_images/1/avatar.jpg">' +
    '<a href="/Reader/status/100/photo/1"><img src="https://pbs.twimg.com/media/photo.jpg"></a>' +
    '<a href="/Reader/status/101/video/1"><img src="https://pbs.twimg.com/amplify_video_thumb/1/clip.jpg"></a></main>',
    'https://x.com/Reader/media/grid');
  assert.deepEqual(result.profile.tabs, ['with_replies', 'reposts', 'likes', 'media']);
  assert.deepEqual(result.posts.map(({ id, video }) => ({ id, video })), [{ id: '100', video: false }, { id: '101', video: true }]);
});

test('follows a quote without a permalink through its wrapper and leaves body links alone', () => {
  const html = '<a data-testid="AppTabBar_Profile_Link" href="/Reader">Profile</a>' +
    '<main><article><a href="/Writer/status/100"><time>1h</time></a>' +
    '<div data-testid="tweetText">Comment</div><div data-testid="quoteTweet">' +
    '<div data-testid="tweetText">Original <a href="/Someone/status/300">third post</a></div>' +
    '</div></article></main>';
  const { window } = new JSDOM(html, { url: 'https://x.com/Writer/status/100', runScripts: 'outside-only' });
  try {
    const quote = window.document.querySelector('[data-testid="quoteTweet"]');
    quote.addEventListener('click', (event) => {
      assert.equal(event.target, quote);
      window.history.pushState(null, '', '/Original/status/200');
    });
    window.eval('const qyxOpenQuote = "100";' + script);
    assert.equal(window.location.pathname, '/Original/status/200');
  } finally {
    window.close();
  }
});

test('canonicalizes a quoted media link and ignores links to other posts in quote text', () => {
  const html = '<a data-testid="AppTabBar_Profile_Link" href="/Reader">Profile</a>' +
    '<main><article><a href="/Writer/status/100"><time>1h</time></a>' +
    '<div data-testid="quoteTweet"><div data-testid="tweetText"><a href="/Other/status/999">third post</a></div>' +
    '<a href="/Original/status/200/video/1"><img src="https://pbs.twimg.com/ext_tw_video_thumb/123/pu/img/a.jpg">' +
    '</a></div></article></main>';
  assert.equal(evaluate(html, 'https://x.com/Writer/status/100').posts[0].quotedPost.path, '/Original/status/200');
});

test('reads X immersive recommendation cards in web order and excludes the underlying page and ads', () => {
  const cell = (id, handle, extra = '') => '<div data-testid="cellInnerDiv-tweet-' + id + '">' +
    '<div data-testid="User-Name"><a href="/' + handle + '">Name</a><a href="/' + handle + '">@' + handle +
    '</a></div><div data-testid="tweetText">Caption ' + id + '</div>' +
    '<div data-testid="videoPlayer"><video poster="https://pbs.twimg.com/ext_tw_video_thumb/' + id +
    '/pu/img/a.jpg"></video></div>' + extra + '</div>';
  const html = '<a data-testid="AppTabBar_Profile_Link" href="/Reader">Profile</a>' +
    '<main><article><a href="/Other/status/999"><time>2h</time></a></article></main>' +
    '<div data-testid="modalContainer"></div><div data-testid="vss-scroll-view">' + cell('100', 'Seed') + cell('400', 'Next') +
    cell('300', 'Promoted', '<span>Ad</span>') + cell('200', 'Last') + '</div>';
  const result = evaluate(html, 'https://x.com/Seed/status/100/mediaViewer?currentTweet=400');
  assert.deepEqual(result.posts.map(({ id, handle, video, body }) => [id, handle, video, body]), [
    ['100', 'Seed', true, 'Caption 100'], ['400', 'Next', true, 'Caption 400'], ['200', 'Last', true, 'Caption 200']
  ]);
});


test('reads an immersive video viewer even when X omits the navigation chrome', () => {
  const html = '<div role="dialog"><div data-testid="cellInnerDiv-tweet-400">' +
    '<div data-testid="User-Name"><a href="/Next">Next</a><a href="/Next">@Next</a></div>' +
    '<div data-testid="videoPlayer"><video poster="https://pbs.twimg.com/ext_tw_video_thumb/400/pu/img/a.jpg"></video></div>' +
    '</div></div>';
  const result = evaluate(html, 'https://x.com/Seed/status/100/mediaViewer');
  assert.equal(result.authenticated, true);
  assert.deepEqual(result.posts.map(({ id, handle, video }) => [id, handle, video]), [['400', 'Next', true]]);
});

test('reads discovery from X while separating US trends and excluding promoted rows', () => {
  const { window } = new JSDOM(
    '<a data-testid="AppTabBar_Profile_Link" href="/owner">Profile</a><main data-testid="primaryColumn"></main>' +
    '<aside data-testid="sidebarColumn">' +
    '<div data-testid="trend">Shanghai trending\n<span data-testid="trendName">Local topic</span></div>' +
    '<div data-testid="trend">Trending in the United States\n<span data-testid="trendName">US topic</span></div>' +
    '<div data-testid="trend"><span>Promoted by advertiser</span><span data-testid="trendName">Ad topic</span></div>' +
    '<div data-testid="UserCell"><a href="/example">Example</a></div>' +
    '<section><h2>NFL</h2><ul><li>Giants vs Commanders</li></ul></section></aside>',
    { url: 'https://x.com/home', runScripts: 'outside-only' });
  try {
    const snapshot = JSON.parse(window.eval(script));
    assert.deepEqual(snapshot.discovery.map(({ kind, rows }) => [kind, rows.map(({ title }) => title)]), [
      ['trends', ['Local topic']], ['us', ['US topic']], ['people', ['Example']], ['sports', ['Giants vs Commanders']]
    ]);
  } finally {
    window.close();
  }
});

test('uses the X sports tab for the sports section on the narrow explore layout', () => {
  const { window } = new JSDOM(
    '<a data-testid="AppTabBar_Profile_Link" href="/owner">Profile</a><main data-testid="primaryColumn">' +
    '<div data-testid="trend"><span data-testid="trendName">World Cup</span></div></main>',
    { url: 'https://x.com/explore/tabs/sports', runScripts: 'outside-only' });
  try {
    const snapshot = JSON.parse(window.eval(script));
    assert.equal(snapshot.discovery[0].kind, 'sports');
    assert.equal(snapshot.discovery[0].rows[0].query, 'World Cup');
  } finally {
    window.close();
  }
});

test('switches X notification tabs in place and waits for selection before reading', () => {
  const { window } = new JSDOM('<main><nav aria-label="通知时间线" role="tablist">' +
    '<button role="tab" aria-selected="true">全部</button>' +
    '<button role="tab" aria-selected="false">优先</button>' +
    '<button role="tab" aria-selected="false">提及</button></nav>' +
    '<section data-testid="primaryColumn"><div data-testid="cellInnerDiv">Onboarding banner</div><div role="article">Another onboarding banner</div><article data-notification-id="123">All notification</article></section></main>',
  { url: 'https://x.com/notifications', runScripts: 'outside-only' });
  try {
    const tabs = [...window.document.querySelectorAll('[role="tab"]')];
    tabs.forEach((tab) => tab.addEventListener('click', () => {
      tabs.forEach((item) => item.setAttribute('aria-selected', String(item === tab)));
      window.document.querySelector('article').textContent = tab.textContent + ' notification';
    }));
    const read = (category) => window.eval('(() => { const qyxNotificationCategory = ' +
      JSON.stringify(category) + '; return ' + inboxScript + '; })()');
    assert.deepEqual(Array.from(read('/notifications').rows, (row) => row.title), ['All notification']);
    for (const [path, title] of [['/notifications/verified', '优先'], ['/notifications/mentions', '提及'], ['/notifications', '全部']]) {
      assert.equal(read(path), null);
      assert.equal(read(path), null);
      assert.equal(read(path).rows[0].title, title + ' notification');
    }
  } finally {
    window.close();
  }
});


test('reads people search as native account data without sidebar recommendations or ads', () => {
  const cell = (handle, promoted = false) => '<div data-testid="UserCell">' +
    '<a href="/' + handle + '"><img src="https://pbs.twimg.com/profile_images/1/avatar_normal.jpg"></a>' +
    '<a href="/' + handle + '"><div data-testid="User-Name">Alice</div></a>' +
    '<a href="/' + handle + '">@' + handle + '</a><div data-testid="UserDescription">Open source developer</div>' +
    '<svg data-testid="icon-verified"></svg>' + (promoted ? '<span>Promoted</span>' : '') + '</div>';
  const page = evaluate('<a data-testid="AppTabBar_Profile_Link" href="/Reader">Profile</a>' +
    '<main data-testid="primaryColumn">' + cell('Alice') + cell('AdUser', true) + '</main>' +
    '<aside data-testid="sidebarColumn">' + cell('Other') + '</aside>',
    'https://x.com/search?q=Alice&src=typed_query&f=user');
  assert.equal(page.searchMode, 'people');
  const people = page.discovery.find(section => section.kind === 'people').rows;
  assert.equal(people.length, 1);
  assert.equal(people[0].path, '/Alice');
  assert.equal(people[0].title, 'Alice');
  assert.equal(people[0].subtitle, '@Alice\nOpen source developer');
  assert.equal(people[0].verified, true);
  assert.match(people[0].avatar, /profile_images/);
});

test('identifies all five official search filters separately', () => {
  for (const [filter, mode] of [['', 'top'], ['live', 'latest'], ['user', 'people'], ['video', 'videos'], ['image', 'photos']]) {
    const page = evaluate('<a data-testid="AppTabBar_Profile_Link" href="/Reader">Profile</a><main></main>',
      'https://x.com/search?q=test&src=typed_query' + (filter ? '&f=' + filter : ''));
    assert.equal(page.searchMode, mode);
    assert.equal(page.query, 'test');
  }
});
