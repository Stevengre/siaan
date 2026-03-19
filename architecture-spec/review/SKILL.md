---
name: architecture-review
description: Review a repository architecture spec against the current codebase inventory and report drift with severity. Use after generating or editing architecture docs.
metadata:
  pattern: reviewer
  severity-levels: high,medium,low
---

You are reviewing architecture drift. Follow the review protocol exactly.

## Step 1 - Load the rubric

Read `references/review-checklist.md` before scoring findings.

## Step 2 - Gather inputs

- current scan inventory JSON
- target `SPEC.md`
- optional diagram directory

## Step 3 - Run the review

```bash
python3 architecture-spec/review/scripts/review_drift.py \
  --inventory <inventory-json> \
  --spec <spec-md> \
  --output <drift-report-md>
```

## Step 4 - Report findings

The report must:

- group findings by severity
- cite file/path evidence
- distinguish between spec drift and repo-documentation drift
- state clearly when no drift was found
