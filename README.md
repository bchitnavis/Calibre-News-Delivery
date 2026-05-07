__English__ · [简体中文](README.zh-CN.md)

---

# Calibre News Delivery

![](banner.png)

Leverages GitHub Actions to schedule Calibre to deliver news to SMTP email or an Obsidian news folder.

## Shortcut

 __[Upload Recipe](../../upload/master)__ | __[Add Built-in Recipe](../../edit/master/recipe_list.txt)__ | __[Update Schedule](../../edit/master/.github/workflows/calibre-news.yml)__ | __[Workflow](../../actions/workflows/calibre-news.yml)__ | __[Environments](../../settings/environments)__ | [Enable/Disable](../../settings/actions) | [Destroy](../../settings#danger-zone)

## Setup

1) Create a project using the __[use this template]__ button located in the top right corner.
2) Navigate to [ [Settings](../../settings) > __[Environments](../../settings/environments)__ ] in your project.
3) Click "__New environment__" to create a new environment named `calibre-news`.
4) Add the required "__environment secrets__" to the environment as follows.

|Name|Required|Description|Example|
|---|---|---|---|
|DELIVERY|No|Delivery target: `obsidian` or `smtp` (default is `obsidian`)|obsidian|
|OBSIDIAN_NEWS_DIR|Yes for `obsidian`|Folder to publish converted files (overrides workflow default)|C:/Users/bchit/vaults/Bharat's Obsidian Synced Vault/22.00 - News|
|FROM|Yes for `smtp`|Your email address|xxx@gmail.com|
|TO|Yes for `smtp`|Destination email address|xxx@kindle.com|
|ENCRYPT|Yes for `smtp`|SMTP encryption method|SSL|
|SECRET|Yes for `smtp`|SMTP password|xxxxxxxxxx|
|SMTP|Yes for `smtp`|SMTP server|smtp.gmail.com|
|PORT|Yes for `smtp`|SMTP port|465|
|FORMAT|No|The ebook format (default is epub)|epub|
|SIZE|No, `smtp` only|Attachment size limit (default is 25MB)|25|
|DAYS|No|Ebooks retention period (default is 90 days)|90|

5) (Optional) Add repository variable `RUNNER_LABEL` under [Settings > Secrets and variables > Actions > Variables].

|Variable|Required|Description|Example|
|---|---|---|---|
|RUNNER_LABEL|No|Runner label used by the workflow (default `ubuntu-latest`)|self-hosted|

6) Navigate to "__[Actions](../../actions)__" and click [ __Calibre News Delivery__ > __Run workflow__ ] to test.

With default settings, the workflow publishes converted files to `OBSIDIAN_NEWS_DIR`.

> [!TIP]
> 📹 A Brief Tour Video: [https://youtu.be/sIFsoztF58A](https://youtu.be/sIFsoztF58A)

## Schedule

The default delivery is scheduled to occur daily at midnight (00:00) UTC. You can change it according to your preference. The cron expression `- cron: '0 0 * * *'` can be found in the workflow file located at:

```
/.github/workflows/calibre-news.yml
```

Please refer to the "__[schedule](https://docs.github.com/en/actions/using-workflows/events-that-trigger-workflows#schedule)__" documentation to specify an appropriate time. For example, if you are in a timezone that is UTC+8 and want the delivery to start at 6:00 AM every day, you can set the cron expression as `0 22 * * *`, calculated using the formula `UTC Time = Local Time − Offset`.

Additionally, you can manually trigger the delivery on the "__[Actions](../../actions)__" page of your project.

## Recipe

For the built-in recipes, you need to add their titles (found in the `Title` attribute of the recipe file) to the plain text file __[recipe_list.txt](recipe_list.txt)__, one title per line. For manually written recipes, simply place them in the root of the project.

You can specify the cover and style for a recipe. Place the cover image in the "__covers__" folder and the style file in the "__styles__" folder. Both filenames must match the corresponding recipe title or filename. Be aware that the style may be ignored by the Send to Kindle service.

You can upload the recipe files using either the Git tool or GitHub's online uploading feature. The best practice is to test the recipe locally to ensure no errors occur before uploading it.

## Storage

All converted ebooks will be zipped together and stored in the Artifacts of GitHub Actions. You can find and download them in the job details of each workflow record. Each file will be retained for up to 90 days from the date it is generated.

You can change the retention period in the "__[Artifact and log retention](../../settings/actions#retention-header)__" section on the Actions settings page. You can also do this through the environment settings (refer to the [Setup](#setup) section).

Be aware that files exceeding the size limit for email attachments will not be sent via SMTP. You will need to download them manually from the Artifacts.

## Obsidian Notes

To publish to your vault, set `DELIVERY=obsidian` and set `OBSIDIAN_NEWS_DIR` to your target news folder.

This repository is currently configured with a workflow default path of `C:/Users/bchit/vaults/Bharat's Obsidian Synced Vault/22.00 - News` when `OBSIDIAN_NEWS_DIR` is not provided as a secret.

Because GitHub-hosted runners cannot access local folders on your machine, this mode requires a runner that can reach your vault path (for example, a self-hosted runner on the same machine where your vault is stored).

For Windows vault paths (like `C:/Users/you/Documents/Obsidian/Vault/News`), set:

1) `DELIVERY=obsidian`
2) `OBSIDIAN_NEWS_DIR=C:/.../YourVault/News`
3) Repository variable `RUNNER_LABEL=self-hosted`

