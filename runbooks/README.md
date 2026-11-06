# Runbooks

A runbook says what to do when something specific goes wrong: how to tell
it's happening, what to check first, and how to fix it. Write them for the
person who gets paged at 2am. That might be you.

One file per problem, named after the symptom: `api-returns-502.md`,
`disk-full.md`.

Template:

```markdown
# <Symptom, e.g. "API returns 502">

## How you know
<the alert, the error message, or what users report>

## Check first
1. <command> and what a healthy result looks like

## Fix
1. <step>

## Why it happens
<one paragraph>
```
