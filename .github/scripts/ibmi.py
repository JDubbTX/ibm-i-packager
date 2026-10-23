"""Run this project's GitLab component commands inside the GitHub Alpine runner."""

import os
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

import yaml


ROOT = Path(__file__).resolve().parents[2]
INPUT = re.compile(r"\$\[\[\s*inputs\.([a-z_]+)\s*\]\]")
GENERATED_TEST = Path(".github/generated/github.test.sqlrpgle")
FIXTURES = {
    "PKGTSTSRC": "GHPTSTSRC",
    "PKGTSTTGT": "GHPTSTTGT",
    "PKGTSTDTA": "GHPTSTDTA",
    "PKGTSTPGM": "GHPTSTPGM",
    "/tmp/pkgtest_": "/tmp/gh_pkgtest_",
}


def component_script(component, job_name, overrides):
    """Render only before_script/script; workflow orchestration stays in Actions."""
    with (ROOT / "templates" / (component + ".yml")).open() as source:
        spec, jobs = yaml.safe_load_all(source)
    inputs = {name: value["default"] for name, value in spec["spec"]["inputs"].items()}
    unknown = overrides.keys() - inputs.keys()
    if unknown:
        raise ValueError("Unknown component inputs: " + ", ".join(sorted(unknown)))
    inputs.update(overrides)
    job = jobs[job_name]
    commands = job["before_script"] + job["script"]
    if not all(isinstance(command, str) for command in commands):
        raise ValueError("Component commands must be strings")
    script = INPUT.sub(lambda match: inputs[match[1]], "\n".join(commands))
    if "$[[" in script:
        raise ValueError("Unresolved component input")
    return "set -eo pipefail\n" + script + "\n"


def github_test_source(source):
    # Replace SQL schema literals as well as RPG constants and JSON/IFS paths.
    for original, replacement in FIXTURES.items():
        if original not in source:
            raise ValueError("Missing expected test fixture: " + original)
        source = source.replace(original, replacement)
    return source


def verify_test_results(path):
    root = ET.parse(path).getroot()
    cases = list(root.iter("testcase"))
    if not cases:
        raise ValueError("iRPGUnit did not report any test cases")
    if (next(root.iter("failure"), None) is not None
            or next(root.iter("error"), None) is not None):
        raise ValueError("iRPGUnit reported failures or errors")
    for suite in root.iter():
        if suite.tag in ("testsuite", "testsuites"):
            if int(suite.get("failures", "0")) or int(suite.get("errors", "0")):
                raise ValueError("iRPGUnit reported failures or errors")
    print("iRPGUnit: {} test cases passed".format(len(cases)), flush=True)


def validate_environment(env):
    for name in ("IBMI_ADDRESS", "IBMI_USERID", "SSH_PRIVATE_KEY", "SSH_KNOWN_HOSTS",
                 "OBJECT_LIB", "BUILD_DIR", "GITHUB_SHA", "GITHUB_RUN_ID",
                 "GITHUB_RUN_ATTEMPT"):
        if not env.get(name):
            raise ValueError("Required GitHub secret/variable is missing: " + name)
    if not re.fullmatch(r"GH[A-Z0-9_]{0,8}", env["OBJECT_LIB"]):
        raise ValueError("GitHub OBJECT_LIB must start with GH and be at most 10 characters")
    if env["OBJECT_LIB"] in FIXTURES.values():
        raise ValueError("OBJECT_LIB must not be a test fixture library")
    path = env["BUILD_DIR"]
    if (not re.fullmatch(r"/[A-Za-z0-9_./-]+", path)
            or ".." in path.split("/") or "/github" not in path.lower()):
        raise ValueError("BUILD_DIR must be an absolute, shell-safe GitHub-specific path")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", env["IBMI_ADDRESS"]):
        raise ValueError("IBMI_ADDRESS must be a hostname or IPv4 address")
    if not re.fullmatch(r"[A-Za-z0-9_]+", env["IBMI_USERID"]):
        raise ValueError("IBMI_USERID must be an IBM i user profile")
    port = env.get("IBMI_SSH_PORT", "22")
    if not port.isdigit() or not 1 <= int(port) <= 65535:
        raise ValueError("IBMI_SSH_PORT must be between 1 and 65535")
    for name in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT"):
        if not env[name].isdigit():
            raise ValueError(name + " must be numeric")
    if not re.fullmatch(r"[0-9a-f]{40,64}", env["GITHUB_SHA"]):
        raise ValueError("GITHUB_SHA must be a full Git commit hash")
    if env.get("DEPLOY_SAMPLES", "false") not in ("true", "false"):
        raise ValueError("DEPLOY_SAMPLES must be true or false")


def main():
    env = os.environ.copy()
    validate_environment(env)
    env.update(
        CI_PROJECT_DIR=str(ROOT),
        CI_PROJECT_NAME=ROOT.name,
        CI_COMMIT_SHORT_SHA=env["GITHUB_SHA"][:8],
    )
    library = env["OBJECT_LIB"]
    common = {"build_lib": library, "packager_lib": library,
              "test_src": GENERATED_TEST.as_posix()}
    with (ROOT / ".gitlab/ci/ibmi-pipeline.yml").open() as source:
        includes = yaml.safe_load(source)["include"]
    # Consume the same sample object selection and package names as GitLab.
    sample_pack = dict(includes[1]["inputs"], src_lib=library, packager_lib=library)
    sample_unpack = dict(includes[2]["inputs"], default_lib=library, packager_lib=library)
    stages = [
        ("build", "ibmi-cicd", "ibmi:build", common),
        ("test", "ibmi-cicd", "ibmi:test", common),
        ("pack", "pack", "$[[ inputs.job_name ]]", {
            "src_lib": library, "packager_lib": library,
            "objects": includes[0]["inputs"]["objects"],
            "object_types": includes[0]["inputs"]["object_types"],
        }),
        ("pack-samples", "pack", "$[[ inputs.job_name ]]", sample_pack),
    ]
    if env.get("DEPLOY_SAMPLES") == "true":
        stages.append(("unpack-samples", "unpack", "$[[ inputs.job_name ]]", sample_unpack))
    isolated_source = github_test_source(
        (ROOT / "test/qrpglesrc/pkgtest.test.sqlrpgle").read_text()
    )
    generated = ROOT / GENERATED_TEST
    generated.parent.mkdir(parents=True, exist_ok=True)
    generated.write_text(isolated_source)
    try:
        for stage, component, job, inputs in stages:
            print("::group::IBM i " + stage, flush=True)
            env["CI_JOB_ID"] = "gh_{}_{}_{}".format(
                env["GITHUB_RUN_ID"], env["GITHUB_RUN_ATTEMPT"], stage
            )
            try:
                subprocess.run(["bash", "-c", component_script(component, job, inputs)],
                               cwd=ROOT, env=env, check=True)
                if stage == "test":
                    verify_test_results(ROOT / "rpgunit-results.xml")
            finally:
                print("::endgroup::", flush=True)
    finally:
        generated.unlink()
        generated.parent.rmdir()


if __name__ == "__main__":
    main()
