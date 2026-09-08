#!/usr/bin/env python3
"""Read-only verifier for the adjacent Fable review input manifest."""
import hashlib
import json
import pathlib
import stat
import subprocess
import sys


def git(root, *arguments):
    result = subprocess.run(["/usr/bin/git", "-C", str(root), *arguments], capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors="replace").strip())
    return result.stdout


def head(root):
    try:
        return git(root, "rev-parse", "--verify", "HEAD").decode().strip()
    except RuntimeError:
        # An unborn HEAD is expected only when Git still identifies this checkout.
        git(root, "rev-parse", "--git-dir")
        return None


def branch(root):
    result = subprocess.run(["/usr/bin/git", "-C", str(root), "symbolic-ref", "--short", "-q", "HEAD"], capture_output=True)
    if result.returncode == 1:
        return None
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors="replace").strip())
    return result.stdout.decode().strip()


def status(root, excluded=()):
    entries = git(root, "status", "--porcelain=v1", "-z", "--untracked-files=all").decode().split("\0")
    result = []
    index = 0
    while index < len(entries):
        entry = entries[index]
        index += 1
        if not entry:
            continue
        value = {"status": entry[:2], "path": entry[3:]}
        if "R" in entry[:2] or "C" in entry[:2]:
            value["from"] = entries[index]
            index += 1
        if not any(value["path"].startswith(prefix) for prefix in excluded):
            result.append(value)
    return result


def fingerprint(path):
    path = pathlib.Path(path)
    if not path.exists() and not path.is_symlink():
        return {"missing": True}
    mode = stat.S_IMODE(path.lstat().st_mode)
    if path.is_symlink():
        return {"type": "symlink", "target": str(path.readlink()), "mode": mode}
    if not path.is_file():
        return {"type": "non-file", "mode": mode}
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return {"type": "file", "bytes": path.stat().st_size, "sha256": digest.hexdigest(), "mode": mode}


def runtime_files(root):
    root = pathlib.Path(root)
    return sorted(str(path.relative_to(root)) for path in root.rglob("*") if (path.is_file() or path.is_symlink()) and path.name != ".DS_Store")


def verify(manifest_path):
    manifest_path = pathlib.Path(manifest_path)
    original = manifest_path.read_bytes()
    manifest = json.loads(original)
    differences = []
    for repository in manifest["repositories"]:
        root = pathlib.Path(repository["path"])
        label = repository["name"]
        try:
            current_head = head(root)
            if current_head != repository["head"]:
                differences.append(label + ": HEAD changed")
            if branch(root) != repository["branch"]:
                differences.append(label + ": branch changed")
            if status(root, repository["excludedPrefixes"]) != repository["status"]:
                differences.append(label + ": Git status changed")
            current_diff = hashlib.sha256(git(root, "diff", "--binary", "HEAD") if current_head else b"").hexdigest()
            if current_diff != repository["trackedDiffSHA256"]:
                differences.append(label + ": tracked diff changed")
            for relative, expected in repository["files"].items():
                if fingerprint(root / relative) != expected:
                    differences.append(label + ": " + relative + " changed")
        except (OSError, RuntimeError) as error:
            differences.append(label + ": " + str(error))
    for path, expected in manifest["installedFiles"].items():
        try:
            if fingerprint(path) != expected:
                differences.append("installed: " + path + " changed")
        except OSError as error:
            differences.append("installed: " + str(error))
    for root, expected in manifest.get("runtimeRoots", {}).items():
        if runtime_files(root) != expected:
            differences.append("runtime file inventory changed: " + root)
    print(json.dumps({"manifestSHA256": hashlib.sha256(original).hexdigest(), "matched": not differences, "differences": differences}, indent=2))
    return 1 if differences else 0


if __name__ == "__main__":
    default = pathlib.Path(__file__).with_name("fable-5.1-review-inputs.json")
    sys.exit(verify(sys.argv[1] if len(sys.argv) > 1 else default))
