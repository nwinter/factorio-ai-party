"""Cloudflare Workers AI client (stdlib only) for the stream audio service.

Credentials, in order:
  1. CLOUDFLARE_API_TOKEN (+ CLOUDFLARE_ACCOUNT_ID), e.g. a token scoped to "Workers AI: Read/Edit".
  2. The wrangler OAuth login (~/Library/Preferences/.wrangler/config/default.toml or ~/.wrangler/config/default.toml).
     Its access token lasts about an hour; `npx wrangler whoami` refreshes it. This client re-reads the file
     whenever the cached token is close to expiry, and runs `npx wrangler whoami` itself once it has expired.
The token is only ever sent to api.cloudflare.com, the service that issued it.
"""
import json, os, re, shutil, subprocess, time, urllib.error, urllib.request

API = "https://api.cloudflare.com/client/v4"
WRANGLER_CONFIGS = ["~/Library/Preferences/.wrangler/config/default.toml", "~/.wrangler/config/default.toml",
                    "~/.config/.wrangler/config/default.toml"]
ACCOUNT_NAME = os.environ.get("CLOUDFLARE_ACCOUNT_NAME", "")


class CFError(RuntimeError):
    pass


class WorkersAI:
    def __init__(self, account_id=None, timeout=30):
        self.timeout = timeout
        self._token, self._expires = None, 0
        self.account_id = account_id or os.environ.get("CLOUDFLARE_ACCOUNT_ID")
        self.neurons = 0.0  # running estimate, filled by callers that know the per-model rate

    # ---- auth --------------------------------------------------------------------------------------------------
    def token(self):
        env = os.environ.get("CLOUDFLARE_API_TOKEN")
        if env:
            return env
        if self._token and time.time() < self._expires - 60:
            return self._token
        try:
            return self._wrangler_token()
        except CFError:
            if not shutil.which("npx"):
                raise
        # `wrangler whoami` refreshes an expired OAuth token with the stored refresh token (a stream outlives the hour)
        subprocess.run(["npx", "wrangler", "whoami"], capture_output=True, timeout=90)
        return self._wrangler_token()

    def _wrangler_token(self):
        for path in WRANGLER_CONFIGS:
            path = os.path.expanduser(path)
            if os.path.exists(path):
                text = open(path).read()
                tok = re.search(r'^oauth_token\s*=\s*"([^"]+)"', text, re.M)
                exp = re.search(r'^expiration_time\s*=\s*"([^"]+)"', text, re.M)
                if tok:
                    self._token = tok.group(1)
                    self._expires = _iso(exp.group(1)) if exp else time.time() + 600
                    if self._expires < time.time():
                        raise CFError("wrangler OAuth token expired: run `npx wrangler whoami` to refresh it, "
                                      "or set CLOUDFLARE_API_TOKEN")
                    return self._token
        raise CFError("no Cloudflare credentials: set CLOUDFLARE_API_TOKEN or run `npx wrangler login`")

    def _req(self, method, url, body=None, ctype="application/json", raw=False, timeout=None):
        data = None
        if body is not None:
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
        req = urllib.request.Request(url, data=data, method=method,
                                     headers={"Authorization": "Bearer " + self.token(), "Content-Type": ctype})
        try:
            with urllib.request.urlopen(req, timeout=timeout or self.timeout) as r:
                payload = r.read()
                return (payload, r.headers.get("Content-Type", "")) if raw else json.loads(payload)
        except urllib.error.HTTPError as e:
            raise CFError(f"{e.code} {e.read()[:400].decode(errors='replace')}") from None

    def account(self):
        if not self.account_id:
            accts = self._req("GET", f"{API}/accounts")["result"]
            pick = next((a for a in accts if a["name"] == ACCOUNT_NAME), accts[0] if accts else None)
            if not pick:
                raise CFError("no Cloudflare account visible to this token")
            self.account_id = pick["id"]
        return self.account_id

    # ---- calls -------------------------------------------------------------------------------------------------
    def run(self, model, inputs, raw=False, timeout=None):
        """POST /ai/run/MODEL. JSON models return `result`; audio models (raw=True) return (bytes, content type)."""
        url = f"{API}/accounts/{self.account()}/ai/run/{model}"
        out = self._req("POST", url, inputs, raw=raw, timeout=timeout)
        if raw:
            payload, ctype = out
            if ctype.startswith("application/json"):
                j = json.loads(payload)
                res = j.get("result", j)
                if isinstance(res, dict) and res.get("audio"):  # some TTS models answer base64 in JSON
                    import base64
                    return base64.b64decode(res["audio"]), "audio/mpeg"
                raise CFError(f"expected audio from {model}, got {str(j)[:300]}")
            return payload, ctype
        if not out.get("success", True):
            raise CFError(str(out.get("errors"))[:400])
        return out.get("result", out)

    def models(self, task=None, search=None):
        q = []
        if task:
            q.append("task=" + urllib.request.quote(task))
        if search:
            q.append("search=" + urllib.request.quote(search))
        q.append("per_page=100")
        return self._req("GET", f"{API}/accounts/{self.account()}/ai/models/search?" + "&".join(q))["result"]


def _iso(s):
    import datetime
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


if __name__ == "__main__":
    import sys
    ai = WorkersAI()
    task = sys.argv[1] if len(sys.argv) > 1 else "Text-to-Speech"
    for m in ai.models(task=task):
        print(m["name"], "|", (m.get("description") or "")[:90].replace("\n", " "))
