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
        # /igd/<value>.xml is a UPnP router description (laid out like an eero's)
        # whose WAN service reports <value> as the external IP. /igd-nowan.xml has no WAN service.
        if u.path.startswith("/igd"):
            v = u.path[len("/igd/"):-len(".xml")] if u.path.startswith("/igd/") else None
            svc = ("<service>\n  <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>\n"
                   "  <serviceId>urn:upnp-org:serviceId:WANIPConn1</serviceId>\n  <SCPDURL>/wanipcn.xml</SCPDURL>\n"
                   "  <controlURL>/ipc/%s</controlURL>\n  <eventSubURL>/evt</eventSubURL>\n</service>" % v) if v else ""
            b = ("<?xml version=\"1.0\"?>\r\n<root><device><friendlyName>mock</friendlyName><serviceList>\r\n"
                 "<service><serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType>"
                 "<controlURL>/l3f</controlURL></service>\r\n%s</serviceList></device></root>" % svc).encode()
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
        if self.path.startswith("/ipc/"):
            n = int(self.headers.get("Content-Length", 0)); req = self.rfile.read(n).decode()
            ok = "GetExternalIPAddress" in self.headers.get("SOAPAction", "") and "GetExternalIPAddress" in req
            v = self.path[len("/ipc/"):]
            b = ("<?xml version=\"1.0\"?><s:Envelope><s:Body><u:GetExternalIPAddressResponse>"
                 "<NewExternalIPAddress>%s</NewExternalIPAddress></u:GetExternalIPAddressResponse></s:Body></s:Envelope>" % v
                 if ok else "<s:Envelope><s:Body><s:Fault/></s:Body></s:Envelope>").encode()
            self.send_response(200 if ok else 500); self.end_headers(); self.wfile.write(b); return
        if not self.auth(): return
        d = self.body(); d["id"] = "r%d" % (len(STATE["records"]) + 1); STATE["records"].append(d)
        self.send({"success": True, "result": d})

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
