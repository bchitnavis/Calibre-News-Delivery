#!/usr/bin/env python3
import os
import re
import sys
from urllib.parse import parse_qs
from urllib.parse import urlparse


def parse_cookies(cookie_header, target_url):
    host = (urlparse(target_url).hostname or '').strip()
    cookies = []
    for part in cookie_header.split(';'):
        part = part.strip()
        if not part:
            continue
        name, _, value = part.partition('=')
        name = name.strip()
        value = value.strip()
        if name:
            cookies.append({
                'name': name,
                'value': value,
                'domain': host,
                'path': '/',
            })
    return cookies


def dismiss_ft_consent(page):
    # FT sometimes shows a Sourcepoint consent iframe that intercepts clicks.
    consent_selectors = [
        'button[title*="Accept"]',
        'button[aria-label*="Accept"]',
        'button:has-text("Accept")',
        'button:has-text("I Agree")',
        'button:has-text("Agree")',
    ]

    for frame in page.frames:
        if 'consent-manager.ft.com' not in (frame.url or ''):
            continue
        for selector in consent_selectors:
            try:
                btn = frame.locator(selector).first
                if btn.count() > 0:
                    btn.click(timeout=3000)
                    page.wait_for_timeout(500)
                    return True
            except Exception:
                continue
    return False


def maybe_login_ft(context, username, password):
    username = (username or '').strip()
    password = (password or '').strip()
    if not username or not password:
        return

    epaper_auth_url = 'https://subs.ft.com/spa3_sfepaper_3M20'
    login_url = (
        'https://accounts.ft.com/login?location='
        'https%3A%2F%2Fsubs.ft.com%2Fspa3_sfepaper_3M20'
    )

    login_page = context.new_page()
    try:
        login_page.goto(
            login_url,
            timeout=35000,
            wait_until='domcontentloaded',
        )
        dismiss_ft_consent(login_page)
        login_page.wait_for_selector('#enter-email', timeout=15000)
        login_page.fill('#enter-email', username)
        login_page.click('#enter-email-next')
        dismiss_ft_consent(login_page)
        login_page.wait_for_selector('#enter-password', timeout=20000)
        login_page.fill('#enter-password', password)
        try:
            login_page.click('#sign-in-button', timeout=8000)
        except Exception:
            dismiss_ft_consent(login_page)
            login_page.click('#sign-in-button', timeout=8000)
        login_page.wait_for_load_state('networkidle', timeout=35000)

        if 'accounts.ft.com/passkeys/set-up' in login_page.url:
            try:
                login_page.click('text=Not now', timeout=10000)
                login_page.wait_for_load_state('networkidle', timeout=35000)
            except Exception:
                pass

        # Prime FT's e-paper SSO surface so the PressReader session can pick up
        # the external FT authentication before article and issue fetches.
        login_page.goto(epaper_auth_url, timeout=35000, wait_until='domcontentloaded')
        login_page.wait_for_load_state('networkidle', timeout=20000)
    finally:
        login_page.close()


def find_pressreader_preload_data(page):
    response = page.evaluate(
        """
        () => {
            const text = document.body ? (document.body.innerText || '') : '';
            const match = text.match(/loadCallback\d+\((.*)\);?$/s);
            return match ? match[1] : '';
        }
        """
    )
    if not response:
        return None

    try:
        import json
        return json.loads(response)
    except Exception:
        return None


def extract_pressreader_bearer_token(page):
    # Most reliable path: ask the active PressReader session for a bearer token.
    try:
        init = page.evaluate(
            """
            async () => {
                const res = await fetch('/authentication/v1/initialize', {
                    method: 'POST',
                    credentials: 'include',
                    headers: {'content-type': 'application/json'},
                    body: '{}'
                });
                if (!res.ok) return '';
                const data = await res.json();
                return (data && data.bearerToken) ? data.bearerToken : '';
            }
            """
        )
        if init:
            return init.strip()
    except Exception:
        pass

    # Fallback path for older sessions where preload contains auth bootstrap.
    resources = page.evaluate(
        """
        () => performance.getEntriesByType('resource')
            .map(r => r.name)
            .filter(name => name.includes('/services/preload?accessToken='))
        """
    )
    for resource_url in resources:
        parsed = urlparse(resource_url)
        access_token = parse_qs(parsed.query).get('accessToken', [''])[0].strip()
        if not access_token:
            continue

        preload_page = page.context.new_page()
        try:
            preload_page.goto(resource_url, timeout=35000, wait_until='domcontentloaded')
            preload_data = find_pressreader_preload_data(preload_page)
            bearer = (((preload_data or {}).get('auth') or {}).get('BearerToken') or '').strip()
            if bearer:
                return bearer
        finally:
            preload_page.close()
    return ''


