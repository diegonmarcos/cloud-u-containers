---
id: skill-brand-guidelines
type: skill
name: "Brand Guidelines"
path: brand-guidelines
summary: "Apply Anthropic brand styling"
category: Communication
source: anthropics/skills
requiredMcp:
  - Read
  - Write
parameters:
  - name: "Main Colors"
    type: Hex
    required: true
    description: "#141413 (dark), #faf9f5 (light), #b0aea5 (mid gray)"
  - name: Accents
    type: Hex
    required: true
    description: "#d97757 (orange), #6a9bcc (blue), #788c5d (green)"
  - name: Fonts
    type: Typography
    required: true
    description: "Poppins (headings), Lora (body)"
---

Apply official brand identity: Colors (Dark #141413, Light #faf9f5, Orange #d97757, Blue #6a9bcc, Green #788c5d), Typography (Headings: Poppins, Body: Lora). Smart font application to 24pt+ headings, automatic fallbacks.

The skill ensures consistent brand application across all generated documents, presentations, and web pages. The color palette centers on a warm neutral foundation -- dark charcoal (#141413) and warm off-white (#faf9f5) -- with mid-gray (#b0aea5) for secondary elements. Three accent colors serve distinct purposes: orange (#d97757) for primary actions and emphasis, blue (#6a9bcc) for informational elements and links, and green (#788c5d) for success states and positive indicators.

Typography uses Poppins for headings at 24pt and above, providing clean geometric authority, with Lora as the body font for comfortable reading at smaller sizes. The skill automatically applies appropriate fallback font stacks and handles cases where custom fonts may not be available.

## Example

- "Apply brand colors and typography to this HTML landing page"
- "Generate a styled status report document using the brand palette and Poppins/Lora fonts"
- "Convert this plain markdown into a branded HTML email with proper color scheme and typography"
- "Create a branded presentation template with consistent heading styles, accent colors, and font hierarchy"
