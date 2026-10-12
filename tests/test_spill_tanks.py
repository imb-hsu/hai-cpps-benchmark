"""Numerical overflow and conservation checks for both shared tank models."""

import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import unittest

import numpy as np
import pandas as pd

from runner import _compiler_environment
from config import load_benchmark_config
from model_generation import generate_plant_text, model_files_for_setup


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(
    shutil.which("omc") and os.environ.get("RUN_OMC_TESTS") == "1",
    "set RUN_OMC_TESTS=1 to run spill conservation simulations",
)
class SpillTankTests(unittest.TestCase):
    def test_every_vessel_in_every_process_module_can_start_above_its_rim(self):
        cases = {
            "ds1": ("mixer0", {"tank_B201": 0.145, "tank_B202": 0.145,
                                "tank_B203": 0.145, "tank_B204": 0.225}),
            "ds2": ("distill0", {"tank_B101": 0.225, "tank_B102": 0.225,
                                  "tank_B103": 0.225, "distill": 1.225}),
            "ds3": ("filter0", {"tank_B101": 0.225, "tank_B102": 0.225}),
            "ds4": ("bottling0", {"tank_B401": 0.225, "tank_B402": 0.225}),
        }
        config_dir = ROOT / "code"
        benchmark = load_benchmark_config(config_dir / "benchmark_setup.json")
        for dataset, (module, tanks) in cases.items():
            with self.subTest(dataset=dataset):
                setup = benchmark[dataset]
                model = generate_plant_text(setup)
                modifiers = ", ".join(f"{tank}(level_start={level})"
                                      for tank, level in tanks.items())
                model = model.replace(f" {module}(", f" {module}({modifiers}, ")
                frame = self._simulate(model, "processPlant", 2,
                                       model_files_for_setup(setup, config_dir))
                for tank in tanks:
                    self.assertGreater(frame[f"{module}.{tank}.spill_mass"].iloc[-1], 0)
                    self.assertGreater(frame[f"{module}.{tank}.spill_m_flow"].iloc[0], 0)

    def test_rim_spills_conserve_mass_and_enthalpy_and_stop_after_inflow(self):
        model = '''model SpillRegression
  package Medium = Modelica.Media.Water.StandardWater;
  inner Modelica.Fluid.System system(p_ambient=1e5);
  SpillTanks.TankWithTopPorts tank(redeclare package Medium=Medium,
    crossArea=0.001, height=0.02, V0=0.0001, level_start=0.005,
    nTopPorts=1, nPorts=0, T_start=310,
    energyDynamics=Modelica.Fluid.Types.Dynamics.FixedInitial,
    massDynamics=Modelica.Fluid.Types.Dynamics.FixedInitial);
  SpillTanks.TankWithEvaporator evaporator(redeclare package Medium=Medium,
    crossArea=0.001, height=0.02, V0=0.0001, level_start=0.005,
    n_TopPorts=1, top_pipeArea={0.0001},
    InnerTankTop(each m_flow_negative(start=false)), n_SidePorts=0, side_pipeArea=zeros(0),
    n_BottomPorts=0, bottom_pipeArea=zeros(0), min_level_for_heating=0.0001,
    p_ambient=1e5, T_start=310,
    initType=Modelica.Fluid.Examples.AST_BatchPlant.BaseClasses.Init.InitialValues);
  Modelica.Fluid.Sources.MassFlowSource_T inlet[2](redeclare each package Medium=Medium,
    each nPorts=1, each T=330, each use_m_flow_in=true);
  Modelica.Fluid.Sources.FixedBoundary sink(redeclare package Medium=Medium,
    nPorts=3, p=1e5);
  Real supplied_mass(start=0, fixed=true);
  Real spilled_enthalpy[2](each start=0, each fixed=true);
  Real mass_error[2];
  Real energy_error[2];
  parameter Real initial_mass[2](each fixed=false);
  parameter Real initial_energy[2](each fixed=false);
initial equation
  initial_mass = {tank.m, evaporator.m};
  initial_energy = {tank.U, evaporator.U};
equation
  inlet[1].m_flow_in = if time < 15 then 0.005 else 0;
  inlet[2].m_flow_in = inlet[1].m_flow_in;
  der(supplied_mass) = inlet[1].m_flow_in;
  connect(inlet[1].ports[1], tank.topPorts[1]);
  connect(inlet[2].ports[1], evaporator.TopFluidPort[1]);
  connect(tank.spillPort, sink.ports[1]);
  connect(evaporator.spillPort, sink.ports[2]);
  connect(evaporator.Condensed, sink.ports[3]);
  der(spilled_enthalpy[1]) = tank.spill_m_flow*tank.spillPort.h_outflow;
  der(spilled_enthalpy[2]) = evaporator.spill_m_flow*evaporator.spillPort.h_outflow;
  mass_error = {tank.m, evaporator.m} + {tank.spill_mass, evaporator.spill_mass}
    - initial_mass - fill(supplied_mass, 2);
  energy_error = {tank.U + tank.p_ambient*tank.V,
                 evaporator.U + evaporator.p_ambient*evaporator.V}
    + spilled_enthalpy - initial_energy
    - {tank.p_ambient*(tank.crossArea*tank.level_start + tank.V0),
       evaporator.p_ambient*(evaporator.crossArea*evaporator.level_start + evaporator.V0)}
    - fill(supplied_mass*Medium.specificEnthalpy_pTX(1e5, 330, Medium.reference_X), 2);
end SpillRegression;
'''
        frame = self._simulate(model, "SpillRegression", 30)
        for name in ("tank", "evaporator"):
            flow = frame[f"{name}.spill_m_flow"]
            mass = frame[f"{name}.spill_mass"]
            self.assertAlmostEqual(flow.iloc[0], 0.0, places=10)
            self.assertGreater(mass.iloc[-1], 0.05)
            self.assertGreater(flow.max(), 0.004)
            self.assertLess(flow.iloc[-1], 0.0001)
            self.assertGreaterEqual(flow.min(), 0.0)
            self.assertTrue((mass.diff().dropna() >= -1e-9).all())
            self.assertLess(frame[f"{name}.level"].max(), 0.03)
        for index in (1, 2):
            self.assertLess(np.abs(frame[f"mass_error[{index}]"]).max(), 1e-6)
            self.assertLess(np.abs(frame[f"energy_error[{index}]"]).max(), 0.1)

    def test_evaporating_tank_spills_liquid_while_condensing_vapour(self):
        model = '''model BoilingSpillRegression
  package Medium = Modelica.Media.Water.StandardWater;
  SpillTanks.TankWithEvaporator tank(redeclare package Medium=Medium,
    crossArea=0.001, height=0.02, V0=0.0001, level_start=0.015,
    n_TopPorts=1, top_pipeArea={0.0001},
    InnerTankTop(each m_flow_negative(start=false)), n_SidePorts=0, side_pipeArea=zeros(0),
    n_BottomPorts=0, bottom_pipeArea=zeros(0), min_level_for_heating=0.0001,
    p_ambient=1e5, use_T_start=false,
    h_start=Medium.bubbleEnthalpy(Medium.setSat_p(1e5))+100,
    initType=Modelica.Fluid.Examples.AST_BatchPlant.BaseClasses.Init.InitialValues);
  inner Modelica.Fluid.System system(p_ambient=1e5);
  Modelica.Fluid.Sources.MassFlowSource_h inlet(redeclare package Medium=Medium,
    nPorts=1, m_flow=0.005, h=Medium.bubbleEnthalpy(Medium.setSat_p(1e5))+100);
  Modelica.Fluid.Sources.FixedBoundary sink(redeclare package Medium=Medium,
    nPorts=2, p=1e5);
  Modelica.Thermal.HeatTransfer.Sources.FixedHeatFlow heater(Q_flow=100);
  Real mass_error;
  Real condensed_mass(start=0, fixed=true);
  parameter Real initial_mass(fixed=false);
initial equation
  initial_mass = tank.m;
equation
  connect(heater.port, tank.heatPort);
  connect(inlet.ports[1], tank.TopFluidPort[1]);
  connect(tank.spillPort, sink.ports[1]);
  connect(tank.Condensed, sink.ports[2]);
  der(condensed_mass) = -tank.Condensed.m_flow;
  mass_error = tank.m + tank.spill_mass + condensed_mass - initial_mass - 0.005*time;
end BoilingSpillRegression;
'''
        frame = self._simulate(model, "BoilingSpillRegression", 10)
        self.assertGreater(frame["tank.spill_mass"].iloc[-1], 0.02)
        self.assertGreater(frame["condensed_mass"].iloc[-1], 0)
        # Two-phase density is sensitive to the solver's interpolated states.
        self.assertLess(np.abs(frame["mass_error"]).max(), 5e-6)
        self.assertLess(np.abs(frame["tank.spillPort.h_outflow"] - frame["tank.h"]).max(), 1e-6)

    def _simulate(self, model, name, stop, module_files=()):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "test.mo").write_text(model)
            (root / "call.mos").write_text(
                'loadModel(Modelica, {"4.0.0"});\n'
                f'loadFile("{ROOT / "models" / "SpillTanks.mo"}");\n'
                + "".join(f'loadFile("{path}");\n' for path in module_files
                          if path.name != "SpillTanks.mo")
                + 'loadFile("test.mo");\n'
                f'simulate({name}, stopTime={stop}, numberOfIntervals={stop * 20}, '
                'outputFormat="csv", tolerance=1e-8);\ngetErrorString();\n'
            )
            process = subprocess.Popen(
                [shutil.which("omc"), "call.mos"], cwd=root,
                env=_compiler_environment(), stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True, start_new_session=True,
            )
            try:
                stdout, stderr = process.communicate(timeout=120)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
                raise
            self.assertEqual(process.returncode, 0, stdout + stderr)
            self.assertIn("simulation finished successfully", stdout.lower(), stdout)
            frame = pd.read_csv(root / f"{name}_res.csv")
            self.assertAlmostEqual(frame.time.iloc[-1], stop)
            return frame
