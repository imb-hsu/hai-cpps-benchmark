import contextlib
import io
import json
import unittest
from tempfile import TemporaryDirectory
from pathlib import Path
from unittest.mock import patch

import campaign
from campaign import prepare_shards, run_pool
from config import generate_single_fault_campaign, load_benchmark_config


REPOSITORY = Path(__file__).resolve().parents[1]


class CampaignTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = load_benchmark_config(
            REPOSITORY / "code" / "benchmark_setup.json"
        )

    def test_every_fault_run_has_exactly_one_true_boolean(self):
        for run in generate_single_fault_campaign(self.config):
            active = []
            for module_name, module in run.setup["model"]["modules"].items():
                active.extend(
                    (module_name, name)
                    for name, enabled in module["faults"].items()
                    if enabled
                )
            self.assertEqual(active, [(run.target_module, run.target_fault)])

    def test_campaign_inputs_are_not_mutated(self):
        generate_single_fault_campaign(self.config)
        for scenario in self.config.values():
            for module in scenario["model"]["modules"].values():
                self.assertFalse(any(module["faults"].values()))

    def test_v22_shard_startup_needs_no_separate_release_readme(self):
        config = REPOSITORY / "code" / "benchmark_setup.json"
        with TemporaryDirectory() as directory:
            output = Path(directory) / "results"
            manifests = {}
            prepare_shards(output, manifests, config, ("ds1",))
            shard = output / "ds1"
            manifest = manifests["ds1"]
            snapshot = shard / "generation"
            self.assertEqual(len(manifest["recordings"]), 28)
            self.assertEqual(manifest["status"], "running")
            self.assertTrue((shard / "campaign.json").is_file())
            self.assertTrue((snapshot / "requirements.txt").is_file())
            self.assertTrue((snapshot / "code" / "campaign.py").is_file())
            self.assertTrue((snapshot / "models" / "Mixer.mo").is_file())
            self.assertEqual(set(manifest["generation_sha256"]), {
                str(path.relative_to(snapshot))
                for path in snapshot.rglob("*") if path.is_file()
            })

    def _pool(self, root, failures=(), topologies=("ds1",),
              start_failure=None, coverage_failure=None):
        launched = []

        class Worker:
            def __init__(self, pid, exit_code):
                self.pid = pid
                self.exit_code = exit_code
                self.returncode = None
                self.polls = 0

            def poll(self):
                self.polls += 1
                if self.polls >= 2:
                    self.returncode = self.exit_code
                return self.returncode

        def start(plan, output, build, logs, config):
            scenario = plan[0].scenario_id
            launched.append(scenario)
            log_path = logs / f"{scenario}.log"
            if scenario == start_failure:
                raise OSError("worker could not be spawned")
            build_dir = build / plan[0].base_dataset / scenario
            build_dir.mkdir(parents=True, exist_ok=True)
            (build_dir / "compiled-model").write_text("build artifact")
            log = log_path.open("a")
            log.write("simulated worker failure\n" if scenario in failures else "completed\n")
            return Worker(len(launched), int(scenario in failures)), log, log_path

        def coverage(path, run):
            if run.scenario_id == coverage_failure:
                raise ValueError("invalid coverage artifact")
            return {"missing_command_ranges": [], "unvisited_controller_phases": []}

        with contextlib.redirect_stdout(io.StringIO()), \
                patch.object(campaign, "start_worker", side_effect=start), \
                patch.object(campaign, "coverage", side_effect=coverage), \
                patch.object(campaign, "duplicate_signal_groups", return_value=[]), \
                patch.object(campaign.time, "sleep"), \
                patch.object(campaign, "stop_workers") as stop, \
                patch.object(campaign, "check_campaign", return_value={
                    "valid": True, "recordings": 28, "shards": {}, "errors": [],
                }) as check:
            result = run_pool(root / "results", root / "build", root / "logs", 3,
                              topologies=topologies)
        stop.assert_not_called()
        return result, launched, check.call_count

    def test_multiple_recording_failures_do_not_stop_other_workers(self):
        failures = {"ds1_001_healthy", "ds1_001_mixer0_anom_valve_in0_persistent"}
        with TemporaryDirectory() as directory:
            root = Path(directory)
            result, launched, checks = self._pool(root, failures)
            manifest = json.loads((root / "results/ds1/campaign.json").read_text())
            failure_log = (root / "logs/failed_simulations.log").read_text()
            self.assertEqual(result, 1)
            self.assertEqual(len(launched), 28)
            self.assertEqual(set(manifest["failed"]), failures)
            self.assertEqual(manifest["blocked"], {})
            self.assertEqual(len(manifest["completed"]), 26)
            self.assertEqual(manifest["status"], "failed")
            self.assertEqual(checks, 0)
            self.assertFalse((root / "results/ds1_release_manifest.json").exists())
            self.assertFalse((root / "build/ds1/ds1_002_healthy").exists())
            for scenario in failures:
                self.assertIn(f"FAILED {scenario}:", failure_log)
                self.assertIn(str(root / "logs" / f"{scenario}.log"), failure_log)
                self.assertEqual(manifest["failed"][scenario]["exit_code"], 1)
                self.assertTrue((root / "build/ds1" / scenario / "compiled-model").is_file())

    def test_failed_healthy_control_blocks_its_faults_and_other_shards_finish(self):
        control = "ds1_016_healthy"
        with TemporaryDirectory() as directory:
            root = Path(directory)
            result, launched, _ = self._pool(root, {control}, ("ds1", "ds3"))
            ds1 = json.loads((root / "results/ds1/campaign.json").read_text())
            ds3 = json.loads((root / "results/ds3/campaign.json").read_text())
            self.assertEqual(result, 1)
            self.assertEqual(set(ds1["failed"]), {control})
            self.assertEqual(len(ds1["blocked"]), 12)
            self.assertEqual(len(ds1["completed"]), 15)
            self.assertFalse(any("_anom_" in scenario for scenario in launched
                                 if scenario.startswith("ds1_")))
            self.assertEqual(ds3["status"], "complete")
            self.assertEqual(len(ds3["completed"]), 26)
            failure_log = (root / "logs/failed_simulations.log").read_text()
            for scenario, details in ds1["blocked"].items():
                self.assertEqual(details["paired_healthy"], control)
                self.assertIn(f"BLOCKED {scenario}:", failure_log)

    def test_retry_clears_current_failures_and_keeps_failure_log_history(self):
        failure = "ds1_001_healthy"
        with TemporaryDirectory() as directory:
            root = Path(directory)
            first, _, _ = self._pool(root, {failure})
            second, launched, checks = self._pool(root)
            manifest = json.loads((root / "results/ds1/campaign.json").read_text())
            failure_log = (root / "logs/failed_simulations.log").read_text()
            self.assertEqual((first, second), (1, 0))
            self.assertIn(failure, launched)
            self.assertEqual(manifest["failed"], {})
            self.assertEqual(manifest["blocked"], {})
            self.assertEqual(len(manifest["completed"]), 28)
            self.assertEqual(manifest["status"], "complete")
            self.assertEqual(checks, 1)
            self.assertTrue((root / "results/ds1_release_manifest.json").is_file())
            self.assertFalse((root / "build/ds1" / failure).exists())
            self.assertEqual(failure_log.count(f"FAILED {failure}:"), 1)
            self.assertIn("28 completed, 0 failed, 0 blocked", failure_log)

    def test_worker_start_and_coverage_errors_are_recorded_and_queue_continues(self):
        for kind in ("start_failure", "coverage_failure"):
            with self.subTest(kind=kind), TemporaryDirectory() as directory:
                root = Path(directory)
                result, launched, _ = self._pool(root, **{kind: "ds1_016_healthy"})
                manifest = json.loads((root / "results/ds1/campaign.json").read_text())
                self.assertEqual(result, 1)
                self.assertEqual(len(launched), 16)
                self.assertEqual(len(manifest["completed"]), 15)
                self.assertEqual(len(manifest["blocked"]), 12)
                self.assertIn("error", manifest["failed"]["ds1_016_healthy"])
                self.assertFalse((root / "build/ds1/ds1_001_healthy").exists())
                if kind == "coverage_failure":
                    self.assertTrue((root / "build/ds1/ds1_016_healthy/compiled-model").is_file())


if __name__ == "__main__":
    unittest.main()
