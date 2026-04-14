# Migration and Format Safety Rules

Read this file when the task touches data migrations, format conversions, irreversible transformations, or compatibility of stored data.

## Migration and Format Safety

- Do not perform one-way data migrations or irreversible format changes without explicit approval unless already clearly approved by the project.
- If a migration is needed, explain rollback implications, compatibility impact, and whether existing data will be transformed in place or copied forward.
- Prefer reversible or copy-forward migrations over destructive in-place conversion where practical.