def main():
    if len(sys.argv) < 2:
        print('Usage: ft_fetch_playwright.py <url>', file=sys.stderr)
        sys.exit(1)

    url = sys.argv[1]
    cookie_header = os.environ.get('FT_COOKIE_HEADER', '').strip()
    username = os.environ.get('FT_USERNAME', '').strip()
    password = os.environ.get('FT_PASSWORD', '').strip()

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

    try:
        with sync_playwright() as p:
            # Use an isolated browser context per fetch to avoid profile-lock
            # errors like "Firefox already running" from persistent contexts.
            browser = p.firefox.launch(headless=False)
            context = browser.new_context(
                user_agent=(
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:149.0) '
                    'Gecko/20100101 Firefox/149.0'
                ),
                extra_http_headers={
                    'Accept-Language': 'en-US,en;q=0.9',
                    'Referer': 'https://www.ft.com/',
                },
            )

            if cookie_header:
                cookies = parse_cookies(cookie_header, url)
                if cookies:
                    context.add_cookies(cookies)

            maybe_login_ft(context, username, password)

            page = context.new_page()
            try:
                page.goto(url, timeout=35000, wait_until='domcontentloaded')
                page.wait_for_function(
                    """
                    () => {
                        const textViewScroller = document.querySelector('.scroller');
                        const hasTextViewContent = textViewScroller && (
                            textViewScroller.querySelector('article[data-articleid]') ||
                            textViewScroller.querySelector('.section-topic')
                        );
                        const hasArticleContent = document.querySelector(
                            '.layout-section.page-section.section-article, #article-body, .article__content-body'
                        );
                        return Boolean(hasTextViewContent || hasArticleContent);
                    }
                    """,
                    timeout=20000,
                )
            except PlaywrightTimeout:
                pass

            # PressReader textview lazily renders section cards. Capture each
            # section by iterating sidebar navigation and merging scroller HTML.
            if '/textview' in url:
                html = build_textview_index_html(page)
            else:
                html = build_article_html(page)
            context.close()
            browser.close()

        sys.stdout.buffer.write(html.encode('utf-8'))
        sys.stdout.buffer.flush()
    except Exception as exc:
        print('Playwright fetch error: %s' % exc, file=sys.stderr)
        sys.exit(3)


def build_textview_index_html(page):
    merged_scroller = []
    seen_blocks = set()

    def add_scroller_snapshot():
        block = page.evaluate(
            """
            () => {
                const scroller = document.querySelector('.scroller');
                return scroller ? scroller.innerHTML : '';
            }
            """
        )
        if block and block not in seen_blocks:
            seen_blocks.add(block)
            merged_scroller.append(block)

    def nudge_scroll():
        page.evaluate(
            """
            () => {
                const main = document.querySelector('.m-content-main');
                const scroller = document.querySelector('.scroller');
                if (main) {
                    main.scrollBy(0, Math.max(800, Math.floor(main.clientHeight * 0.9)));
                }
                if (scroller) {
                    scroller.scrollBy(0, Math.max(800, Math.floor(scroller.clientHeight * 0.9)));
                }
                window.scrollBy(0, Math.max(500, Math.floor(window.innerHeight * 0.8)));
            }
            """
        )

    try:
        page.wait_for_selector('.nav-link', timeout=10000)
    except Exception:
        # If nav is unavailable, fall back to current page content.
        return page.content()

    add_scroller_snapshot()

    nav_links = page.locator('.nav-link')
    nav_count = nav_links.count()
    for i in range(nav_count):
        try:
            nav_links.nth(i).click(timeout=3000)
        except Exception:
            continue

        # Allow async render, then scroll a bit to trigger card hydration.
        page.wait_for_timeout(350)
        add_scroller_snapshot()
        for _ in range(2):
            nudge_scroll()
            page.wait_for_timeout(250)
            add_scroller_snapshot()

    if not merged_scroller:
        return page.content()

    return '<html><body><div class="scroller">%s</div></body></html>' % ''.join(merged_scroller)


