# Common Pitfalls in Case Documentation

## 1. Presumption of Innocence

**Wrong:** "Corrupt official Ram Sharma embezzled funds from the Ministry."
**Right:** "Ram Sharma is accused of embezzlement at the Ministry of Education. Special Court Case No. 1234 is ongoing. He is presumed innocent until proven guilty."

## 2. Missing Source Attribution

Every factual claim must have a cited source. Use the source linking system.

**Wrong:** "The contract was inflated by 300%."
**Right:** "According to the Auditor General's report (2081), the contract was inflated by 300%. [Source: OAG-2081-042]"

## 3. Imprecise Language

**Wrong:** "A lot of money was stolen."
**Right:** "According to the CIAA charge sheet, NPR 42,000,000 (approximately USD 315,000) was misappropriated."

## 4. Not Verifying Court Case Status

Always check the current status of court cases before referencing them. A case may have been:
- Withdrawn
- Dismissed
- Settled
- Overturned on appeal

Use `extract_court_data` to verify before publishing.

## 5. Mixing Opinion with Fact

**Wrong:** "This is clearly a case of rampant corruption."
**Right:** "The CIAA has filed a case alleging corruption. Court proceedings are ongoing."

## 6. Outdated Information

Court cases evolve. A verdict may be appealed. Always check:
- Is a higher court reviewing this?
- Has the Special Court verdict been challenged at the Supreme Court?
- Are there related cases involving the same parties?

## 7. Entity Linking Errors

- Always verify NES entity IDs before linking
- Do not link generic references (e.g. "the government" → specific ministry or department)
- Use `search_entities` to find the correct NES ID
