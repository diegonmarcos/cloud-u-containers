---
id: skill-webapp-testing
type: skill
name: "WebApp Testing"
path: webapp-testing
summary: "Playwright E2E testing"
category: Development
source: anthropics/skills
requiredMcp:
  - Read
  - Write
  - Bash
  - mcp__playwright
parameters:
  - name: "Playwright MCP"
    type: "MCP Server"
    required: true
    description: "Browser automation capability"
---

Test local web applications using Playwright MCP. E2E testing, visual regression, accessibility testing. Requires Playwright MCP server configured. Capture screenshots, interact with pages, validate flows.

The skill leverages the Playwright MCP server to automate browser interactions against running web applications. It supports end-to-end testing workflows: navigating pages, clicking elements, filling forms, asserting visible text, and capturing screenshots for visual regression. Accessibility testing checks for proper ARIA attributes, keyboard navigation, and color contrast issues.

The testing process follows a structured approach: identify critical user flows, write test scenarios that exercise those flows, execute them through the Playwright MCP tools, and report results with screenshots as evidence. Tests run against local dev servers, staging environments, or any reachable URL.

## Example

- "Test the login flow of my app at localhost:3000 -- fill credentials, submit, verify dashboard loads"
- "Run visual regression on the homepage by capturing screenshots at mobile, tablet, and desktop widths"
- "Test accessibility of the signup form -- check label associations, tab order, and screen reader text"
- "Validate the checkout flow end-to-end: add item to cart, enter shipping, confirm payment, verify confirmation page"
