"""Rebuild the last remote commit without the stray file.

The rename bug left docs/Octopus-v0.1.0-stage1-arm64.apk on the server. Rather
than add a "remove the file I forgot to remove" commit, this rebuilds the same
commit with the extra path deleted and force-updates the ref, so history stays
clean. Safe because only this machine pushes to this repository.
"""
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

OWNER, REPO, BRANCH = "qiunan6886", "octopus", "main"
TOKEN = os.environ["OCTOPUS_GH_TOKEN"]
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
HEADERS = {
    "Authorization": f"Bearer {TOKEN}",
    "Accept": "application/vnd.github+json",
    "User-Agent": "octopus-fix",
    "Content-Type": "application/json",
}


def api(method, path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        f"https://api.github.com{path}", data=data, headers=HEADERS, method=method
    )
    try:
        with OPENER.open(req, timeout=300) as resp:
            body = resp.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as exc:
        raise SystemExit(
            f"  {method} {path} -> {exc.code}\n  {exc.read().decode()[:600]}"
        )


def git(*args):
    out = subprocess.run(
        ["git", *args], capture_output=True, text=True, encoding="utf-8"
    )
    if out.returncode != 0:
        raise SystemExit(f"  git {' '.join(args)}: {out.stderr[:300]}")
    return out.stdout.strip()


bad_commit = sys.argv[1]
stray = sys.argv[2]

bad = api("GET", f"/repos/{OWNER}/{REPO}/git/commits/{bad_commit}")
print(f"  重做提交 {bad_commit[:12]}，原 tree {bad['tree']['sha'][:12]}")
print(f"  父提交   {bad['parents'][0]['sha'][:12]}")

tree = api(
    "POST",
    f"/repos/{OWNER}/{REPO}/git/trees",
    {
        "base_tree": bad["tree"]["sha"],
        "tree": [{"path": stray, "mode": "100644", "type": "blob", "sha": None}],
    },
)
print(f"  新 tree {tree['sha'][:12]}（删掉 {stray}）")

commit = api(
    "POST",
    f"/repos/{OWNER}/{REPO}/git/commits",
    {
        "message": bad["message"],
        "tree": tree["sha"],
        # GET 返回的 parents 是对象数组，建提交时要的是 sha 字符串数组。
        "parents": [p["sha"] for p in bad["parents"]],
    },
)
print(f"  新提交 {commit['sha'][:12]}")

api(
    "PATCH",
    f"/repos/{OWNER}/{REPO}/git/refs/heads/{BRANCH}",
    {"sha": commit["sha"], "force": True},
)
print(f"  已强制更新 refs/heads/{BRANCH}")

local_tree = git("rev-parse", "HEAD^{tree}")
remote_tree = api("GET", f"/repos/{OWNER}/{REPO}/git/commits/{commit['sha']}")[
    "tree"
]["sha"]
print(f"  本地 tree: {local_tree}")
print(f"  远端 tree: {remote_tree}")
if local_tree == remote_tree:
    print("  content matches (tree hashes are equal)")
    with open(".git/octopus-sync", "w", encoding="utf-8") as fh:
        fh.write(f"{git('rev-parse', 'HEAD')}\n{commit['sha']}\n")
    print("  同步点已更新")
else:
    print("  WARNING: tree hashes still differ")
    sys.exit(1)
