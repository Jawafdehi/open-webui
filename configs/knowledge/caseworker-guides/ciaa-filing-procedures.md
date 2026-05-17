# CIAA Case Filing Procedures

## Overview

The Commission for the Investigation of Abuse of Authority (CIAA) is Nepal's primary anti-corruption body. It has the constitutional mandate to investigate and prosecute corruption cases.

## Filing a Case with CIAA

### Step 1: Complaint Registration
- File a written complaint at any CIAA office
- Can be filed anonymously
- Must include specific allegations with supporting evidence if available
- Complaints can be filed in-person, by mail, or through the CIAA hotline

### Step 2: Preliminary Investigation
- CIAA reviews the complaint for jurisdiction and merit
- Preliminary fact-finding conducted
- Decision made within 30 days of complaint registration

### Step 3: Formal Investigation
- If preliminary findings warrant, a formal investigation opens
- CIAA has powers to: summon witnesses, seize documents, freeze assets, arrest suspects
- Investigation must be completed within 6 months (extendable)

### Step 4: Case Filing at Special Court
- Upon investigation completion, CIAA files a charge sheet at the Special Court
- Case is registered with a case number
- Accused is notified and has right to defense

## Jawafdehi Workflow

1. Search for existing published cases: `search_cases "CIAA education"`
2. Extract court case data: `extract_court_data special <case-number>`
3. Create case draft: `create_case_draft`
4. Upload source documents: `upload_source`
