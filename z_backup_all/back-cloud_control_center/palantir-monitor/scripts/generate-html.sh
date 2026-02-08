#!/bin/bash
#
# Generate HTML Email Template from Markdown Report
# Converts palantir markdown to styled HTML
#

REPORT_FILE="$1"
HTML_OUTPUT="${2:-${REPORT_FILE%.md}.html}"

cat > "$HTML_OUTPUT" << 'HTML_HEADER'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Palantir Monitor - Cloud Health Report</title>
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            line-height: 1.6;
            color: #333;
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
            background-color: #f5f5f5;
        }
        .container {
            background-color: white;
            border-radius: 8px;
            padding: 30px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        h1 {
            color: #2c3e50;
            border-bottom: 3px solid #3498db;
            padding-bottom: 10px;
            font-size: 28px;
        }
        h2 {
            color: #34495e;
            border-left: 4px solid #3498db;
            padding-left: 15px;
            margin-top: 30px;
            font-size: 22px;
        }
        h3 {
            color: #546e7a;
            margin-top: 20px;
            font-size: 18px;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin: 20px 0;
            background-color: white;
        }
        th {
            background-color: #3498db;
            color: white;
            padding: 12px;
            text-align: left;
            font-weight: 600;
        }
        td {
            padding: 10px 12px;
            border-bottom: 1px solid #ecf0f1;
        }
        tr:hover {
            background-color: #f8f9fa;
        }
        .status-ok {
            color: #27ae60;
            font-weight: bold;
        }
        .status-warn {
            color: #f39c12;
            font-weight: bold;
        }
        .status-fail {
            color: #e74c3c;
            font-weight: bold;
        }
        .topology-box {
            background-color: #ecf0f1;
            border-left: 4px solid #3498db;
            padding: 15px;
            margin: 20px 0;
            font-family: 'Courier New', monospace;
            white-space: pre;
            overflow-x: auto;
            font-size: 12px;
            line-height: 1.4;
        }
        .summary-box {
            background-color: #fff3cd;
            border: 1px solid #ffc107;
            border-radius: 5px;
            padding: 15px;
            margin: 20px 0;
        }
        .metadata {
            color: #666;
            font-size: 14px;
            margin: 10px 0;
        }
        ul {
            list-style-type: none;
            padding-left: 0;
        }
        li {
            padding: 5px 0;
            margin-left: 20px;
        }
        .footer {
            margin-top: 30px;
            padding-top: 20px;
            border-top: 1px solid #ecf0f1;
            color: #7f8c8d;
            font-size: 12px;
            text-align: center;
        }
        hr {
            border: none;
            border-top: 2px solid #ecf0f1;
            margin: 30px 0;
        }
    </style>
</head>
<body>
<div class="container">
HTML_HEADER

# Process markdown file line by line
while IFS= read -r line; do
    # Convert markdown headings to HTML
    if [[ "$line" =~ ^#[[:space:]]+(.*) ]]; then
        title="${BASH_REMATCH[1]}"
        echo "<h1>$title</h1>"
    elif [[ "$line" =~ ^##[[:space:]]+(.*) ]]; then
        title="${BASH_REMATCH[1]}"
        echo "<h2>$title</h2>"
    elif [[ "$line" =~ ^###[[:space:]]+(.*) ]]; then
        title="${BASH_REMATCH[1]}"
        echo "<h3>$title</h3>"

    # Convert metadata
    elif [[ "$line" =~ ^\*\*Generated:\*\*[[:space:]]+(.*) ]]; then
        echo "<p class='metadata'><strong>Generated:</strong> ${BASH_REMATCH[1]}</p>"
    elif [[ "$line" =~ ^\*\*Report[[:space:]]ID:\*\*[[:space:]]+(.*) ]]; then
        echo "<p class='metadata'><strong>Report ID:</strong> ${BASH_REMATCH[1]}</p>"

    # Detect table start
    elif [[ "$line" =~ ^\|.*\| ]]; then
        if [[ ! "$in_table" ]]; then
            echo "<table>"
            in_table=1
            is_header=1
        fi

        # Process table row
        echo "<tr>"
        IFS='|' read -ra cells <<< "$line"
        for cell in "${cells[@]}"; do
            cell=$(echo "$cell" | xargs)  # trim whitespace
            [[ -z "$cell" ]] && continue

            # Skip separator rows
            [[ "$cell" =~ ^-+$ ]] && continue

            # Color code status indicators
            if [[ "$cell" =~ \[OK\] ]]; then
                cell="${cell//\[OK\]/<span class='status-ok'>✅ OK</span>}"
            fi
            if [[ "$cell" =~ \[WARN\] ]]; then
                cell="${cell//\[WARN\]/<span class='status-warn'>⚠️ WARN</span>}"
            fi
            if [[ "$cell" =~ \[FAIL\] ]]; then
                cell="${cell//\[FAIL\]/<span class='status-fail'>❌ FAIL</span>}"
            fi

            if [[ "$is_header" == "1" ]]; then
                echo "<th>$cell</th>"
            else
                echo "<td>$cell</td>"
            fi
        done
        echo "</tr>"
        is_header=0

    # Table ended
    elif [[ "$in_table" == "1" ]] && [[ ! "$line" =~ ^\| ]]; then
        echo "</table>"
        in_table=0

    # ASCII topology box
    elif [[ "$line" =~ ^┌ ]] || [[ "$in_ascii_box" == "1" ]]; then
        if [[ ! "$in_ascii_box" ]]; then
            echo "<div class='topology-box'>"
            in_ascii_box=1
        fi
        echo "$line"
        if [[ "$line" =~ ^└ ]] || [[ "$line" =~ Docker[[:space:]]Networks ]]; then
            in_ascii_box=0
            echo "</div>"
        fi

    # Code blocks
    elif [[ "$line" =~ ^\`\`\` ]]; then
        if [[ ! "$in_code" ]]; then
            echo "<div class='topology-box'>"
            in_code=1
        else
            echo "</div>"
            in_code=0
        fi

    # Horizontal rules
    elif [[ "$line" =~ ^---+$ ]]; then
        echo "<hr>"

    # List items
    elif [[ "$line" =~ ^-[[:space:]]+(.*) ]] || [[ "$line" =~ ^\*[[:space:]]+(.*) ]]; then
        item="${BASH_REMATCH[1]}"
        # Color code status in list items
        item="${item//\[OK\]/<span class='status-ok'>✅ OK</span>}"
        item="${item//\[WARN\]/<span class='status-warn'>⚠️ WARN</span>}"
        item="${item//\[FAIL\]/<span class='status-fail'>❌ FAIL</span>}"
        echo "<li>$item</li>"

    # Regular paragraphs
    elif [[ -n "$line" ]]; then
        # Color code inline status
        line="${line//\[OK\]/<span class='status-ok'>✅ OK</span>}"
        line="${line//\[WARN\]/<span class='status-warn'>⚠️ WARN</span>}"
        line="${line//\[FAIL\]/<span class='status-fail'>❌ FAIL</span>}"

        # Bold text
        line="${line//\*\*/<strong>}"
        line="${line//<strong>/<strong>}"
        line="${line//<strong>/<\/strong>}"

        echo "<p>$line</p>"
    else
        echo "<br>"
    fi
done < "$REPORT_FILE" >> "$HTML_OUTPUT"

# Close any open tables
if [[ "$in_table" == "1" ]]; then
    echo "</table>" >> "$HTML_OUTPUT"
fi

cat >> "$HTML_OUTPUT" << 'HTML_FOOTER'
<div class="footer">
    <p><em>Generated by Palantir Monitor</em></p>
    <p>🔍 Monitoring your cloud infrastructure 24/7</p>
</div>
</div>
</body>
</html>
HTML_FOOTER

echo "HTML report generated: $HTML_OUTPUT"
