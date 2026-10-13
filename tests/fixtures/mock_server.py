"""Mock HTTP server used to test the smoke test.

Usage: python mock_server.py MODE [PORT] [STARTUP_DELAY]

MODE:
  ok     answer 200 immediately
  slow   do not listen for STARTUP_DELAY seconds, then answer 200
  500    answer HTTP 500 to every request
  hang   accept connections but never send a response
"""
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

mode = sys.argv[1] if len(sys.argv) > 1 else "ok"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 8000
delay = float(sys.argv[3]) if len(sys.argv) > 3 else 8.0


def log(msg):
    print(f"[mock:{mode}] {msg}", flush=True)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        log(f"GET {self.path}")
        if mode == "hang":
            time.sleep(3600)
            return
        status = 500 if mode == "500" else 200
        body = b"internal error\n" if status == 500 else b"ok\n"
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


class Server(ThreadingHTTPServer):
    daemon_threads = True


if mode == "slow":
    log(f"starting up, not listening for {delay:.0f}s")
    time.sleep(delay)

log(f"listening on port {port}")
Server(("0.0.0.0", port), Handler).serve_forever()