The workflow uses a PowerShell-native publish step on Windows runners, so `C:/...` paths are handled directly.

## Standalone Windows Mode

You can run this project locally on Windows without GitHub Actions.

### Requirements

1) Install Calibre and ensure these commands are available in your terminal PATH:
	- `ebook-convert`
	- `ebook-meta`
	- `calibre-smtp` (only if you use SMTP delivery)

### Setup

1) Copy `standalone.config.example.json` to `standalone.config.json`.
2) Edit `standalone.config.json`:
	- Set `delivery` to `obsidian`.
	- Set `obsidianNewsDir` to your vault news folder.
 	- Optional for NYT subscription access: set `nytAuth.username`, `nytAuth.password`, and/or `nytAuth.cookieHeader`.
	- Optional NYT reliability tuning: set `nytAuth.useEmbeddedContent` and `nytAuth.maxArticlesPerFeed`.
3) Ensure your recipes are in `recipe_list.txt` and/or `*.recipe` files are in repository root.

For NYT specifically, cookie-based auth is typically more reliable than username/password. You can paste a browser cookie header string into `nytAuth.cookieHeader`.

Recommended NYT settings for fewer failures:
1) `nytAuth.useEmbeddedContent = true`
2) `nytAuth.maxArticlesPerFeed = 8`
3) `nytAuth.excludeFeeds = ["Opinion.xml", "Arts.xml"]`
4) `nytAuth.threads = 1`
5) `nytAuth.delaySeconds = 2`

You can also target only specific sections:
1) `nytAuth.includeFeeds = ["HomePage.xml", "World.xml", "US.xml", "Business.xml"]`
2) Leave `includeFeeds` empty to keep all default feeds.

To auto-generate a cookie header from your local browser profile:

```powershell
powershell -ExecutionPolicy Bypass -File .\extract-nyt-cookie-header.ps1 -Browser firefox -UpdateConfig -ConfigPath .\standalone.config.json
```

Notes:
1) Supported browsers are `firefox`, `edge`, and `chrome`.
2) The helper uses `sqlite3.exe` if present, otherwise it falls back to `py` or `python`.
3) Add `-CopyToClipboard` to also copy the header string to your clipboard.

For FT specifically, you must use the interactive login script because FT's CAPTCHAs and consent frames reliably block headless automated logins.
```powershell
python interactive_ft_login.py
```
This script will open a Firefox window. Log into `ft.com` manually, and when fully logged in, press Enter in your terminal. The script will automatically extract and inject the active cookies into `standalone.config.json` under `ftAuth.cookieHeader`.

Recommended FT settings for stability and automation:
1) `ftAuth.maxArticlesPerFeed = 50`
2) `ftAuth.threads = 1`
3) `ftAuth.delaySeconds = 4`
4) Leave `ftAuth.issueUrl` and `ftAuth.startArticleUrl` completely empty (`""`) to automatically target the current daily issue.

### Run

From repository root in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\run-local.ps1 -ConfigPath .\standalone.config.json
```

Converted files are saved in `converted_ebooks` and published to your configured `obsidianNewsDir`.

### One-Command Run (Refresh Cookie + Deliver)

You can refresh NYT cookie and run delivery in one command:

```powershell
powershell -ExecutionPolicy Bypass -File .\run-local-with-cookie-refresh.ps1 -ConfigPath .\standalone.config.json -Browser firefox
```

Optional: add `-CopyCookieToClipboard` if you also want the cookie header copied.

### Schedule Locally (Optional)

Use Windows Task Scheduler to run `run-local.ps1` on your preferred schedule.

## Notice

This project does not accept any PRs for adding recipes. Please do something interesting on your own.

## Links

* [API documentation for recipes](https://manual.calibre-ebook.com/news_recipe.html)
* [Calibre recipe repository](https://github.com/kovidgoyal/calibre/tree/master/recipes)
* [Adding your favorite news website](https://manual.calibre-ebook.com/news.html)

## License

[GNU General Public License v3.0](LICENSE)
