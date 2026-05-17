# Evidence Collection Best Practices

## Source Documentation

Every piece of evidence must be traceable to its source:

- **Court orders**: Include case number, court identifier, verdict date
- **Government documents**: Include issuing authority, document number, date
- **Media reports**: Include publication name, date, author, URL
- **Financial records**: Include institution, account details, date range

## Digital Evidence

- Preserve original files — never modify originals
- Document chain of custody
- Screenshots must include visible URL bar and timestamp
- Download and archive web pages (use `convert_document` tool)

## Document Categories

| Category | API Type | Examples |
|----------|----------|---------|
| Court Order | `LEGAL_COURT_ORDER` | Special Court verdicts, Supreme Court writs |
| Procedural | `LEGAL_PROCEDURAL` | Charge sheets, investigation reports |
| Government | `OFFICIAL_GOVERNMENT` | CIAA reports, ministry documents |
| Financial | `FINANCIAL_FORENSIC` | Audit reports, bank statements |
| Media | `MEDIA_NEWS` | Newspaper articles, TV reports |
| Investigation | `INVESTIGATIVE_REPORT` | NGO reports, research papers |

## Uploading Evidence

Use the `upload_source` tool to add evidence to a case:

```
upload_source
  title: "Special Court Verdict in Case 1234"
  description: "Final verdict convicting [name] for procurement fraud"
  source_type: LEGAL_COURT_ORDER
  publication_date: 2082-01-15
  file_path: /path/to/verdict.pdf
```

## Common Mistakes

- Missing publication dates on media sources
- Using incorrect source_type (e.g. LEGAL_COURT_ORDER for a newspaper article)
- Not verifying the document is the final/official version
- Uploading documents without OCR when text extraction is needed
