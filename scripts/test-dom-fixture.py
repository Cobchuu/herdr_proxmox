"""Loopback operations fixture for native DOM UI verification.

This uses the production session handler and disposable organization storage.
All operational data and mutations below are deterministic simulation; it never
installs tools, updates services, changes SSH, deploys, or reads real projects.
The OperationsFixture class can also be attached to preview-jaspr.py.
"""
import argparse
import importlib.util
import json
from http.server import ThreadingHTTPServer
from pathlib import Path
import sys
import tempfile
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "web/gateway"))
import server
from organizations import OrganizationStore


class OperationsFixture:
    def __init__(self):
        self.actions = []
        self.mode = "lan"
        self.key_count = 0
        self.setup_id = None
        self.setup_count = 0
        self.logs = [dict(id="dom-log", label="Maya snapshot", size_bytes=48,
                          pane="w1:p1", source="visible", created_at="2026-10-13T12:00:00Z",
                          download_allowed=True)]
        self.run = dict(id="dom-exact-build", target="a" * 40, repository="demo",
                        state="complete", command="validate exact commit",
                        checks=[dict(id="unit", name="Unit tests", status="passed", duration_ms=12, exit_code=0)],
                        artifact=dict(bytes=3, sha256="demo-static-package-hash"),
                        deployment_package=dict(bytes=3, sha256="demo-gateway-package-hash",
                                                required_checks_verified=True, checks=[]))
        self.deployment = dict(state="idle", installed="dom-preview", latest="dom-preview-v2",
                               available=True, supported=True, rollback_available=True,
                               provenance_repairable=True, deployment_mode="local")
        self.base_plan = dict(path="demo", branch="main", base="origin/main",
                              head="b" * 40, target="c" * 40)
        self.event = dict(id="dom-event", name="Maya", repository="demo", path="/projects/demo",
                          target="a" * 40, state="validation_pending", updated_at="2026-10-13T12:00:00Z",
                          verification=dict(target_incorporated=True, conflicts=0, merging=False),
                          tests=dict(status="not_run", summary="Pinned SDK not installed"),
                          blocker_label="missing_toolchain", job_id="dom-job",
                          recovery=dict(ref="refs/herdr/recovery/dom-event", commit="d" * 40))
        self.config = dict(repository="demo", organization_id="demo-org", enabled=False,
                           profile_id="demo-coordinator", coordinator_state="persona_sent")

    def get(self, path):
        endpoint = urlsplit(path).path.removeprefix("/api/")
        if endpoint == "__fixture/actions":
            return {"actions": self.actions}
        if endpoint == "validation":
            return dict(runs=[self.run], executor="service", queued=0)
        if endpoint == "build":
            return dict(build_id="dom-running-build", source_sha="b" * 40,
                        package_version="dom-preview", deployment_mode="local")
        if endpoint in ("updates", "updates/check"):
            return dict(self.deployment)
        if endpoint == "updates/alphas":
            return dict(releases=[dict(version="dom-preview-alpha", notes="Simulated alpha build.")])
        if endpoint == "sdk":
            return dict(supported=True, state="idle", toolchains={
                "dart": dict(label="Dart", installed=False, required="3.12.0", declared_by="Demo catalog")})
        if endpoint == "ssh-access":
            return dict(key_count=self.key_count)
        if endpoint == "dashboard-access":
            return dict(mode=self.mode, pending_mode=None)
        if endpoint == "cli-setup":
            return dict(clis=[dict(id=key, name=name, installed=True,
                                  status="not_configured", detail="Simulated provider; use no real credentials.",
                                  integration=dict(current=True, version="demo"))
                              for key, name in [("codex", "Codex"), ("claude", "Claude Code")]],
                        integrations=dict(total=2, connected=2, outdated=0, missing=0))
        if endpoint == "logs":
            return dict(logs=self.logs, total_bytes=sum(log["size_bytes"] for log in self.logs))
        if endpoint == "integration":
            return dict(checked="2026-10-13T12:00:00Z", coordination=dict(
                configurations=[self.config], events=[self.event], recoveries=[self.event], audit=[]))
        return None

    def post(self, path, body):
        endpoint = urlsplit(path).path.removeprefix("/api/")
        supported = (endpoint.startswith(("updates/", "cli-setup/", "integration/", "logs/")) or
                     endpoint in ("projects/browse", "projects/git", "sdk/install", "ssh-access/add", "dashboard-access", "validation/run"))
        if not supported:
            return None
        self.actions.append(dict(endpoint=endpoint, body=body))
        if endpoint in ("updates/check", "updates/alphas"):
            return self.get(path)
        if endpoint.startswith("updates/"):
            return dict(state="queued", simulated=True)
        if endpoint == "sdk/install":
            return dict(state="queued", toolchain=body["toolchain"], simulated=True)
        if endpoint == "ssh-access/add":
            self.key_count += 1
            return dict(key_count=self.key_count, added=True)
        if endpoint == "dashboard-access":
            if body.get("mode") == "ssh" and (not body.get("tunnel_ready") or self.key_count < 1):
                raise ValueError("A configured SSH key and tested tunnel are required.")
            self.mode = body["mode"]
            return dict(pending_mode=self.mode)
        if endpoint == "cli-setup/start":
            self.setup_count += 1
            self.setup_id = f"dom-setup-{self.setup_count}"
            return dict(id=self.setup_id)
        if endpoint == "cli-setup/poll":
            return dict(output="" if body.get("cursor") else "\x1b[32mProvider sign-in (simulated)\x1b[0m\r\nhttps://example.com/sign-in\r\nUse arrows and Enter to choose.\r\n", cursor=1, running=True)
        if endpoint == "cli-setup/close":
            self.setup_id = None
            return {}
        if endpoint in ("cli-setup/input", "cli-setup/resize"):
            return {}
        if endpoint in ("cli-setup/verify", "cli-setup/install_integration"):
            return dict(detail="Simulated account operation completed.")
        if endpoint == "logs/preview":
            return dict(text="Simulated retained terminal text.\n", truncated=False)
        if endpoint == "logs/ticket":
            return dict(ticket="fixture-ticket", mode=body["mode"])
        if endpoint == "logs/delete":
            self.logs = [log for log in self.logs if log["id"] != body["id"]]
            return {}
        if endpoint == "logs/save":
            self.logs.append(dict(id=f"dom-log-{len(self.logs)+1}", label=body["label"],
                                  pane=body["pane"], source=body["source"], size_bytes=48,
                                  created_at="2026-10-13T12:00:00Z", download_allowed=True))
            return {}
        if endpoint == "projects/browse":
            path = body.get("path", "")
            if path == "demo/README.md":
                return dict(kind="file", path=path, size=45, binary=False, content="# DOM fixture\n\nRead-only project preview.\n")
            return dict(kind="folder", root="/projects", entries=[dict(
                name="demo" if not path else "README.md", path="demo" if not path else "demo/README.md",
                kind="folder" if not path else "file", size=None if not path else 45,
                modified="2026-10-13T12:00:00Z")])
        if endpoint == "projects/git":
            if body.get("action") == "update_base":
                return dict(state="complete")
            if body.get("file"):
                return dict(diff="diff --git a/README.md b/README.md\n+Native DOM dashboard\n", truncated=False)
            return dict(repository=True, repository_path="demo", base_update=self.base_plan,
                        worktrees=[dict(path="demo", cwd="/projects/demo", branch="main", commit="b" * 40,
                                        upstream="origin/main", ahead=0, behind=1, base="origin/main",
                                        base_behind=1, checkout_role="shared", conflicts=0,
                                        counts=dict(added=0, deleted=0, modified=1),
                                        changes=[dict(path="README.md", status=" M", kind="modified")])])
        if endpoint == "integration/configure":
            self.config.update(body)
        return dict(simulated=True)


