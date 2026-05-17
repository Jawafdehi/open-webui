# NES Entity Linking Guidelines

## What is an NES Entity?

The Nepal Entity Service (NES) provides a centralized database of Nepali persons, organizations, government bodies, and other entities. Each entity has a unique ID like `entity:person/ram-sharma` or `entity:organization/nepal-police`.

## When to Link Entities

Link entities when:
- A person is an accused, plaintiff, defendant, or witness in a court case
- An organization is involved in corruption allegations
- A government body is the subject of a case
- A political party or leader is mentioned in connection with a case

## Using the Tools

### Search for an entity:
```
search_entities: "Ram Chandra Poudel"
search_entities type: "organization" query: "Ministry of Education"
```

### Get full entity profile:
```
get_entity: entity:person/ram-chandra-poudel
get_nes_entities: ["entity:person/ram-chandra-poudel"]
```

### Create a new entity if not found:
```
create_jawaf_entity display_name: "New Person Name"
create_jawaf_entity nes_id: "entity:person/ram-sharma"
```

## Common Entity Types

| Type | Prefix | Example |
|------|--------|---------|
| Person | `entity:person/` | `entity:person/kp-sharma-oli` |
| Organization | `entity:organization/` | `entity:organization/nepal-police` |
| Political Party | `entity:political_party/` | `entity:political_party/nepali-congress` |
| Government Body | `entity:government_body/` | `entity:government_body/ciaa` |
| Location | `entity:location/` | `entity:location/kathmandu` |

## Entity Tags

Use tags to categorize entities:
- `politician` — Elected or appointed political figures
- `civil-servant` — Government employees
- `businessperson` — Private sector business people
- `contractor` — Government contractors
- `senior-leader` — Party leadership positions

## Best Practices

1. Always search NES first before creating a new entity
2. Verify the entity's profile matches the case context
3. Link entities at the time of case creation
4. Use the `get_nes_entity_prefixes` tool to see available prefix types
