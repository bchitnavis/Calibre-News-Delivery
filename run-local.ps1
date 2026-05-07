[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\standalone.config.json"
)

$ErrorActionPreference = 'Stop'

$script:LoggingEnabled = $false
$script:LogFilePath = $null
$script:DebugLoggingEnabled = $false
$script:VerboseNativeOutput = $true

function Sanitize-LogMessage {
    param([string]$Message)

    if ($null -eq $Message) {
        return ''
    }

    $sanitized = [string]$Message
    $sanitized = $sanitized -replace '(?i)(cookie(header)?\s*[:=]\s*)(.+)', '${1}<redacted>'
    $sanitized = $sanitized -replace '(?i)(--password=)(\S+)', '${1}<redacted>'
    $sanitized = $sanitized -replace '(?i)(password\s*[:=]\s*)(\S+)', '${1}<redacted>'
    return $sanitized
}

function Initialize-Logger {
    param(
        [string]$RepoRoot,
        [pscustomobject]$LoggingConfig
    )

    $script:LoggingEnabled = $true
    if ($LoggingConfig -and $null -ne $LoggingConfig.enabled) {
        $script:LoggingEnabled = [bool]$LoggingConfig.enabled
    }

    $script:DebugLoggingEnabled = $false
    if ($LoggingConfig -and $null -ne $LoggingConfig.debug) {
        $script:DebugLoggingEnabled = [bool]$LoggingConfig.debug
    }

    $script:VerboseNativeOutput = $true
    if ($LoggingConfig -and $null -ne $LoggingConfig.verboseNativeOutput) {
        $script:VerboseNativeOutput = [bool]$LoggingConfig.verboseNativeOutput
    }

    if (-not $script:LoggingEnabled) {
        return
    }

    $logDir = 'logs'
    if ($LoggingConfig -and $LoggingConfig.directory) {
        $logDir = [string]$LoggingConfig.directory
    }

    if ([System.IO.Path]::IsPathRooted($logDir)) {
        $logDirectoryPath = $logDir
    }
    else {
        $logDirectoryPath = Join-Path $RepoRoot $logDir
    }

    New-Item -ItemType Directory -Path $logDirectoryPath -Force | Out-Null
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogFilePath = Join-Path $logDirectoryPath ("run-$timestamp.log")
    New-Item -ItemType File -Path $script:LogFilePath -Force | Out-Null
}

function Write-Log {
    param(
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string]$Level,
        [string]$Message,
        [switch]$ForceConsole
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $sanitized = Sanitize-LogMessage -Message $Message
    $line = "[$timestamp] [$Level] $sanitized"

    if ($script:LoggingEnabled -and $script:LogFilePath) {
        Add-Content -LiteralPath $script:LogFilePath -Value $line
    }

    $shouldWriteConsole = $true
    if ($Level -eq 'DEBUG' -and -not $script:DebugLoggingEnabled -and -not $ForceConsole) {
        $shouldWriteConsole = $false
    }

    if (-not $shouldWriteConsole) {
        return
    }

    switch ($Level) {
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'DEBUG' { Write-Host $line -ForegroundColor DarkGray }
        default { Write-Host $line }
    }
}

function Invoke-LoggedNativeCommand {
    param(
        [string]$CommandName,
        [string[]]$Arguments,
        [string]$CommandLabel
    )

    $output = New-Object System.Collections.Generic.List[string]
    & $CommandName @Arguments 2>&1 | ForEach-Object {
        $entry = $_
        if ($null -ne $entry) {
            $text = [string]$entry
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                [void]$output.Add($text)
                if ($script:VerboseNativeOutput) {
                    Write-Log -Level 'DEBUG' -Message "[$CommandLabel] $text" -ForceConsole
                }
                else {
                    Write-Log -Level 'DEBUG' -Message "[$CommandLabel] $text"
                }
            }
        }
    }
    return @($output)
}

function Assert-Command {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Required command not found in PATH: $Name"
    }
}

function Require-Property {
    param(
        [pscustomobject]$Object,
        [string]$Name
    )
    $value = $Object.$Name
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
        throw "Missing required config property: $Name"
    }
    return $value
}

function Convert-ToSafeFileName {
    param([string]$Value)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $safe = New-Object System.Text.StringBuilder
    foreach ($ch in $Value.ToCharArray()) {
        if ($invalid -contains $ch) {
            [void]$safe.Append('_')
        }
        else {
            [void]$safe.Append($ch)
        }
    }
    return $safe.ToString().Trim()
}

