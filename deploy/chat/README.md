# chat.jawafdehi.org — jawafdehi-mcp Integration

Service definition and OpenWebUI config to add jawafdehi-mcp (HTTP mode)
to the chat.jawafdehi.org stack. Also covers config-as-code deployment
for Jawafdehi model presets, system prompts, and knowledge bases.

## MCP Architecture

```
User → Google OAuth → OpenWebUI
                         │
                         │  Custom Headers:
                         │  X-Jawafdehi-User-Id: {{USER_ID}}
                         │  X-Jawafdehi-User-Name: {{USER_NAME}}
                         │
                         ▼  http://jawafdehi-mcp:8000  (internal Docker network)
                  jawafdehi-mcp (Streamable HTTP)
                         │
                         │  Forwards headers + service account token
                         ▼
                  jawafdehi-api (resolves identity, enforces permissions)
```

No nginx needed — jawafdehi-mcp runs on an unexposed port on the same Docker
network as OpenWebUI. There is no external path for header spoofing.

## Config-as-Code Architecture

```
chat.jawafdehi.org
├── OpenWebUI (Jawafdehi fork)
│   ├── SQLite/PostgreSQL backend
│   ├── Redis cache (optional)
│   └── Ollama sidecar (LLM inference)
├── configs/                  ← Config-as-code (this repo)
│   ├── models/               ← Model presets
│   ├── prompts/              ← Nepali system prompts
│   ├── groups/               ← User group definitions
│   └── knowledge/            ← Knowledge base documents
└── scripts/bootstrap-config.sh ← Applies configs to running instance
```

## MCP Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | jawafdehi-mcp service definition (add to existing OpenWebUI compose) |
| `openwebui/tools-config.json` | OpenWebUI External Tools MCP server config |
| `mcp.env.example` | Template for jawafdehi-mcp environment variables |

## Config-as-Code Files

| File | Purpose |
|------|---------|
| `scripts/bootstrap-config.sh` | Idempotent script to push configs to OpenWebUI API |
| `configs/models/*.json` | Model preset definitions |
| `configs/prompts/*.nep` | Nepali system prompts |
| `configs/groups/*.json` | User group definitions with model/tool access |
| `configs/knowledge/**/*.md` | Knowledge base documents |

## MCP Quick Start

1. Set up the service account on the jawafdehi-api server:
   ```bash
   python manage.py migrate
   python manage.py setup_chat_service_account
   ```

2. Copy the environment template and fill in credentials:
   ```bash
   cp mcp.env.example mcp.env
   # Edit mcp.env — set JAWAFDEHI_API_TOKEN from step 1
   ```

3. Add the `jawafdehi-mcp` service definition from `docker-compose.yml`
   to the existing OpenWebUI docker-compose, then restart:
   ```bash
   docker compose up -d
   ```

4. Configure OpenWebUI:
   - Go to Admin Settings → External Tools
   - Import the MCP server config from `openwebui/tools-config.json`

## MCP Identity Flow

1. OpenWebUI authenticates users via Google OAuth
2. `{{USER_ID}}` and `{{USER_NAME}}` tokens are resolved at request time
3. OpenWebUI sends these as `X-Jawafdehi-User-Id` and `X-Jawafdehi-User-Name` headers directly to jawafdehi-mcp
4. jawafdehi-mcp reads `X-Jawafdehi-User-Id`, calls `GET /api/caseworker/me` with the service account token
5. jawafdehi-api resolves the OpenWebUI user ID to a real Django user and returns roles
6. jawafdehi-mcp filters tools based on roles (caseworker → all tools, public → read-only)

## MCP ChatUserIdentity Mapping

Before users can access caseworker tools, create `ChatUserIdentity` records
mapping OpenWebUI user IDs to Django users:

```python
from cases.models import ChatUserIdentity
from django.contrib.auth import get_user_model

User = get_user_model()
user = User.objects.get(username="caseworker.name")
ChatUserIdentity.objects.create(owui_user_id="abc123-def456", user=user)
```

## MCP Security

