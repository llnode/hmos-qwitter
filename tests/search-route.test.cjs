const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { test } = require('node:test');
const assert = require('node:assert/strict');
const ts = require('typescript');
const source = readFileSync(join(__dirname, '../entry/src/main/ets/web/XPage.ets'), 'utf8');
const routeSource = "const X_ORIGIN = 'https://x.com';\n" + source.slice(source.indexOf('export enum Surface'), source.indexOf('export class PostBodyLink'));
const compiled = ts.transpileModule(routeSource, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
const exported = {};
new Function('exports', compiled)(exported);
const { Surface, XRoute } = exported;
test('keeps five search routes distinct and preserves Unicode queries and legacy Latest routes', () => {
  const query = '鸿蒙 & from:OpenHarmony';
  const urls = [['top', null], ['latest', 'live'], ['people', 'user'], ['videos', 'video'], ['photos', 'image']].map(([mode, filter]) => {
    const url = new URL(new XRoute(Surface.Search, '/search', query, 0, '', false, mode).url());
    assert.equal(url.searchParams.get('q'), mode === 'photos' ? query + ' filter:images' : query);
    assert.equal(url.searchParams.get('f'), filter);
    return url.href;
  });
  assert.equal(new Set(urls).size, 5);
  assert.equal(new URL(new XRoute(Surface.Search, '/search', query, 0, '', true).url()).searchParams.get('f'), 'live');
});
