"""Consumer-facing actions, rendered from the existing GitLab components."""

import base64
import binascii
import json
import os
from pathlib import Path
import re
import subprocess
import uuid

from ibmi import component_script, verify_test_results


NAME = r"[A-Z][A-Z0-9_#@]{0,9}"


def require_match(value, pattern, name):
    if not re.fullmatch(pattern, value):
        raise ValueError("Invalid action input: " + name)
    return value


def relative_path(value, workspace, name):
    require_match(value, r"[A-Za-z0-9_./-]+", name)
    path = Path(value)
    if path.is_absolute() or ".." in path.parts or not path.parts:
        raise ValueError(name + " must be a nonempty workspace-relative path")
    resolved = (workspace / path).resolve()
    if resolved == workspace or workspace not in resolved.parents:
        raise ValueError(name + " must stay inside the workspace")
    return value


def configuration(raw, workspace, env):
    operation = raw.get("operation") or "pack"
    if operation not in ("pack", "unpack", "ci"):
        raise ValueError("operation must be pack, unpack, or ci")
    for name in ("ibmi-address", "ibmi-userid", "ssh-private-key", "ssh-known-hosts"):
        if not raw.get(name):
            raise ValueError("Required action input: " + name)
    try:
        key = base64.b64decode("".join(raw["ssh-private-key"].split()), validate=True)
    except (binascii.Error, ValueError):
        raise ValueError("ssh-private-key must be valid base64") from None
    if not key:
        raise ValueError("ssh-private-key must decode to a nonempty key")
    require_match(raw["ibmi-address"], r"[A-Za-z0-9][A-Za-z0-9_.-]*", "ibmi-address")
    require_match(raw["ibmi-userid"], r"[A-Za-z0-9_]+", "ibmi-userid")
    port = raw.get("ibmi-ssh-port") or "22"
    if not port.isdigit() or not 1 <= int(port) <= 65535:
        raise ValueError("ibmi-ssh-port must be between 1 and 65535")
    # File-type GitLab variable paths are intentionally not accepted by actions.
    if "\n" not in raw["ssh-known-hosts"] and not raw["ssh-known-hosts"].strip().startswith(
            (raw["ibmi-address"], "[", "|1|")):
        raise ValueError("ssh-known-hosts must contain verified known_hosts entries")
    directory = relative_path(raw.get("artifact-dir") or "artifacts", workspace, "artifact-dir")
    manifest = raw.get("manifest-name") or (
        "unpack-manifest.html" if operation == "unpack" else "pack-manifest.html")
    require_match(manifest, r"[A-Za-z0-9_-][A-Za-z0-9_.-]*", "manifest-name")
    library = require_match(raw.get("packager-lib") or "PACKAGER", NAME, "packager-lib")
    inputs = {"packager_lib": library, "artifact_dir": directory, "manifest_name": manifest}
    if operation in ("pack", "ci"):
        source = require_match(raw.get("src-lib") or "PACKAGER", NAME, "src-lib")
        objects = raw.get("objects") or "*ALL"
        types = raw.get("object-types") or "*ALL"
        if not objects.split() or not types.split():
            raise ValueError("objects and object-types must not be blank")
        for token in objects.split():
            require_match(token, r"(?:\*ALL|[A-Z#@][A-Z0-9_#@]{0,9}\*?)", "objects")
        for token in types.split():
            require_match(token, r"\*[A-Z]+", "object-types")
        version = raw.get("version") or env["GITHUB_SHA"][:8]
        require_match(version, r"[A-Za-z0-9_.-]{1,10}", "version")
        release = require_match(raw.get("target-release") or "*CURRENT",
                                r"(?:\*CURRENT|\*PRV|V[0-9]R[0-9]M[0-9])", "target-release")
        filename = require_match(raw.get("stmf-name") or "package.savf",
                                 r"[A-Za-z0-9_-][A-Za-z0-9_.-]*", "stmf-name")
        inputs.update(src_lib=source, objects=" ".join(objects.split()), object_types=" ".join(types.split()),
                      version=version, target_release=release, stmf_name=filename)
    else:
        target = require_match(raw.get("default-lib") or "", NAME, "default-lib")
        package = relative_path(raw.get("stmf-artifact") or "artifacts/package.savf",
                                workspace, "stmf-artifact")
        if not (workspace / package).is_file():
            raise ValueError("Input package does not exist: " + package)
        mapping = raw.get("map-file") or "*NONE"
        if mapping != "*NONE":
            relative_path(mapping, workspace, "map-file")
            if not (workspace / mapping).is_file():
                raise ValueError("Mapping file does not exist: " + mapping)
        preserve = require_match(raw.get("copy-data") or "*YES", r"\*(?:YES|NO)", "copy-data")
        backup = require_match(raw.get("backup-savf") or "*NONE",
                               r"(?:\*NONE|" + NAME + "/" + NAME + ")", "backup-savf")
        inputs.update(default_lib=target, stmf_artifact=package, map_file=mapping,
                      copy_data=preserve, backup_savf=backup)
    if operation == "ci":
        build_dir = require_match(raw.get("build-dir") or "", r"/[A-Za-z0-9_./-]+", "build-dir")
        if ".." in build_dir.split("/") or len(Path(build_dir).parts) < 3:
            raise ValueError("build-dir must be a dedicated absolute IFS directory")
        test_source = raw.get("test-src") or "*NONE"
        if test_source != "*NONE":
            relative_path(test_source, workspace, "test-src")
            if not (workspace / test_source).is_file():
                raise ValueError("Test source does not exist: " + test_source)
        ci = {"build_lib": source, "test_src": test_source,
              "test_pgm": require_match(raw.get("test-pgm") or "TPKGTEST", NAME, "test-pgm"),
              "rpgunit_lib": require_match(raw.get("rpgunit-lib") or "RPGUNIT", NAME, "rpgunit-lib")}
    else:
        build_dir, ci = "", None
    return operation, inputs, ci, build_dir


