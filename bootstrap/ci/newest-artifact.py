#!/usr/bin/env python3
"""newest-artifact.py NAME [--any] -> id of the newest, unexpired artifact NAME from a SUCCESSFUL workflow run.

Why: the stage workflows pack and upload their tree even after a failure or a cancel (so a retry can resume), and
GitHub lists artifacts by id, not by success. "per_page=1" once handed stage 5 the half-built tree of a cancelled
stage 4b run: every ESO Base build after that shipped without iris/radeonsi/llvmpipe/Vulkan (software-only
desktop on most PCs). --any accepts unfinished runs too (stage 4b resume).
Needs GH_TOKEN and GITHUB_REPOSITORY."""
import json, os, sys, urllib.request

name = sys.argv[1]
any_run = "--any" in sys.argv[2:]
repo, tok = os.environ["GITHUB_REPOSITORY"], os.environ["GH_TOKEN"]


def get(path):
    req = urllib.request.Request("https://api.github.com/repos/" + repo + path,
                                 headers={"Authorization": "Bearer " + tok, "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


arts = [a for a in get(f"/actions/artifacts?name={name}&per_page=100")["artifacts"] if not a.get("expired")]
arts.sort(key=lambda a: a.get("created_at") or "", reverse=True)
for a in arts:
    run = (a.get("workflow_run") or {}).get("id")
    if any_run:
        ok = True
    else:
        try:
            ok = run is not None and get(f"/actions/runs/{run}").get("conclusion") == "success"
        except Exception as e:  # noqa: BLE001
            print(f"newest-artifact: run {run}: {e}", file=sys.stderr)
            ok = False
    if ok:
        print(f"newest-artifact: {name} = artifact {a['id']} from run {run} ({a.get('created_at')})", file=sys.stderr)
        print(a["id"])
        sys.exit(0)
    print(f"newest-artifact: skipping artifact {a['id']} (run {run} did not succeed)", file=sys.stderr)
sys.exit(f"newest-artifact: no usable {name} artifact")
