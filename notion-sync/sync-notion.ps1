param(
    [string]$NotionToken = $env:NOTION_TOKEN,
    [string]$NotionDatabase = $env:NOTION_DATABASE_URL,
    [string]$NotionPage = $env:NOTION_PAGE_URL,
    [string]$DateProperty = $env:NOTION_DATE_PROPERTY,
    [string]$OutputPath = $env:NOTION_OUTPUT_PATH,
    [string]$RepoUrl = $env:GITHUB_REPO_URL,
    [string]$Branch = $env:GIT_BRANCH,
    [string]$CommitMessage = $env:GIT_COMMIT_MESSAGE
)

$ErrorActionPreference = "Stop"

function Load-DotEnv {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    Get-Content -LiteralPath $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith("#")) {
            return
        }

        $parts = $line -split "=", 2
        if ($parts.Count -ne 2) {
            return
        }

        $name = $parts[0].Trim()
        $value = $parts[1].Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        if ($name) {
            [Environment]::SetEnvironmentVariable($name, $value, "Process")
        }
    }
}

function Get-RequiredValue {
    param(
        [string]$Value,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name is required. Set it in .env or pass it as a parameter."
    }

    return $Value
}

function Get-DateString {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return (Get-Date).ToString("yyyy-MM-dd")
    }

    try {
        return ([datetimeoffset]::Parse($Value)).ToLocalTime().ToString("yyyy-MM-dd")
    } catch {
        try {
            return ([datetime]::Parse($Value)).ToString("yyyy-MM-dd")
        } catch {
            return (Get-Date).ToString("yyyy-MM-dd")
        }
    }
}

function Get-PageDateString {
    param(
        $Page,
        [string]$PreferredDateProperty
    )

    if ($Page.properties) {
        if (-not [string]::IsNullOrWhiteSpace($PreferredDateProperty)) {
            $preferred = $Page.properties.PSObject.Properties | Where-Object { $_.Name -eq $PreferredDateProperty } | Select-Object -First 1
            if ($preferred -and $preferred.Value.type -eq "date" -and $preferred.Value.date -and $preferred.Value.date.start) {
                return Get-DateString $preferred.Value.date.start
            }
        }

        foreach ($property in $Page.properties.PSObject.Properties) {
            $value = $property.Value
            if ($value.type -eq "date" -and $value.date -and $value.date.start) {
                return Get-DateString $value.date.start
            }
        }
    }

    return (Get-Date).ToString("yyyy-MM-dd")
}

function Get-DefaultOutputPath {
    param(
        $Page,
        [string]$PreferredDateProperty
    )

    $meetingDate = Get-PageDateString $Page $PreferredDateProperty
    return "Scrum/$meetingDate.md"
}

