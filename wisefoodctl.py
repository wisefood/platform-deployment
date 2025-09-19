#!/usr/bin/env python3
from __future__ import annotations
import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import List, Optional

REPO_ROOT = Path(__file__).resolve().parent
ENV_DIR = REPO_ROOT / "environments"

TOOLS = {
    "tk": "tk",
    "helm": "helm",
    "kubectl": "kubectl",
    "jb": "jb",
}

INSTALLATION_URLS = {
    "tk_amd64": "https://github.com/grafana/tanka/releases/latest/download/tk-linux-amd64",
    "tk_arm64": [
        "https://github.com/grafana/tanka/releases/latest/download/tk-linux-arm",
        "https://github.com/grafana/tanka/releases/latest/download/tk-linux-arm64",
    ],
    "jb_amd64": "https://github.com/jsonnet-bundler/jsonnet-bundler/releases/latest/download/jb-linux-amd64",
    "jb_arm64": [
        "https://github.com/jsonnet-bundler/jsonnet-bundler/releases/latest/download/jb-linux-arm",
        "https://github.com/jsonnet-bundler/jsonnet-bundler/releases/latest/download/jb-linux-arm64",
    ],
}


def info(msg: str):
    print(f"[WISEFOOD-CTL] {msg}")


def error(msg: str):
    print(f"\033[91m[WISEFOOD-CTL] ERROR: {msg}\033[0m", file=sys.stderr)
    sys.exit(1)

def warning(msg: str):
    print(f"\033[93m[WISEFOOD-CTL] WARNING: {msg}\033[0m", file=sys.stderr)

def verify_choice(prompt: str) -> bool:
    while True:
        choice = input(f"{prompt} [y/n]: ").strip().lower()
        if choice in ["y", "yes"]:
            return True
        elif choice in ["n", "no"]:
            return False
        else:
            print("Please enter 'y' or 'n'.")

def run(cmd: List[str], check: bool = True, interactive: bool = False, cwd: Optional[Path] = None) -> int:
    print("→", " ".join(cmd), file=sys.stderr)
    stdin = None if interactive else subprocess.DEVNULL
    rc = subprocess.run(cmd, stdin=stdin, cwd=cwd).returncode
    if check and rc != 0:
        error(f"Command failed with exit code {rc}: {' '.join(cmd)}")
    return rc


def get_os_arch() -> str:
    import platform

    os_name = platform.system().lower()
    arch = platform.machine().lower()
    if os_name == "linux":
        if arch in ["x86_64", "amd64"]:
            return "amd64"
        elif arch in ["aarch64", "arm64", "armv8l"]:
            return "arm64"
        elif arch in ["armv7l", "armv6l"]:
            return "arm"
    error(f"Unsupported OS/Architecture: {os_name}/{arch}")
    sys.exit(1)


# ---------------------------
# Install helpers
# ---------------------------

def install_tanka(dest: str = "/usr/local/bin/tk", force: bool = False):
    arch = get_os_arch()
    if shutil.which("tk") and not force:
        info("tk already present; use --force to reinstall.")
        return

    url = INSTALLATION_URLS["tk_amd64"] if arch == "amd64" else INSTALLATION_URLS["tk_arm64"][1]
    run(["sudo", "curl", "-fsSL", "-o", dest, url], interactive=True)
    run(["sudo", "chmod", "a+x", dest], interactive=True)
    run(["tk", "version"], check=False)
    info("Tanka installed.")


def install_jb(dest: str = "/usr/local/bin/jb", force: bool = False):
    arch = get_os_arch()
    if shutil.which("jb") and not force:
        info("jb already present; use --force to reinstall.")
        return

    url = INSTALLATION_URLS["jb_amd64"] if arch == "amd64" else INSTALLATION_URLS["jb_arm64"][1]
    run(["sudo", "curl", "-fsSL", "-o", dest, url], interactive=True)
    run(["sudo", "chmod", "a+x", dest], interactive=True)
    run(["jb", "--version"], check=False)
    info("Jsonnet Bundler installed.")


def install_helm():
    # Uses official Helm install script; it invokes sudo if needed.
    cmd = ["bash", "-lc", "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"]
    run(cmd, interactive=True)
    run(["helm", "version"], check=False)
    info("Helm installed.")


# ---------------------------
# Repo checks and actions
# ---------------------------

def setup_dir_structure():
    if not ENV_DIR.exists():
        ENV_DIR.mkdir(parents=True)
        info(f"Created {ENV_DIR}")