class FixtureHandler(server.Handler):
    def do_GET(self):
        if self.path.startswith("/api/") and self.path not in ("/api/session", "/api/snapshot", "/api/organizations/state", "/api/organizations/directory"):
            if not self.authenticated():
                return
            if urlsplit(self.path).path == "/api/validation/artifact":
                self.send_response(200); self.send_header("Content-Length", "3"); self.end_headers(); self.wfile.write(b"dom"); return
            if urlsplit(self.path).path == "/api/validation/log":
                content = b"Simulated exact-commit build log.\n"
                self.send_response(200); self.send_header("Content-Length", str(len(content))); self.end_headers(); self.wfile.write(content); return
            response = self.server.operations.get(self.path)
            if response is not None:
                self.reply(200, response); return
            if self.path.startswith("/api/notifications"):
                self.reply(200, {}); return
        super().do_GET()

    def do_POST(self):
        if self.path.startswith("/api/") and self.path not in ("/api/session", "/api/session/logout"):
            if not self.authenticated():
                return
            # Leave unrelated gateway endpoints' bodies unread.
            endpoints = ("updates/", "cli-setup/", "integration/", "logs/", "projects/", "sdk/install", "ssh-access/add", "dashboard-access", "validation/run")
            if self.path.removeprefix("/api/").startswith(endpoints):
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
                try:
                    response = self.server.operations.post(self.path, body)
                except ValueError as error:
                    self.reply(400, {"error": str(error)}); return
                self.reply(200, response or {}); return
        super().do_POST()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8794)
    args = parser.parse_args()
    server.ROOT = ROOT / "web/jaspr_dashboard/build/web"
    spec = importlib.util.spec_from_file_location("dom_agent_fixture", ROOT / "scripts/preview-agents.py")
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    with tempfile.TemporaryDirectory(prefix="herdr-dom-operations-") as folder:
        projects = Path(folder) / "projects"; projects.mkdir()
        mock = module.MockHerdr(); server.command = mock.command; server.PROJECTS = projects
        store = OrganizationStore(Path(folder) / "organizations.sqlite3", projects, mock.command)
        http = ThreadingHTTPServer(("127.0.0.1", args.port), FixtureHandler)
        http.token = "jaspr-preview-token"; http.sessions = server.BrowserSessions(); http.organizations = store
        http.operations = OperationsFixture()
        print(f"Simulated DOM operations: http://127.0.0.1:{args.port}/ · token jaspr-preview-token", flush=True)
        try:
            http.serve_forever()
        finally:
            http.server_close(); store.close()


if __name__ == "__main__":
    main()
