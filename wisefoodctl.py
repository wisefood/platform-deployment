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
from kubernetes import client, config
import string
import random
import base64

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


def run(
    cmd: List[str],
    check: bool = True,
    interactive: bool = False,
    cwd: Optional[Path] = None,
) -> int:
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

    url = (
        INSTALLATION_URLS["tk_amd64"]
        if arch == "amd64"
        else INSTALLATION_URLS["tk_arm64"][1]
    )
    run(["sudo", "curl", "-fsSL", "-o", dest, url], interactive=True)
    run(["sudo", "chmod", "a+x", dest], interactive=True)
    run(["tk", "version"], check=False)
    info("Tanka installed.")


def install_jb(dest: str = "/usr/local/bin/jb", force: bool = False):
    arch = get_os_arch()
    if shutil.which("jb") and not force:
        info("jb already present; use --force to reinstall.")
        return

    url = (
        INSTALLATION_URLS["jb_amd64"]
        if arch == "amd64"
        else INSTALLATION_URLS["jb_arm64"][1]
    )
    run(["sudo", "curl", "-fsSL", "-o", dest, url], interactive=True)
    run(["sudo", "chmod", "a+x", dest], interactive=True)
    run(["jb", "--version"], check=False)
    info("Jsonnet Bundler installed.")


def install_helm():
    # Uses official Helm install script; it invokes sudo if needed.
    cmd = [
        "bash",
        "-lc",
        "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash",
    ]
    run(cmd, interactive=True)
    run(["helm", "version"], check=False)
    info("Helm installed.")


# ---------------------------
# Environment & Secret Builders
# ---------------------------


def load_yaml(yaml_path: Path) -> dict:
    import yaml
    with open(yaml_path, "r") as f:
        return yaml.safe_load(f)


def generate_random_string(length=40, chunk_size=8, separator="-"):
    characters = string.ascii_letters + string.digits
    raw_string = "".join(random.choices(characters, k=length))
    chunks = [raw_string[i : i + chunk_size] for i in range(0, length, chunk_size)]
    return separator.join(chunks)

def create_and_apply_k8s_secret(secret_name: str, namespace: str, data_dict: dict):
    """
    Creates a Kubernetes secret and applies it to the cluster.

    Args:
        secret_name (str): Name of the secret.
        namespace (str): Kubernetes namespace.
        data_dict (dict): Dictionary containing secret data.
    """
    # Encode data to base64 as required by Kubernetes secrets
    encoded_data = {
        k: base64.b64encode(v.encode("utf-8")).decode("utf-8")
        for k, v in data_dict.items()
    }

    # Define the secret structure
    secret = client.V1Secret(
        api_version="v1",
        kind="Secret",
        metadata=client.V1ObjectMeta(name=secret_name, namespace=namespace),
        data=encoded_data,
        type="Opaque",
    )
    # Apply the secret to the Kubernetes cluster
    config.load_kube_config()
    v1 = client.CoreV1Api()
    try:
        v1.create_namespaced_secret(namespace=namespace, body=secret)
        info(f"Secret '{secret_name}' applied successfully.")
    except client.exceptions.ApiException as e:
        if e.status == 409:
            warning(f"Secret '{secret_name}' already exists in namespace '{namespace}'. Will not overwrite.")
        else:
            error(f"Failed to apply secret: {e}")


def generate_sample_yaml(file_path="example_config.yaml"):
    """
    Generates a YAML configuration file with sample values and comprehensive comments.
    """
    yaml_content = """# This is a sample configuration file for the WiseFood platform deployment. It is provided 
# as input to the bootstrap script for generating Kubernetes secrets and
# configuring the Tanka environment.

# Environment name (e.g., "staging", "production", "minikube.dev")
env: "minikube.dev"

# Define either "amazon" for AWS or "minikube" for local Kubernetes
platform: "minikube"

# The Kubernetes context to use
k8s_context: "minikube"

# The Kubernetes namespace for deployment
namespace: "wisefood-dev"

# The contact person for this configuration
author: "dpetrou@athenarc.gr"

dns:
  - domain: "minikube"  # DNS configuration name, could be "wisefood.gr" or "wisefood-project.eu" for public configs
  - scheme: "https"  # Scheme to use (e.g., "http" or "https")
  - subdomains:
    -  keycloak: "auth"  # Keycloak subdomain
    -  minio: "minio"  # MinIO subdomain
    -  primary: "app"  # Main application subdomain

config:
  - smtp: 
    - server: "@@YOUR_SMPT_SERVER_URL@@"  # SMTP server address
    - port: "465"  # SMTP port (e.g., 465 for SSL, 587 for TLS)
    - username: "@@YOUR_SMPT_SERVER_USERNAME@@"  # SMTP username for authentication

secrets:
  - sysadmin-pass: "##YOUR_PASSWORD_HERE##" # Password for WiseFood Administrator user 
  - postgres-db-pass: "##YOUR_PASSWORD_HERE##" # Password for PostgreSQL postgres (default) user
  - wisefood-db-pass: "##YOUR_PASSWORD_HERE##" # Password for PostgreSQL wisefood user
  - keycloak-db-pass: "##YOUR_PASSWORD_HERE##" # Password for PostgreSQL keycloak user 
  - smtp-pass: "##SMTP-PASSWORD##" # Password for SMTP server (mailing server)
  - session-secret: "##YOUR_SESSION_KEY_HERE##" # Secret key for session encryptions
    """
    with open(file_path, "w") as file:
        file.write(yaml_content)
    info(
        f"YAML sample configuration file '{file_path}' has been generated successfully."
    )


