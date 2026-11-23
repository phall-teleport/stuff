import { appendFileSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import type { Page, TestInfo } from '@playwright/test';

/**
 * Captures what the browser actually sent and received for the CVE data fetch,
 * including when Chromium blocks it on CORS. Playwright's own request/response
 * events don't expose response headers for CORS-blocked requests, so this
 * listens on the Chrome DevTools Protocol instead.
 *
 * The cache theory being tested: CloudFront doesn't key its cache on `Origin`,
 * so each edge (x-amz-cf-pop) serves whichever headers the request that filled
 * the cache got, for up to max-age=3600. If true, we should see:
 *   - blocked fetches have NO access-control-allow-origin, x-cache "Hit"
 *   - successful fetches HAVE access-control-allow-origin
 *   - the outcome flips per edge as `age` rolls over, not per request
 */

export type CorsEvidence = {
  at: string;
  test: string;
  attempt: number;
  pageOrigin: string;
  url: string;
  sentOrigin: string | null;
  status: number | null;
  outcome: 'ok' | 'cors-blocked' | 'failed' | 'not-seen';
  corsError: string | null; // e.g. "MissingAllowOriginHeader"
  errorText: string | null; // e.g. "net::ERR_FAILED"
  acao: string | null; // access-control-allow-origin
  xCache: string | null; // "Hit from cloudfront" / "Miss from cloudfront"
  age: string | null;
  pop: string | null; // x-amz-cf-pop (which CloudFront edge)
  etag: string | null;
  vary: string | null;
  server: string | null;
};

const LOG = path.join(__dirname, '..', 'cors-log', 'cors-evidence.jsonl');

const lower = (h: Record<string, string> = {}) =>
  Object.fromEntries(Object.entries(h).map(([k, v]) => [k.toLowerCase(), v]));

export async function captureCorsEvidence(page: Page, testInfo: TestInfo, urlPattern: RegExp) {
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('Network.enable');

  let requestId: string | null = null;
  let url = '';
  let sentOrigin: string | null = null;
  let status: number | null = null;
  let headers: Record<string, string> = {};
  let outcome: CorsEvidence['outcome'] = 'not-seen';
  let corsError: string | null = null;
  let errorText: string | null = null;

  cdp.on('Network.requestWillBeSent', (e) => {
    if (requestId || !urlPattern.test(e.request.url)) return;
    requestId = e.requestId;
    url = e.request.url;
    sentOrigin = lower(e.request.headers).origin ?? null;
  });
  // Headers as actually put on the wire (Origin is often only visible here).
  cdp.on('Network.requestWillBeSentExtraInfo', (e) => {
    if (e.requestId === requestId) sentOrigin = lower(e.headers).origin ?? sentOrigin;
  });
  // Raw response headers: delivered even when CORS then blocks the response.
  cdp.on('Network.responseReceivedExtraInfo', (e) => {
    if (e.requestId !== requestId) return;
    status = e.statusCode;
    headers = { ...headers, ...lower(e.headers) };
  });
  cdp.on('Network.responseReceived', (e) => {
    if (e.requestId !== requestId) return;
    status = e.response.status;
    headers = { ...lower(e.response.headers), ...headers };
  });
  cdp.on('Network.loadingFinished', (e) => {
    if (e.requestId === requestId) outcome = 'ok';
  });
  cdp.on('Network.loadingFailed', (e) => {
    if (e.requestId !== requestId) return;
    errorText = e.errorText;
    corsError = e.corsErrorStatus?.corsError ?? null;
    outcome = corsError ? 'cors-blocked' : 'failed';
  });

  /** Call after the fetch has settled (or the test is ending) to record it. */
  return async function record(): Promise<CorsEvidence> {
    const ev: CorsEvidence = {
      at: new Date().toISOString(),
      test: testInfo.title,
      attempt: testInfo.retry,
      pageOrigin: new URL(page.url() || testInfo.project.use.baseURL || 'about:blank').origin,
      url,
      sentOrigin,
      status,
      outcome,
      corsError,
      errorText,
      acao: headers['access-control-allow-origin'] ?? null,
      xCache: headers['x-cache'] ?? null,
      age: headers['age'] ?? null,
      pop: headers['x-amz-cf-pop'] ?? null,
      etag: headers['etag'] ?? null,
      vary: headers['vary'] ?? null,
      server: headers['server'] ?? null,
    };
    await testInfo.attach('cors-evidence', {
      body: JSON.stringify(ev, null, 2),
      contentType: 'application/json',
    });
    mkdirSync(path.dirname(LOG), { recursive: true });
    appendFileSync(LOG, JSON.stringify(ev) + '\n');
    console.log(
      `[cors] ${ev.outcome.padEnd(12)} acao=${ev.acao ?? '-'} ${ev.xCache ?? '-'} age=${ev.age ?? '-'} pop=${ev.pop ?? '-'}` +
        (ev.corsError ? ` corsError=${ev.corsError}` : ''),
    );
    await cdp.detach().catch(() => {});
    return ev;
  };
}
