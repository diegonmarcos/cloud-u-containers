#!/bin/bash
# Simple MD to HTML converter with table support

cat <<'HTML'
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<style>
body { font-family: -apple-system, sans-serif; line-height: 1.6; color: #333; max-width: 900px; margin: 20px auto; padding: 20px; }
h1 { color: #2563eb; border-bottom: 2px solid #2563eb; padding-bottom: 8px; }
h2 { color: #1e40af; margin-top: 25px; }
h3 { color: #374151; margin-top: 15px; }
ul { margin: 10px 0; padding-left: 25px; list-style: none; }
li { margin: 5px 0; }
table { width: 100%; border-collapse: collapse; margin: 15px 0; }
th { background: #1e40af; color: white; padding: 10px; text-align: left; }
td { padding: 8px 10px; border-bottom: 1px solid #e5e7eb; }
tr:nth-child(even) { background: #f9fafb; }
hr { border: none; border-top: 1px solid #e5e7eb; margin: 20px 0; }
code { background: #f3f4f6; padding: 2px 5px; border-radius: 3px; font-family: monospace; }
strong { color: #1e293b; }
</style>
</head>
<body>
HTML

# Process markdown with table support
awk '
BEGIN { in_table = 0 }
/^\|/ {
    if (!in_table) { print "<table>"; in_table = 1; first_row = 1 }
    gsub(/^\||\|$/, "")
    if (/^[-|: ]+$/) { next }
    n = split($0, cells, "|")
    print "<tr>"
    for (i = 1; i <= n; i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", cells[i])
        if (first_row) print "<th>" cells[i] "</th>"
        else print "<td>" cells[i] "</td>"
    }
    print "</tr>"
    first_row = 0
    next
}
!/^\|/ && in_table { print "</table>"; in_table = 0 }
/^# / { gsub(/^# /, ""); print "<h1>" $0 "</h1>"; next }
/^## / { gsub(/^## /, ""); print "<h2>" $0 "</h2>"; next }
/^### / { gsub(/^### /, ""); print "<h3>" $0 "</h3>"; next }
/^---$/ { print "<hr>"; next }
/^  - / { gsub(/^  - /, ""); print "<li style=\"margin-left:20px\">" $0 "</li>"; next }
/^- / { gsub(/^- /, ""); print "<li>" $0 "</li>"; next }
{ gsub(/\*\*([^*]+)\*\*/, "<strong>\\1</strong>"); print }
END { if (in_table) print "</table>" }
'

cat <<'HTML'
</body>
</html>
HTML
