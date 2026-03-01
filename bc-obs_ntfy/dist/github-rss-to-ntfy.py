#!/usr/bin/env python3
import sys; sys.stdout.reconfigure(line_buffering=True)
"""
GitHub RSS to ntfy bridge
Fetches GitHub activity feeds and pushes to ntfy
"""
import json
import time
import hashlib
import urllib.request
import urllib.error
import xml.etree.ElementTree as ET
from pathlib import Path
from datetime import datetime

NTFY_URL = 'http://ntfy:80'
NTFY_TOPIC = 'github'
STATE_FILE = '/var/cache/ntfy/github-seen.json'
CHECK_INTERVAL = 300  # 5 minutes

# GitHub feeds to monitor
GITHUB_FEEDS = [
    {
        'name': 'diegonmarcos activity',
        'url': 'https://github.com/diegonmarcos.atom',
        'icon': 'octocat'
    },
]

def load_seen():
    try:
        return json.loads(Path(STATE_FILE).read_text())
    except:
        return {}

def save_seen(seen):
    Path(STATE_FILE).write_text(json.dumps(seen))

def send_ntfy(title, message, priority='default', tags=None, click=None):
    data = message.encode('utf-8')
    headers = {
        'Title': title[:250],
        'Priority': priority,
    }
    if tags:
        headers['Tags'] = ','.join(tags)
    if click:
        headers['Click'] = click
    
    req = urllib.request.Request(
        f'{NTFY_URL}/{NTFY_TOPIC}',
        data=data,
        headers=headers,
        method='POST'
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status == 200
    except Exception as e:
        print(f'ntfy error: {e}')
        return False

def fetch_feed(url):
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'ntfy-rss-bridge/1.0'})
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.read().decode('utf-8')
    except Exception as e:
        print(f'Feed fetch error: {e}')
        return None

def strip_html(text):
    """Remove HTML tags from text"""
    import re
    if not text:
        return ''
    # Remove HTML tags
    text = re.sub(r'<[^>]+>', '', text)
    # Decode HTML entities
    text = text.replace('&amp;', '&').replace('&lt;', '<').replace('&gt;', '>').replace('&quot;', '"')
    # Clean up whitespace
    text = ' '.join(text.split())
    return text

def parse_atom_feed(xml_content):
    entries = []
    try:
        root = ET.fromstring(xml_content)
        ns = {'atom': 'http://www.w3.org/2005/Atom'}
        for entry in root.findall('.//atom:entry', ns):
            title = entry.find('atom:title', ns)
            link = entry.find('atom:link', ns)
            updated = entry.find('atom:updated', ns)
            content = entry.find('atom:content', ns)

            # Extract and clean content text
            content_text = ''
            if content is not None:
                # Get all text including from nested elements
                content_text = ''.join(content.itertext())
                content_text = strip_html(content_text)[:200]

            entries.append({
                'id': hashlib.md5((title.text if title is not None else '').encode()).hexdigest()[:12],
                'title': title.text if title is not None else 'No title',
                'link': link.get('href') if link is not None else '',
                'updated': updated.text if updated is not None else '',
                'content': content_text
            })
    except Exception as e:
        print(f'Parse error: {e}')
    return entries[:10]  # Only latest 10

def main():
    print('GitHub RSS to ntfy bridge starting...')
    print(f'Monitoring {len(GITHUB_FEEDS)} feeds')
    print(f'Pushing to: {NTFY_URL}/{NTFY_TOPIC}')
    
    seen = load_seen()
    
    while True:
        for feed in GITHUB_FEEDS:
            print(f'Checking: {feed["name"]}')
            xml_content = fetch_feed(feed['url'])
            if not xml_content:
                continue
            
            entries = parse_atom_feed(xml_content)
            feed_key = hashlib.md5(feed['url'].encode()).hexdigest()[:8]
            
            for entry in entries:
                entry_key = f'{feed_key}:{entry["id"]}'
                if entry_key in seen:
                    continue
                
                # New entry - send notification
                title = f"GitHub: {entry['title'][:100]}"
                message = entry['content'] if entry['content'] else entry['title']
                
                if send_ntfy(
                    title=title,
                    message=message,
                    priority='default',
                    tags=['github', feed.get('icon', 'octocat')],
                    click=entry['link']
                ):
                    print(f'Sent: {entry["title"][:50]}...')
                    seen[entry_key] = time.time()
        
        # Cleanup old entries (older than 7 days)
        cutoff = time.time() - (7 * 24 * 3600)
        seen = {k: v for k, v in seen.items() if v > cutoff}
        save_seen(seen)
        
        time.sleep(CHECK_INTERVAL)

if __name__ == '__main__':
    main()
