import { test, expect } from '@playwright/test';
import { captureCorsEvidence } from './cors-evidence';

const PAGE = '/docs/reference/vulnerability-management/customer/';
const DATA_URL = /goteleport\.dev\/cve-tracker\/latest\.json/;

/**
 * Not a functional test: this records whether the CVE data fetch was blocked
 * and what headers the CDN sent, then checks the outcome matches the CORS
 * header. Run it repeatedly over a few hours (see scripts/cors-watch.sh) and
 * summarize with scripts/cors-summary.mjs.
 *
 * Run alone with no retries so each run is exactly one sample:
 *   npx playwright test cors-cache --retries=0
 */
test('CORS outcome is explained by the cached response headers', async ({ page }, testInfo) => {
  const record = await captureCorsEvidence(page, testInfo, DATA_URL);

  const settled = page
    .waitForEvent('requestfinished', { predicate: (r) => DATA_URL.test(r.url()), timeout: 30_000 })
    .catch(() => null);
  const failed = page
    .waitForEvent('requestfailed', { predicate: (r) => DATA_URL.test(r.url()), timeout: 30_000 })
    .catch(() => null);
  await page.goto(PAGE);
  await Promise.race([settled, failed]);
  await page.waitForTimeout(500); // let the final CDP loadingFinished/loadingFailed land

  const ev = await record();

  expect(ev.outcome, 'the data request was never seen; is the preview up?').not.toBe('not-seen');
  expect(ev.sentOrigin, 'browser should send Origin on a cross-origin fetch').toBeTruthy();

  if (ev.outcome === 'ok') {
    // Succeeded cross-origin => the response must have allowed our origin.
    expect(ev.acao, 'fetch succeeded, so the response had a CORS header').toMatch(
      new RegExp(`^(\\*|${ev.sentOrigin!.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')})$`),
    );
  } else {
    // Blocked => the CDN response had no usable CORS header.
    expect(ev.corsError, `fetch failed for a non-CORS reason: ${ev.errorText}`).toBeTruthy();
    expect(ev.acao === null || ev.acao !== ev.sentOrigin).toBe(true);
  }
});