def generate_env_main(env_spec):
    pass

def generate_spec_json(env_name: str, env_spec: dict):
    path = ENV_DIR / env_name / 'spec.json'
    with open(path, "r") as spec_file:
        spec_data = json.load(spec_file)
    spec_data["metadata"][
        "namespace"
    ] = str(ENV_DIR / env_name / 'main.jsonnet')
    spec_data["spec"]["injectLabels"] = True
    spec_data["spec"]["resourceDefaults"]["annotations"] = {
        "wisefood.eu/author": env_spec["author"]
    }
    spec_data["spec"]["resourceDefaults"]["labels"] = {
        "app.kubernetes.io/managed-by": "tanka",
        "app.kubernetes.io/part-of": "wisefood",
        "wisefood.deployment": "main",
    }

    with open(path, "w") as json_file:
        json.dump(spec_data, json_file, indent=2)

    info(f"Environment {env_name}, spec.json file updated")
    
def generate_env(env_name, env_spec):
    # Generate the tanka env structure
    run(
        ["tk", "env", "add", str(ENV_DIR / env_name), "--context-name", env_spec["k8s_context"], "--namespace", env_spec["namespace"]],
        check=True,
    )

def generate_secrets(env_spec: dict):
    """
    Generate Kubernetes secrets based on the environment specification.

    Args:
        env_spec (dict): The environment specification containing secrets and namespace.
    """
    namespace = env_spec.get("namespace", "default")
    secrets = env_spec.get("secrets", {})
    for secret in secrets:
        for secret_name, secret_value in secret.items():
            create_and_apply_k8s_secret(
                secret_name=secret_name,
                namespace=namespace,
                data_dict={"password": secret_value},
            )
    info(f"Secrets for namespace '{namespace}' have been generated and applied.")

def create_env(config_yaml_path: str, force: bool = False):

    try:
        env_spec = load_yaml(config_yaml_path)
        env_name = env_spec["env"]
    except Exception as e:
        error(f"Could not parse deployment configuration file or generate environment: {e}")

    path = ENV_DIR / env_name
    if path.exists() and any(path.iterdir()) and not force:
        error(f"Environment '{env_name}' already exists at {path} and contains files. Use --force carefully if want to overwrite it.")
    path.mkdir(parents=True, exist_ok=force)
    generate_env(env_name, env_spec)
    info(f"Environment '{env_name}' created at {path}")
    generate_spec_json(env_name, env_spec)
    generate_secrets(env_spec)
    generate_env_main(env_spec)
   

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
        error(
            f"Environments directory does not exist or is not a directory. Expected at: {ENV_DIR}"
        )


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

def deps_update():
    validate_tools()
    run(["jb", "update"], cwd=REPO_ROOT)


def deps_vendor():
    validate_tools()
    run(["tk", "tool", "charts", "vendor"], cwd=REPO_ROOT)


def hard_init():
    warning(
        "This will initialize the deployment setup and install required tools, potentially overwriting existing configurations."
    )
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

    # sample
    p_sample = sub.add_parser(
        "sample", help="Generate a sample YAML configuration file"
    )
    p_sample.add_argument(
        "-o",
        "--output",
        default="example_config.yaml",
        help="Output file path (default: example_config.yaml)",
    )
    p_sample.set_defaults(func=lambda args: generate_sample_yaml(file_path=args.output))

    # init
    p_init = sub.add_parser("init", help="Initialize directory structure")
    p_init.set_defaults(func=lambda args: (hard_init()))

    # validate
    p_validate = sub.add_parser("validate", help="Validate tools and repo structure")
    p_validate.set_defaults(func=lambda args: validate_setup())

    # list envs
    p_list = sub.add_parser("list", help="List available Tanka environments")
    p_list.set_defaults(
        func=lambda args: print("\n".join(list_envs()) or "(no environments)")
    )

    # create environment
    p_deploy = sub.add_parser("env", help="Build an environment based on an input YAML file")
    p_deploy.add_argument("config_file", help="Path to deployment configuration file (.yaml or .yml)")
    p_deploy.add_argument("--force", action="store_true", help="Force environment creation, overwriting existing files")
    p_deploy.set_defaults(func=lambda args: create_env(config_yaml_path=args.config_file, force=args.force))

    # deps
    p_deps = sub.add_parser("deps", help="Manage Jsonnet/Helm chart dependencies")
    dsub = p_deps.add_subparsers(dest="deps_cmd", required=True)
    dsub.add_parser("update", help="Run 'jb update'").set_defaults(
        func=lambda a: deps_update()
    )
    dsub.add_parser("vendor", help="Run 'tk tool charts vendor'").set_defaults(
        func=lambda a: deps_vendor()
    )

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