def build_article_html(page):
    api_error = None
    api_failures = []
    try:
        article_id = (urlparse(page.url).path.rstrip('/').split('/') or [''])[-1]
        if article_id.isdigit():
            api_url = (
                'https://ingress.pressreader.com/services/v1/articles/%s/'
                '?articleFields=4095&confirm=true&isHyphenated=true'
            ) % article_id

            # Retry once because PressReader auth/bootstrap can be flaky per article request.
            for attempt in range(2):
                bearer_token = extract_pressreader_bearer_token(page)
                if not bearer_token:
                    api_failures.append('missing bearer token (attempt %d)' % (attempt + 1))
                else:
                    response = page.request.get(
                        api_url,
                        headers={
                            'Authorization': 'Bearer %s' % bearer_token,
                            'Referer': page.url,
                        },
                        timeout=35000,
                    )
                    if response.ok:
                        raw = response.text()
                        article_html = build_article_html_from_api_response(raw)
                        if article_html:
                            return article_html
                        payload_info = summarize_api_payload(raw)
                        api_failures.append(
                            'api response had no usable paragraph payload '
                            '(attempt %d, body_len=%d, %s)'
                            % (attempt + 1, len(raw or ''), payload_info)
                        )
                    else:
                        api_failures.append(
                            'api status %d (attempt %d)' % (response.status, attempt + 1)
                        )

                if attempt == 0:
                    try:
                        page.reload(timeout=35000, wait_until='domcontentloaded')
                        page.wait_for_timeout(500)
                    except Exception:
                        pass
    except Exception as exc:
        api_error = exc

    fallback_html = page.content()
    fallback_reasons = detect_shell_or_teaser_fallback(fallback_html)
    if fallback_reasons:
        if api_failures:
            title = extract_title_from_html(fallback_html) or 'Unavailable article'
            if title in ('EnglishРусский', 'Prev', 'Next'):
                title = 'Unavailable article'
            reason = ' | '.join(fallback_reasons + api_failures)
            epub_reason = summarize_reason_for_epub(reason)
            return build_diagnostic_article_html(title, epub_reason)
        message = 'fallback article HTML rejected: %s' % '; '.join(fallback_reasons)
        if api_failures:
            message += '; api_failures=%s' % ' | '.join(api_failures)
        if api_error:
            message += '; api_error=%s' % api_error
        raise RuntimeError(message)

    return fallback_html


def detect_shell_or_teaser_fallback(html):
    reasons = []
    body = html or ''
    lower = body.lower()

    if 'subscribe to the financial times' in lower or 'subs.ft.com/epaper3for1' in lower:
        reasons.append('subscription page marker found')

    article_text_nodes = len(re.findall(r'class=["\'][^"\']*article-text[^"\']*["\']', body, flags=re.IGNORECASE))
    expanded_nodes = len(re.findall(r'<article[^>]+class=["\'][^"\']*expanded[^"\']*["\']', body, flags=re.IGNORECASE))

    if article_text_nodes == 0 and expanded_nodes == 0:
        reasons.append('missing expanded/article-text nodes')

    if 30000 <= len(body) <= 36000 and article_text_nodes == 0:
        reasons.append('template-sized article fallback without body paragraphs')

    teaser_match = re.search(r'\.\.\.(?:\s*<|\s*$)', body)
    if teaser_match and article_text_nodes <= 1:
        reasons.append('teaser-style truncation detected')

    return reasons


