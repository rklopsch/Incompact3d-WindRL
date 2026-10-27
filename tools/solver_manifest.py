import argparse
import hashlib
import json
import subprocess
from pathlib import Path


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args]).decode().strip()


def source_hash(root):
    digest = hashlib.sha256()
    paths = git(root, "ls-files", "--cached", "--others", "--exclude-standard", "--",
                "CMakeLists.txt", "src", "cmake", "tools").splitlines()
    for relative in sorted(set(paths)):
        path = root / relative
        if path.is_file() and "__pycache__" not in path.parts:
            digest.update(relative.encode())
            digest.update(path.read_bytes())
    return digest.hexdigest()


def binary_hash(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    binary = args.binary.resolve()
    manifest = binary.with_name("windrl-solver.json")
    if args.verify:
        data = json.loads(manifest.read_text())
        if data.get("protocol") != 2 or data.get("source_hash") != source_hash(root):
            raise SystemExit("Solver source/protocol changed: rebuild Incompact3d-WindRL")
        if data.get("binary_hash") != binary_hash(binary):
            raise SystemExit("Solver executable differs from its build manifest: rebuild Incompact3d-WindRL")
    else:
        data = {
            "protocol": 2,
            "components": ["ux", "uy", "uz", "p"],
            "commit": git(root, "rev-parse", "HEAD"),
            "dirty": bool(git(root, "status", "--porcelain", "--untracked-files=no")),
            "source_hash": source_hash(root),
            "binary_hash": binary_hash(binary),
        }
        manifest.write_text(json.dumps(data, indent=2) + "\n")
    print(json.dumps(data))


if __name__ == "__main__":
    main()