---
id: skill-internal-comms
type: skill
name: "Internal Comms"
path: internal-comms
summary: "Status reports & newsletters"
category: Communication
source: anthropics/skills
requiredMcp:
  - Read
  - Write
parameters:
  - name: "3p-updates.md"
    type: Template
    required: false
    description: "Progress/Plans/Problems format"
  - name: "company-newsletter.md"
    type: Template
    required: false
    description: "Newsletter format"
  - name: "faq-answers.md"
    type: Template
    required: false
    description: "FAQ response format"
  - name: "general-comms.md"
    type: Template
    required: false
    description: "Fallback template"
---

Write internal communications with company formats: 3P updates (Progress/Plans/Problems), company newsletters, FAQ responses, status reports, leadership updates, incident reports. Load guideline files from examples/ directory.

The skill provides structured templates for common internal communication needs. The 3P update format (Progress/Plans/Problems) is used for team and project status reports -- each section is concise and actionable. Company newsletters follow a structured layout with sections for announcements, team highlights, upcoming events, and key metrics. FAQ responses maintain a consistent tone and format for addressing recurring questions.

When guideline files exist in the examples/ directory, the skill loads them to ensure formatting matches established organizational patterns. When no template matches the request, it falls back to the general communications template, which provides a clear structure adaptable to any internal message type including leadership updates, incident reports, policy changes, and team announcements.

## Example

- "Write a 3P status update for the infrastructure team covering last sprint's container migration work"
- "Draft a company newsletter announcing the new authentication system and upcoming maintenance window"
- "Create FAQ responses for the most common questions about the VPN migration"
- "Write an incident report for yesterday's 2-hour database outage following the postmortem template"
