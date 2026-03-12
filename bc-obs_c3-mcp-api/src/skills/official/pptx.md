---
id: skill-pptx
type: skill
name: PPTX
path: pptx
summary: "PowerPoint presentations"
category: "Document Skills"
source: anthropics/skills
requiredMcp:
  - Read
  - Write
  - Bash
parameters:
  - name: html2pptx
    type: Script
    required: true
    description: "Convert HTML slides to PPTX"
  - name: "ooxml scripts"
    type: Python
    required: true
    description: "unpack.py, pack.py, validate.py"
  - name: inventory.py
    type: Script
    required: false
    description: "Template text inventory"
  - name: thumbnail.py
    type: Script
    required: true
    description: "Generate slide grids for validation"
  - name: Sharp
    type: Node.js
    required: false
    description: "Rasterize gradients/icons to PNG"
---

# PPTX

Full PowerPoint support: create from HTML via html2pptx, edit via OOXML manipulation, use templates with inventory.py, thumbnail generation, slide rearrangement. Supports web-safe fonts only, two-column layouts preferred, validate with thumbnails.

## Example Prompts

- "Create a 10-slide presentation about Q4 results from this data"
- "Extract all text and images from this PowerPoint file"
- "Rearrange the slides and apply a consistent template to this deck"
- "Generate thumbnail previews of all slides for review"