def build_article_html_from_api_response(raw):
    try:
        import html
        import json
        data = json.loads(raw)
    except Exception:
        return ''

    payload = data
    if not (payload.get('paragraphs') or payload.get('Paragraphs')):
        if isinstance(data.get('article'), dict):
            payload = data.get('article')
        elif isinstance(data.get('data'), dict):
            payload = data.get('data')

    paragraphs = []
    for source in [
        payload.get('paragraphs'),
        payload.get('Paragraphs'),
        payload.get('content'),
        payload.get('body'),
        payload.get('contentBlocks'),
        payload.get('sections'),
    ]:
        collect_text_fragments(source, paragraphs)

    paragraphs = [html.escape(fragment) for fragment in paragraphs if fragment]

    if not paragraphs:
        access_reason = build_access_reason(data, payload)
        if access_reason:
            title = html.escape((payload.get('title') or payload.get('Title') or 'Unavailable article').strip())
            return build_diagnostic_article_html(title, access_reason)
        return ''

    title = html.escape((payload.get('title') or payload.get('Title') or '').strip())
    subtitle = html.escape((payload.get('subtitle') or payload.get('Subtitle') or '').strip())
    author = html.escape((payload.get('author') or payload.get('Author') or '').strip())
    date = html.escape((payload.get('date') or payload.get('Date') or '').strip())

    image_html = ''
    images = payload.get('images') or payload.get('Images') or []
    if images:
        for image in images:
            url = (((image or {}).get('size') or {}).get('url') or '').strip()
            if not url:
                url = ((image or {}).get('url') or '').strip()
            if url:
                image_html = '<figure class="article-pic"><img src="%s" /></figure>' % html.escape(url, quote=True)
                break

    subtitle_html = '<div class="article-subtitle">%s</div>' % subtitle if subtitle else ''
    author_html = '<div class="author">%s</div>' % author if author else ''
    date_html = '<div class="date">%s</div>' % date if date else ''
    body = ''.join('<p class="article-text">%s</p>' % paragraph for paragraph in paragraphs)
    return '<html><body><article class="expanded"><div class="article-content"><div class="article-title">%s</div>%s%s%s%s%s</div></article></body></html>' % (
        title,
        subtitle_html,
        author_html,
        date_html,
        image_html,
        body,
    )


def summarize_api_payload(raw):
    try:
        import json
        data = json.loads(raw)
    except Exception:
        return 'non-json-api-body'

    payload = data
    if isinstance(data.get('article'), dict):
        payload = data.get('article')
    elif isinstance(data.get('data'), dict):
        payload = data.get('data')

    paragraph_count = len(payload.get('paragraphs') or payload.get('Paragraphs') or [])
    top_keys = sorted(list(data.keys()))[:8]
    status = data.get('status') or data.get('Status') or data.get('code') or data.get('Code')
    message = data.get('message') or data.get('Message') or data.get('error') or data.get('Error')
    bits = [
        'top_keys=%s' % ','.join(str(k) for k in top_keys),
        'paragraph_count=%d' % paragraph_count,
    ]
    if status:
        bits.append('status=%s' % status)
    if message:
        bits.append('message=%s' % str(message)[:120])
    access_reason = build_access_reason(data, payload)
    if access_reason:
        bits.append('access=%s' % access_reason)
    return '; '.join(bits)


def collect_text_fragments(node, out, depth=0):
    if depth > 5 or node is None:
        return

    if isinstance(node, str):
        text = node.strip()
        if text:
            out.append(text)
        return

    if isinstance(node, list):
        for item in node:
            collect_text_fragments(item, out, depth + 1)
        return

    if not isinstance(node, dict):
        return

    for key in ['text', 'Text', 'content', 'Content', 'body', 'Body', 'paragraphText', 'ParagraphText']:
        value = node.get(key)
        if isinstance(value, str):
            text = value.strip()
            if text:
                out.append(text)

    for key in ['paragraphs', 'Paragraphs', 'items', 'Items', 'children', 'Children', 'content', 'Content', 'body', 'Body', 'sections', 'Sections']:
        if key in node:
            collect_text_fragments(node.get(key), out, depth + 1)


