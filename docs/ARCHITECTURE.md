# chat.jawafdehi.org — Architecture & Status

> **Living document.** Updated 2026-05-19. Change this file when the
> architecture changes so it remains the central reference.

---

## Table of Contents

1. [Start Here](#start-here)
2. [Production Architecture](#production-architecture)
3. [Repository Map](#repository-map)
4. [Identity & Authentication Flow](#identity--authentication-flow)
5. [Customizations to OpenWebUI](#customizations-to-openwebui)
6. [Where to Make Changes](#where-to-make-changes)
7. [Deployment](#deployment)
8. [CI/CD Pipeline](#cicd-pipeline)
9. [Known Gaps & Planned Work](#known-gaps--planned-work)

---

## Start Here

This document is the entry point for anyone working on or troubleshooting
**chat.jawafdehi.org** — the Jawafdehi chat interface.

- **New to the project?** Read [Production Architecture](#production-architecture)
  then [Identity & Auth](#identity--authentication-flow).
- **Need to make a code change?** See [Where to Make Changes](#where-to-make-changes).
- **Deploying or debugging a deploy?** See [Deployment](#deployment) and [CI/CD](#cicd-pipeline).

### The Stack in One Sentence

Google OAuth → OpenWebUI (Docker, jawafdehi-main fork) → jawafdehi-mcp
(MCP server, internal network) → jawafdehi-api (Django, identity + data).

### Repos at a Glance

| Repo | What It Does |
|------|-------------|
| [Jawafdehi/open-webui](https://github.com/Jawafdehi/open-webui) | Chat UI fork — frontend, MCP client, OAuth, branding |
| [Jawafdehi/jawafdehi-mcp](https://github.com/Jawafdehi/jawafdehi-mcp) | MCP server — case/entity/judicial tools, identity proxy |
| [Jawafdehi/JawafdehiAPI](https://github.com/Jawafdehi/JawafdehiAPI) | Django backend — cases, entities, user identity |
| [Jawafdehi/infra](https://github.com/Jawafdehi/infra) | Terraform, VPS provisioning, nginx config |

---

## Production Architecture

```
                          Internet
                             │
                     ┌───────▼────────┐
                     │    nginx       │  monal.cloud VPS (50.175.70.14)
                     │  port 443      │  certbot / Let's Encrypt
                     │  port 80 (→443)│  TLS termination + WebSocket upgrade
                     └───────┬────────┘
                             │  proxy_pass http://127.0.0.1:8080
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
              │                                   │
              │  Bind mounts (prod only):         │
              │    code/middleware.py             │
              │    code/tools_utils.py            │
              │    code/tools_models.py           │
              │    static/* → /app/build/static/  │
              └──────┬───────────────────────────┘
                     │
                     │  Internal Docker network
                     │  http://jawafdehi-mcp:8000
                     │  Headers: X-Jawafdehi-User-Id, X-Jawafdehi-User-Name
                     │
              ┌──────▼───────────────────────────┐
              │        jawafdehi-mcp              │
              │  Streamable HTTP MCP Server       │
              │  Port: 8000 (expose only)         │
              │  Image: uv:python3.12-bookworm    │
              │  Runs: uvx jawafdehi-mcp-http     │
              └──────┬───────────────────────────┘
                     │
                     │  Authorization: Token <service-account>
                     │  X-Jawafdehi-User-Id forwarded
                     │
              ┌──────▼───────────────────────────┐
              │        jawafdehi-api               │
              │  Django backend                    │
              │  URL: https://portal.jawafdehi.org │
              │  Endpoint: GET /api/caseworker/me  │
              │  Resolves ChatUserIdentity → User  │
              │  Returns user + roles              │
              └───────────────────────────────────┘
```

### Services at a Glance

| Service | URL | Port | Tech | Purpose |
|---------|-----|------|------|---------|
| nginx | chat.jawafdehi.org | 443, 80 | nginx + certbot | TLS termination, reverse proxy |
| OpenWebUI | chat.jawafdehi.org | 8080 (internal) | FastAPI + Svelte | Chat UI, OAuth, MCP client |
| jawafdehi-mcp | internal only | 8000 | Python (MCP SDK) | Accountability tools, identity proxy |
| jawafdehi-api | portal.jawafdehi.org | — | Django | User identity, case/entity CRUD |

### Production Docker Compose (`docker-compose.prod.yml`)

Two services, one internal network:

**openwebui:**
- Pre-built image `jawafdehi/open-webui:jawafdehi-main`
- Binds to `127.0.0.1:8080:8080` (localhost-only, nginx in front)
- Secrets from `/opt/openwebui-secrets/.env` via `env_file`
- 3 Python code overrides bind-mounted `:ro`
- 12 static asset files bind-mounted to `/app/build/static/`
- Logging: `json-file` driver, 10 MB rotation, max 3 files
- Volume: `openwebui-data:/app/backend/data`

**jawafdehi-mcp:**
- Image `ghcr.io/astral-sh/uv:python3.12-bookworm-slim`
- Installs git at startup, runs `uvx` from jawafdehi-mcp git repo
- Port 8000 `expose` only (not published — unreachable from outside)
- Secrets from `/opt/openwebui-secrets/mcp.env` via `env_file`
- Volume: `chat_logs:/var/log/jawafdehi-mcp`

### Production Environment Variables

| Variable | Set In | Purpose |
|----------|--------|---------|
| `WEBUI_NAME=Jawafdehi Chat` | compose | Display name in UI |
| `WEBUI_URL=https://chat.jawafdehi.org` | compose | Public URL |
| `WEBUI_SECRET_KEY` | `/opt/openwebui-secrets/.env` | Session secret (user-supplied) |
| `GOOGLE_CLIENT_ID` | `/opt/openwebui-secrets/.env` | Google OAuth client ID |
| `GOOGLE_CLIENT_SECRET` | `/opt/openwebui-secrets/.env` | Google OAuth client secret |
| `OAUTH_CLIENT_INFO_ENCRYPTION_KEY` | `/opt/openwebui-secrets/.env` | OAuth info encryption |
| `ENABLE_MCP=true` | compose | Enable MCP client |
| `ENABLE_FORWARD_USER_INFO_HEADERS=true` | compose | Forward `X-OpenWebUI-User-*` on proxied requests |
| `BYPASS_MODEL_ACCESS_CONTROL=true` | compose | Any user can access any model |
| `ENABLE_CUSTOM_MODEL_FALLBACK=true` | compose | Allow custom model fallback |
| `ENABLE_OAUTH_SIGNUP=true` | compose | Allow Google OAuth signup |
| `ENABLE_LOGIN_FORM=false` | compose | Disable email/password login |
| `OAUTH_MERGE_ACCOUNTS_BY_EMAIL=true` | compose | Merge by email on OAuth |
| `OAUTH_PROVIDER=google` | compose | OAuth provider |
| `OPENID_PROVIDER_URL=https://accounts.google.com` | compose | OpenID Connect provider |
| `JAWAFDEHI_API_BASE_URL` | `/opt/openwebui-secrets/mcp.env` | jawafdehi-api URL |
| `JAWAFDEHI_API_TOKEN` | `/opt/openwebui-secrets/mcp.env` | Service account token for jawafdehi-api |
| `NES_API_BASE_URL` | `/opt/openwebui-secrets/mcp.env` | NES API URL (optional, defaults to nes.jawafdehi.org) |
| `LOG_LEVEL` | `/opt/openwebui-secrets/mcp.env` | MCP log level (default: info) |
| `LOG_FILE` | `/opt/openwebui-secrets/mcp.env` | MCP log file path (optional) |
| `HTTP_HOST=0.0.0.0` | compose | MCP HTTP bind address |
| `HTTP_PORT=8000` | compose | MCP HTTP port |

### Secrets on Host

Rendered at `/opt/openwebui-secrets/`:
- `.env` — OpenWebUI OAUTH secrets (from `.env.example`)
- `mcp.env` — jawafdehi-mcp secrets (from `mcp.env.example`)
- `admin-api-key.txt` — OpenWebUI admin API key (for bootstrap)
- `owui-log-writer.credentials.json` — GCP credentials (host-level, not in compose)

### Volumes

| Volume | Mount Point | Purpose |
|--------|------------|---------|
| `openwebui-data` | `/app/backend/data` | OpenWebUI app data (prod) |
| `open-webui` | `/app/backend/data` | OpenWebUI app data (dev) |
| `chat_logs` | `/var/log/jawafdehi-mcp` | MCP server logs (both) |

---

## Repository Map

| Repo | Primary Branch | Description |
|------|---------------|-------------|
| open-webui | **`jawafdehi-main`** (deployed) | OpenWebUI fork with all Jawafdehi customizations |
| jawafdehi-mcp | `main` | MCP server — accountability tools + identity proxy |
| JawafdehiAPI | `main` | Django backend — cases, entities, ChatUserIdentity |
| infra | `main` | Terraform, VPS bootstrap scripts, nginx config |

`jawafdehi-main` is the single deployed branch. `jawafdehi-custom` is a
historical predecessor (all changes absorbed). Feature branches (`JAWA-*`)
merge into `jawafdehi-main`.

---

## Identity & Authentication Flow

### Step-by-Step

1. **Browser → Google OAuth → OpenWebUI**
   User clicks "Sign in with Google". OpenWebUI redirects to Google. On callback,
   OpenWebUI creates or identifies the user by their Google account email. The
   user gets an internal OpenWebUI ID (UUID).

2. **OpenWebUI resolves `{{USER_ID}}` and `{{USER_NAME}}`**
   When the user sends a chat message that triggers MCP tool calls, OpenWebUI's
   `get_custom_headers()` in `backend/open_webui/utils/headers.py` resolves
   template variables: `{{USER_ID}}` → `user.id`, `{{USER_NAME}}` → `user.name`.
   These are server-side — users cannot spoof them.

3. **OpenWebUI → jawafdehi-mcp (custom headers)**
   The resolved values are sent as HTTP headers on every MCP tool request:
   ```
   X-Jawafdehi-User-Id: <OpenWebUI internal UUID>
   X-Jawafdehi-User-Name: <user display name>
   ```
   These header names are configured in `deploy/chat/openwebui/tools-config.json`,
   not via environment variables.

4. **jawafdehi-mcp → jawafdehi-api (identity resolution)**
   jawafdehi-mcp reads `X-Jawafdehi-User-Id` from the incoming request and calls:
   ```
   GET https://portal.jawafdehi.org/api/caseworker/me
   Authorization: Token <JAWAFDEHI_API_TOKEN>
   X-Jawafdehi-User-Id: <forwarded ID>
   ```
   The service account token authenticates the MCP server itself. The
   `X-Jawafdehi-User-Id` header tells jawafdehi-api *which* end user is making
   the request.

5. **jawafdehi-api resolves identity**
   The `ChatUserIdentity` model maps `owui_user_id` → Django `User`. The API
   returns `{ user_id, username, roles: ["Contributor", ...] }`.

6. **Per-user tool filtering**
   jawafdehi-mcp uses the returned roles to filter available MCP tools:
   - Caseworker roles → all tools (read + write)
   - Public / unauthenticated → read-only tools only
   - No identity mapped → read-only tools only

### Separate Header Forwarding (`ENABLE_FORWARD_USER_INFO_HEADERS`)

In addition to the MCP custom headers above, OpenWebUI also forwards generic
user info headers (`X-OpenWebUI-User-Id`, `X-OpenWebUI-User-Name`,
`X-OpenWebUI-User-Email`, `X-OpenWebUI-User-Role`) on ALL proxied requests when
`ENABLE_FORWARD_USER_INFO_HEADERS=true`. This is a separate mechanism from the
MCP tool-specific `X-Jawafdehi-*` headers.

### ChatUserIdentity Model

Defined in `JawafdehiAPI/cases/models.py`:

```python
class ChatUserIdentity(models.Model):
    owui_user_id = models.CharField(max_length=255, unique=True)
    user = models.ForeignKey(User, on_delete=models.CASCADE)
```

Create mappings via Django admin or `python manage.py setup_chat_service_account`.

### Public vs. Caseworker Access

| Feature | Public User | Caseworker |
|---------|------------|------------|
| Chat UI | Yes | Yes |
| Google SSO | Required | Required |
| Read-only MCP tools (search cases, entities, judicial data) | Yes | Yes |
| Write MCP tools (create cases, upload sources, NES changes) | No | Yes |
| Tool Approval UI | N/A | Yes |

---

## Customizations to OpenWebUI

### MCP Server Integration

OpenWebUI connects to jawafdehi-mcp via Streamable HTTP on the internal Docker
network (`http://jawafdehi-mcp:8000`). Connection config is in
`deploy/chat/openwebui/tools-config.json`.

Custom headers (`X-Jawafdehi-User-Id`, `X-Jawafdehi-User-Name`) use template
variables `{{USER_ID}}` and `{{USER_NAME}}` resolved at request time by
`get_custom_headers()` in `backend/open_webui/utils/headers.py`.

**Key files:**
- `backend/open_webui/utils/headers.py` — template variable resolution
- `deploy/chat/openwebui/tools-config.json` — MCP server connection + header config
- `deploy/chat/code/middleware.py` — production override (chat pipeline, tool dispatch)

### Tool Call Approval UI

When a tool is marked as requiring approval (`needs_approval`), the chat pauses
and the user sees approve/deny buttons in the UI. Users can whitelist tools so
future calls auto-approve.

The approval logic lives entirely in the production middleware override
(`deploy/chat/code/middleware.py`). There is no separate `pending_approvals`
module and no `ENABLE_TOOL_APPROVAL` env var — approval is unconditional for
configured tools.

**Key files:**
- `deploy/chat/code/middleware.py` — server-side approval gating (lines ~4573–4602)
- `src/lib/components/common/ToolCallDisplay.svelte` — approve/deny/allow-always UI

### Custom Prompt Suggestions

Jawafdehi-themed prompt suggestions are set via `DEFAULT_PROMPT_SUGGESTIONS`
in the dev compose (`docker-compose.yml`). In production, prompt suggestions
are configured through the OpenWebUI admin UI.

### Config-as-Code

Structured configs committed to the repo for repeatable, automated deployment.

```
deploy/chat/configs/
├── README.md
├── models/
│   └── jawafdehi-caseworker.json    # Full model config (base: deepseek-v4-pro)
└── knowledge/
    ├── collections.json             # KB collection → document mapping
    └── caseworker/                  # Skills pulled from jawafdehi-meta at deploy
```

**Skill content flow:**
```
jawafdehi-meta (author) → deploy.sh (clone at CI time)
     .kiro/skills/<name>/SKILL.md
                         → configs/knowledge/caseworker/<name>.md (staging)
                         → bootstrap-config.sh (upload to OWUI KB API)
```

Skills are authored in `jawafdehi-meta` under `.kiro/skills/`. At deploy time,
`deploy.sh` clones jawafdehi-meta, copies the `SKILL.md` files into
`configs/knowledge/caseworker/`, and `bootstrap-config.sh` uploads them to the
OpenWebUI Knowledge Base API. This means: to update a skill, edit it in
`jawafdehi-meta`; the next CI deploy picks up the change automatically.

**Bootstrap script** (`deploy/chat/bin/bootstrap-config.sh`):
- Idempotent — safe on every deploy.
- Applies models and knowledge collections via OpenWebUI REST API.
- Retries for up to 3 minutes waiting for API readiness.
- Requires `OWUI_BASE_URL` and `OWUI_API_KEY` env vars (not `OPENWEBUI_API_KEY`).
- Supports `OWUI_DRY_RUN=1` and `OWUI_VERBOSE=1`.

### Python Code Overrides (Production)

Three files in `deploy/chat/code/` are bind-mounted `:ro` over the corresponding
backend modules in the running container — they override without requiring a
Docker image rebuild.

| Override File | Replaces in Container | Purpose |
|---------------|----------------------|---------|
| `code/middleware.py` | `backend/open_webui/utils/middleware.py` | Chat pipeline, MCP tool dispatch, tool approval gating |
| `code/tools_utils.py` | `backend/open_webui/utils/tools.py` | Tool resolution and execution |
| `code/tools_models.py` | `backend/open_webui/models/tools.py` | Tool/function model definitions |

> **WARNING — Drift Risk.** These overrides are snapshots of the corresponding
> `backend/open_webui/` modules. If the upstream source in `jawafdehi-main`
> changes but the `deploy/chat/code/` snapshot is not updated, production will
> run stale or broken code. **Always update the matching snapshot when changing
> the corresponding backend module.** The deploy workflow copies the entire
> `deploy/chat/` tree — stale snapshots deploy instantly.

### Jawafdehi Branding

Static assets bind-mounted in production to `/app/build/static/`:

| File(s) | Purpose |
|---------|---------|
| `favicon.png`, `.ico`, `.svg`, `favicon-dark.png` | Browser tab icon (light + dark) |
| `favicon-96x96.png` | Android/Chrome favicon |
| `apple-touch-icon.png` | iOS home screen icon |
| `logo.png` | Application logo |
| `splash.png`, `splash-dark.png` | Loading splash screens |
| `web-app-manifest-192x192.png`, `-512x512.png` | PWA manifest icons |
| `site.webmanifest` | PWA manifest |
| `custom.css` | Custom CSS overrides |

### Docker Build

- AMD64-only builds pushed to Docker Hub: `jawafdehi/open-webui:jawafdehi-main`
- Public images — no auth required for pull.
- Built via `.github/workflows/build-release.yml`.

---

## Where to Make Changes

| What to Change | Where | Details |
|---------------|-------|---------|
| **OpenWebUI behavior** (chat pipeline, tool dispatch, tool approval) | `backend/open_webui/utils/middleware.py` + update `deploy/chat/code/middleware.py` snapshot | Production runs the snapshot |
| **MCP header template resolution** | `backend/open_webui/utils/headers.py` | `get_custom_headers()` resolves `{{USER_ID}}`, `{{USER_NAME}}` |
| **Tool definitions** | `backend/open_webui/models/tools.py` + update `deploy/chat/code/tools_models.py` | Production runs the snapshot |
| **Tool execution logic** | `backend/open_webui/utils/tools.py` + update `deploy/chat/code/tools_utils.py` | Production runs the snapshot |
| **MCP tool implementations** (new tools, tool behavior) | [jawafdehi-mcp](https://github.com/Jawafdehi/jawafdehi-mcp) `main` branch | Deployed via `uvx` from git — no image rebuild |
| **MCP connection config** (headers, URL, timeout) | `deploy/chat/openwebui/tools-config.json` | Copied to `/opt/openwebui/` on deploy |
| **User identity / roles** | [JawafdehiAPI](https://github.com/Jawafdehi/JawafdehiAPI) `cases/models.py`, `GET /api/caseworker/me` | `ChatUserIdentity` mapping |
| **Model presets** | `deploy/chat/configs/models/jawafdehi-caseworker.json` | Applied by `bootstrap-config.sh` |
| **Knowledge Base collections** | `deploy/chat/configs/knowledge/collections.json` + doc files | Applied by `bootstrap-config.sh` |
| **Caseworker skills** | [jawafdehi-meta](https://github.com/Jawafdehi/jawafdehi-meta) `.kiro/skills/<name>/SKILL.md` | Pulled at deploy time by `deploy.sh` |
| **Prompt suggestions** (dev) | `docker-compose.yml` `DEFAULT_PROMPT_SUGGESTIONS` | Inline JSON in compose |
| **Prompt suggestions** (prod) | OpenWebUI Admin Settings → Models | Configured via UI |
| **Nginx config** | `deploy/chat/nginx/chat.jawafdehi.org.conf` | Must be applied to host manually after repo change |
| **Branding assets** | `deploy/chat/static/` | Copied on deploy, bind-mounted in prod |
| **CI/CD workflow** | `.github/workflows/deploy-chat.yml` | Triggers on push to `jawafdehi-main` |
| **Docker Compose env vars** | `docker-compose.prod.yml` `environment:` block | Immediate on redeploy |
| **Secrets** | `/opt/openwebui-secrets/` on monal host | Not in repo — managed on the VPS |

---

## Deployment

### Host

- **Provider:** monal.cloud
- **IP:** 50.175.70.14
- **Domain:** chat.jawafdehi.org
- **Secrets dir:** `/opt/openwebui-secrets/`
- **App root:** `/opt/openwebui/`
- **Deploy user:** must be in `docker` group

### Repo Layout (`deploy/chat/`)

```
deploy/chat/
├── README.md
├── docker-compose.yml              # Dev stack (builds from jawafdehi-main source)
├── docker-compose.prod.yml         # Production stack (pre-built image + code overrides)
├── .env.example                    # OAUTH secrets template
├── mcp.env.example                 # jawafdehi-mcp secrets template
├── openwebui/
│   └── tools-config.json           # MCP server connection + header config
├── bin/
│   ├── deploy.sh                   # CI deploy script (syncs bundle → redeploy)
│   └── bootstrap-config.sh         # Idempotent config push (models + KB)
├── code/                           # Production Python override snapshots
│   ├── middleware.py
│   ├── tools_models.py
│   └── tools_utils.py
├── configs/                        # Config-as-code (models + knowledge)
│   ├── README.md
│   ├── models/
│   │   └── jawafdehi-caseworker.json
│   └── knowledge/
│       ├── collections.json
│       └── caseworker/
├── static/                         # Jawafdehi branding assets (12 files)
├── nginx/
│   └── chat.jawafdehi.org.conf     # Reverse proxy config
└── ... (other OpenWebUI source)
```

### Dev vs. Production Compose

| Feature | `docker-compose.yml` (dev) | `docker-compose.prod.yml` (prod) |
|---------|---------------------------|----------------------------------|
| Image | Built from source (`jawafdehi-main`) | `jawafdehi/open-webui:jawafdehi-main` |
| Port binding | `3000:8080` | `127.0.0.1:8080:8080` |
| Code overrides | None | Bind-mounted `:ro` from `code/` |
| Static assets | Volume-mounted | Bind-mounted `:ro` to `/app/build/static/` |
| Secrets | Inline env vars | `env_file` from `/opt/openwebui-secrets/` |
| MCP secrets | `mcp.env` (local file) | `/opt/openwebui-secrets/mcp.env` |
| Prompts | `DEFAULT_PROMPT_SUGGESTIONS` env var | Configured via Admin UI |
| Logging | Default | `json-file`, 10 MB rotation, max 3 |

### Deploy Script (`bin/deploy.sh`)

Runs on the monal host as part of CI:
1. Verifies target dirs (`/opt/openwebui`, `/opt/openwebui-secrets`) exist and are writable
2. Checks required secrets exist: `.env`, `mcp.env`, `admin-api-key.txt`
3. Verifies bundle integrity (compose file, code overrides, key static assets)
4. Rsyncs bundle to `/opt/openwebui/` (excludes secrets)
5. Pulls Docker image `jawafdehi/open-webui:jawafdehi-main`
6. Runs `docker compose -f docker-compose.prod.yml up -d`
7. Fetches skills from jawafdehi-meta (clones `.kiro/skills/` → copies to `configs/knowledge/caseworker/`)
8. Runs `bootstrap-config.sh` with `OWUI_API_KEY` from `admin-api-key.txt`
9. Exits non-zero on bootstrap failure

Env vars for deploy.sh: `BUNDLE_DIR` (default `/tmp/openwebui-deploy`), `BRANCH` (default `jawafdehi-main`).

### Config-as-Code Bootstrap

After deploy, `bootstrap-config.sh` applies configs:
```bash
export OWUI_BASE_URL="https://chat.jawafdehi.org"
export OWUI_API_KEY="sk-..."     # from /opt/openwebui-secrets/admin-api-key.txt
./deploy/chat/bin/bootstrap-config.sh
```

Supports `OWUI_DRY_RUN=1`, `OWUI_VERBOSE=1`.

---

## CI/CD Pipeline

Workflow: `.github/workflows/deploy-chat.yml`

**Triggers:**
- Push to `jawafdehi-main` when `deploy/chat/**` or the workflow file changes
- Manual `workflow_dispatch` (optional `ref` override, optional `setup_only` mode)

**Job steps (monal-instance1 environment):**
1. Checkout repo (`actions/checkout@v5`)
2. Install SSH key (`shimataro/ssh-key-action@v2`)
3. Host setup: create `/opt/openwebui`, `/opt/openwebui-secrets`, set permissions
4. Rsync `deploy/chat/` to VPS under `/tmp/openwebui-deploy-<timestamp>/`
5. Run `deploy.sh` on host with `BUNDLE_DIR` pointing to uploaded bundle

Also present in the repo:
- `.github/workflows/build-release.yml` — Docker image build + push
- `.github/workflows/release-pypi.yml` — PyPI release

---

## Known Gaps & Planned Work

### Current Gaps

1. **No monitoring/alerting** on the chat stack.
2. **No database backup** documented for OpenWebUI volumes.
3. **Code overrides drift risk** — `deploy/chat/code/*.py` snapshots must stay in sync
   with `backend/open_webui/` modules. See warning in [Python Code Overrides](#python-code-overrides-production).
4. **Public anonymous access** — not yet implemented; all users must sign in via Google.
5. **Config-as-code prompts/groups** — bootstrap supports them, but the `configs/` tree
   currently has only the model preset and skills KB.

### See Also

- Project: [chat.jawafdehi.org](/JAWA/projects/chat.jawafdehi.org)
