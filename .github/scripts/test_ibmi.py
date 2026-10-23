import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import yaml

import ibmi


class GitHubCITests(unittest.TestCase):
    def environment(self):
        return {
            "IBMI_ADDRESS": "ibmi.example.com",
            "IBMI_USERID": "builder",
            "SSH_PRIVATE_KEY": "test-placeholder",
            "SSH_KNOWN_HOSTS": "test-placeholder",
            "OBJECT_LIB": "GHPACK",
            "BUILD_DIR": "/home/builder/GitHubBuilds/ibm-i-packager",
            "GITHUB_SHA": "a" * 40,
            "GITHUB_RUN_ID": "123",
            "GITHUB_RUN_ATTEMPT": "2",
        }

    def test_environment(self):
        ibmi.validate_environment(self.environment())

    def test_rejects_missing_and_unsafe_configuration(self):
        for name, value in (
            ("OBJECT_LIB", "JWEIRICH2"),
            ("OBJECT_LIB", "GHPTSTSRC"),
            ("OBJECT_LIB", "GHTOOLONG123"),
            ("BUILD_DIR", "/home/builder/IBMiBuilds"),
            ("BUILD_DIR", "/home/builder/GitHubBuilds/../IBMiBuilds"),
            ("BUILD_DIR", "/home/builder/GitHubBuilds'; exit 0; '"),
            ("IBMI_USERID", "builder\nHost *"),
            ("IBMI_ADDRESS", "-oProxyCommand=anything"),
            ("IBMI_SSH_PORT", "65536"),
            ("GITHUB_SHA", "'"),
            ("GITHUB_RUN_ID", "../123"),
            ("SSH_PRIVATE_KEY", ""),
            ("DEPLOY_SAMPLES", "yes"),
        ):
            with self.subTest(name=name, value=value):
                with self.assertRaises(ValueError):
                    ibmi.validate_environment(dict(self.environment(), **{name: value}))

    def test_fixture_isolation_includes_embedded_sql_and_ifs_paths(self):
        source = (ibmi.ROOT / "test/qrpglesrc/pkgtest.test.sqlrpgle").read_text()
        isolated = ibmi.github_test_source(source)
        for original, replacement in ibmi.FIXTURES.items():
            self.assertNotIn(original, isolated)
            self.assertEqual(source.count(original), isolated.count(replacement))
        self.assertIn("CREATE TABLE GHPTSTSRC.TSTCUSTPF", isolated)
        self.assertIn("WHERE SYSTEM_OBJECT_SCHEMA = 'GHPTSTDTA'", isolated)
        self.assertIn("/include 'src/qrpglesrc/PKGTYPES.rpgleinc'", isolated)

    def test_fixture_generation_fails_on_missing_expected_names(self):
        with self.assertRaisesRegex(ValueError, "Missing expected test fixture"):
            ibmi.github_test_source("unexpected source")

    def test_rendered_commands_are_valid_bash(self):
        for component, job, inputs in (
            ("ibmi-cicd", "ibmi:build", {"build_lib": "GHPACK"}),
            ("ibmi-cicd", "ibmi:test", {"test_src": ibmi.GENERATED_TEST.as_posix()}),
            ("pack", "$[[ inputs.job_name ]]", {"src_lib": "GHPACK"}),
            ("unpack", "$[[ inputs.job_name ]]", {"default_lib": "GHPACK"}),
        ):
            with self.subTest(component=component, job=job):
                script = ibmi.component_script(component, job, inputs)
                self.assertNotIn("$[[", script)
                self.assertTrue(script.startswith("set -eo pipefail\n"))
                subprocess.run(["bash", "-n"], input=script, text=True, check=True)

    def test_unknown_inputs_fail(self):
        with self.assertRaisesRegex(ValueError, "Unknown component inputs"):
            ibmi.component_script("pack", "$[[ inputs.job_name ]]", {"typo": "x"})

    def test_junit_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "results.xml"
            for xml, valid in (
                ('<testsuite tests="1"><testcase name="ok"/></testsuite>', True),
                ('<testsuites><testsuite><testcase/></testsuite></testsuites>', True),
                ('<testsuite tests="0"/>', False),
                ('<testsuite><testcase><failure/></testcase></testsuite>', False),
                ('<testsuite><testcase><error/></testcase></testsuite>', False),
                ('<testsuite failures="1"><testcase/></testsuite>', False),
            ):
                with self.subTest(xml=xml):
                    path.write_text(xml)
                    if valid:
                        ibmi.verify_test_results(path)
                    else:
                        with self.assertRaises(ValueError):
                            ibmi.verify_test_results(path)

    def test_workflow_does_not_expose_secrets_to_pull_requests(self):
        with (ibmi.ROOT / ".github/workflows/ibmi.yml").open() as source:
            workflow = yaml.load(source, Loader=yaml.BaseLoader)
        self.assertEqual(set(workflow["on"]), {"push", "workflow_dispatch"})
        self.assertEqual(workflow["permissions"], {"contents": "read"})
        self.assertEqual(workflow["concurrency"]["cancel-in-progress"], "false")

    def run_pipeline(self, deploy=False, fail_stage=None):
        actual_root = ibmi.ROOT
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in ("test/qrpglesrc/pkgtest.test.sqlrpgle",
                             ".gitlab/ci/ibmi-pipeline.yml",
                             "templates/ibmi-cicd.yml", "templates/pack.yml",
                             "templates/unpack.yml"):
                destination = root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_text((actual_root / relative).read_text())
            stages = []

            def run(args, **kwargs):
                subprocess.run(["bash", "-n"], input=args[2], text=True, check=True)
                stage = kwargs["env"]["CI_JOB_ID"].removeprefix("gh_123_2_")
                stages.append(stage)
                if stage == fail_stage:
                    raise subprocess.CalledProcessError(1, args)
                if stage == "test":
                    (root / "rpgunit-results.xml").write_text(
                        '<testsuite><testcase name="passed"/></testsuite>'
                    )

            env = dict(self.environment(), DEPLOY_SAMPLES=str(deploy).lower())
            # Keep the real subprocess runner for Bash syntax validation.
            real_run = subprocess.run

            def mock_run(args, **kwargs):
                with patch("subprocess.run", real_run):
                    return run(args, **kwargs)

            with patch.object(ibmi, "ROOT", root), patch.dict(os.environ, env, clear=True):
                with patch.object(ibmi.subprocess, "run", side_effect=mock_run):
                    if fail_stage:
                        with self.assertRaises(subprocess.CalledProcessError):
                            ibmi.main()
                    else:
                        ibmi.main()
            self.assertFalse((root / ibmi.GENERATED_TEST).exists())
            return stages

    def test_automatic_pipeline_order(self):
        self.assertEqual(self.run_pipeline(), ["build", "test", "pack", "pack-samples"])

    def test_deployment_requires_explicit_opt_in(self):
        self.assertEqual(self.run_pipeline(deploy=True),
                         ["build", "test", "pack", "pack-samples", "unpack-samples"])

    def test_failed_tests_stop_packaging_and_clean_generated_source(self):
        self.assertEqual(self.run_pipeline(fail_stage="test"), ["build", "test"])


if __name__ == "__main__":
    unittest.main()
