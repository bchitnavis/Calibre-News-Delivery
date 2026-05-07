# Calibre News Delivery - User Manual

This manual provides detailed operational instructions for running the Calibre News Delivery pipeline specifically focused on The Financial Times and New York Times via Windows standalone configuration.

## Core Setup
All behavior is controlled via `standalone.config.json` in the root of the repository. Do not commit this file with your live cookies.
You must have Calibre installed and added to your system PATH.

## Financial Times Configuration
Financial Times aggressively blocks automated headless logins with CAPTCHAs. Therefore, we use live session cookies.

### 1. Re-Authenticating (When your session expires)
If your generated EPUBs contain placeholder text ("Metadata-only response from PressReader"), your cookies have expired.
1. Open PowerShell in the project directory.
2. Run `python interactive_ft_login.py`.
3. A Firefox window will open. Log in to `ft.com` manually.
4. Once fully logged in, return to your PowerShell window and press **Enter**.
5. The script automatically extracts your live cookies and securely stores them in `standalone.config.json`.

### 2. Targeting Feeds (Sections)
You can target specific sections of the FT e-paper by adding their exact titles to `ftAuth.includeFeeds` in `standalone.config.json`.
*   **Example**: `["front page", "national", "international", "companies & markets", "opinion", "lex"]`
*   If `includeFeeds` is left completely empty (`[]`), the pipeline will download all available sections.

### 3. Pacing & Throttling
To avoid triggering anti-bot protections from PressReader:
*   Keep `ftAuth.threads` at `1`.
*   Keep `ftAuth.delaySeconds` between `3` and `5` seconds to simulate a human pacing between articles.
*   Set `ftAuth.maxArticlesPerFeed` to control the size of the final ebook (e.g., `50`).

### 4. Daily Automation
To ensure the pipeline dynamically finds today's newspaper issue, both `issueUrl` and `startArticleUrl` must be completely empty (`""`).
*   If `startArticleUrl` contains a URL, the pipeline will ignore your `includeFeeds` and simply download a raw block of sequential articles starting from that URL.
*   If `issueUrl` is populated, it will lock the pipeline to that specific day's paper forever.

## New York Times Configuration
New York Times is also managed via `standalone.config.json` under `nytAuth`. 
NYT also relies on cookie-based authentication.
1. Log into NYT on your primary browser (Firefox, Edge, or Chrome).
2. Run the extraction helper to grab your cookies from your local browser profile:
   `powershell -ExecutionPolicy Bypass -File .\extract-nyt-cookie-header.ps1 -Browser firefox -UpdateConfig -ConfigPath .\standalone.config.json`
3. We recommend `useEmbeddedContent: true`, `delaySeconds: 2`, and `maxArticlesPerFeed: 8` for the most reliable NYT extraction.

## Executing the Pipeline
Run the delivery script:
```powershell
powershell -ExecutionPolicy Bypass -File .\run-local.ps1 -ConfigPath .\standalone.config.json
```
The script will fetch the articles, format them into an EPUB, and publish it directly to your configured Obsidian vault directory (`obsidianNewsDir`).
