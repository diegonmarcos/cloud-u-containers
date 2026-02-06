#!/bin/bash
#
# Simple Markdown to HTML Converter
# Converts basic markdown formatting to HTML for email body
#

convert_md_to_html() {
    local input="$1"

    # Start HTML
    cat <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            line-height: 1.6;
            color: #333;
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
            background-color: #f5f5f5;
        }
        .container {
            background-color: white;
            padding: 30px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        h1 { color: #2563eb; border-bottom: 3px solid #2563eb; padding-bottom: 10px; }
        h2 { color: #1e40af; border-bottom: 2px solid #dbeafe; padding-bottom: 8px; margin-top: 30px; }
        h3 { color: #1e3a8a; margin-top: 20px; }
        h4 { color: #1e293b; margin-top: 15px; }
        table {
            width: 100%;
            border-collapse: collapse;
            margin: 20px 0;
            background-color: white;
            box-shadow: 0 1px 3px rgba(0,0,0,0.1);
        }
        th {
            background-color: #2563eb;
            color: white;
            padding: 12px;
            text-align: left;
            font-weight: 600;
        }
        td {
            padding: 10px 12px;
            border-bottom: 1px solid #e5e7eb;
        }
        tr:nth-child(even) {
            background-color: #f9fafb;
        }
        tr:hover {
            background-color: #f3f4f6;
        }
        code {
            background-color: #f3f4f6;
            padding: 2px 6px;
            border-radius: 3px;
            font-family: 'Courier New', monospace;
            font-size: 0.9em;
        }
        pre {
            background-color: #1e293b;
            color: #e2e8f0;
            padding: 15px;
            border-radius: 5px;
            overflow-x: auto;
            font-family: 'Courier New', monospace;
        }
        pre code {
            background-color: transparent;
            color: #e2e8f0;
            padding: 0;
        }
        .status-ok { color: #059669; font-weight: 600; }
        .status-warn { color: #d97706; font-weight: 600; }
        .status-fail { color: #dc2626; font-weight: 600; }
        .emoji { font-size: 1.2em; }
        hr {
            border: none;
            border-top: 2px solid #e5e7eb;
            margin: 30px 0;
        }
        strong {
            color: #1e293b;
        }
        a {
            color: #2563eb;
            text-decoration: none;
        }
        a:hover {
            text-decoration: underline;
        }
        ul, ol {
            margin: 15px 0;
            padding-left: 30px;
        }
        li {
            margin: 8px 0;
        }
        blockquote {
            border-left: 4px solid #2563eb;
            margin: 20px 0;
            padding-left: 20px;
            color: #64748b;
            font-style: italic;
        }
    </style>
</head>
<body>
    <div class="container">
HTML

    # Convert markdown to HTML (basic conversion)
    echo "$input" | sed \
        -e 's/^# \(.*\)/<h1>\1<\/h1>/' \
        -e 's/^## \(.*\)/<h2>\1<\/h2>/' \
        -e 's/^### \(.*\)/<h3>\1<\/h3>/' \
        -e 's/^#### \(.*\)/<h4>\1<\/h4>/' \
        -e 's/^\*\*\(.*\)\*\*/<strong>\1<\/strong>/g' \
        -e 's/\*\*\([^*]*\)\*\*/<strong>\1<\/strong>/g' \
        -e 's/\[OK\]/<span class="status-ok">✅ OK<\/span>/g' \
        -e 's/\[FAIL\]/<span class="status-fail">❌ FAIL<\/span>/g' \
        -e 's/\[WARN\]/<span class="status-warn">⚠️ WARN<\/span>/g' \
        -e 's/^---$/<hr\/>/g' \
        -e 's/^$/\<br\/\>/g' \
        -e 's/^| /<table><tr><td>/; s/ | /<\/td><td>/g; s/ |$/<\/td><\/tr>/' \
        -e 's/^```$/<pre><code>/; s/^```/<\/code><\/pre>/' \
        -e '/^<table>/,/^<\/table>/ { s/^\|/<tr><th>/; s/\|/<\/th><th>/g; s/\|$/<\/th><\/tr>/; }'

    # Close HTML
    cat <<'HTML'
    </div>
</body>
</html>
HTML
}

# Main
if [[ -n "$1" ]]; then
    convert_md_to_html "$(cat "$1")"
else
    convert_md_to_html "$(cat)"
fi
