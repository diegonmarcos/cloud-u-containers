---
id: skill-doc-coauthoring
type: skill
name: "Doc Co-authoring"
path: doc-coauthoring
summary: "Three-stage collaborative writing"
category: Communication
source: anthropics/skills
requiredMcp:
  - Read
  - Write
  - Edit
  - Task
  - AskUserQuestion
parameters:
  - name: "Stage 1"
    type: Workflow
    required: true
    description: "Context gathering: doc type, audience, impact, constraints"
  - name: "Stage 2"
    type: Workflow
    required: true
    description: "Section-by-section: clarify --> brainstorm --> curate --> draft"
  - name: "Stage 3"
    type: Workflow
    required: true
    description: "Reader testing with fresh sub-agent"
---

Structured 3-stage workflow: 1) Context Gathering (meta-questions, info dumping), 2) Refinement (clarify --> brainstorm --> curate --> draft --> iterate per section), 3) Reader Testing (sub-agent tests with fresh context). For PRDs, specs, proposals, RFCs.

**Stage 1 -- Context Gathering**: The skill begins by asking meta-questions to understand the document's purpose, target audience, expected impact, and constraints. It encourages "info dumping" where the author shares raw thoughts, existing notes, and reference materials without worrying about structure. This stage produces a structured brief that guides the rest of the process.

**Stage 2 -- Section-by-Section Refinement**: Each section of the document goes through a four-step cycle: clarify (resolve ambiguities with targeted questions), brainstorm (generate multiple approaches), curate (select the strongest direction), and draft (produce polished prose). The author reviews and iterates on each section before moving to the next.

**Stage 3 -- Reader Testing**: A fresh sub-agent with no prior context reads the completed document and attempts to answer key comprehension questions. This reveals gaps, unclear sections, and assumptions that insiders might miss. Feedback from the reader test drives final revisions.

## Example

- "Co-author a PRD for adding real-time collaboration to the document editor"
- "Help me write an RFC proposing a migration from REST to GraphQL for our internal APIs"
- "Draft a technical spec for the new authentication service with me, section by section"
- "Co-write a project proposal for adopting infrastructure-as-code across all environments"
