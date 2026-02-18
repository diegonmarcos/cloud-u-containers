#!/usr/bin/env python3
from http.server import HTTPServer, BaseHTTPRequestHandler
import smtplib
import json
import os
from email import message_from_bytes
from email.utils import parseaddr

SMTP_HOST = os.getenv('SMTP_HOST', '127.0.0.1')
SMTP_PORT = int(os.getenv('SMTP_PORT', '25'))
SMTP_USER = os.getenv('SMTP_USER', 'me@diegonmarcos.com')
SMTP_PASS = os.getenv('SMTP_PASS', 'ogeid1A!')
API_KEY = os.getenv('API_KEY', 'stalwart-proxy-key-2025')
LISTEN_PORT = int(os.getenv('LISTEN_PORT', '8080'))
HELO_DOMAIN = 'smtp-proxy.diegonmarcos.com'

class SMTPProxyHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        auth = self.headers.get('X-API-Key', '')
        if auth != API_KEY:
            self.send_error(401, 'Unauthorized')
            return
        content_length = int(self.headers.get('Content-Length', 0))
        raw_email = self.rfile.read(content_length)
        try:
            msg = message_from_bytes(raw_email)
            mail_from = parseaddr(msg.get('From', ''))[1] or 'cloudflare@localhost'
            mail_to = parseaddr(msg.get('To', ''))[1] or SMTP_USER
            print(f'[SMTP] Delivering from {mail_from} to {mail_to} via {SMTP_HOST}:{SMTP_PORT}')
            
            with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=30, local_hostname=HELO_DOMAIN) as smtp:
                if SMTP_PORT == 587:
                    smtp.starttls()
                    smtp.login(SMTP_USER, SMTP_PASS)
                smtp.sendmail(mail_from, [mail_to], raw_email)
            
            print(f'[SMTP] Delivered successfully')
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'status': 'delivered', 'from': mail_from, 'to': mail_to}).encode())
        except Exception as e:
            print(f'[SMTP] Error: {e}')
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'status': 'error', 'error': str(e)}).encode())

    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
        else:
            self.send_error(404)

    def log_message(self, format, *args):
        print(f'[HTTP] {args[0]}')

if __name__ == '__main__':
    server = HTTPServer(('0.0.0.0', LISTEN_PORT), SMTPProxyHandler)
    print(f'SMTP Proxy listening on port {LISTEN_PORT}')
    print(f'SMTP relay: {SMTP_HOST}:{SMTP_PORT} (HELO: {HELO_DOMAIN})')
    server.serve_forever()
