# Financial Times Download Strategy

This document outlines a robust, long-term strategy for reliably extracting daily articles from the Financial Times (via PressReader) using your Calibre-News-Delivery pipeline.

## 1. Authentication (The Cookie Strategy)
Financial Times actively deploys Sourcepoint consent iframes and CAPTCHAs that reliably block traditional `username`/`password` headless logins. 

**Best Practice:**
Always use cookie-based authentication.
1. When your session expires (or the EPUB starts returning placeholder text), run the custom script we built:
   ```powershell
   python interactive_ft_login.py
   ```
2. A browser will open. Log into `ft.com` manually.
3. Return to your terminal and press **Enter**. 
4. The script will automatically safely extract your live, human-verified cookies and inject them into `standalone.config.json` under `ftAuth.cookieHeader`, clearing out the brittle password fields.

## 2. Feed Selection (`includeFeeds`)
You mentioned you will update `ftAuth.includeFeeds` to suit your needs. Since you are moving to a feed-based selection, **you must clear the custom override**.

**Important Configuration Change:**
In `standalone.config.json`, make sure `startArticleUrl` is completely empty. If it contains a URL, the recipe will ignore your feeds and stubbornly extract a raw sequential block of articles!
```json
"startArticleUrl": "",
```

**Using Feeds:**
The FT PressReader index divides the paper into sections. You can target specific sections by adding keywords to `includeFeeds`.
*   **Targeting:** The keywords are case-insensitive.
*   **Examples:** `["lex", "companies", "world news", "markets"]`
*   **Blank Array:** If you leave `includeFeeds: []` completely empty, the recipe will download *all* sections of the newspaper. 

## 3. Pacing and Rate Limiting
Fetching too fast will result in temporary IP bans or forced CAPTCHA challenges from PressReader's API.

*   `threads`: **Must be set to `1`**. Do not attempt parallel downloads for FT.
*   `delaySeconds`: **Keep between `3` and `5`**. This introduces a human-like pause between each article fetch, guaranteeing long-term stability.
*   `maxArticlesPerFeed`: Tune this based on your reading capacity. Setting it to `10` with `4` feeds means downloading 40 articles. At a 4-second delay, this takes roughly 3 minutes to compile.

## 4. Daily Automation (Issue Dates)
Right now, your `standalone.config.json` has a hardcoded `issueUrl` (e.g., `https://ft.pressreader.com/v99e/20260507/textview`). This means it will download the May 7th paper forever.

**To automate daily downloads:**
Clear the `issueUrl` field in your config:
```json
"issueUrl": "",
```
When this field is empty, `ft.recipe` automatically calculates today's date (e.g., `YYYYMMDD`) and dynamically builds the URL for the newest daily edition.

## 5. Scheduling
With the configuration fully tuned, you can automate this pipeline to run every morning before you wake up.

**Windows Task Scheduler:**
1. Open Windows Task Scheduler and create a "Basic Task".
2. Set the trigger to **Daily** at your preferred time (e.g., `06:00 AM`).
3. Set the action to **Start a Program**:
   *   **Program/script:** `powershell`
   *   **Add arguments:** `-WindowStyle Hidden -ExecutionPolicy Bypass -File .\run-local.ps1 -ConfigPath .\standalone.config.json`
   *   **Start in:** `C:\Users\bchit\repos\Calibre-News-Delivery`

*(Note: Every 30-90 days, your FT cookie may naturally expire. When you wake up to an empty EPUB, simply run `interactive_ft_login.py` again to refresh it.)*
