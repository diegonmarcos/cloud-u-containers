---
id: skill-xlsx
type: skill
name: XLSX
path: xlsx
summary: "Excel spreadsheet operations"
category: "Document Skills"
source: anthropics/skills
requiredMcp:
  - Read
  - Write
  - Bash
parameters:
  - name: pandas
    type: Python
    required: true
    description: "Data analysis and manipulation"
  - name: openpyxl
    type: Python
    required: true
    description: "Complex formatting and formulas"
  - name: recalc.py
    type: Script
    required: true
    description: "LibreOffice formula recalculation"
  - name: "Zero formula errors"
    type: Validation
    required: true
    description: "No #REF!, #DIV/0!, #VALUE!, #N/A, #NAME?"
---

# XLSX

Comprehensive spreadsheet operations: create/edit with formulas using openpyxl, data analysis with pandas, formula recalculation via LibreOffice recalc.py, financial model standards with color coding (blue=inputs, black=formulas).

## Example Prompts

- "Create a financial model spreadsheet with revenue projections and formatted formulas"
- "Analyze the data in this Excel file and produce summary statistics"
- "Recalculate all formulas in this spreadsheet and validate there are no errors"
- "Build a pivot-style summary sheet from the raw data tab"