def main():
    workspace = Path.cwd().resolve()
    raw = json.loads(os.environ["ACTION_INPUTS"])
    operation, inputs, ci, build_dir = configuration(raw, workspace, os.environ)
    output = workspace / inputs["artifact_dir"]
    output.mkdir(parents=True, exist_ok=True)
    if not os.access(output, os.W_OK):
        raise PermissionError("artifact-dir is not writable by the runner user; restore its ownership")
    for name in (inputs["manifest_name"], inputs.get("stmf_name")):
        if name and (output / name).exists() and not os.access(output / name, os.W_OK):
            raise PermissionError("An output file is not writable by the runner user: " + name)
    home = Path(os.environ["HOME"])
    home.mkdir(mode=0o700, parents=True, exist_ok=True)
    env = dict(os.environ, IBMI_ADDRESS=raw["ibmi-address"], IBMI_USERID=raw["ibmi-userid"],
               IBMI_SSH_PORT=raw.get("ibmi-ssh-port") or "22",
               SSH_PRIVATE_KEY=raw["ssh-private-key"], SSH_KNOWN_HOSTS=raw["ssh-known-hosts"],
               CI_PROJECT_DIR=str(workspace), CI_PROJECT_NAME=workspace.name,
               CI_COMMIT_SHORT_SHA=os.environ["GITHUB_SHA"][:8], BUILD_DIR=build_dir)
    stages = []
    if ci:
        stages.extend([("build", "ibmi-cicd", "ibmi:build", ci),
                       ("test", "ibmi-cicd", "ibmi:test", ci)])
    stages.append(("unpack" if operation == "unpack" else "pack",
                   "unpack" if operation == "unpack" else "pack", "$[[ inputs.job_name ]]", inputs))
    invocation = uuid.uuid4().hex
    for stage, component, job, options in stages:
        env["CI_JOB_ID"] = "gh_{}_{}_{}_{}".format(
            env["GITHUB_RUN_ID"], env["GITHUB_RUN_ATTEMPT"], stage, invocation)
        print("::group::IBM i " + stage, flush=True)
        try:
            script = component_script(component, job, options)
            script = "\n".join(line for line in script.splitlines()
                               if not line.startswith("apk add "))
            subprocess.run(["bash", "-c", script], cwd=workspace, env=env, check=True)
            if stage == "test" and ci["test_src"] != "*NONE":
                verify_test_results(workspace / "rpgunit-results.xml")
        finally:
            print("::endgroup::", flush=True)


if __name__ == "__main__":
    main()
