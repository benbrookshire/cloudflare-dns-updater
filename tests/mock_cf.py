import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

STATE = {"records": [{"id": "r1", "type": "A", "name": "example.com", "content": "1.1.1.1", "proxied": True, "ttl": 1}]}
LOG = []

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b)
    def body(self):
        n = int(self.headers.get("Content-Length", 0)); return json.loads(self.rfile.read(n)) if n else {}
    def auth(self):
        if self.headers.get("Authorization") != "Bearer good":
            self.send({"success": False, "errors": [{"code": 9109, "message": "Invalid access token"}]}, 403); return False
        return True
    def do_GET(self):
        u = urlparse(self.path); q = parse_qs(u.query)
        # /ip/<value> answers like ipify (bare IP); /trace/<value> like Cloudflare's trace
        if u.path.startswith("/ip/") or u.path.startswith("/trace/"):
            v = u.path.split("/", 2)[2]
            b = ("fl=1\nip=%s\nts=1\n" % v if u.path.startswith("/trace/") else v + "\n").encode()
            self.send_response(200); self.end_headers(); self.wfile.write(b); return
        if not self.auth(): return
        if u.path == "/zones":
            self.send({"success": True, "result": [{"id": "z1"}] if q.get("name") == ["example.com"] else []}); return
        if u.path == "/zones/z1/dns_records":
            r = [x for x in STATE["records"] if x["type"] == q["type"][0] and x["name"] == q["name"][0]]
            self.send({"success": True, "result": r}); return
        if u.path == "/state":
            self.send(STATE); return
        self.send({"success": False, "errors": ["404"]}, 404)
    def do_PATCH(self):
        if not self.auth(): return
        rid = self.path.rsplit("/", 1)[1]; d = self.body(); LOG.append(("PATCH", rid, d))
        for x in STATE["records"]:
            if x["id"] == rid: x.update(d)
        self.send({"success": True, "result": {}})
    def do_POST(self):
        if not self.auth(): return
        d = self.body(); d["id"] = "r%d" % (len(STATE["records"]) + 1); STATE["records"].append(d)
        self.send({"success": True, "result": d})

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
