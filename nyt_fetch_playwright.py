#!/usr/bin/env python3
"""
Playwright-based full-article fetcher for NYT.

Usage:
    python nyt_fetch_playwright.py <url>

Strategy:
  - Uses a *persistent* Firefox profile so DataDome maintains a consistent
    session across runs for this specific browser fingerprint.
  - Injects only NYT auth cookies (NYT-S, NYT-T, etc.) from NYT_COOKIE_HEADER.
    The DataDome cookie is intentionally excluded — it is fingerprint-bound to
    the original Firefox session and causes an immediate CAPTCHA challenge when
    used from a different browser's TLS/fingerprint.  Playwright earns its own
    DataDome session through the homepage warm-up step.
  - Visits the NYT homepage first on every call to let DataDome refresh its
    cookie for Playwright's fingerprint, then visits the target article.

Environment variables:
    NYT_COOKIE_HEADER            Raw Cookie header string from an authenticated
                                 Firefox session (all cookies; datadome filtered out).
    NYT_PLAYWRIGHT_PROFILE_DIR   Optional override for the persistent profile path.

Exit codes:
    0  success
    1  bad arguments
    2  playwright not installed
    3  navigation / extraction error
"""
import os
import pathlib
import sys

# Only these NYT auth cookies are injected.  DataDome and other fingerprint-
# bound tracking cookies are explicitly excluded so Playwright can build its
# own valid DataDome session through a real browser interaction.
_NYT_AUTH_COOKIE_NAMES = {
    'nyt-s', 'nyt-t', 'nyt-jkidd', 'nyt-auth-method', 'nyt-gdpr', 'nyt-geo',
    'regi_cookie', 'nyt-purr', 'purr-cache', 'nyt-a', 'nyt-b-sid', 'nyt-mps',
    'nyt-s-present', 'nyt-us', 'jkidd-p', 'nyt-b-did', 'nyt-unified-auth',
    'gclb',
}


def parse_auth_cookies(cookie_header):
    """Return only the NYT auth cookies from a raw Cookie header string."""
    cookies = []
    for part in cookie_header.split(';'):
        part = part.strip()
        if not part:
            continue
        name, _, value = part.partition('=')
        name = name.strip()
        value = value.strip()
        if name and name.lower() in _NYT_AUTH_COOKIE_NAMES:
            cookies.append({
                'name': name,
                'value': value,
                'domain': '.nytimes.com',
                'path': '/',
            })
    return cookies


def main():
    if len(sys.argv) < 2:
        print('Usage: nyt_fetch_playwright.py <url>', file=sys.stderr)
        sys.exit(1)

    url = sys.argv[1]
    cookie_header = os.environ.get('NYT_COOKIE_HEADER', '').strip()

    try:
        from playwright.sync_api import TimeoutError as PlaywrightTimeout
        from playwright.sync_api import sync_playwright
    except ImportError:
        print(
            'playwright not installed. '
            'Run: pip install playwright && python -m playwright install firefox',
            file=sys.stderr,
        )
        sys.exit(2)

    # Resolve persistent profile directory.
    profile_dir_env = os.environ.get('NYT_PLAYWRIGHT_PROFILE_DIR', '').strip()
    profile_dir = pathlib.Path(profile_dir_env) if profile_dir_env else pathlib.Path.home() / '.nyt_playwright_profile'
    profile_dir.mkdir(parents=True, exist_ok=True)

    # Check if the persistent profile already has a DataDome cookie from a
    # previous session.  If so, skip the homepage warm-up to save ~10-15s per
    # article.  On first ever use (empty profile), the warm-up is required.
    datadome_cookie_file = profile_dir / 'datadome_seeded'
    needs_warmup = not datadome_cookie_file.exists()

    try:
        with sync_playwright() as p:
            context = p.firefox.launch_persistent_context(
                str(profile_dir),
                headless=True,
                user_agent=(
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:138.0) '
                    'Gecko/20100101 Firefox/138.0'
                ),
                extra_http_headers={
                    'Accept-Language': 'en-US,en;q=0.9',
                },
            )

            # Inject NYT auth cookies (DataDome excluded by design).
            if cookie_header:
                auth_cookies = parse_auth_cookies(cookie_header)
                if auth_cookies:
                    context.add_cookies(auth_cookies)
                    print(
                        'Injected %d NYT auth cookies' % len(auth_cookies),
                        file=sys.stderr,
                    )

            page = context.new_page()

            # Warm-up: visit the NYT homepage so DataDome can issue its session
            # cookie for this browser fingerprint.  Only needed once per profile.
            if needs_warmup:
                print('Warm-up: visiting homepage to seed DataDome session', file=sys.stderr)
                try:
                    page.goto('https://www.nytimes.com/', timeout=20000, wait_until='domcontentloaded')
                    # Mark as seeded so future runs skip this step.
                    datadome_cookie_file.touch()
                except PlaywrightTimeout:
                    print('Warm-up timed out, proceeding anyway', file=sys.stderr)
                except Exception as e:
                    print('Warm-up error: %s' % e, file=sys.stderr)

            # Navigate to the target article.
            try:
                page.goto(url, timeout=30000, wait_until='domcontentloaded')
                page.wait_for_selector(
                    'article, [data-testid="article-body"], section[name="articleBody"]',
                    timeout=15000,
                )
            except PlaywrightTimeout:
                # Use whatever is loaded — partial content is better than nothing.
                pass

            html = page.content()
            print('Page size: %d chars' % len(html), file=sys.stderr)
            context.close()

        sys.stdout.buffer.write(html.encode('utf-8'))
        sys.stdout.buffer.flush()
    except Exception as exc:
        print('Playwright fetch error: %s' % exc, file=sys.stderr)
        sys.exit(3)


if __name__ == '__main__':
    main()
