# Jawafdehi OpenWebUI Config-as-Code

This directory stores Jawafdehi-specific OpenWebUI configuration as version-controlled files.

## Structure

```
configs/
├── README.md                           # This file
├── models/
│   └── jawafdehi-caseworker.json       # Deployed model config (full, not a skeleton)
├── skills/
│   ├── skills.json                     # Copied from jawafdehi-meta at deploy
│   └── *.md                            # Copied from jawafdehi-meta at deploy
└── knowledge/
    └── collections.json                # KB collection metadata
```

## How it works

1. Config files are committed to the Jawafdehi `open-webui` fork
2. `bootstrap-config.sh` reads all configs and applies them to the running OpenWebUI instance
3. The bootstrap script is idempotent — it checks if each item already exists before creating it
4. On a fresh deploy, the script creates everything; on restart, it's a no-op

## Model Configuration

`jawafdehi-caseworker.json` is a snapshot of the deployed "Jawafdehi Caseworker"
configuration. It includes:

- `base_model_id`: `deepseek-v4-pro`
- System prompt for caseworker assistance
- Full capability set (file upload, web search, code interpreter, terminal, citations)
- MCP tool binding (`server:mcp:jawafdehi`)
- Caseworker skill binding (`jawafdehi-caseworker`)

This is a complete model config — not a skeleton. It can be applied directly
by the bootstrap script with no manual steps needed.

## Skills

Caseworker skills are loaded as native OpenWebUI Skills (not Knowledge Base).
The skills manifest (`skills.json`) and content files live in
`jawafdehi-meta/.kiro/skills/` as the source of truth, and are copied to
`configs/skills/` at deploy time by `deploy.sh`.

The `apply_skills()` function in the bootstrap script:

1. Reads `skills.json` for registered skill metadata
2. Checks which skills already exist via `GET /api/v1/skills/`
3. Creates missing skills via `POST /api/v1/skills/create`
4. Updates existing skills via `POST /api/v1/skills/id/{id}/update`

This ensures skill content stays current across deploys.

## Adding Knowledge Base docs

Place Markdown documents below `configs/knowledge/` and register them in `collections.json`.
The bootstrap script uploads them via the OpenWebUI Knowledge API.