function Get-NotionObjectId {
    param(
        [string]$Value,
        [string]$Name
    )

    $trimmed = $Value.Trim()
    $searchText = $trimmed

    try {
        $uri = [uri]$trimmed
        if ($uri.IsAbsoluteUri -and $uri.AbsolutePath) {
            $searchText = $uri.AbsolutePath
        }
    } catch {
    }

    $uuidMatches = [regex]::Matches($searchText, "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
    if ($uuidMatches.Count -gt 0) {
        return $uuidMatches[$uuidMatches.Count - 1].Value.Replace("-", "").ToLower()
    }

    $matches = [regex]::Matches($searchText, "[0-9a-fA-F]{32}")
    if ($matches.Count -gt 0) {
        return $matches[$matches.Count - 1].Value.ToLower()
    }

    throw "Could not find a Notion id in $Name."
}

function ConvertTo-NotionUuid {
    param([string]$PageId)

    if ($PageId.Contains("-")) {
        return $PageId
    }

    return "{0}-{1}-{2}-{3}-{4}" -f $PageId.Substring(0, 8), $PageId.Substring(8, 4), $PageId.Substring(12, 4), $PageId.Substring(16, 4), $PageId.Substring(20, 12)
}

function Invoke-NotionApi {
    param(
        [string]$Uri,
        [string]$Method = "Get",
        $Body = $null
    )

    $headers = @{
        "Authorization" = "Bearer $script:NotionToken"
        "Notion-Version" = "2022-06-28"
    }

    if ($null -eq $Body) {
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
    }

    $json = $Body | ConvertTo-Json -Depth 20
    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -ContentType "application/json" -Body $json
}

function Get-LatestDatabasePage {
    param([string]$DatabaseId)

    $encodedDatabaseId = [uri]::EscapeDataString((ConvertTo-NotionUuid $DatabaseId))
    $body = @{
        page_size = 1
        sorts = @(
            @{
                timestamp = "last_edited_time"
                direction = "descending"
            }
        )
    }

    $response = Invoke-NotionApi "https://api.notion.com/v1/databases/$encodedDatabaseId/query" "Post" $body
    $pages = @($response.results)
    if ($pages.Count -eq 0) {
        throw "No pages found in NOTION_DATABASE_URL."
    }

    return $pages[0]
}

function Get-Blocks {
    param([string]$BlockId)

    $encodedBlockId = [uri]::EscapeDataString((ConvertTo-NotionUuid $BlockId))
    $results = @()
    $cursor = $null

    do {
        $uri = "https://api.notion.com/v1/blocks/$encodedBlockId/children?page_size=100"
        if ($cursor) {
            $uri += "&start_cursor=$([uri]::EscapeDataString($cursor))"
        }

        $response = Invoke-NotionApi $uri
        $results += @($response.results)
        $cursor = $response.next_cursor
    } while ($cursor)

    return $results
}

function Format-RichText {
    param($Items)

    if (-not $Items) {
        return ""
    }

    $parts = foreach ($item in $Items) {
        $text = $item.plain_text
        if ($null -eq $text) {
            $text = ""
        }

        $text = $text.Replace('`', '\`')

        if ($item.href) {
            $escapedHref = $item.href.Replace(")", "%29")
            $text = "[$text]($escapedHref)"
        }

        if ($item.annotations) {
            if ($item.annotations.code) {
                $text = "``$text``"
            }
            if ($item.annotations.bold) {
                $text = "**$text**"
            }
            if ($item.annotations.italic) {
                $text = "*$text*"
            }
            if ($item.annotations.strikethrough) {
                $text = "~~$text~~"
            }
        }

        $text
    }

    return ($parts -join "")
}

function Get-PageTitle {
    param($Page)

    foreach ($property in $Page.properties.PSObject.Properties) {
        $value = $property.Value
        if ($value.type -eq "title") {
            $title = Format-RichText $value.title
            if (-not [string]::IsNullOrWhiteSpace($title)) {
                return $title
            }
        }
    }

    return "Notion Page"
}

function Get-FileExtensionFromUrl {
    param([string]$Url)

    try {
        $path = ([uri]$Url).AbsolutePath
        $extension = [IO.Path]::GetExtension($path)
        if ($extension -and $extension.Length -le 8) {
            return $extension
        }
    } catch {
    }

    return ".bin"
}

function Save-Asset {
    param(
        [string]$Url,
        [string]$BlockId,
        [string]$FallbackExtension
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $null
    }

    $extension = Get-FileExtensionFromUrl $Url
    if ($extension -eq ".bin" -and $FallbackExtension) {
        $extension = $FallbackExtension
    }

    $assetDirectory = Join-Path $script:WorkspaceRoot "assets/notion/$script:PageId"
    New-Item -ItemType Directory -Force -Path $assetDirectory | Out-Null

    $safeBlockId = $BlockId.Replace("-", "")
    $fileName = "$safeBlockId$extension"
    $target = Join-Path $assetDirectory $fileName
    Invoke-WebRequest -Uri $Url -OutFile $target | Out-Null

    $relative = "assets/notion/$script:PageId/$fileName"
    return $relative
}

function ConvertTo-MarkdownLinkPath {
    param([string]$WorkspaceRelativePath)

    $fromDirectory = $script:WorkspaceRoot
    if (-not [string]::IsNullOrWhiteSpace($script:OutputDirectory)) {
        $fromDirectory = Join-Path $script:WorkspaceRoot $script:OutputDirectory
    }

    New-Item -ItemType Directory -Force -Path $fromDirectory | Out-Null

    $fromUri = [uri]((Resolve-Path -LiteralPath $fromDirectory).Path.TrimEnd("\") + "\")
    $toPath = Join-Path $script:WorkspaceRoot $WorkspaceRelativePath
    $toUri = [uri]$toPath
    $relative = $fromUri.MakeRelativeUri($toUri).ToString()
    return [uri]::UnescapeDataString($relative).Replace("\", "/")
}

function Format-TableBlock {
    param(
        $Block,
        [int]$Depth
    )

    $rows = @(Get-Blocks $Block.id | Where-Object { $_.type -eq "table_row" })
    if ($rows.Count -eq 0) {
        return ""
    }

    $lines = @()
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $cells = @($rows[$i].table_row.cells | ForEach-Object { Format-RichText $_ })
        $escapedCells = @($cells | ForEach-Object { $_.Replace("|", "\|") })
        $lines += "| " + ($escapedCells -join " | ") + " |"

        if ($i -eq 0) {
            $separators = @($cells | ForEach-Object { "---" })
            $lines += "| " + ($separators -join " | ") + " |"
        }
    }

    return ($lines -join "`n") + "`n"
}

function Format-Children {
    param(
        $Block,
        [int]$Depth
    )

    if (-not $Block.has_children) {
        return ""
    }

    $children = Get-Blocks $Block.id
    return Format-Blocks $children ($Depth + 1)
}

function Format-Blocks {
    param(
        $Blocks,
        [int]$Depth = 0
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $indent = "  " * $Depth

    foreach ($block in $Blocks) {
        $text = ""
        $children = ""

        switch ($block.type) {
            "paragraph" {
                $text = Format-RichText $block.paragraph.rich_text
                $children = Format-Children $block $Depth
                if ($text -or $children) {
                    $lines.Add($text)
                    if ($children) { $lines.Add($children.TrimEnd()) }
                    $lines.Add("")
                }
            }
            "heading_1" {
                $lines.Add("# $(Format-RichText $block.heading_1.rich_text)")
                $lines.Add("")
            }
            "heading_2" {
                $lines.Add("## $(Format-RichText $block.heading_2.rich_text)")
                $lines.Add("")
            }
            "heading_3" {
                $lines.Add("### $(Format-RichText $block.heading_3.rich_text)")
                $lines.Add("")
            }
            "bulleted_list_item" {
                $text = Format-RichText $block.bulleted_list_item.rich_text
                $lines.Add("$indent- $text")
                $children = Format-Children $block $Depth
                if ($children) { $lines.Add($children.TrimEnd()) }
            }
            "numbered_list_item" {
                $text = Format-RichText $block.numbered_list_item.rich_text
                $lines.Add("${indent}1. $text")
                $children = Format-Children $block $Depth
                if ($children) { $lines.Add($children.TrimEnd()) }
            }
            "to_do" {
                $text = Format-RichText $block.to_do.rich_text
                $checked = if ($block.to_do.checked) { "x" } else { " " }
                $lines.Add("$indent- [$checked] $text")
                $children = Format-Children $block $Depth
                if ($children) { $lines.Add($children.TrimEnd()) }
            }
            "toggle" {
                $text = Format-RichText $block.toggle.rich_text
                $lines.Add("$indent<details>")
                $lines.Add("$indent<summary>$text</summary>")
                $children = Format-Children $block $Depth
                if ($children) { $lines.Add($children.TrimEnd()) }
                $lines.Add("$indent</details>")
                $lines.Add("")
            }
            "quote" {
                $text = Format-RichText $block.quote.rich_text
                $lines.Add("> $text")
                $children = Format-Children $block $Depth
                if ($children) {
                    $quotedChildren = ($children.TrimEnd() -split "`n" | ForEach-Object { "> $_" }) -join "`n"
                    $lines.Add($quotedChildren)
                }
                $lines.Add("")
            }
            "callout" {
                $text = Format-RichText $block.callout.rich_text
                $lines.Add("> [!NOTE]")
                if ($text) { $lines.Add("> $text") }
                $children = Format-Children $block $Depth
                if ($children) {
                    $quotedChildren = ($children.TrimEnd() -split "`n" | ForEach-Object { "> $_" }) -join "`n"
                    $lines.Add($quotedChildren)
                }
                $lines.Add("")
            }
            "code" {
                $language = $block.code.language
                if (-not $language) { $language = "" }
                $text = Format-RichText $block.code.rich_text
                $lines.Add('```' + $language)
                $lines.Add($text)
                $lines.Add('```')
                $lines.Add("")
            }
            "divider" {
                $lines.Add("---")
                $lines.Add("")
            }
            "image" {
                $caption = Format-RichText $block.image.caption
                $url = if ($block.image.type -eq "external") { $block.image.external.url } else { $block.image.file.url }
                $assetPath = Save-Asset $url $block.id ".png"
                if ($assetPath) {
                    $alt = if ($caption) { $caption } else { "image" }
                    $linkPath = ConvertTo-MarkdownLinkPath $assetPath
                    $lines.Add("![$alt]($linkPath)")
                    if ($caption) { $lines.Add("*$caption*") }
                    $lines.Add("")
                }
            }
            "file" {
                $caption = Format-RichText $block.file.caption
                $url = if ($block.file.type -eq "external") { $block.file.external.url } else { $block.file.file.url }
                $assetPath = Save-Asset $url $block.id ".bin"
                $label = if ($caption) { $caption } else { "file" }
                if ($assetPath) {
                    $linkPath = ConvertTo-MarkdownLinkPath $assetPath
                    $lines.Add("[$label]($linkPath)")
                    $lines.Add("")
                }
            }
            "pdf" {
                $caption = Format-RichText $block.pdf.caption
                $url = if ($block.pdf.type -eq "external") { $block.pdf.external.url } else { $block.pdf.file.url }
                $assetPath = Save-Asset $url $block.id ".pdf"
                $label = if ($caption) { $caption } else { "PDF" }
                if ($assetPath) {
                    $linkPath = ConvertTo-MarkdownLinkPath $assetPath
                    $lines.Add("[$label]($linkPath)")
                    $lines.Add("")
                }
            }
            "bookmark" {
                $caption = Format-RichText $block.bookmark.caption
                $label = if ($caption) { $caption } else { $block.bookmark.url }
                $lines.Add("[$label]($($block.bookmark.url))")
                $lines.Add("")
            }
            "embed" {
                $lines.Add("$($block.embed.url)")
                $lines.Add("")
            }
            "table" {
                $table = Format-TableBlock $block $Depth
                if ($table) {
                    $lines.Add($table.TrimEnd())
                    $lines.Add("")
                }
            }
            "child_page" {
                $lines.Add("- $($block.child_page.title)")
            }
            default {
                $children = Format-Children $block $Depth
                if ($children) {
                    $lines.Add($children.TrimEnd())
                    $lines.Add("")
                }
            }
        }
    }

    return ($lines -join "`n").TrimEnd() + "`n"
}

function Invoke-Git {
    param([string[]]$Arguments)

    & git @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed."
    }
}

function Get-WorkspaceRoot {
    $directory = Get-Item -LiteralPath $PSScriptRoot

    while ($directory) {
        if (Test-Path -LiteralPath (Join-Path $directory.FullName ".git")) {
            return $directory.FullName
        }

        $directory = $directory.Parent
    }

    return (Get-Location).Path
}

function Get-RemoteDefaultBranch {
    param([string]$RemoteName)

    try {
        $output = & git ls-remote --symref $RemoteName HEAD 2>$null
        foreach ($line in $output) {
            if ($line -match "ref:\s+refs/heads/([^\s]+)\s+HEAD") {
                return $Matches[1]
            }
        }
    } catch {
    }

    return $null
}

function Ensure-GitRemoteAndBranch {
    param(
        [string]$RemoteUrl,
        [string]$TargetBranch
    )

    Invoke-Git @("rev-parse", "--is-inside-work-tree") | Out-Null

    $existingOrigin = & git remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0) {
        Invoke-Git @("remote", "add", "origin", $RemoteUrl)
    } elseif ($existingOrigin -ne $RemoteUrl) {
        Invoke-Git @("remote", "set-url", "origin", $RemoteUrl)
    }

    if ([string]::IsNullOrWhiteSpace($TargetBranch)) {
        $TargetBranch = Get-RemoteDefaultBranch "origin"
    }

    if ([string]::IsNullOrWhiteSpace($TargetBranch)) {
        $TargetBranch = "main"
    }

    & git fetch --quiet origin $TargetBranch *> $null
    $remoteBranchExists = ($LASTEXITCODE -eq 0)
    $currentBranch = (& git branch --show-current).Trim()

    if ($remoteBranchExists) {
        & git show-ref --verify --quiet "refs/heads/$TargetBranch"
        $localBranchExists = ($LASTEXITCODE -eq 0)

        if ($currentBranch -ne $TargetBranch) {
            if ($localBranchExists) {
                Invoke-Git @("checkout", "--quiet", $TargetBranch)
            } else {
                Invoke-Git @("checkout", "--quiet", "-B", $TargetBranch, "origin/$TargetBranch")
            }
        }

        Invoke-Git @("pull", "--quiet", "--ff-only", "origin", $TargetBranch)
    } else {
        if ($currentBranch -ne $TargetBranch) {
            Invoke-Git @("checkout", "--quiet", "-B", $TargetBranch)
        }
    }

    return $TargetBranch
}

$script:WorkspaceRoot = Get-WorkspaceRoot
Set-Location -LiteralPath $script:WorkspaceRoot

$rootEnvPath = Join-Path $script:WorkspaceRoot ".env"
$scriptEnvPath = Join-Path $PSScriptRoot ".env"
if ($rootEnvPath -ne $scriptEnvPath) {
    Load-DotEnv $rootEnvPath
}
Load-DotEnv $scriptEnvPath

if (-not $NotionToken) { $NotionToken = $env:NOTION_TOKEN }
if (-not $NotionDatabase) { $NotionDatabase = $env:NOTION_DATABASE_URL }
if (-not $NotionPage) { $NotionPage = $env:NOTION_PAGE_URL }
if (-not $DateProperty) { $DateProperty = $env:NOTION_DATE_PROPERTY }
if (-not $OutputPath) { $OutputPath = $env:NOTION_OUTPUT_PATH }
if (-not $RepoUrl) { $RepoUrl = $env:GITHUB_REPO_URL }
if (-not $Branch) { $Branch = $env:GIT_BRANCH }
if (-not $CommitMessage) { $CommitMessage = $env:GIT_COMMIT_MESSAGE }

$script:NotionToken = Get-RequiredValue $NotionToken "NOTION_TOKEN"
if ([string]::IsNullOrWhiteSpace($NotionDatabase) -and [string]::IsNullOrWhiteSpace($NotionPage)) {
    throw "Set NOTION_DATABASE_URL for automatic latest-page sync, or set NOTION_PAGE_URL for one specific page."
}
if ([string]::IsNullOrWhiteSpace($RepoUrl)) { $RepoUrl = "https://github.com/weeeeestern/2026-Software-Engineering.git" }
if ([string]::IsNullOrWhiteSpace($CommitMessage)) { $CommitMessage = "Sync scrum meeting notes" }

if (-not [string]::IsNullOrWhiteSpace($NotionDatabase)) {
    $databaseId = Get-NotionObjectId $NotionDatabase "NOTION_DATABASE_URL"
    Write-Host "Finding latest page in Notion database $(ConvertTo-NotionUuid $databaseId)..."
    $page = Get-LatestDatabasePage $databaseId
} else {
    $pageId = Get-NotionObjectId $NotionPage "NOTION_PAGE_URL"
    $pageUuid = ConvertTo-NotionUuid $pageId
    Write-Host "Reading Notion page $pageUuid..."
    $page = Invoke-NotionApi "https://api.notion.com/v1/pages/$pageUuid"
}

$title = Get-PageTitle $page
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Get-DefaultOutputPath $page $DateProperty }

$script:OutputDirectory = Split-Path -Parent $OutputPath
$script:PageId = $page.id.Replace("-", "").ToLower()
$activeBranch = Ensure-GitRemoteAndBranch $RepoUrl $Branch
$blocks = Get-Blocks $script:PageId
$body = Format-Blocks $blocks

$markdown = @"
# $title

$body
"@

$targetPath = Join-Path $script:WorkspaceRoot $OutputPath
$targetDirectory = Split-Path -Parent $targetPath
if ($targetDirectory) {
    New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($targetPath, $markdown.TrimEnd() + "`n", $utf8NoBom)
Write-Host "Wrote $OutputPath"

$pathsToAdd = @($OutputPath)
if (Test-Path -LiteralPath (Join-Path $script:WorkspaceRoot "notion-sync")) { $pathsToAdd += "notion-sync" }
if (Test-Path -LiteralPath (Join-Path $script:WorkspaceRoot ".gitignore")) { $pathsToAdd += ".gitignore" }
if (Test-Path -LiteralPath (Join-Path $script:WorkspaceRoot "assets")) { $pathsToAdd += "assets" }

$gitAddArgs = @("add", "--") + $pathsToAdd
Invoke-Git $gitAddArgs

$status = & git status --porcelain
if ([string]::IsNullOrWhiteSpace(($status -join "`n"))) {
    Write-Host "No changes to commit."
    exit 0
}

Invoke-Git @("commit", "-m", $CommitMessage)
Invoke-Git @("push", "--quiet", "-u", "origin", $activeBranch)

Write-Host "Synced Notion page to $RepoUrl on branch $activeBranch."
