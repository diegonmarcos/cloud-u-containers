---
id: skill-mcp-builder
type: skill
name: "MCP Builder"
path: mcp-builder
summary: "Create MCP servers"
category: Development
source: anthropics/skills
requiredMcp:
  - Write
  - Read
  - Bash
  - Glob
  - WebSearch
---

Guide for building Model Context Protocol (MCP) servers to extend Claude with external tools. Research API --> Implement server --> Test with Bash --> Package. Integrates databases, APIs, and services.

The skill walks through the full lifecycle of creating an MCP server. It starts with researching the target API or service to understand its capabilities and authentication requirements. Implementation follows the MCP SDK patterns -- defining tools with JSON Schema input validation, implementing handlers, and setting up the stdio transport. Testing is done iteratively using Bash to invoke the server and validate tool responses. The final package includes proper dependency management, configuration examples, and documentation for end users.

MCP servers can expose tools (callable functions), resources (readable data), and prompts (reusable templates). The skill covers all three primitives and helps choose which patterns fit the integration being built.

## Example

- "Build an MCP server that wraps the GitHub API for issue and PR management"
- "Create an MCP server connecting to a PostgreSQL database with query and schema inspection tools"
- "Implement an MCP server for Slack that can read channels, post messages, and search history"
- "Build an MCP server that integrates with a local file-based task manager"
