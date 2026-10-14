"""Report the simulator failure behind a truncated result."""

import json
from pathlib import Path
from tempfile import TemporaryDirectory

from runner import _nonlinear_failure_context


def test_nonlinear_failure_names_the_system_and_unknowns():
    with TemporaryDirectory() as directory:
        root = Path(directory)
        log = root / "processPlant.log"
        log.write_text(
            "LOG_ASSERT | debug | Solving non-linear system 5712 failed at time=9130.\n"
            "LOG_STDOUT | info | model terminate | Simulation terminated by an assert at time: 9130\n"
        )
        (root / "processPlant_info.json").write_text(json.dumps({
            "equations": [{"eqIndex": 5712, "defines": ["bottling0.pipe1.p", "bottling0.pipe1.h"]}],
        }))
        assert _nonlinear_failure_context(log) == (
            "OpenModelica terminated while solving nonlinear system 5712 "
            "(bottling0.pipe1.p, bottling0.pipe1.h)"
        )
        log.write_text("Solving non-linear system 5712 failed at time=1\n"
                       "The simulation finished successfully.\n")
        assert _nonlinear_failure_context(log) is None
