#!/usr/bin/env python3
"""
HTTP-to-SMTP Proxy for Cloudflare Worker
Receives emails via HTTPS POST and delivers via SMTP to Stalwart
Uses manual SMTP commands for reliable delivery
"""

from http.server import HTTPServer, BaseHTTPRequestHandler
import smtplib
import socket
import json
import os
from email import message_from_bytes
from email.utils import parseaddr

# Configuration
SMTP_HOST = os.getenv("SMTP_HOST", "127.0.0.1")
SMTP_PORT = int(os.getenv("SMTP_PORT", "25"))
SMTP_USER = os.getenv("SMTP_USER", "me@diegonmarcos.com")
SMTP_PASS = os.getenv("SMTP_PASS", "ogeid1A!")
API_KEY = os.getenv("API_KEY", "stalwart-proxy-key-2025")
LISTEN_PORT = int(os.getenv("LISTEN_PORT", "8025"))
HELO_DOMAIN = os.getenv("HELO_DOMAIN", "smtp-proxy.diegonmarcos.com")

class SMTPProxyHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        # Check API key
        auth = self.headers.get("X-API-Key", "")
        if auth != API_KEY:
            self.send_error(401, "Unauthorized")
            return

        # Read raw email from request body
        content_length = int(self.headers.get("Content-Length", 0))
        raw_email = self.rfile.read(content_length)

        try:
            # Parse email to get From/To
            msg = message_from_bytes(raw_email)
            mail_from = parseaddr(msg.get("From", ""))[1] or "cloudflare@localhost"
            mail_to = parseaddr(msg.get("To", ""))[1] or SMTP_USER

            # Use manual SMTP commands for reliable delivery
            smtp = smtplib.SMTP(timeout=30)
            smtp.connect(SMTP_HOST, SMTP_PORT)

            # Manual EHLO with proper FQDN
            smtp.docmd('EHLO', HELO_DOMAIN)

            # Manual MAIL FROM / RCPT TO / DATA
            code, resp = smtp.docmd('MAIL FROM:', f'<{mail_from}>')
            if code != 250:
                raise Exception(f"MAIL FROM failed: {code} {resp}")

            code, resp = smtp.docmd('RCPT TO:', f'<{mail_to}>')
            if code != 250:
                raise Exception(f"RCPT TO failed: {code} {resp}")

            code, resp = smtp.docmd('DATA')
            if code != 354:
                raise Exception(f"DATA failed: {code} {resp}")

            # Send email data - ensure proper line endings and termination
            email_data = raw_email if isinstance(raw_email, bytes) else raw_email.encode()
            smtp.send(email_data)
            if not email_data.endswith(b'\r\n'):
                smtp.send(b'\r\n')
            smtp.send(b'.\r\n')

            # Read DATA response
            code, resp = smtp.getreply()
            if code != 250:
                raise Exception(f"DATA END failed: {code} {resp}")

            smtp.quit()

            # Success response
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({
                "status": "delivered",
                "from": mail_from,
                "to": mail_to
            }).encode())

        except Exception as e:
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({
                "status": "error",
                "error": str(e)
            }).encode())

    def do_GET(self):
        # Health check
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
        else:
            self.send_error(404)

    def log_message(self, format, *args):
        print(f"[SMTP-Proxy] {args[0]}")

if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", LISTEN_PORT), SMTPProxyHandler)
    print(f"SMTP Proxy listening on port {LISTEN_PORT}")
    print(f"SMTP relay: {SMTP_HOST}:{SMTP_PORT}")
    server.serve_forever()