def build_access_reason(data, payload):
    access = payload.get('access') or data.get('access') or {}
    bits = []

    if isinstance(access, dict):
        for key in [
            'granted', 'hasAccess', 'isAllowed', 'isAccessible', 'allowed',
            'isPreview', 'previewAllowed', 'isLocked', 'isEntitled',
        ]:
            if key in access:
                bits.append('%s=%s' % (key, access.get(key)))

        for key in ['status', 'reason', 'type', 'code', 'message', 'error', 'restriction']:
            value = access.get(key)
            if value not in (None, '', []):
                bits.append('%s=%s' % (key, value))

        # Pull one level deeper for common nested entitlement structures.
        for nested_key in ['details', 'entitlement', 'rights', 'policy']:
            nested = access.get(nested_key)
            if isinstance(nested, dict):
                for key in ['status', 'reason', 'code', 'message', 'type']:
                    value = nested.get(key)
                    if value not in (None, '', []):
                        bits.append('%s.%s=%s' % (nested_key, key, value))

    # Some responses expose access context at top-level.
    for source_name, source in [('data', data), ('payload', payload)]:
        if not isinstance(source, dict):
            continue
        for key in ['classification', 'articleSource', 'status', 'code', 'message', 'error']:
            value = source.get(key)
            if isinstance(value, (str, int, float, bool)) and str(value).strip():
                bits.append('%s.%s=%s' % (source_name, key, value))

    if isinstance(access, dict) and not bits:
        # Last-resort: include a compact snapshot so we can see unexpected key names.
        try:
            import json
            compact = json.dumps(access, ensure_ascii=False, separators=(',', ':'))
            if compact and compact != '{}':
                bits.append('access.raw=%s' % compact[:220])
        except Exception:
            pass

    # Deduplicate while preserving order.
    seen = set()
    unique_bits = []
    for bit in bits:
        bit_str = str(bit)
        if bit_str in seen:
            continue
        seen.add(bit_str)
        unique_bits.append(bit_str)

    if unique_bits:
        return ', '.join(unique_bits[:12])
    return ''


def build_diagnostic_article_html(title, reason):
    import html
    safe_reason = html.escape(reason)
    return (
        '<html><body><article class="expanded">'
        '<div class="article-content">'
        '<div class="article-title">%s</div>'
        '<p class="article-text">Article text is unavailable from PressReader for this entry.</p>'
        '<p class="article-text"><strong>Access details:</strong> %s</p>'
        '</div></article></body></html>'
    ) % (title, safe_reason)


def summarize_reason_for_epub(reason):
    text = (reason or '').strip()
    lower = text.lower()

    if 'api response had no usable paragraph payload' in lower:
        return 'Metadata-only response from PressReader (no article paragraphs available for this entry).'

    if 'subscription page marker found' in lower:
        return 'Subscription page was returned instead of article text.'

    if 'missing expanded/article-text nodes' in lower:
        return 'Article body nodes were not present in the fetched page.'

    if 'missing bearer token' in lower:
        return 'Authentication token could not be acquired for article API access.'

    if 'api status' in lower:
        m = re.search(r'api status\s+(\d+)', lower)
        if m:
            return 'Article API returned HTTP status %s.' % m.group(1)
        return 'Article API returned a non-success status.'

    return text[:220] if text else 'Article text is unavailable.'


def extract_title_from_html(html_text):
    if not html_text:
        return ''
    for pattern in [
        r'<h1[^>]*>(.*?)</h1>',
        r'<title[^>]*>(.*?)</title>',
    ]:
        match = re.search(pattern, html_text, flags=re.IGNORECASE | re.DOTALL)
        if match:
            raw = re.sub(r'<[^>]+>', ' ', match.group(1))
            cleaned = re.sub(r'\s+', ' ', raw).strip()
            if cleaned:
                if re.fullmatch(r'[A-Za-z\u0400-\u04FF]+', cleaned) and len(cleaned) <= 20:
                    # Avoid language-toggle labels like "EnglishРусский".
                    continue
                return cleaned
    return ''

if __name__ == '__main__':
    main()
