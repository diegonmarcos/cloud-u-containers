#!/usr/bin/env python3
from http.server import HTTPServer, ThreadingHTTPServer, BaseHTTPRequestHandler
import smtplib
import json
import os
import sys
import logging
from email import message_from_bytes
from email.utils import parseaddr

logging.basicConfig(stream=sys.stdout, level=logging.INFO,
                    format='%(asctime)s [%(levelname)s] %(message)s')

SMTP_HOST = os.getenv('SMTP_HOST', '127.0.0.1')
SMTP_PORT = int(os.getenv('SMTP_PORT', '25'))
SMTP_USER = os.getenv('SMTP_USER', 'me@diegonmarcos.com')
SMTP_PASS = os.getenv('SMTP_PASS', '')
API_KEY = os.getenv('API_KEY', '')
LISTEN_PORT = int(os.getenv('LISTEN_PORT', '8080'))
HELO_DOMAIN = 'smtp-proxy.diegonmarcos.com'

class SMTPProxyHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        logging.info(f'POST from {self.client_address[0]} path={self.path} CF-IP={self.headers.get("CF-Connecting-IP","none")} XFF={self.headers.get("X-Forwarded-For","none")}')
        auth = self.headers.get('X-API-Key', '')
        if auth != API_KEY:
            logging.warning(f'AUTH FAILED from {self.client_address[0]}')
            self.send_error(401, 'Unauthorized')
            return
        content_length = int(self.headers.get('Content-Length', 0))
        raw_email = self.rfile.read(content_length)
        # Extract original sender IP from CF Worker headers
        original_ip = (self.headers.get('CF-Connecting-IP')
                       or self.headers.get('X-Forwarded-For', '').split(',')[0].strip()
                       or self.client_address[0])
        try:
            msg = message_from_bytes(raw_email)
            mail_from = parseaddr(msg.get('From', ''))[1] or 'cloudflare@localhost'
            mail_to = parseaddr(msg.get('To', ''))[1] or SMTP_USER
            logging.info(f'Delivering from={mail_from} to={mail_to} via={SMTP_HOST}:{SMTP_PORT} client={original_ip}')

            with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=30, local_hostname=HELO_DOMAIN) as smtp:
                if SMTP_PORT == 587:
                    smtp.starttls()
                    smtp.login(SMTP_USER, SMTP_PASS)
                # XCLIENT: pass original sender IP so Maddy can do SPF/DNSBL/rDNS checks
                smtp.docmd('XCLIENT', f'ADDR={original_ip}')
                smtp.sendmail(mail_from, [mail_to], raw_email)

            logging.info(f'Delivered OK msg_id={msg.get("Message-ID","?")}')
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'status': 'delivered', 'from': mail_from, 'to': mail_to}).encode())
        except Exception as e:
            logging.error(f'Delivery failed: {e}')
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
        logging.info(f'HTTP {args[0]}')

if __name__ == '__main__':
    server = ThreadingHTTPServer(('0.0.0.0', LISTEN_PORT), SMTPProxyHandler)
    logging.info(f'SMTP Proxy listening on port {LISTEN_PORT}')
    logging.info(f'SMTP relay: {SMTP_HOST}:{SMTP_PORT} (HELO: {HELO_DOMAIN})')
    server.serve_forever()
