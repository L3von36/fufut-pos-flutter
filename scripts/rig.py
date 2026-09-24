#!/usr/bin/env python3
"""Same-origin dev rig for the Flutter web build.

Serves build/web on localhost and proxies /api/* to the production Worker so
the browser keeps the session cookie first-party — exactly the arrangement
the prod Pages proxy provides. Flutter web cannot send an explicit Cookie
header (forbidden header), so without this the login POST works but every
following request loses the session.

Usage:  python3 scripts/rig.py [port]   (default 8090)
"""
import http.server
import os
import sys
import urllib.error
import urllib.request

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8090
WEB = os.path.join(os.path.dirname(__file__), '..', 'build', 'web')
# FUFUT_RIG_API overrides the upstream — point it at a local box
# (http://127.0.0.1:8787) to rehearse without touching production.
API = os.environ.get('FUFUT_RIG_API', 'https://fufut-api.fufutcoffee.workers.dev')

HOP = {'connection', 'keep-alive', 'transfer-encoding', 'te', 'trailer',
       'proxy-authenticate', 'proxy-authorization', 'upgrade',
       'content-encoding', 'content-length', 'host',
       # Never ask upstream for a compressed body: the response is relayed
       # raw, and a gzip payload without its Content-Encoding header reads
       # as binary garbage to the browser.
       'accept-encoding'}


class Rig(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, fmt, *args):
        sys.stderr.write('%s %s\n' % (self.command, self.path))

    # ── proxy ────────────────────────────────────────────────────────────
    def _proxy(self):
        length = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(length) if length else None
        if body and self.path.startswith('/api/auth/'):
            sys.stderr.write('BODY %s\n' % body[:300].decode('utf-8', 'replace'))
        req = urllib.request.Request(
            API + self.path, data=body, method=self.command)
        for k, v in self.headers.items():
            if k.lower() not in HOP:
                req.add_header(k, v)
        try:
            resp = urllib.request.urlopen(req, timeout=60)
        except urllib.error.HTTPError as e:
            resp = e
        except Exception as e:  # noqa: BLE001
            self.send_error(502, str(e))
            return

        ctype = (resp.headers.get('Content-Type') or '').lower()
        if ctype.startswith('text/event-stream'):
            # Stream relay: SSE must arrive incrementally or the browser's
            # EventSource never fires open/message callbacks and the
            # Flutter web board would sit on "Polling" forever.
            self.send_response(resp.status if hasattr(resp, 'status') else 200)
            for k, v in resp.headers.items():
                if k.lower() not in HOP and k.lower() != 'content-length':
                    self.send_header(k, v)
            self.send_header('Connection', 'close')
            self.end_headers()
            try:
                while True:
                    chunk = resp.read(512)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            except Exception:  # noqa: BLE001 — client gone / upstream cut
                pass
            finally:
                self.close_connection = True
            return

        payload = resp.read()
        self.send_response(resp.status if hasattr(resp, 'status') else 200)
        for k, v in resp.headers.items():
            if k.lower() not in HOP:
                self.send_header(k, v)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    # ── static ───────────────────────────────────────────────────────────
    def _static(self):
        path = self.path.split('?', 1)[0].split('#', 1)[0]
        if path == '/':
            path = '/index.html'
        fs = os.path.normpath(os.path.join(WEB, path.lstrip('/')))
        if not fs.startswith(os.path.normpath(WEB)) or not os.path.isfile(fs):
            # SPA fallback: unknown routes boot the app.
            fs = os.path.join(WEB, 'index.html')
        ext = os.path.splitext(fs)[1].lower()
        types = {'.html': 'text/html', '.js': 'text/javascript',
                 '.css': 'text/css', '.png': 'image/png',
                 '.svg': 'image/svg+xml', '.json': 'application/json',
                 '.wasm': 'application/wasm', '.webp': 'image/webp',
                 '.ico': 'image/x-icon', '.ttf': 'font/ttf',
                 '.woff': 'font/woff', '.woff2': 'font/woff2'}
        with open(fs, 'rb') as f:
            payload = f.read()
        self.send_response(200)
        self.send_header('Content-Type', types.get(ext, 'application/octet-stream'))
        self.send_header('Content-Length', str(len(payload)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(payload)

    def _handle(self):
        if self.path.startswith('/api/'):
            self._proxy()
        else:
            self._static()

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = _handle


if __name__ == '__main__':
    http.server.ThreadingHTTPServer(('127.0.0.1', PORT), Rig).serve_forever()
