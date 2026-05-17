# Jawafdehi OpenWebUI Config-as-Code

This directory stores Jawafdehi-specific OpenWebUI configuration as version-controlled files.

## Structure

```
configs/
├── README.md                        # This file
├── models/
│   ├── caseworker-assistant.json    # Caseworker model preset
│   ├── entity-researcher.json       # Entity research model preset
│   └── public-assistant.json        # Public-facing model preset
├── prompts/
│   ├── caseworker-assistant.nep     # Nepali system prompt for caseworkers
│   ├── entity-researcher.nep        # Nepali system prompt for entity research
│   └── public-assistant.nep         # Nepali system prompt for public users
├── knowledge/
│   ├── legal-framework/             # Nepali legal documents
│   ├── caseworker-guides/           # Caseworker operational guides
│   └── court-reference/             # Court system reference docs
└── groups/
    └── caseworkers.json             # Caseworker group config
scripts/
└── bootstrap-config.sh              # Idempotent script to apply configs via OpenWebUI API
```

## How it works

1. Config files are committed to the Jawafdehi `open-webui` fork
2. `bootstrap-config.sh` reads all configs and applies them to the running OpenWebUI instance
3. The bootstrap script is idempotent — it checks if each item already exists before creating it
4. On a fresh deploy, the script creates everything; on restart, it's a no-op

## Adding a new model

1. Create `configs/models/<name>.json` with the model preset
2. Create `configs/prompts/<name>.nep` with the system prompt
3. Run `bootstrap-config.sh` to apply

## Adding Knowledge Base docs

Place Markdown files in the appropriate subdirectory under `configs/knowledge/`.
The bootstrap script will upload them via the OpenWebUI Knowledge API.