- jawafdehi-mcp port is internal only (`expose`, not `ports`) — unreachable from outside
- OpenWebUI's Custom Headers are the sole source of `X-Jawafdehi-*` headers
- Service account token is never exposed to end users
- jawafdehi-api enforces authorization server-side regardless of tool requests

---

## Config-as-Code Bootstrap

After initial deploy, apply Jawafdehi model presets, Knowledge Base docs,
and system prompts via the bootstrap script:

```bash
export OPENWEBUI_URL="https://chat.jawafdehi.org"
export OPENWEBUI_API_KEY="sk-..."  # From Admin Settings → API Keys
./scripts/bootstrap-config.sh
```

The script is idempotent — safe to run on every deploy.

**Apply specific sections only:**
```bash
./scripts/bootstrap-config.sh --models-only
./scripts/bootstrap-config.sh --prompts-only
./scripts/bootstrap-config.sh --groups-only
./scripts/bootstrap-config.sh --knowledge-only
```

**Dry run:** `./scripts/bootstrap-config.sh --dry-run`

### Bootstrap Script Requirements

- `OPENWEBUI_API_KEY` — an **admin** API key for the target OpenWebUI instance
- Network access to the OpenWebUI API
- Only `bash`, `curl`, and `python3` needed — no external dependencies

### API Key Setup

1. Sign in to the OpenWebUI instance as admin
2. Go to **Settings → Account → API Keys**
3. Generate a new API key with admin scope
4. Export it: `export OPENWEBUI_API_KEY="sk-..."`

## Model Preset Format

Files in `configs/models/` (e.g., `caseworker-assistant.json`):

```json
{
  "id": "caseworker-assistant",
  "name": "Caseworker Assistant",
  "base_model_id": null,
  "params": { "temperature": 0.3, "top_p": 0.9 },
  "meta": {
    "description": "Jawafdehi caseworker assistant",
    "profile_image_url": "/static/favicon.png",
    "capabilities": { "vision": false }
  },
  "is_active": true
}
```

The `id` field maps to a corresponding system prompt file at `configs/prompts/{id}.nep`.

## System Prompt Format

Files in `configs/prompts/` are plain Nepali text (`.nep` extension). The filename stem must match a model `id`. The prompt is registered as an OpenWebUI prompt with command `/<model-id>`.

## Group Format

Files in `configs/groups/` (e.g., `caseworkers.json`):

```json
{
  "name": "caseworkers",
  "description": "Jawafdehi caseworker group",
  "models": ["caseworker-assistant", "entity-researcher"],
  "tools": ["search_cases", "get_case"],
  "permissions": {
    "workspace.models": true,
    "workspace.knowledge": true,
    "chat.uploads": true,
    "chat.delete": true
  }
}
```

After group creation, the bootstrap script grants the group `read` access to each model in the `models` list.

## Knowledge Base Format

Place Markdown files in subdirectories under `configs/knowledge/`. Each subdirectory becomes a knowledge base collection. The bootstrap script:
1. Creates the knowledge base (if it doesn't exist)
2. Uploads all `.md` files from the subdirectory
3. Adds them to the knowledge base for RAG

```
configs/knowledge/
├── caseworker-guides/
│   └── guide.md
├── legal-framework/
│   └── prevention-act.md
└── court-reference/
    └── procedure.md
```

## Adding a New Assistant

1. Create `configs/models/<id>.json` with the model preset
2. Create `configs/prompts/<id>.nep` with the system prompt
3. Add the model ID to the relevant groups in `configs/groups/`
4. Run `./scripts/bootstrap-config.sh`
5. Verify the model appears in the OpenWebUI model selector

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `API_ERROR:401` | Invalid or missing API key | Check `OPENWEBUI_API_KEY` is set and is an admin key |
| `API_ERROR:403` | Insufficient permissions | API key must have admin scope |
| Model exists but prompt is missing | Filename mismatch | Prompt file stem must exactly match model `id` |
| Group has no model access | Access grant update failed | Run again or manually add access via admin panel |
