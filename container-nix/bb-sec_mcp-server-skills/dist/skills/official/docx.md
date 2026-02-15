---
id: skill-docx
type: skill
name: DOCX
path: docx
summary: "Word document manipulation"
category: "Document Skills"
source: anthropics/skills
requiredMcp:
  - Read
  - Write
  - Bash
parameters:
  - name: pandoc
    type: CLI
    required: true
    description: "Text extraction with tracked changes"
  - name: "docx (npm)"
    type: Node.js
    required: true
    description: "Document creation"
  - name: LibreOffice
    type: CLI
    required: false
    description: "PDF/image conversion"
  - name: defusedxml
    type: Python
    required: false
    description: "Secure XML parsing for OOXML"
---

# DOCX

Comprehensive Word document handling: text extraction via pandoc, raw XML access for comments/formatting/media, document creation with docx-js, tracked changes (redlining) with OOXML, and visualization via LibreOffice PDF conversion.

## Example Prompts

- "Extract all text from this Word document including tracked changes"
- "Create a new DOCX report with headings, tables, and a cover page"
- "Convert this Word document to PDF preserving all formatting"
- "List all comments and reviewer annotations in this DOCX file"