def validate_tools():
    missing_tools = [name for name, cmd in TOOLS.items() if shutil.which(cmd) is None]
    if missing_tools:
        error(f"Missing required tools: {', '.join(missing_tools)}")


def validate_structure():
    if not ENV_DIR.exists() or not ENV_DIR.is_dir():
        error(f"Environments directory does not exist or is not a directory. Expected at: {ENV_DIR}")


def validate_setup():
    validate_tools()
    validate_structure()
    info("Deployment setup is valid.")


def list_envs() -> List[str]:
    if not ENV_DIR.exists():
        return []
    envs = []
    for p in sorted(ENV_DIR.iterdir()):
        if p.is_dir() and (p / "spec.json").exists():
            envs.append(p.name)
    return envs


def tk_apply(env_name: str, auto_approve: bool = False):
    validate_tools()
    path = ENV_DIR / env_name
    if not (path / "spec.json").exists():
        error(f"Environment '{env_name}' not found at {path}")
    cmd = ["tk", "apply", str(path)]
    if auto_approve:
        cmd.append("-y")
    run(cmd)


def tk_diff(env_name: str):
    validate_tools()
    path = ENV_DIR / env_name
    if not (path / "spec.json").exists():
        error(f"Environment '{env_name}' not found at {path}")
    run(["tk", "diff", str(path)])


def deps_update():
    validate_tools()
    run(["jb", "update"], cwd=REPO_ROOT)


def deps_vendor():
    validate_tools()
    run(["tk", "tool", "charts", "vendor"], cwd=REPO_ROOT)



def hard_init():
    warning("This will initialize the deployment setup and install required tools, potentially overwriting existing configurations.")
    if not verify_choice("Are you sure you want to proceed?"):
        info("Aborted.")
        return
    setup_dir_structure()
    install_jb()
    install_tanka()
    validate_tools()
    deps_update()
    deps_vendor()
    info("Initialized deployment setup.")

# ---------------------------
# CLI
# ---------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Wisefood Deployment Control Tool")
    sub = parser.add_subparsers(dest="cmd", required=True)

    # init
    p_init = sub.add_parser("init", help="Initialize directory structure")
    p_init.set_defaults(func=lambda args: (hard_init()))

    # validate
    p_validate = sub.add_parser("validate", help="Validate tools and repo structure")
    p_validate.set_defaults(func=lambda args: validate_setup())

    # list envs
    p_list = sub.add_parser("list", help="List available Tanka environments")
    p_list.set_defaults(func=lambda args: print("\n".join(list_envs()) or "(no environments)"))

    # plan (diff)
    p_plan = sub.add_parser("plan", help="Show diff for an environment")
    p_plan.add_argument("env", help="Environment name under ./environments")
    p_plan.set_defaults(func=lambda args: tk_diff(args.env))

    # deploy (apply)
    p_deploy = sub.add_parser("deploy", help="Apply an environment to the cluster")
    p_deploy.add_argument("env", help="Environment name under ./environments")
    p_deploy.add_argument("-y", "--yes", action="store_true", help="Auto-approve apply (-y)")
    p_deploy.set_defaults(func=lambda args: tk_apply(args.env, auto_approve=args.yes))

    # deps
    p_deps = sub.add_parser("deps", help="Manage Jsonnet/Helm chart dependencies")
    dsub = p_deps.add_subparsers(dest="deps_cmd", required=True)
    dsub.add_parser("update", help="Run 'jb update'").set_defaults(func=lambda a: deps_update())
    dsub.add_parser("vendor", help="Run 'tk tool charts vendor'").set_defaults(func=lambda a: deps_vendor())

    # install
    p_install = sub.add_parser("install", help="Install tooling (requires sudo)")
    isub = p_install.add_subparsers(dest="tool", required=True)

    it = isub.add_parser("tanka", help="Install Grafana Tanka")
    it.add_argument("--force", action="store_true")
    it.add_argument("--dest", default="/usr/local/bin/tk")
    it.set_defaults(func=lambda a: install_tanka(dest=a.dest, force=a.force))

    ij = isub.add_parser("jb", help="Install Jsonnet Bundler")
    ij.add_argument("--force", action="store_true")
    ij.add_argument("--dest", default="/usr/local/bin/jb")
    ij.set_defaults(func=lambda a: install_jb(dest=a.dest, force=a.force))

    ih = isub.add_parser("helm", help="Install Helm 3")
    ih.set_defaults(func=lambda a: install_helm())

    return parser


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
