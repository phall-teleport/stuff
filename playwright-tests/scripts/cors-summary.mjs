// Summarize cors-log/cors-evidence.jsonl and say which theory the data supports.
import { readFileSync } from 'node:fs';
const rows = readFileSync(new URL('../cors-log/cors-evidence.jsonl', import.meta.url), 'utf8')
  .trim().split('\n').filter(Boolean).map((l) => JSON.parse(l)).filter((r) => r.outcome !== 'not-seen');
if (!rows.length) { console.log('no samples yet'); process.exit(0); }

const pad = (s, n) => String(s ?? '-').padEnd(n);
console.log(pad('time', 25) + pad('pop', 12) + pad('outcome', 14) + pad('x-cache', 22) + pad('age', 6) + pad('acao', 40) + 'corsError');
for (const r of rows) console.log(pad(r.at, 25) + pad(r.pop, 12) + pad(r.outcome, 14) + pad(r.xCache, 22) + pad(r.age, 6) + pad(r.acao, 40) + (r.corsError ?? ''));

const ok = rows.filter((r) => r.outcome === 'ok');
const blocked = rows.filter((r) => r.outcome === 'cors-blocked');
const okWithAcao = ok.filter((r) => r.acao);
const blockedNoAcao = blocked.filter((r) => !r.acao);
const byPop = Object.groupBy(rows, (r) => r.pop ?? '?');
const flippingPops = Object.entries(byPop).filter(([, rs]) => new Set(rs.map((r) => r.outcome)).size > 1);

console.log(`\n${rows.length} samples: ${ok.length} ok (${okWithAcao.length} with ACAO), ${blocked.length} CORS-blocked (${blockedNoAcao.length} without ACAO)`);
console.log(`edges: ${Object.keys(byPop).join(', ')}; edges that flipped: ${flippingPops.map(([p]) => p).join(', ') || 'none'}`);

if (ok.length === 0) {
  console.log('\nVERDICT: always blocked, never any ACAO -> origin is simply not allowed (no cache effect observed).');
} else if (blocked.length === 0) {
  console.log('\nVERDICT: never blocked in this window -> keep sampling across more cache refreshes.');
} else if (flippingPops.length && okWithAcao.length === ok.length && blockedNoAcao.length === blocked.length) {
  console.log('\nVERDICT: cache theory supported. The same edge flips between responses with and without');
  console.log('ACAO, and every outcome matches the header. CloudFront is caching CORS headers without keying');
  console.log('on Origin. Fix: add Origin to the cache key (or managed CORS-S3Origin) or a response headers policy.');
} else {
  console.log('\nVERDICT: mixed results not cleanly explained by the cache; inspect the table above.');
}
