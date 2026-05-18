# chat.jawafdehi.org — Architecture & Status Overview

> **Living document.** Update this file whenever the architecture changes so it
> remains the central reference for new and continuing contributors.

---

## Table of Contents

1. [Service Map](#service-map)
2. [Repository Map](#repository-map)
3. [Identity & Authentication Flow](#identity--authentication-flow)
4. [Customizations to OpenWebUI](#customizations-to-openwebui)
5. [Deployment](#deployment)
6. [CI/CD Pipeline](#cicd-pipeline)
7. [Infrastructure](#infrastructure)
8. [Related Issues & PRs](#related-issues--prs)
9. [Known Gaps & Planned Work](#known-gaps--planned-work)
10. [Keeping This Document Up to Date](#keeping-this-document-up-to-date)

---

## Service Map

```
                          Internet
                             │
                     ┌───────▼────────┐
                     │    nginx       │  monal.cloud VPS (50.175.70.14)
                     │  port 443      │  certbot / Let's Encrypt
                     │  port 80 (→443)│
                     └───────┬────────┘
                             │
              ┌──────────────▼──────────────────┐
              │        OpenWebUI                 │
              │  Fork: Jawafdehi/open-webui      │
              │  Branch: jawafdehi-main          │
              │  Image: jawafdehi/open-webui     │
              │         :jawafdehi-main (Docker) │
              │  Port: 8080 (127.0.0.1 only)     │
              │  Auth: Google OAuth SSO          │
              │  URL: https://chat.jawafdehi.org │
              │  Branding: Jawafdehi static      │
              │            assets volume-mounted │
              └──────┬───────────────────────────┘
                     │
                     │  X-Jawafdehi-User-Id: {{USER_ID}}
                     │  X-Jawafdehi-User-Name: {{USER_NAME}}
                     │
              ┌──────▼───────────────────────────┐
              │        jawafdehi-mcp              │
              │  Streamable HTTP MCP Server       │
              │  Port: 8000 (internal Docker net) │
              │  No public port exposure          │
              └──────┬───────────────────────────┘
                     │
                     │  Service account token
                     │  + X-Jawafdehi-User-Id header
                     │
              ┌──────▼───────────────────────────┐
              │        jawafdehi-api               │
              │  Django backend                    │
              │  URL: https://portal.jawafdehi.org │
              │  Endpoint: GET /api/caseworker/me  │
              │  Resolves ChatUserIdentity → User  │
              └───────────────────────────────────┘
```

### Services at a Glance

| Service | URL | Port | Tech | Purpose |
|---------|-----|------|------|---------|
| nginx | chat.jawafdehi.org | 443 | nginx + certbot | TLS termination, reverse proxy |
| OpenWebUI | chat.jawafdehi.org | 8080 | Python (FastAPI) + Svelte | Chat UI, Google OAuth, MCP client |
| jawafdehi-mcp | internal | 8000 | Python (MCP SDK) | Accountability tools, identity proxy |
| jawafdehi-api | portal.jawafdehi.org | — | Django | User identity, case/entity CRUD |

---

## Repository Map

### Active Repos

| Repo | URL | Primary Branch | Description |
|------|-----|---------------|-------------|
| open-webui | [Jawafdehi/open-webui](https://github.com/Jawafdehi/open-webui) | `main` (upstream), **`jawafdehi-main`** (deployed) | OpenWebUI fork with Jawafdehi customizations |
| jawafdehi-mcp | [Jawafdehi/jawafdehi-mcp](https://github.com/Jawafdehi/jawafdehi-mcp) | `main` | MCP server — accountability tools for caseworkers & public |
| JawafdehiAPI | [Jawafdehi/JawafdehiAPI](https://github.com/Jawafdehi/JawafdehiAPI) | `main` | Django backend — cases, entities, identity |
| infra | [Jawafdehi/infra](https://github.com/Jawafdehi/infra) | `main` | Terraform, VPS scripts, nginx config |

### OpenWebUI Branch Structure

`jawafdehi-main` is the primary development branch. It consolidates all previously
scattered feature branches into a single maintained line. `jawafdehi-custom` is a
historical predecessor (all changes have been merged into `jawafdehi-main`).

| Branch | Based On | Status | Purpose |
|--------|----------|--------|---------|
| `jawafdehi-main` | `main` | **Deployed** | All Jawafdehi customizations + CI/CD + assets |
| `jawafdehi-custom` | `main` | Historical | Predecessor (all changes absorbed into main) |
| `JAWA-894-architecture-doc` | `jawafdehi-main` | Open PR #13 | This architecture document |

### jawafdehi-mcp Branch Structure

| Branch | Status | Purpose |
|--------|--------|---------|
| `main` | Deployed | Current production |
| `feat/JAWA-1222-user-name-header` | Merged → main | Forward X-Jawafdehi-User-Name header |
| `ja/JAWA-600-http-transport` | Merged → main | Streamable HTTP transport |
| `ja/JAWA-601-user-filtering-audit` | Merged → main | Per-user tool filtering |
| `feat/jawa-578-markdown-descriptions` | Merged → main | Markdown tool descriptions |
| `jaWA-327-numeric-slugs` | Merged → main | Slug-based case lookup |
| `feat/agentic-api-enrichment` | Merged → main | Additional MCP tools |

---

## Identity & Authentication Flow

### High-Level Auth Flow

```
1. Browser → Google OAuth → OpenWebUI
     User authenticates via Google SSO. OpenWebUI creates/identifies the user
     by their Google account email.

2. OpenWebUI → jawafdehi-mcp (custom MCP headers)
     For every MCP tool request, OpenWebUI injects:
       X-Jawafdehi-User-Id: <OpenWebUI internal user ID>
       X-Jawafdehi-User-Name: <user display name>
     These are template variables ({{USER_ID}}, {{USER_NAME}}) resolved
     server-side — users cannot spoof them.

3. jawafdehi-mcp → jawafdehi-api (identity resolution)
     jawafdehi-mcp calls GET /api/caseworker/me on jawafdehi-api with:
       Authorization: Token <service-account-token>
       X-Jawafdehi-User-Id: <forwarded ID>
     jawafdehi-api resolves the ID via ChatUserIdentity → Django User.

4. jawafdehi-api → jawafdehi-mcp (identity response)
     Returns { user_id, username, roles: ["Contributor"|"Admin"|"Moderator"|...] }

5. Per-user tool filtering
     jawafdehi-mcp uses roles to filter available tools:
       - Caseworker roles (Contributor, Admin, Moderator) → ALL tools
       - Public / unauthenticated → Read-only tools only
```

### Public vs. Caseworker Access

| Feature | Public User | Caseworker |
|---------|------------|------------|
| Chat UI | ✅ Yes | ✅ Yes |
| Google SSO | ✅ Required | ✅ Required |
| ChatUserIdentity mapping | ❌ Not needed | ✅ Required |
| MCP Tools (read-only: search cases, entities, judicial data) | ✅ Yes | ✅ Yes |
| MCP Tools (write: create cases, upload sources, submit NES changes) | ❌ Denied | ✅ Yes |
| Tool Approval UI | ❌ N/A | ✅ Yes |

### ChatUserIdentity Model

Defined in `JawafdehiAPI/cases/models.py`:

```python
class ChatUserIdentity(models.Model):
    owui_user_id = models.CharField(max_length=255, unique=True)
    user = models.ForeignKey(User, on_delete=models.CASCADE)
```

Maps OpenWebUI internal user IDs to Django User accounts. Create using the
Django admin or `python manage.py setup_chat_service_account`.

---

## Customizations to OpenWebUI

All customizations live in the `jawafdehi-main` branch.

### 1. Custom Prompt Suggestions

Replaced generic OpenWebUI prompts with Jawafdehi-themed suggestions:
- Procurement corruption in Nepal
- CIAA case handling
- Big corruption cases
- Case counts by fiscal year
- "What is Jawafdehi?"
- How to file a CIAA complaint

**Files:** `backend/open_webui/config.py`

### 2. MCP Server Integration

- OpenWebUI connects to jawafdehi-mcp via Streamable HTTP on internal Docker network
- Custom headers: `X-Jawafdehi-User-Id`, `X-Jawafdehi-User-Name`
- Header template variables resolved at request time via `get_custom_headers()`
- Config: `deploy/chat/openwebui/tools-config.json`

**Key env vars:**
- `ENABLE_MCP=true`
- `ENABLE_FORWARD_USER_INFO_HEADERS=true`
- `ENABLE_OAUTH_SIGNUP=true`
- `ENABLE_LOGIN_FORM=false`
- `OAUTH_MERGE_ACCOUNTS_BY_EMAIL=true`

**Files:**
- `backend/open_webui/utils/headers.py` — template variable resolution
- `backend/open_webui/utils/middleware.py` — header forwarding
- `deploy/chat/code/middleware.py` — production override snapshot

### 3. Tool Call Approval UI

Server-side pending approval tracking with WebSocket notification:
- User-initiated tool calls pause pending user approval
- Socket.IO events: `approval:tool:pending`, `approval:tool:response`, `approval:tool:restore`
- Configurable timeout (`TOOL_APPROVAL_TIMEOUT`, default 300s)
- Survives WebSocket disconnect (replays on reconnect)
- Crash resilience: pending approvals persist across tab crashes
- **Allow Always** button: users can whitelist a tool so future calls auto-approve
- **Enable/disable toggle**: controlled via `ENABLE_TOOL_APPROVAL` env var
- Null-guard on `event_emitter` prevents crashes when WebSocket is not connected

**Key env vars:**
- `ENABLE_TOOL_APPROVAL` — enable/disable tool approval gating (default: off)
- `TOOL_APPROVAL_TIMEOUT` — seconds before auto-deny (default: 300)

**Files:**
- `backend/open_webui/utils/pending_approvals.py` — server-side tracking
- `backend/open_webui/socket/main.py` — WebSocket handlers
- `src/lib/utils/tool-approval.ts` — client-side callbacks + Allow Always persistence
- `src/lib/components/common/ToolCallDisplay.svelte` — approve/deny/allow-always UI
- `src/routes/+layout.svelte` — RPC handler

### 4. Bypass Model Access Control (JAWA-1322)

`BYPASS_MODEL_ACCESS_CONTROL=true` allows any user to access any configured model
without per-user model permission checks. Applied in both the dev and prod compose files.

### 5. Config-as-Code (JAWA-1058/1353/1354/1403)

Structured configs for repeatable, automated deployments.

**Configs directory:**
```
deploy/chat/configs/
├── README.md                           # Usage & structure docs
├── models/
│   └── jawafdehi-caseworker.json       # Caseworker model preset
└── knowledge/
    ├── collections.json                # KB collection metadata
    └── (knowledge doc files)
```

**Collections** (`collections.json`) define caseworker skills KB:
- `jawafdehi-caseworker.md` — AI assistant skills for corruption case analysis
- `jawafdehi-case-reviewer.md` — Case review skills
- `jawafdehi-script-generator.md` — Public communication script generation

**Skills source of truth:** Skill content is **authored in** `jawafdehi-meta`
(at `.agents/skills/{skill-name}/SKILL.md`) and **pulled at deploy time** by
`deploy.sh`. The deploy script clones jawafdehi-meta, copies the SKILL.md
files into `configs/knowledge/caseworker/`, and `bootstrap-config.sh` uploads
them to the OpenWebUI Knowledge Base API.

```
jawafdehi-meta (author) → deploy.sh (fetch at CI time)
                         → configs/knowledge/caseworker/ (staging)
                         → bootstrap-config.sh (upload to OWUI KB API)
```

This means: to update a skill, edit it in `jawafdehi-meta`; the next CI deploy
will pick up the change automatically.

**Bootstrap script** at `deploy/chat/bin/bootstrap-config.sh`:
- Idempotent — safe to run on every deploy
- Applies models, knowledge base docs, prompts, and groups via OpenWebUI API
- Requires `OPENWEBUI_API_KEY` and `OPENWEBUI_URL`
- Supports `--dry-run`, `--models-only`, `--knowledge-only`, `--prompts-only`, `--groups-only`

**Configs API router** at `backend/open_webui/routers/configs.py`.

### 6. Python Code Overrides (Production)

In production, key OpenWebUI modules are overridden via bind-mounted Python files:

| Mount | Overrides | Purpose |
|-------|-----------|---------|
| `code/middleware.py` | `open_webui/utils/middleware.py` | Chat pipeline, MCP tool handling, responses API |
| `code/tools_models.py` | `open_webui/models/tools.py` | Tool/function model definitions |
| `code/tools_utils.py` | `open_webui/utils/tools.py` | Tool resolution and execution utilities |

These are snapshots of the corresponding backend files from `jawafdehi-main`, kept
in `deploy/chat/code/` so they can be iterated on without rebuilding the Docker image.

### 7. Jawafdehi Branding (JAWA-585)

Static assets are volume-mounted into the OpenWebUI container:

| Asset | Purpose |
|-------|---------|
| `favicon.png`, `.ico`, `.svg` | Browser tab icon (light/dark) |
| `favicon-96x96.png` | Android/Chrome favicon |
| `apple-touch-icon.png` | iOS home screen icon |
| `logo.png` | Application logo |
| `splash.png`, `splash-dark.png` | Loading splash screens |
| `web-app-manifest-*.png` | PWA manifest icons |
| `site.webmanifest` | PWA manifest |
| `custom.css` | Custom CSS overrides |

### 8. Docker Build (amd64-only)

- AMD64-only builds for simpler CI/CD
- Images pushed to Docker Hub: `jawafdehi/open-webui:jawafdehi-main`
- Public images — no auth required for pull
- Image exported as tar.gz for offline deploy

---

## Deployment

### Host

- **Provider:** monal.cloud
- **IP:** 50.175.70.14
- **Domain:** chat.jawafdehi.org
- **Secrets dir:** `/opt/openwebui-secrets/` (on host)

### Stack (Production)

```
nginx (port 443) → OpenWebUI (127.0.0.1:8080, pre-built image)
                 → jawafdehi-mcp (internal Docker port 8000)
```

### Deployment Layout

```
deploy/chat/
├── docker-compose.yml              # Dev/reference stack (builds from source)
├── docker-compose.prod.yml         # Production stack (pre-built Docker image)
├── .env.example                    # OAUTH secrets template
├── mcp.env.example                 # jawafdehi-mcp secrets template
├── openwebui/tools-config.json     # MCP connection config
├── bin/
│   ├── deploy.sh                   # Self-contained deploy script
│   └── bootstrap-config.sh         # Idempotent config push
├── code/                           # Python override snapshots
│   ├── middleware.py
│   ├── tools_models.py
│   └── tools_utils.py
├── configs/                        # Config-as-code
│   ├── models/
│   └── knowledge/
├── static/                         # Jawafdehi branding assets
├── nginx/
│   └── chat.jawafdehi.org.conf     # Nginx config (in repo)
└── README.md                       # Setup instructions
```

### Dev vs. Production Compose Files

| Feature | `docker-compose.yml` (dev) | `docker-compose.prod.yml` (production) |
|---------|---------------------------|----------------------------------------|
| Image | Builds from `jawafdehi-main` source | Pre-built `jawafdehi/open-webui:jawafdehi-main` |
| Port binding | `3000:8080` | `127.0.0.1:8080:8080` |
| Code overrides | None | Bind-mounted from `code/` |
| Static assets | Volume-mounted | Volume-mounted |
| OAUTH secrets | Inline | env_file from `/opt/openwebui-secrets/` |
| Logging | Default | `json-file` with rotation (10m/3 files) |
| Secrets dir | — | `/opt/openwebui-secrets/` |

### Key Environment Variables

| Variable | Service | Purpose |
|----------|---------|---------|
| `WEBUI_NAME` | OpenWebUI | Display name ("Jawafdehi Chat") |
| `WEBUI_URL` | OpenWebUI | Public URL |
| `WEBUI_SECRET_KEY` | OpenWebUI | Session secret |
| `ENABLE_MCP=true` | OpenWebUI | Enable MCP client |
| `ENABLE_FORWARD_USER_INFO_HEADERS=true` | OpenWebUI | Forward user info via custom headers |
| `BYPASS_MODEL_ACCESS_CONTROL=true` | OpenWebUI | Allow any model for any user |
| `ENABLE_TOOL_APPROVAL` | OpenWebUI | Enable tool call approval gating |
| `TOOL_APPROVAL_TIMEOUT` | OpenWebUI | Seconds before auto-deny (default 300) |
| `ENABLE_OAUTH_SIGNUP=true` | OpenWebUI | Allow Google OAuth signup |
| `ENABLE_LOGIN_FORM=false` | OpenWebUI | Disable email/password login |
| `OAUTH_MERGE_ACCOUNTS_BY_EMAIL=true` | OpenWebUI | Merge by email on OAuth |
| `GOOGLE_CLIENT_ID` | OpenWebUI | Google OAuth client ID |
| `GOOGLE_CLIENT_SECRET` | OpenWebUI | Google OAuth client secret |
| `OPENWEBUI_API_KEY` | bootstrap | Admin API key for config-as-code bootstrap |
| `JAWAFDEHI_API_BASE_URL` | jawafdehi-mcp | jawafdehi-api URL |
| `JAWAFDEHI_API_TOKEN` | jawafdehi-mcp | Service account token |
| `HTTP_HOST` / `HTTP_PORT` | jawafdehi-mcp | HTTP server bind |
| `LOG_LEVEL` / `LOG_FILE` | jawafdehi-mcp | Logging configuration |

### Volumes

| Volume | Mount | Purpose |
|--------|-------|---------|
| `open-webui` / `openwebui-data` | `/app/backend/data` | OpenWebUI app data |
| `chat_logs` | `/var/log/jawafdehi-mcp` | MCP server logs |

### Config-as-Code Bootstrap

After deploy, apply Jawafdehi model presets, knowledge docs, and system prompts:

```bash
export OPENWEBUI_URL="https://chat.jawafdehi.org"
export OPENWEBUI_API_KEY="sk-..."  # Admin Settings → API Keys
./deploy/chat/bin/bootstrap-config.sh
```

Idempotent — safe to run on every deploy. Supports `--dry-run`, `--models-only`,
`--knowledge-only`, `--prompts-only`, `--groups-only`.

---

## CI/CD Pipeline

### Deploy Workflow (`.github/workflows/deploy-chat.yml`)

Triggers:
- **Push** to `jawafdehi-main` when `deploy/chat/**` or the workflow file changes
- **Manual** via `workflow_dispatch` (optional ref override)

Deploy process:
1. Checkout repository
2. rsync repository to VPS host
3. Run `deploy/chat/bin/deploy.sh` on host
4. `deploy.sh` syncs bundle to `/opt/openwebui`, sets permissions, runs `docker compose -f docker-compose.prod.yml up -d`

---

## Infrastructure

### VPS Setup

- **Provider:** monal.cloud
- **Secrets:** `/opt/openwebui-secrets/` — `.env`, `mcp.env`, GCP credentials
- **App root:** `/opt/openwebui/` — deploy bundle destination

### Nginx Config

Lives in the repo at `deploy/chat/nginx/chat.jawafdehi.org.conf`:
- Port 80 → redirect to HTTPS
- Port 443 → reverse proxy to `127.0.0.1:8080`
- WebSocket upgrade support
- 600s read/send timeout for streaming responses
- Certbot-managed Let's Encrypt certificates

### VPS Provisioning (`infra/vps/`)

| File | Purpose |
|------|---------|
| `bootstrap.sh` | Initial VPS setup |
| `multi-user.sh` | Multi-user SSH configuration |
| `create-user.sh` | Create new system users |
| `templates/zshrc` | Default zsh config |

### AWS/Terraform (`infra/terraform/`)

Terraform configs for AWS resources used by jawafdehi-api and other services.

---

## Related Issues & PRs

### Open PRs (open-webui repo)

| PR | Issue | Title | Base | Status |
|----|-------|-------|------|--------|
| #13 | [JAWA-894](/JAWA/issues/JAWA-894) | Living architecture/status document | jawafdehi-main | Open |

### Recently Merged (open-webui repo)

| PR | Issue | Title |
|----|-------|-------|
| #26 | [JAWA-1403](/JAWA/issues/JAWA-1403) | Fetch skills at deploy time, wait 3min for API readiness |
| #25 | [JAWA-585](/JAWA/issues/JAWA-585) | Jawafdehi static asset volume mounts |
| #24 | [JAWA-1403](/JAWA/issues/JAWA-1403) | Fix bootstrap syntax, add caseworker skills as KB |
| #23 | [JAWA-1403](/JAWA/issues/JAWA-1403) | Wire OWUI_API_KEY for bootstrap |
| #22 | [JAWA-1403](/JAWA/issues/JAWA-1403) | Consolidate configs, rename custom/ → code/ |
| #21 | [JAWA-1403](/JAWA/issues/JAWA-1403) | Simplify deploy: remove curl mode, gcplogs → json-file |
| #19 | [JAWA-1403](/JAWA/issues/JAWA-1403) | Assert secrets exist, add GCP auth to deploy |
| #16 | [JAWA-1403](/JAWA/issues/JAWA-1403) | Fix deploy.sh permissions |
| #15 | [JAWA-1403](/JAWA/issues/JAWA-1403) | CI-driven deploy workflow |
| #12 | [JAWA-1356](/JAWA/issues/JAWA-1356) | Tool approval: Allow Always + ENABLE_TOOL_APPROVAL |
| #11 | [JAWA-1357](/JAWA/issues/JAWA-1357) | Crash resilience for pending approvals |
| #9  | [JAWA-1354](/JAWA/issues/JAWA-1354) | Bootstrap script + deploy docs |
| #8  | [JAWA-1353](/JAWA/issues/JAWA-1353) | Knowledge base document collections |
| #6  | [JAWA-1058](/JAWA/issues/JAWA-1058) | Config-as-code: model preset + bootstrap |
| #4  | [JAWA-1322](/JAWA/issues/JAWA-1322) | BYPASS_MODEL_ACCESS_CONTROL=true |

### Key Historic Changes (jawafdehi-mcp)

| Issue | Title | What Changed |
|-------|-------|-------------|
| [JAWA-600](/JAWA/issues/JAWA-600) | Streamable HTTP transport | HTTP mode for MCP server |
| [JAWA-601](/JAWA/issues/JAWA-601) | Per-user tool filtering | Auth-based tool gating |
| [JAWA-578](/JAWA/issues/JAWA-578) | Markdown descriptions | Tool descriptions use Markdown |
| [JAWA-327](/JAWA/issues/JAWA-327) | Slug enforcement | Numeric → slug lookups |
| [JAWA-1222](/JAWA/issues/JAWA-1222) | User-Name header | Forward X-Jawafdehi-User-Name |

### Other Relevant Issues

| Issue | Title | Status |
|-------|-------|--------|
| [JAWA-1325](/JAWA/issues/JAWA-1325) | Tool call approval UI (approve/deny) | Done |
| [JAWA-1197](/JAWA/issues/JAWA-1197) | Fix chat ID prefix | Done |
| [JAWA-1228](/JAWA/issues/JAWA-1228) | Fix MCP header template vars | Done |

---

## Known Gaps & Planned Work

### Current Gaps

1. **No monitoring/alerting** on the chat stack
2. **No database backup** documented for OpenWebUI volumes
3. **Config-as-code prompts/groups not yet deployed** — bootstrap supports them,
   but the `configs/` tree currently has only the model preset and skills KB;
   Nepali system prompts and group definitions from the original 1058 branch
   were removed during merge simplification
4. **Code overrides drift risk** — `deploy/chat/code/*.py` snapshots must stay
   in sync with the corresponding `backend/open_webui/` modules
5. **Public anonymous access** — not yet implemented; all users must sign in via Google

### Recently Resolved

- ~~CI/CD pipeline~~ — `deploy-chat.yml` workflow now deploys on push to `jawafdehi-main`
- ~~Nginx config in repo~~ — `deploy/chat/nginx/chat.jawafdehi.org.conf`
- ~~Jawafdehi branding~~ — static assets volume-mounted
- ~~Secrets management~~ — `/opt/openwebui-secrets/` convention
- ~~Bypass model access control (JAWA-1322)~~ — merged
- ~~Config-as-code bootstrap (JAWA-1058/1354)~~ — merged, `bin/bootstrap-config.sh`
- ~~Knowledge collections (JAWA-1353)~~ — merged, caseworker skills KB
- ~~Tool approval enhancements (JAWA-1356)~~ — merged, Allow Always + ENABLE_TOOL_APPROVAL
- ~~Crash resilience (JAWA-1357)~~ — merged

### Planned Work

- See project: [chat.jawafdehi.org](/JAWA/projects/chat.jawafdehi.org)
- Deploy remaining config-as-code assets (prompts, groups)
- Public-facing mode: restricted tool access for unauthenticated/anonymous users
- Chat history and analytics
- Multi-model support for different assistant personas

---

## Keeping This Document Up to Date

1. **When you merge a PR** to `jawafdehi-main`, update the relevant section.
2. **When you add a new service** or change the auth flow, update the [Service Map](#service-map) and [Identity & Authentication Flow](#identity--authentication-flow).
3. **When you open/close an issue or PR** that affects architecture, update [Related Issues & PRs](#related-issues--prs).
4. **When you deploy a change**, update [Deployment](#deployment) — especially env vars and volumes.
5. **When the deploy layout changes** (new files in `deploy/chat/`), update the [Deployment Layout](#deployment-layout).

> **Pro tip.** Add an `ARCHITECTURE.md` reminder to your PR template or CI
> checklist so no one forgets.
