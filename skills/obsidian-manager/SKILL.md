---
name: obsidian-manager
description: Reads and writes notes to the user's Nexus Obsidian vault. Use when the user asks to record ideas, create notes, search the vault, update projects, or organize information in Obsidian.
---

# Obsidian Manager (Nexus)

This skill provides direct access to the user's central knowledge base, the Nexus Obsidian vault, located at:
`/Users/hyunss/Library/CloudStorage/GoogleDrive-cosmos6464@gmail.com/내 드라이브/Obsidian/nexus/nexus/nexus`

## Quick start

To read a note:
1. Search for the note using the `glob` or `grep_search` tools within the vault path.
2. Read the file contents using `read_file`.

To create or update a note:
1. Ensure the target directory exists within the vault path.
2. Use `write_file` or `replace` to modify the note content.

## Vault Structure

Respect the existing folder structure when creating new notes:
- `00-inbox/`: Unclassified quick notes and ideas.
- `01-projects/`: Active project folders.
- `02-tech/`: Tech stacks, libraries, frameworks.
- `03-reference/`: General reference materials and documentation.
- `04-daily/`: Daily logs (Format: YYYY-MM-DD.md).
- `05-work/`: Work logs and procedures.

## Note Creation Guidelines

### 1. Frontmatter (YAML)
Always include the following YAML frontmatter at the top of new notes:
```yaml
---
created: YYYY-MM-DD HH:mm
tags: [tag1, tag2]
aliases: [AliasName]
---
```

### 2. Linking
- Use standard Obsidian wikilinks `[[Note Title]]` for internal linking.
- Ensure tags are relevant and use lowercase if possible.

## Workflows

### Saving a new idea or snippet
1. Determine if it belongs to a specific project (`01-projects`), tech (`02-tech`), or is just a general thought (`00-inbox`).
2. Generate the YAML frontmatter with the current date/time.
3. Write the markdown content to the appropriate directory using `write_file`.

### Updating a Daily Note
1. Check if today's daily note exists in `04-daily/YYYY-MM-DD.md`.
2. If it does not exist, create it with the standard frontmatter.
3. Append or insert the new content into the daily note using `replace` or `write_file` (if new).