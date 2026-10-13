"""Push local commits to GitHub through the Git Data API.

Why not `git push`: on this network `github.com:443` is unreachable while
`api.github.com` resolves to a different, working IP. This replays each local
commit through the API instead -- create blobs, build a tree, create a commit,
move the ref -- which is exactly what a push does.

Commit history is preserved: each local commit becomes one remote commit.

Usage: push_via_api.py <remote_base_sha>
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

# urllib 在 Windows 上会读注册表里的系统代理。这里的系统代理指向一个已经关掉的
# 本地端口，于是每次请求都 ConnectionRefused。显式用空 ProxyHandler 绕过。
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def api(method, path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        f"{API}{path}", data=data, headers=HEADERS, method=method
    )
    try:
        with _OPENER.open(req, timeout=180) as resp:
            body = resp.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        raise SystemExit(f"  API {method} {path} -> {exc.code}\n  {detail[:800]}")
    except urllib.error.URLError as exc:
        raise SystemExit(f"  API {method} {path} -> 网络失败: {exc.reason}")


def git(*args, binary=False):
    out = subprocess.run(["git", *args], capture_output=True)
    if out.returncode != 0:
        raise SystemExit(
            f"  git {' '.join(args)} failed: {out.stderr.decode('utf-8', 'replace')[:400]}"
        )
    return out.stdout if binary else out.stdout.decode("utf-8", "replace")


def changed_files(parent, commit):
    """[(status, path)] for one commit. -z avoids git's path quoting."""
    raw = git("diff", "--name-status", "-z", parent, commit)
    fields = raw.split("\0")
    result = []
    i = 0
    while i < len(fields):
        code = fields[i]
        if not code:
            i += 1
            continue
        # 重命名会多出一个路径字段
        if code.startswith("R") or code.startswith("C"):
            result.append((code[0], fields[i + 2]))
            i += 3
        else:
            result.append((code[0], fields[i + 1]))
            i += 2
    return result


def main():
    base_sha = sys.argv[1]
    commits = git("rev-list", "--reverse", f"{base_sha}..HEAD").split()
    if not commits:
        raise SystemExit("  没有需要推送的提交")

    print(f"  远端基线: {base_sha[:12]}")
    print(f"  待推送提交: {len(commits)}")

    running = base_sha
    for sha in commits:
        subject = git("log", "-1", "--format=%s", sha).strip()
        message = git("log", "-1", "--format=%B", sha)

        base_tree = api("GET", f"/repos/{OWNER}/{REPO}/git/commits/{running}")["tree"][
            "sha"
        ]

        entries = []
        for code, path in changed_files(sha + "^", sha):
            if code == "D":
                entries.append(
                    {"path": path, "mode": "100644", "type": "blob", "sha": None}
                )
                continue
            content = git("cat-file", "blob", f"{sha}:{path}", binary=True)
            blob = api(
                "POST",
                f"/repos/{OWNER}/{REPO}/git/blobs",
                {"content": base64.b64encode(content).decode(), "encoding": "base64"},
            )
            entries.append(
                {"path": path, "mode": "100644", "type": "blob", "sha": blob["sha"]}
            )

        tree = api(
            "POST",
            f"/repos/{OWNER}/{REPO}/git/trees",
            {"base_tree": base_tree, "tree": entries},
        )
        commit = api(
            "POST",
            f"/repos/{OWNER}/{REPO}/git/commits",
            {"message": message, "tree": tree["sha"], "parents": [running]},
        )
        running = commit["sha"]
        print(f"    {sha[:8]} -> {running[:8]}  {subject[:60]}  ({len(entries)} 文件)")

    api(
        "PATCH",
        f"/repos/{OWNER}/{REPO}/git/refs/heads/{BRANCH}",
        {"sha": running, "force": False},
    )
    print(f"  已更新 refs/heads/{BRANCH} -> {running[:12]}")

    # API 创建的提交对象不在本地，所以不能拿它 update-ref。记下映射关系即可：
    # 本地 HEAD 的 tree 和远端一致，内容就是相同的。
    local_tree = git("rev-parse", "HEAD^{tree}").strip()
    remote_tree = api("GET", f"/repos/{OWNER}/{REPO}/git/commits/{running}")["tree"][
        "sha"
    ]
    with open(".git/octopus-remote-head", "w", encoding="utf-8") as fh:
        fh.write(f"{running}\n")
    print(f"  本地 HEAD tree: {local_tree}")
    print(f"  远端 main tree: {remote_tree}")
    if local_tree == remote_tree:
        print("  内容一致 ✓（tree 相同即逐字节相同）")
    else:
        print("  ⚠ tree 不一致，需要检查")
        sys.exit(1)


main()
