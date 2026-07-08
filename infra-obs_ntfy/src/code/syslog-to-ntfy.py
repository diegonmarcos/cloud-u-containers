#!/usr/bin/env python3
"""
Syslog to ntfy bridge
Tails syslog messages and pushes Sauron alerts to ntfy channels
"""
import json
import time
import re
import subprocess
from pathlib import Path
import urllib.request
import urllib.error

SYSLOG_FILE = '/var/log/messages'
NTFY_URL = 'http://ntfy:8090'
NTFY_TOPIC = 'sec_yara'
STATE_FILE = '/var/cache/ntfy/syslog-offset.txt'

def get_last_offset():
    try:
        return int(Path(STATE_FILE).read_text().strip())
    except:
        return 0

def save_offset(offset):
    Path(STATE_FILE).write_text(str(offset))

def send_ntfy(title, message, priority='default', tags=None):
    """Send notification to ntfy"""
    data = message.encode('utf-8')
    headers = {
        'Title': title[:250],
        'Priority': priority,
    }
    if tags:
        headers['Tags'] = ','.join(tags)
    
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

def parse_sauron_alert(line):
    """Parse Sauron alert from syslog line"""
    # Try to extract JSON from the line
    try:
        # Format: {"vm":"...","ts":"...","alert":{...}}
        match = re.search(r'\{"vm":.*\}', line)
        if match:
            data = json.loads(match.group())
            return data
    except:
        pass
    return None

def main():
    print(f'Syslog-to-ntfy bridge starting...')
    print(f'Watching: {SYSLOG_FILE}')
    print(f'Pushing to: {NTFY_URL}/{NTFY_TOPIC}')
    
    # Wait for syslog file to exist
    while not Path(SYSLOG_FILE).exists():
        print(f'Waiting for {SYSLOG_FILE}...')
        time.sleep(5)
    
    offset = get_last_offset()
    print(f'Starting from offset: {offset}')
    
    while True:
        try:
            with open(SYSLOG_FILE, 'r') as f:
                f.seek(0, 2)  # End of file
                file_size = f.tell()
                
                if offset > file_size:
                    # File was rotated
                    offset = 0
                
                f.seek(offset)
                
                for line in f:
                    alert = parse_sauron_alert(line)
                    if alert:
                        vm = alert.get('vm', 'unknown')
                        ts = alert.get('ts', '')
                        alert_data = alert.get('alert', {})
                        
                        rule = alert_data.get('rule', 'Unknown')
                        path = alert_data.get('path', '')
                        
                        title = f'🔴 Sauron Alert: {rule}'
                        message = f'VM: {vm}\nPath: {path}\nTime: {ts}'
                        
                        if send_ntfy(title, message, priority='high', tags=['warning', 'sauron']):
                            print(f'Sent alert: {rule} on {vm}')
                
                offset = f.tell()
                save_offset(offset)
        
        except Exception as e:
            print(f'Error: {e}')
        
        time.sleep(2)

if __name__ == '__main__':
    main()
