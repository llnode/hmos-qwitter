const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { test } = require('node:test');
const assert = require('node:assert/strict');
const ts = require('typescript');
const source = readFileSync(join(__dirname, '../entry/src/main/ets/web/HlsPlaylist.ets'), 'utf8');
const code = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
const exported = {};
new Function('exports', code)(exported);
const { hlsLines, highestHlsVariant, hlsAudioPath, hlsParts } = exported;

test('selects highest resolution and its matching default audio rendition', () => {
  const lines = hlsLines('#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="wrong",DEFAULT=YES,URI="wrong.m3u8"\n' +
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="alternate",URI="alternate.m3u8"\n' +
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",DEFAULT=YES,URI="sound.m3u8"\n' +
    '#EXT-X-STREAM-INF:BANDWIDTH=9999999,RESOLUTION=640x360,AUDIO="wrong"\nlow.m3u8\n' +
    '#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080,AUDIO="aud"\nhigh.m3u8');
  const variant = highestHlsVariant(lines);
  assert.equal(variant.path, 'high.m3u8');
  assert.equal(hlsAudioPath(lines, variant.audioGroup), 'sound.m3u8');
});

test('preserves init and every media segment in playlist order including byte ranges', () => {
  const parts = hlsParts(hlsLines('#EXTM3U\n#EXT-X-MAP:URI="media.mp4",BYTERANGE="20@0"\n' +
    '#EXT-X-BYTERANGE:100@20\nmedia.mp4\n#EXT-X-BYTERANGE:50\nmedia.mp4\n#EXT-X-ENDLIST'));
  assert.deepEqual(parts, [{ path: 'media.mp4', range: 'bytes=0-19' },
    { path: 'media.mp4', range: 'bytes=20-119' }, { path: 'media.mp4', range: 'bytes=120-169' }]);
});

test('rejects incomplete live streams, encrypted segments and invalid ranges', () => {
  assert.throws(() => hlsParts(hlsLines('#EXTM3U\nsegment.ts')), /live/);
  assert.throws(() => hlsParts(hlsLines('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key"\nsegment.ts\n#EXT-X-ENDLIST')), /Encrypted/);
  assert.throws(() => hlsParts(hlsLines('#EXTM3U\n#EXT-X-BYTERANGE:100\nfirst.mp4\n#EXT-X-ENDLIST')), /range/);
  assert.throws(() => hlsLines('<html>Error</html>'), /Invalid/);
});
