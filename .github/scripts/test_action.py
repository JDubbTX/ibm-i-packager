import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import yaml

import ibmi

spec = importlib.util.spec_from_file_location("packager_action", Path(__file__).with_name("action.py"))
action = importlib.util.module_from_spec(spec)
spec.loader.exec_module(action)


class ConsumerActionTests(unittest.TestCase):
    def inputs(self, **overrides):
        return dict({
            "ibmi-address": "ibmi.example.com", "ibmi-userid": "builder",
            "ssh-private-key": "dGVzdC1wbGFjZWhvbGRlcg==",
            "ssh-known-hosts": "ibmi.example.com ssh-ed25519 public-key",
            "src-lib": "MYAPP", "packager-lib": "TOOLS", "version": "1.1.0",
        }, **overrides)

    def test_all_metadata_inputs_render_for_their_operation(self):
        for relative, operation in (("action.yml", "pack"), ("actions/pack/action.yml", "pack"),
                                    ("actions/unpack/action.yml", "unpack")):
            with self.subTest(action=relative), tempfile.TemporaryDirectory() as directory:
                workspace = Path(directory)
                (workspace / "artifacts").mkdir()
                (workspace / "artifacts/package.savf").write_bytes(b"save-file")
                with (ibmi.ROOT / relative).open() as source:
                    metadata = yaml.safe_load(source)
                inputs = {key: str(value.get("default", "")) for key, value in metadata["inputs"].items()}
                inputs.update(self.inputs(**{"default-lib": "TARGET"}))
                actual, options, ci, _ = action.configuration(inputs, workspace, {"GITHUB_SHA": "a" * 40})
                self.assertEqual(actual, operation)
                self.assertIsNone(ci)
                script = ibmi.component_script(operation, "$[[ inputs.job_name ]]", options)
                subprocess.run(["bash", "-n"], input=script, text=True, check=True)

    def test_ci_consumes_callers_source_and_options(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            (workspace / "suite.test.sqlrpgle").write_text("consumer tests")
            operation, inputs, ci, build_dir = action.configuration(self.inputs(**{
                "operation": "ci", "build-dir": "/home/builder/ci-app",
                "test-src": "suite.test.sqlrpgle",
            }), workspace, {"GITHUB_SHA": "a" * 40})
            self.assertEqual(operation, "ci")
            self.assertEqual(ci["test_src"], "suite.test.sqlrpgle")
            self.assertEqual(ci["build_lib"], "MYAPP")
            self.assertEqual(inputs["packager_lib"], "TOOLS")
            self.assertEqual(build_dir, "/home/builder/ci-app")

    def test_rejects_invalid_or_injectable_inputs_before_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            for name, value in (
                ("operation", "delete"), ("src-lib", "APP;DLTLIB"),
                ("src-lib", "APP$USER"), ("objects", "A' ); exit; #"),
                ("object-types", "*PGM); DLTLIB"), ("version", "elevenchars1"),
                ("version", "$(id)"), ("artifact-dir", "../outside"),
                ("artifact-dir", "/tmp/output"), ("artifact-dir", "."),
                ("stmf-name", "../package.savf"), ("manifest-name", "x\nbad"),
                ("ibmi-address", "-oProxyCommand=x"), ("ibmi-userid", "user\nHost *"),
                ("ssh-known-hosts", "/tmp/known_hosts"), ("ibmi-ssh-port", "65536"),
                ("ssh-private-key", ""),
                ("ssh-private-key", "not base64!"),
            ):
                with self.subTest(name=name, value=value), self.assertRaises(ValueError):
                    action.configuration(self.inputs(**{name: value}), Path(directory),
                                         {"GITHUB_SHA": "a" * 40})

    def test_symlink_escape_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory) / "workspace"
            workspace.mkdir()
            (workspace / "outside").symlink_to(Path(directory), target_is_directory=True)
            with self.assertRaises(ValueError):
                action.relative_path("outside/results", workspace, "artifact-dir")

    def test_unpack_requires_existing_package_and_explicit_target(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            for target in ("", "*SAVLIB", "TARGET"):
                with self.subTest(target=target), self.assertRaises(ValueError):
                    action.configuration(self.inputs(**{
                        "operation": "unpack", "default-lib": target,
                    }), workspace, {"GITHUB_SHA": "a" * 40})

    def test_runner_uses_action_templates_but_writes_in_consumer_workspace(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            raw = self.inputs()
            env = dict(os.environ, ACTION_INPUTS=json.dumps(raw), GITHUB_SHA="a" * 40,
                       GITHUB_RUN_ID="123", GITHUB_RUN_ATTEMPT="1", HOME=str(workspace / "home"))
            with patch.object(action.Path, "cwd", return_value=workspace):
                with patch.dict(os.environ, env), patch.object(action.subprocess, "run") as run:
                    action.main()
            args, kwargs = run.call_args
            self.assertEqual(kwargs["cwd"], workspace)
            self.assertEqual(kwargs["env"]["CI_PROJECT_DIR"], str(workspace))
            self.assertNotIn("apk add ", args[0][2])
            self.assertIn("TOOLS", args[0][2])
            self.assertIn("MYAPP", args[0][2])

    def test_ci_failure_prevents_packaging(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            raw = self.inputs(**{"operation": "ci", "build-dir": "/home/builder/app"})
            env = dict(os.environ, ACTION_INPUTS=json.dumps(raw), GITHUB_SHA="a" * 40,
                       GITHUB_RUN_ID="123", GITHUB_RUN_ATTEMPT="1", HOME=str(workspace / "home"))
            with patch.object(action.Path, "cwd", return_value=workspace):
                with patch.dict(os.environ, env), patch.object(action.subprocess, "run") as run:
                    run.side_effect = subprocess.CalledProcessError(1, ["bash"])
                    with self.assertRaises(subprocess.CalledProcessError):
                        action.main()
                    self.assertEqual(run.call_count, 1)

    def test_invocations_in_same_workflow_get_distinct_remote_workspaces(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            env = dict(os.environ, ACTION_INPUTS=json.dumps(self.inputs()),
                       GITHUB_SHA="a" * 40, GITHUB_RUN_ID="123", GITHUB_RUN_ATTEMPT="1",
                       HOME=str(workspace / "home"))
            with patch.object(action.Path, "cwd", return_value=workspace):
                with patch.dict(os.environ, env), patch.object(action.subprocess, "run") as run:
                    action.main()
                    action.main()
            job_ids = [call.kwargs["env"]["CI_JOB_ID"] for call in run.call_args_list]
            self.assertEqual(len(set(job_ids)), 2)

    def test_unwritable_artifact_directory_fails_before_ssh(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            env = dict(os.environ, ACTION_INPUTS=json.dumps(self.inputs()),
                       GITHUB_SHA="a" * 40, GITHUB_RUN_ID="123", GITHUB_RUN_ATTEMPT="1")
            with patch.object(action.Path, "cwd", return_value=workspace):
                with patch.dict(os.environ, env), patch.object(action.os, "access", return_value=False):
                    with patch.object(action.subprocess, "run") as run:
                        with self.assertRaisesRegex(PermissionError, "not writable"):
                            action.main()
                        run.assert_not_called()

    def test_dogfood_restores_ownership_before_non_root_actions(self):
        with (ibmi.ROOT / ".github/workflows/ibmi.yml").open() as source:
            steps = yaml.safe_load(source)["jobs"]["ibmi"]["steps"]
        restore = next(i for i, step in enumerate(steps)
                       if step.get("name") == "Restore artifact ownership")
        smoke = next(i for i, step in enumerate(steps) if step.get("uses") == "./")
        self.assertLess(restore, smoke)

    def test_rendered_pack_and_unpack_execute_with_mock_transport(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            commands = workspace / "bin"
            commands.mkdir()
            programs = {
                "ssh-keygen": "exit 0",
                "ssh-agent": "printf 'SSH_AUTH_SOCK=/tmp/fake-agent; export SSH_AUTH_SOCK;\\n'",
                "ssh-add": "exit 0",
                "ssh": 'printf "%s\\n" "$*" >> "$TRANSPORT_LOG"',
                "scp": '''
printf "%s\\n" "$*" >> "$TRANSPORT_LOG"
destination="${@: -1}"
if [[ "$destination" != ibmi-target:* ]]; then
  if [[ "$destination" == */ ]]; then
    printf savefile > "$destination/package.savf"
    printf manifest > "$destination/pack-manifest.html"
  else
    printf manifest > "$destination"
  fi
fi
''',
            }
            for name, script in programs.items():
                path = commands / name
                path.write_text("#!/bin/bash\nset -e\n" + script + "\n")
                path.chmod(0o700)
            log = workspace / "transport.log"
            env = dict(os.environ, PATH=str(commands) + ":" + os.environ["PATH"],
                       TRANSPORT_LOG=str(log), HOME=str(workspace / "home"), GITHUB_SHA="a" * 40,
                       GITHUB_RUN_ID="123", GITHUB_RUN_ATTEMPT="1")
            with patch.object(action.Path, "cwd", return_value=workspace):
                for operation in ("pack", "unpack"):
                    raw = self.inputs(**{"operation": operation, "default-lib": "TARGET"})
                    with patch.dict(os.environ, dict(env, ACTION_INPUTS=json.dumps(raw))):
                        action.main()
            self.assertEqual((workspace / "artifacts/package.savf").read_text(), "savefile")
            self.assertEqual((workspace / "artifacts/unpack-manifest.html").read_text(), "manifest")
            transport = log.read_text()
            self.assertIn("TOOLS", transport)
            self.assertIn("TARGET", transport)
            self.assertIn("gh_123_1_pack", transport)
            self.assertIn("gh_123_1_unpack", transport)

    def test_launch_script_syntax(self):
        subprocess.run(["bash", "-n", str(ibmi.ROOT / ".github/scripts/run-action.sh")], check=True)


if __name__ == "__main__":
    unittest.main()
