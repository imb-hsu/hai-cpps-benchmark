"""Isolated and checked OpenModelica execution."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Mapping, Optional

from model_generation import model_files_for_setup, write_run_files
from validation import (
    ValidationError,
    assert_hashes_unchanged,
    snapshot_hashes,
    validate_raw_result,
)


class SimulationError(RuntimeError):
    """Raised when OpenModelica does not produce a complete result."""


@dataclass(frozen=True)
class SimulationArtifacts:
    run_dir: Path
    raw_result: Path
    stdout_log: Path
    stderr_log: Path
    raw_validation: Mapping[str, Any]
    model_hashes: Mapping[str, str]
    modelica_version: Optional[str]


def _omc_executable() -> str:
    omc_path = shutil.which("omc")
    if omc_path is None:
        raise SimulationError("OpenModelica executable 'omc' is not available on PATH")
    return omc_path


def _modelica_version(stdout: str) -> Optional[str]:
    for line in stdout.splitlines():
        match = re.fullmatch(r'"(\d+\.\d+\.\d+(?:[^\"]*)?)"', line.strip())
        if match:
            return match.group(1)
    return None


def _safe_remove_directory(path: Path, root: Path) -> None:
    resolved_path = path.resolve()
    resolved_root = root.resolve()
    try:
        relative = resolved_path.relative_to(resolved_root)
    except ValueError as exc:
        raise SimulationError(
            "Refusing to remove path outside run root: {}".format(resolved_path)
        ) from exc
    if not relative.parts:
        raise SimulationError("Refusing to remove the run root itself")
    shutil.rmtree(resolved_path)


def _compiler_environment() -> Dict[str, str]:
    """Prefer the system compiler so Conda compiler shims cannot break OMC linking."""

    environment = os.environ.copy()
    system_bin = Path("/usr/bin")
    gcc = system_bin / "gcc"
    gxx = system_bin / "g++"
    if gcc.is_file():
        environment["CC"] = str(gcc)
    if gxx.is_file():
        environment["CXX"] = str(gxx)

    path_parts = environment.get("PATH", "").split(os.pathsep)
    preferred = ["/usr/bin", "/bin"]
    environment["PATH"] = os.pathsep.join(
        preferred + [part for part in path_parts if part and part not in preferred]
    )
    return environment


def _nonlinear_termination(log_path: Path) -> bool:
    """Recognize a failed algebraic solve, not earlier recoverable warnings."""
    if not log_path.is_file():
        return False
    tail = log_path.read_text(encoding="utf-8", errors="replace").splitlines()[-100:]
    return (any("Simulation terminated by an assert" in line for line in tail)
            and any("Solving non-linear system" in line and "failed" in line
                    for line in tail))


def _retry_with_kinsol(run_dir: Path, setup: Mapping[str, Any],
                       raw_result: Path) -> Mapping[str, Any]:
    """Retry a terminated simulation with a different nonlinear solver."""
    first_log = run_dir / "processPlant.log"
    if first_log.is_file():
        shutil.copy2(first_log, run_dir / "processPlant.initial.log")
    retry_result = run_dir / "processPlant_kinsol_res.csv"
    stdout_path = run_dir / "kinsol.stdout.log"
    stderr_path = run_dir / "kinsol.stderr.log"
    completed = subprocess.run(
        [str(run_dir / "processPlant"), "-nls=kinsol", f"-r={retry_result.name}"],
        cwd=str(run_dir), env=_compiler_environment(), text=True,
        capture_output=True, check=False,
    )
    stdout_path.write_text(completed.stdout, encoding="utf-8")
    stderr_path.write_text(completed.stderr, encoding="utf-8")
    if completed.returncode != 0 or not retry_result.is_file():
        raise SimulationError(
            f"KINSOL retry failed for {run_dir.name} (exit {completed.returncode}); "
            f"inspect {stdout_path} and {stderr_path}"
        )
    try:
        validation = validate_raw_result(retry_result, setup["sim_setup"])
    except ValidationError as exc:
        raise SimulationError(
            f"KINSOL retry produced an incomplete result for {run_dir.name}: {exc}; "
            f"inspect {stdout_path} and {run_dir / 'processPlant.log'}"
        ) from exc
    retry_result.replace(raw_result)
    return validation


def run_openmodelica(
    setup: Mapping[str, Any],
    config_dir: Path,
    build_root: Path,
    scenario_id: str,
    force: bool = False,
    result_filter: Optional[str] = None,
) -> SimulationArtifacts:
    omc_path = _omc_executable()

    build_root.mkdir(parents=True, exist_ok=True)
    run_dir = build_root / scenario_id
    if run_dir.exists():
        if not force:
            raise SimulationError(
                "Build directory already exists: {} (use --force or --resume)".format(
                    run_dir
                )
            )
        _safe_remove_directory(run_dir, build_root)

    reusable_models = model_files_for_setup(setup, config_dir)
    model_hashes = snapshot_hashes(reusable_models)
    if result_filter is None:
        _, mos_path, _ = write_run_files(setup, config_dir, run_dir)
    else:
        _, mos_path, _ = write_run_files(setup, config_dir, run_dir, result_filter=result_filter)
    stdout_path = run_dir / "omc.stdout.log"
    stderr_path = run_dir / "omc.stderr.log"

    try:
        completed = subprocess.run(
            [omc_path, mos_path.name],
            cwd=str(run_dir),
            env=_compiler_environment(),
            text=True,
            capture_output=True,
            check=False,
        )
        stdout_path.write_text(completed.stdout, encoding="utf-8")
        stderr_path.write_text(completed.stderr, encoding="utf-8")

        raw_result = run_dir / "processPlant_res.csv"
        if completed.returncode != 0:
            raise SimulationError(
                "OpenModelica exited with status {} for {}. Logs: {}, {}".format(
                    completed.returncode, scenario_id, stdout_path, stderr_path
                )
            )
        if "Check of processPlant completed successfully." not in completed.stdout:
            raise SimulationError(
                "OpenModelica model check did not succeed for {}. Logs: {}, {}".format(
                    scenario_id, stdout_path, stderr_path
                )
            )
        if not raw_result.is_file():
            raise SimulationError(
                "OpenModelica reported no shell error but produced no result for {}. "
                "Inspect {} and {}".format(scenario_id, stdout_path, stderr_path)
            )
        try:
            raw_validation = validate_raw_result(raw_result, setup["sim_setup"])
        except ValidationError as exc:
            if _nonlinear_termination(run_dir / "processPlant.log"):
                try:
                    raw_validation = _retry_with_kinsol(run_dir, setup, raw_result)
                except SimulationError as retry_exc:
                    raise SimulationError(
                        f"OpenModelica stopped during a nonlinear solve for "
                        f"{scenario_id}: {exc}. {retry_exc}. Build: {run_dir}"
                    ) from retry_exc
            else:
                raise SimulationError(
                    "Incomplete/invalid OpenModelica result for {}: {}. Build: {}".format(
                        scenario_id, exc, run_dir
                    )
                ) from exc
    finally:
        assert_hashes_unchanged(model_hashes, reusable_models)

    modelica_version = _modelica_version(completed.stdout)
    if modelica_version != "4.0.0":
        raise SimulationError(
            "Expected Modelica Standard Library 4.0.0 for {}, found {!r}. "
            "Inspect {}".format(scenario_id, modelica_version, stdout_path)
        )

    return SimulationArtifacts(
        run_dir=run_dir,
        raw_result=raw_result,
        stdout_log=stdout_path,
        stderr_log=stderr_path,
        raw_validation=raw_validation,
        model_hashes=model_hashes,
        modelica_version=modelica_version,
    )
