"""Start a container campaign only when its results will survive the container."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import sys


WORK = Path("/work")
DEFAULT_OUTPUT = WORK / "output" / "v2.2"
DEFAULT_BUILD = WORK / "build" / "v2.2"


def work_is_mounted() -> bool:
    with Path("/proc/self/mountinfo").open(encoding="utf-8") as mounts:
        return any(line.split()[4] == str(WORK) for line in mounts)


def main(argv: list[str] | None = None) -> None:
    argv = sys.argv[1:] if argv is None else argv
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--build-root", type=Path, default=DEFAULT_BUILD)
    parser.add_argument("--logs", type=Path)
    parser.add_argument("--plan", action="store_true")
    args, _ = parser.parse_known_args(argv)

    if not args.plan and not any(arg in ("-h", "--help") for arg in argv):
        if not work_is_mounted() or not os.access(WORK, os.W_OK):
            raise SystemExit(
                "Mount a writable host directory or named volume at /work "
                "to retain campaign results."
            )
        for label, path in (("--output", args.output),
                            ("--build-root", args.build_root),
                            ("--logs", args.logs)):
            if path is not None and not path.resolve().is_relative_to(WORK.resolve()):
                raise SystemExit(f"{label} must point inside the mounted /work directory")

    os.execv(sys.executable, [
        sys.executable,
        str(Path(__file__).with_name("campaign.py")),
        "--output", str(DEFAULT_OUTPUT),
        "--build-root", str(DEFAULT_BUILD),
        *argv,
    ])


if __name__ == "__main__":
    main()
