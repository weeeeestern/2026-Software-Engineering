# Notion to GitHub Markdown Sync

This repository includes a one-command sync pipeline that exports the latest Notion meeting page to Markdown and pushes it to GitHub.

## Setup

1. Create a Notion integration at <https://www.notion.so/my-integrations>.
2. Copy the integration secret.
3. Share the meeting database with that integration.
4. Copy `.env.example` to `.env`.
5. Fill in `NOTION_TOKEN` and `NOTION_DATABASE_URL` in `.env`.

## Run

```powershell
.\sync-notion.cmd
```

If you prefer running the PowerShell script directly and your machine allows it, this also works:

```powershell
.\sync-notion.ps1
```

By default, the script finds the most recently edited page in the Notion database and writes it to the `Scrum` folder. If that page has a Notion date property, the filename uses that date. Otherwise it uses today's date.

```text
Scrum/2026-05-08.md
```

Then it commits changed files and pushes to:

```text
https://github.com/weeeeestern/2026-Software-Engineering.git
```

You can override the destination path or branch in `.env`. Leave `NOTION_OUTPUT_PATH` empty to keep the automatic `Scrum/yyyy-MM-dd.md` naming. If you ever want to sync one fixed page instead, clear `NOTION_DATABASE_URL` and set `NOTION_PAGE_URL`.

If Git has no commit identity on this machine yet, configure it once:

```powershell
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```