function Get-RecipeCandidates {
    param(
        [string]$RepoRoot,
        [string]$RecipeListFile,
        [string[]]$BuiltinRecipes
    )

    $recipeSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $recipeListPath = Join-Path $RepoRoot $RecipeListFile
    $knownBuiltins = @{}
    foreach ($name in $BuiltinRecipes) {
        $knownBuiltins[$name] = $true
    }

    if (Test-Path $recipeListPath) {
        Get-Content $recipeListPath | ForEach-Object {
            $line = $_.Trim()
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
                return
            }

            if (-not $knownBuiltins.ContainsKey($line)) {
                Write-Log -Level 'WARN' -Message "Built-in recipe not found, skipped: $line"
                return
            }

            if ($line.EndsWith('.recipe', [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$recipeSet.Add($line)
            }
            else {
                [void]$recipeSet.Add("$line.recipe")
            }
        }
    }

    Get-ChildItem -Path $RepoRoot -Filter '*.recipe' -File | ForEach-Object {
        [void]$recipeSet.Add($_.FullName)
    }

    Get-ChildItem -Path $RepoRoot -Filter '*.recipe.py' -File | ForEach-Object {
        [void]$recipeSet.Add($_.FullName)
    }

    return @($recipeSet)
}

function Get-RecipeBaseName {
    param([string]$RecipePath)

    $leaf = if ([System.IO.Path]::IsPathRooted($RecipePath)) {
        [System.IO.Path]::GetFileName($RecipePath)
    }
    else {
        $RecipePath
    }

    if ($leaf.EndsWith('.recipe.py', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $leaf.Substring(0, $leaf.Length - '.recipe.py'.Length)
    }
    if ($leaf.EndsWith('.recipe', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $leaf.Substring(0, $leaf.Length - '.recipe'.Length)
    }
    return [System.IO.Path]::GetFileNameWithoutExtension($leaf)
}

function New-ObsidianNewsNote {
    param(
        [string]$TargetDir,
        [string]$PublishedFileName,
        [pscustomobject]$NoteConfig
    )

    $noteTitle = [System.IO.Path]::GetFileNameWithoutExtension($PublishedFileName)
    $noteFileName = (Convert-ToSafeFileName -Value $noteTitle) + '.md'
    $notePath = Join-Path $TargetDir $noteFileName

    $emojiTitle = if ($NoteConfig -and $NoteConfig.emojiTitle) { [string]$NoteConfig.emojiTitle } else { '📰' }

    $tags = @('news', 'digest', 'calibre')
    if ($NoteConfig -and $NoteConfig.tags) {
        $tags = @($NoteConfig.tags | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    if ($tags.Count -eq 0) {
        $tags = @('news')
    }

    $links = @('22.00 - News', 'Inbox')
    if ($NoteConfig -and $NoteConfig.links) {
        $links = @($NoteConfig.links | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    if ($links.Count -eq 0) {
        $links = @('22.00 - News')
    }

    $yamlTags = ($tags | ForEach-Object { "  - $_" }) -join "`n"
    $inlineTags = ($tags | ForEach-Object { "#$_" }) -join ' '
    $wikiLinks = ($links | ForEach-Object { "- [[{0}]]" -f $_ }) -join "`n"
    $generatedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    $content = @"
---
tags:
$yamlTags
source: calibre-news-delivery
generated: $generatedAt
epub: [[${PublishedFileName}]]
---

# $emojiTitle $noteTitle

> [!summary] Daily News Digest
> Generated automatically from the Calibre recipe pipeline.
> Open the full edition: [[${PublishedFileName}]]

> [!tip] Reading Workflow
> - Highlight key articles.
> - Add notes and connect them with wikilinks.

## $emojiTitle Related
$wikiLinks

## $emojiTitle Tags
$inlineTags

## $emojiTitle Attachment
![[${PublishedFileName}]]
"@

    Set-Content -LiteralPath $notePath -Value $content -Encoding UTF8
    return $notePath
}

try {
    $runStart = Get-Date
    $publishedFileCount = 0
    $publishedNoteCount = 0
    $sentFileCount = 0

    $repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    $configFullPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $ConfigPath))

    if (-not (Test-Path $configFullPath)) {
        throw "Config file not found: $configFullPath"
    }

    $config = Get-Content $configFullPath -Raw | ConvertFrom-Json

    Initialize-Logger -RepoRoot $repoRoot -LoggingConfig $config.logging
    Write-Log -Level 'INFO' -Message "Run started with config: $configFullPath"

    Assert-Command -Name 'ebook-convert'
    Assert-Command -Name 'ebook-meta'

    $delivery = if ($config.delivery) { $config.delivery.ToLowerInvariant() } else { 'obsidian' }
    if ($delivery -ne 'obsidian' -and $delivery -ne 'smtp') {
        throw "delivery must be obsidian or smtp"
    }

    $format = if ($config.format) { $config.format.ToLowerInvariant() } else { 'epub' }
    $author = if ($config.author) { $config.author } else { 'Calibre News Delivery' }
    $publisher = if ($config.publisher) { $config.publisher } else { 'bookfere.com' }
    $outputDir = if ($config.outputDir) { $config.outputDir } else { 'converted_ebooks' }
    $recipeListFile = if ($config.recipeListFile) { $config.recipeListFile } else { 'recipe_list.txt' }
    $coversDir = if ($config.coversDir) { $config.coversDir } else { 'covers' }
    $stylesDir = if ($config.stylesDir) { $config.stylesDir } else { 'styles' }
    $sizeLimitMb = if ($config.sizeLimitMb) { [int]$config.sizeLimitMb } else { 25 }

    $outputPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $outputDir))
    $coversPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $coversDir))
    $stylesPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $stylesDir))

    New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

    $nytAuth = $config.nytAuth
    $nytUsername = ''
    $nytPassword = ''
    $nytCookieHeader = ''
    $nytUseEmbedded = ''
    $nytMaxPerFeed = ''
    $nytIncludeFeeds = ''
    $nytExcludeFeeds = ''
    $nytThreads = ''
    $nytDelaySeconds = ''
    $ftAuth = $config.ftAuth
    $ftUsername = ''
    $ftPassword = ''
    $ftCookieHeader = ''
    $ftMaxPerFeed = ''
    $ftIncludeFeeds = ''
    $ftExcludeFeeds = ''
    $ftThreads = ''
    $ftDelaySeconds = ''
    $ftPlaywrightFallback = ''
    $ftPythonPath = ''
    $ftIssueDate = ''
    $ftIssueUrl = ''
    if ($nytAuth) {
        $nytUsername = if ($nytAuth.username) { [string]$nytAuth.username } else { '' }
        $nytPassword = if ($nytAuth.password) { [string]$nytAuth.password } else { '' }
        $nytCookieHeader = if ($nytAuth.cookieHeader) { [string]$nytAuth.cookieHeader } else { '' }
        $nytUseEmbedded = if ($null -ne $nytAuth.useEmbeddedContent) { [string]$nytAuth.useEmbeddedContent } else { '' }
        $nytMaxPerFeed = if ($nytAuth.maxArticlesPerFeed) { [string]$nytAuth.maxArticlesPerFeed } else { '' }
        if ($nytAuth.includeFeeds) {
            $nytIncludeFeeds = [string]::Join(',', @($nytAuth.includeFeeds))
        }
        if ($nytAuth.excludeFeeds) {
            $nytExcludeFeeds = [string]::Join(',', @($nytAuth.excludeFeeds))
        }
        $nytThreads = if ($nytAuth.threads) { [string]$nytAuth.threads } else { '' }
        $nytDelaySeconds = if ($nytAuth.delaySeconds) { [string]$nytAuth.delaySeconds } else { '' }
        $nytPlaywrightFallback = if ($null -ne $nytAuth.playwrightFallback) { [string]$nytAuth.playwrightFallback } else { '' }
        $nytPythonPath = if ($nytAuth.pythonPath) { [string]$nytAuth.pythonPath } else { '' }
        $env:NYT_USERNAME = $nytUsername
        $env:NYT_PASSWORD = $nytPassword
        $env:NYT_COOKIE_HEADER = $nytCookieHeader
        $env:NYT_USE_EMBEDDED = $nytUseEmbedded
        $env:NYT_MAX_ARTICLES_PER_FEED = $nytMaxPerFeed
        $env:NYT_INCLUDE_FEEDS = $nytIncludeFeeds
        $env:NYT_EXCLUDE_FEEDS = $nytExcludeFeeds
        $env:NYT_THREADS = $nytThreads
        $env:NYT_DELAY_SECONDS = $nytDelaySeconds
        $env:NYT_PLAYWRIGHT_FALLBACK = $nytPlaywrightFallback
        $env:NYT_PYTHON_PATH = $nytPythonPath
        $env:NYT_PLAYWRIGHT_SCRIPT_PATH = Join-Path $repoRoot 'nyt_fetch_playwright.py'
    }
    else {
        $env:NYT_USERNAME = ''
        $env:NYT_PASSWORD = ''
        $env:NYT_COOKIE_HEADER = ''
        $env:NYT_USE_EMBEDDED = ''
        $env:NYT_MAX_ARTICLES_PER_FEED = ''
        $env:NYT_INCLUDE_FEEDS = ''
        $env:NYT_EXCLUDE_FEEDS = ''
        $env:NYT_THREADS = ''
        $env:NYT_DELAY_SECONDS = ''
        $env:NYT_PLAYWRIGHT_FALLBACK = ''
        $env:NYT_PYTHON_PATH = ''
        $env:NYT_PLAYWRIGHT_SCRIPT_PATH = ''
    }

    if ($ftAuth) {
        $ftUsername = if ($ftAuth.username) { [string]$ftAuth.username } else { '' }
        $ftPassword = if ($ftAuth.password) { [string]$ftAuth.password } else { '' }
        $ftCookieHeader = if ($ftAuth.cookieHeader) { [string]$ftAuth.cookieHeader } else { '' }
        $ftMaxPerFeed = if ($ftAuth.maxArticlesPerFeed) { [string]$ftAuth.maxArticlesPerFeed } else { '' }
        if ($ftAuth.includeFeeds) {
            $ftIncludeFeeds = [string]::Join(',', @($ftAuth.includeFeeds))
        }
        if ($ftAuth.excludeFeeds) {
            $ftExcludeFeeds = [string]::Join(',', @($ftAuth.excludeFeeds))
        }
        $ftThreads = if ($ftAuth.threads) { [string]$ftAuth.threads } else { '' }
        $ftDelaySeconds = if ($ftAuth.delaySeconds) { [string]$ftAuth.delaySeconds } else { '' }
        $ftPlaywrightFallback = if ($null -ne $ftAuth.playwrightFallback) { [string]$ftAuth.playwrightFallback } else { '' }
        $ftPythonPath = if ($ftAuth.pythonPath) { [string]$ftAuth.pythonPath } else { '' }
        $ftIssueDate = if ($ftAuth.issueDate) { [string]$ftAuth.issueDate } else { '' }
        $ftIssueUrl = if ($ftAuth.issueUrl) { [string]$ftAuth.issueUrl } else { '' }
        $ftStartArticleUrl = if ($ftAuth.startArticleUrl) { [string]$ftAuth.startArticleUrl } else { '' }

        $env:FT_USERNAME = $ftUsername
        $env:FT_PASSWORD = $ftPassword
        $env:FT_COOKIE_HEADER = $ftCookieHeader
        $env:FT_MAX_ARTICLES_PER_FEED = $ftMaxPerFeed
        $env:FT_INCLUDE_FEEDS = $ftIncludeFeeds
        $env:FT_EXCLUDE_FEEDS = $ftExcludeFeeds
        $env:FT_THREADS = $ftThreads
        $env:FT_DELAY_SECONDS = $ftDelaySeconds
        $env:FT_PLAYWRIGHT_FALLBACK = $ftPlaywrightFallback
        $env:FT_PYTHON_PATH = $ftPythonPath
        $env:FT_PLAYWRIGHT_SCRIPT_PATH = Join-Path $repoRoot 'ft_fetch_playwright.py'
        $env:FT_PRESSREADER_DATE = $ftIssueDate
        $env:FT_PRESSREADER_ISSUE_URL = $ftIssueUrl
        $env:FT_START_ARTICLE_URL = $ftStartArticleUrl
    }
    else {
        $env:FT_USERNAME = ''
        $env:FT_PASSWORD = ''
        $env:FT_COOKIE_HEADER = ''
        $env:FT_MAX_ARTICLES_PER_FEED = ''
        $env:FT_INCLUDE_FEEDS = ''
        $env:FT_EXCLUDE_FEEDS = ''
        $env:FT_THREADS = ''
        $env:FT_DELAY_SECONDS = ''
        $env:FT_PLAYWRIGHT_FALLBACK = ''
        $env:FT_PYTHON_PATH = ''
        $env:FT_PLAYWRIGHT_SCRIPT_PATH = ''
        $env:FT_PRESSREADER_DATE = ''
        $env:FT_PRESSREADER_ISSUE_URL = ''
        $env:FT_START_ARTICLE_URL = ''
    }

    Write-Log -Level 'INFO' -Message 'Loading built-in recipes...'
    $builtinRecipeOutput = Invoke-LoggedNativeCommand -CommandName 'ebook-convert' -Arguments @('--list-recipes') -CommandLabel 'ebook-convert:list-recipes'
    if ($LASTEXITCODE -ne 0) {
        throw "ebook-convert --list-recipes failed with exit code $LASTEXITCODE"
    }
    $builtinRecipeNames = @($builtinRecipeOutput | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    $recipes = Get-RecipeCandidates -RepoRoot $repoRoot -RecipeListFile $recipeListFile -BuiltinRecipes $builtinRecipeNames
    if ($recipes.Count -eq 0) {
        throw 'No recipes to process. Add recipe titles to recipe_list.txt or add *.recipe / *.recipe.py files in repo root.'
    }

    Write-Log -Level 'INFO' -Message ("Recipes queued: {0}" -f $recipes.Count)

    $convertedFiles = New-Object System.Collections.Generic.List[string]
    $failedRecipes = New-Object System.Collections.Generic.List[string]

    foreach ($recipe in $recipes) {
        $recipeLabel = if ([System.IO.Path]::IsPathRooted($recipe)) { Split-Path -Leaf $recipe } else { $recipe }
        $recipeBase = Get-RecipeBaseName -RecipePath $recipe
        $tempOutput = Join-Path $repoRoot ("{0}.{1}" -f $recipeBase, $format)

        try {
            $args = @($recipe, $tempOutput, "--authors=$author", "--publisher=$publisher")

            if ($recipeBase -eq 'nyt_news' -and $nytCookieHeader) {
                $authUser = if ($nytUsername) { $nytUsername } else { 'cookie-auth' }
                $authPassword = if ($nytPassword) { $nytPassword } else { 'cookie-auth' }
                $args += @("--username=$authUser", "--password=$authPassword")
            }

            if ($recipeBase -eq 'ft' -and (-not [string]::IsNullOrWhiteSpace($ftCookieHeader) -or (-not [string]::IsNullOrWhiteSpace($ftUsername) -and -not [string]::IsNullOrWhiteSpace($ftPassword)))) {
                $authUser = if ($ftUsername) { $ftUsername } else { 'cookie-auth' }
                $authPassword = if ($ftPassword) { $ftPassword } else { 'cookie-auth' }
                $args += @("--username=$authUser", "--password=$authPassword")
            }

            $cover = Join-Path $coversPath ("{0}.png" -f $recipeBase)
            if (Test-Path $cover) {
                $args += "--cover=$cover"
            }

            $style = Join-Path $stylesPath ("{0}.css" -f $recipeBase)
            if (Test-Path $style) {
                $args += "--extra-css=$style"
            }

            Write-Log -Level 'INFO' -Message ("Converting: {0}" -f $recipeLabel)
            Invoke-LoggedNativeCommand -CommandName 'ebook-convert' -Arguments $args -CommandLabel ("ebook-convert:{0}" -f $recipeLabel) | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "ebook-convert failed with exit code $LASTEXITCODE"
            }

            if (-not (Test-Path $tempOutput)) {
                throw "Output file not found after conversion: $tempOutput"
            }

            $meta = Invoke-LoggedNativeCommand -CommandName 'ebook-meta' -Arguments @($tempOutput) -CommandLabel ("ebook-meta:{0}" -f $recipeLabel)
            if ($LASTEXITCODE -ne 0) {
                throw "ebook-meta failed with exit code $LASTEXITCODE"
            }
            $titleLine = $meta | Select-String -Pattern '^Title\s*:\s*(.+)$' | Select-Object -First 1
            $title = if ($titleLine) { $titleLine.Matches[0].Groups[1].Value.Trim() } else { $recipeBase }
            $safeTitle = Convert-ToSafeFileName -Value $title
            if ([string]::IsNullOrWhiteSpace($safeTitle)) {
                $safeTitle = $recipeBase
            }

            $finalOutput = Join-Path $outputPath ("{0}.{1}" -f $safeTitle, $format)
            Move-Item -Path $tempOutput -Destination $finalOutput -Force
            $convertedFiles.Add($finalOutput) | Out-Null
        }
        catch {
            $failedRecipes.Add($recipeLabel) | Out-Null
            Write-Log -Level 'WARN' -Message ("Recipe failed and was skipped: {0}. {1}" -f $recipeLabel, $_.Exception.Message)
            if (Test-Path $tempOutput) {
                Remove-Item -Path $tempOutput -Force -ErrorAction SilentlyContinue
            }
            continue
        }
    }

    if ($convertedFiles.Count -eq 0) {
        throw 'No ebooks converted. All recipe conversions failed.'
    }

    if ($failedRecipes.Count -gt 0) {
        Write-Log -Level 'WARN' -Message ("Failed recipes: {0}" -f ($failedRecipes -join ', '))
    }

    if ($delivery -eq 'obsidian') {
        $targetDir = Require-Property -Object $config -Name 'obsidianNewsDir'
        $targetPath = [System.IO.Path]::GetFullPath($targetDir)
        $obsidianNoteConfig = $config.obsidianNote
        $obsidianNoteEnabled = $true
        if ($obsidianNoteConfig -and $null -ne $obsidianNoteConfig.enabled) {
            $obsidianNoteEnabled = [bool]$obsidianNoteConfig.enabled
        }
        New-Item -ItemType Directory -Path $targetPath -Force | Out-Null

        Write-Log -Level 'INFO' -Message ("Publishing to Obsidian folder: {0}" -f $targetPath)
        foreach ($file in $convertedFiles) {
            $publishedFileName = Split-Path -Leaf $file
            $dest = Join-Path $targetPath $publishedFileName
            Copy-Item -LiteralPath $file -Destination $dest -Force
            $publishedFileCount += 1
            Write-Log -Level 'INFO' -Message ("Published: {0}" -f $publishedFileName)

            if ($obsidianNoteEnabled) {
                $notePath = New-ObsidianNewsNote -TargetDir $targetPath -PublishedFileName $publishedFileName -NoteConfig $obsidianNoteConfig
                $publishedNoteCount += 1
                Write-Log -Level 'INFO' -Message ("Published note: {0}" -f (Split-Path -Leaf $notePath))
            }
        }
        Write-Log -Level 'INFO' -Message ("Published files: {0}" -f $convertedFiles.Count)
    }
    else {
        Assert-Command -Name 'calibre-smtp'

        $smtp = $config.smtp
        if (-not $smtp) {
            throw 'Missing smtp object in config for smtp delivery.'
        }

        $relay = Require-Property -Object $smtp -Name 'server'
        $port = Require-Property -Object $smtp -Name 'port'
        $encrypt = Require-Property -Object $smtp -Name 'encryption'
        $username = Require-Property -Object $smtp -Name 'username'
        $password = Require-Property -Object $smtp -Name 'password'
        $from = Require-Property -Object $smtp -Name 'from'
        $to = Require-Property -Object $smtp -Name 'to'

        foreach ($file in $convertedFiles) {
            $sizeMb = [math]::Ceiling((Get-Item -LiteralPath $file).Length / 1MB)
            if ($sizeMb -ge $sizeLimitMb) {
                Write-Log -Level 'WARN' -Message ("Size exceeds limit, skipped: {0} ({1}MB)" -f (Split-Path -Leaf $file), $sizeMb)
                continue
            }

            $title = [System.IO.Path]::GetFileNameWithoutExtension($file)
            Write-Log -Level 'INFO' -Message ("Sending: {0}" -f (Split-Path -Leaf $file))
            & calibre-smtp -a $file -r $relay --port=$port -e $encrypt.ToUpperInvariant() -u $username -p $password -s $title $from $to "Deliver $title"
            if ($LASTEXITCODE -eq 0) {
                $sentFileCount += 1
            }
        }
    }

    $elapsedSeconds = ((Get-Date) - $runStart).TotalSeconds
    Write-Log -Level 'INFO' -Message ("Run summary: queued={0}, converted={1}, failed={2}, publishedFiles={3}, publishedNotes={4}, sentFiles={5}, delivery={6}, durationSeconds={7:N1}" -f $recipes.Count, $convertedFiles.Count, $failedRecipes.Count, $publishedFileCount, $publishedNoteCount, $sentFileCount, $delivery, $elapsedSeconds)
    Write-Log -Level 'INFO' -Message 'Done.'
    if ($script:LoggingEnabled -and $script:LogFilePath) {
        Write-Log -Level 'INFO' -Message ("Log file: {0}" -f $script:LogFilePath)
    }
}
catch {
    Write-Log -Level 'ERROR' -Message $_.Exception.Message
    if ($script:LoggingEnabled -and $script:LogFilePath) {
        Write-Log -Level 'ERROR' -Message ("Log file: {0}" -f $script:LogFilePath)
    }
    exit 1
}
