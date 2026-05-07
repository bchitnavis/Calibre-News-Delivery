# AI Changelog

### 2026-05-06 - Financial Times Automation Improvements

*   **Interactive Cookie Extraction**: Created `interactive_ft_login.py` to overcome FT's strict headless bot detection. The script launches a visible Firefox window for manual login, then safely extracts live session cookies and injects them directly into `standalone.config.json`'s `ftAuth.cookieHeader`.
*   **Sequential Article Slicing (Feature Toggle)**: Modified `ft.recipe` to support a new `startArticleUrl` override. When provided, the recipe will bypass standard feed logic, search the daily PressReader index for the specific article, and download a sequential block of `maxArticlesPerFeed` articles.
*   **Orchestration Support**: Updated `run-local.ps1` to map `$ftAuth.startArticleUrl` to the `FT_START_ARTICLE_URL` environment variable for `ft.recipe`.
*   **Feed Logic Tuning**: Updated `ft.recipe` to respect `maxArticlesPerFeed` *after* filtering feeds instead of truncating sections blindly.
*   **Pacing & Rate Limiting**: Changed default `ftAuth.delaySeconds` to 4 and `ftAuth.maxArticlesPerFeed` to 50 for robust, human-like paced extraction.
*   **Playwright Visibility**: Toggled `headless=False` in `ft_fetch_playwright.py` to allow the user to monitor Playwright extractions and handle random CAPTCHAs if they appear during fetches.
*   **Task Scheduler Deployment**: Created a Windows Scheduled Task named `Calibre News Delivery - Daily FT` to execute the pipeline at 06:00 AM daily.
*   **Documentation**: Updated `README.md` with FT specific instructions and created a comprehensive `USER_MANUAL.md`.
