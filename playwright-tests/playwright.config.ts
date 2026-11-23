import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  timeout: 60_000,
  expect: { timeout: 15_000 },
  retries: 2, // CVE data fetch is intermittently CORS-blocked by the CDN; failures surface as "flaky"
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL: 'https://phall-cve-tracker.dhxf198f1wisu.amplifyapp.com',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
  projects: [
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
        // goteleport.dev's CDN/WAF returns 403 (without CORS headers) to the
        // "HeadlessChrome" UA, which breaks the CVE data fetch. Use a normal Chrome UA.
        userAgent:
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36',
      },
    },
  ],
});
