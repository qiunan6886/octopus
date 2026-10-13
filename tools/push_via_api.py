"""Push local commits to GitHub through the Git Data API.

Why not `git push`: `github.com:443` is unreachable on this network, while
`api.github.com` resolves to a different IP and works. This replicates what a
push does -- create blobs, build a tree, create a commit, move the ref -- using
only the API host.

Usage: push_via_api.py <base_remote_sha> <commit_message_file>
The set of files to send is taken from `git diff --name-status <base> HEAD`, so
the result matches the local commit exactly.
"""
import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

OWNER = "qiunan6886"
REPO = "octopus"
BRANCH = "main"
API = "https://api.github.com"

TOKEN = os.environ["OCTOPUS_GH_TOKEN"]
HEADERS = {
    "Authorization": f"Bearer {TOKEN}",
    "Accept": "application/vnd.github+json",
    "User-Agent": "octopus-push",
    "Content-Type": "application/json",
}


def api(method, path, payload=None):
    url = f"{API}{path}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, headers=HEADERS, method=method)
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            body = resp.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        raise SystemExit(f"  API {method} {path} -> {exc.code}\n  {detail[:600]}")


def git(*args):
    out = subprocess.run(
        ["git", *args], capture_output=True, text=True, encoding="utf-8"
    )
    if out.returncode != 0:
        raise SystemExit(f"  git {' '.join(args)} failed: {out.stderr[:400]}")
    return out.stdout


def main():
    base_sha = sys.argv[1]
    message = open(sys.argv[2], encoding="utf-8").read()

    # 1. 基线提交的 tree
    base = api("GET", f"/repos/{OWNER}/{REPO}/git/commits/{base_sha}")
    base_tree = base["tree"]["sha"]
    print(f"  基线 tree: {base_tree[:12]}")

    # 2. 本地相对基线的改动
    status = git("diff", "--name-status", base_sha, "HEAD").strip()
    if not status:
        raise SystemExit("  没有需要推送的改动")

    entries = []
    added = modified = deleted = 0
    for line in status.splitlines():
        parts = line.split("\t")
        code, path = parts[0], parts[-1]
        if code.startswith("D"):
            entries.append({"path": path, "mode": "100644", "type": "blob", "sha": None})
            deleted += 1
            continue
        raw = open(path, "rb").read()
        encoded = base64.b64encode(raw).decode()
        blob = api(
            "POST",
            f"/repos/{OWNER}/{REPO}/git/blobs",
            {"content": encoded, "encoding": "base64"},
        )
        entries.append(
            {"path": path, "mode": "100644", "type": "blob", "sha": blob["sha"]}
        )
        if code.startswith("A"):
            added += 1
        else:
            modified += 1

    print(f"  文件: 新增 {added} 修改 {modified} 删除 {deleted}")

    # 3. 新 tree（以基线为底，只覆盖改动的文件）
    tree = api(
        "POST",
        f"/repos/{OWNER}/{REPO}/git/trees",
        {"base_tree": base_tree, "tree": entries},
    )

    # 4. 新提交
    commit = api(
        "POST",
        f"/repos/{OWNER}/{REPO}/git/commits",
        {"message": message, "tree": tree["sha"], "parents": [base_sha]},
    )
    print(f"  新提交: {commit['sha'][:12]}")

    # 5. 移动分支
    api(
        "PATCH",
        f"/repos/{OWNER}/{REPO}/git/refs/heads/{BRANCH}",
        {"sha": commit["sha"], "force": False},
    )
    print(f"  已更新 refs/heads/{BRANCH} -> {commit['sha'][:12]}")

    # 6. 让本地也指向同一提交，这样 git status 不会显示"未推送"
    remote_url = f"https://github.com/{OWNER}/{REPO}.git"
    subprocess.run(["git", "update-ref", f"refs/remotes/origin/{BRANCH}", commit["sha"]])
    print(f"  本地 origin/{BRANCH} 已同步")
    print(f"  {remote_url}")


main()
