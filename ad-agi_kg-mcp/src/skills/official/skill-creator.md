---
id: skill-creator
type: skill
name: "Skill Creator"
path: skill-creator
summary: "Build custom skills"
category: "Skill Creation"
source: anthropics/skills
requiredMcp:
  - Write
  - Read
  - Bash
  - AskUserQuestion
parameters:
  - name: "init_skill.py"
    type: Script
    required: true
    description: "Create skeleton skill directory"
  - name: "package_skill.py"
    type: Script
    required: true
    description: "Validate and package to .skill file"
  - name: "SKILL.md"
    type: Markdown
    required: true
    description: "YAML frontmatter + instructions (<500 lines)"
---

Create effective skills: SKILL.md (frontmatter + instructions), bundled resources (scripts/, references/, assets/). Progressive disclosure: metadata (100 words) --> SKILL.md (<5k words) --> resources (as-needed). Init --> Edit --> Package --> Iterate.

The skill guides the creation of new custom skills for Claude Code. It follows a progressive disclosure model where information is layered from compact metadata to full instructions to supplementary resources. This ensures Claude loads only what it needs for a given task.

**Init**: Run `init_skill.py` to create the skeleton directory structure including SKILL.md, scripts/, references/, and assets/ directories. The generated SKILL.md includes the YAML frontmatter template with all required fields.

**Edit**: Write the skill instructions in SKILL.md. The frontmatter defines metadata (name, description, tools needed, parameters). The markdown body contains the actual instructions, kept under 500 lines and 5,000 words. Instructions should be specific, actionable, and include examples of expected behavior.

**Package**: Run `package_skill.py` to validate the skill structure, check frontmatter completeness, verify referenced files exist, and bundle everything into a distributable `.skill` file.

**Iterate**: Test the skill in real conversations, observe where it falls short, and refine instructions based on actual usage patterns.

## Example

- "Create a new skill for generating database migration scripts from schema diffs"
- "Build a skill that helps write and maintain changelog entries following Keep a Changelog format"
- "Package my code review skill with its reference style guide and linting configuration"
- "Initialize a skill for automated API documentation generation from OpenAPI specs"
