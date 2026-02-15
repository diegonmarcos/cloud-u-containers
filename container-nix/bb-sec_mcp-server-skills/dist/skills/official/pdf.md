---
id: skill-pdf
type: skill
name: PDF
path: pdf
summary: "PDF manipulation toolkit"
category: "Document Skills"
source: anthropics/skills
requiredMcp:
  - Read
  - Write
  - Bash
parameters:
  - name: Libraries
    type: Python
    required: true
    description: "pypdf, pdfplumber, reportlab, pytesseract, pdf2image, pandas"
  - name: "CLI Tools"
    type: Bash
    required: false
    description: "pdftotext, qpdf, pdftk (poppler-utils)"
---

# PDF

Comprehensive PDF toolkit: extract text/tables with pdfplumber, OCR scanned docs with pytesseract, create PDFs with reportlab, merge/split with pypdf/qpdf, rotate pages, add watermarks, encrypt/decrypt, and fill form fields.

## Example Prompts

- "Extract the table from page 3 of this PDF into a CSV file"
- "Merge these five PDF files into a single document"
- "OCR this scanned document and extract all the text"
- "Fill in the form fields of this PDF with the provided data"
