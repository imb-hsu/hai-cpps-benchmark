// Adapted from Modelica Standard Library 4.0.0 AST_BatchPlant tank models.
// Changes: passive rim spill ports and conservative mass/enthalpy removal replace
// overflow termination; the evaporator permits the hydraulic head above the rim.
/*
Copyright (c) 1998-2020, Modelica Association and contributors
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

* Neither the name of the copyright holder nor the names of its
  contributors may be used to endorse or promote products derived from
  this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/
package SpillTanks
  import SI = Modelica.Units.SI;
  import Modelica.Fluid.Types;
  import Modelica.Fluid.Vessels;

  model TankWithTopPorts
      "Tank with inlet/outlet ports and with inlet ports at the top"

      import Modelica.Constants;
      import Modelica.Fluid.Fittings.BaseClasses.lossConstant_D_zeta;
      import Modelica.Fluid.Utilities.regRoot2;
      import Modelica.Fluid.Vessels.BaseClasses.VesselPortsData;

    SI.Length level(stateSelect=StateSelect.prefer, start=level_start)
        "Fluid level in the tank";

    //Tank geometry
    parameter SI.Height height "Height of the spill rim";
    parameter SI.Area crossArea "Area of tank";
    parameter SI.Volume V0=0 "Volume of the liquid when level = 0";

    //Ambient
    parameter Medium.AbsolutePressure p_ambient=system.p_ambient
        "Tank surface pressure"
      annotation(Dialog(tab = "Assumptions", group = "Ambient"));
    parameter Medium.Temperature T_ambient=system.T_ambient
        "Tank surface Temperature"
      annotation(Dialog(tab = "Assumptions", group = "Ambient"));

    //Initialization
    parameter SI.Height level_start(min=0) = 0.5*height
        "Start value of tank level"
      annotation(Dialog(tab="Initialization"));

    //Mass and energy balance
    extends Modelica.Fluid.Interfaces.PartialLumpedVolume(
      final fluidVolume = V,
      final initialize_p = false,
      final p_start = p_ambient);

    //Port definitions
    parameter Integer nTopPorts = 0 "Number of inlet ports above height (>= 1)"
                                                  annotation(Dialog(connectorSizing=true));

    Vessels.BaseClasses.VesselFluidPorts_a topPorts[nTopPorts](redeclare
          package Medium = Medium, m_flow(each start=0, each min=0))
        "Inlet ports over height at top of tank (fluid flows only from the port in to the tank)"
      annotation (Placement(transformation(
          extent={{-20,0},{20,10}},
          origin={0,100})));

    parameter Integer nPorts = 0
        "Number of inlet/outlet ports (on bottom and on the side)"
       annotation(Dialog(connectorSizing=true));
    parameter Modelica.Fluid.Vessels.BaseClasses.VesselPortsData portsData[nPorts]
        "Data of inlet/outlet ports at side and bottom of tank";

    Vessels.BaseClasses.VesselFluidPorts_b ports[nPorts](redeclare package
          Medium = Medium, m_flow(each start=0))
        "Inlet/outlet ports at bottom or side of tank (fluid flows in to or out of port; a port might be above the fluid level)"
      annotation (Placement(transformation(
          extent={{-20,0},{20,-10}},
          origin={0,-100})));

    // Heat transfer through boundary
    parameter Boolean use_HeatTransfer = false
        "= true, if HeatTransfer model is used"
        annotation (Dialog(tab="Assumptions", group="Heat transfer"));
    replaceable model HeatTransfer =
        Modelica.Fluid.Vessels.BaseClasses.HeatTransfer.IdealHeatTransfer
      constrainedby
        Modelica.Fluid.Vessels.BaseClasses.HeatTransfer.PartialVesselHeatTransfer
        "Wall heat transfer"
        annotation (Dialog(tab="Assumptions", group="Heat transfer",enable=use_HeatTransfer),choicesAllMatching=true);
    HeatTransfer heatTransfer(
      redeclare package Medium = Medium,
      final n=1,
      final states = {medium.state},
      surfaceAreas={crossArea+2*sqrt(crossArea*Modelica.Constants.pi)*level},
      final use_k = use_HeatTransfer)
        annotation (Placement(transformation(
          extent={{-10,-10},{30,30}},
          rotation=90,
          origin={-50,-10})));
    Modelica.Thermal.HeatTransfer.Interfaces.HeatPort_a heatPort if use_HeatTransfer
      annotation (Placement(transformation(extent={{-110,-10},{-90,10}})));

    // Advanced
    parameter Real hysteresisFactor(min=0) = 0.1
        "Hysteresis for empty pipe = diameter*hysteresisFactor"
      annotation(Dialog(tab="Advanced", group="Port properties"));
    parameter Boolean stiffCharacteristicForEmptyPort = false
        "= true, if steep pressure loss characteristic for empty pipe port"
      annotation(Dialog(tab="Advanced", group="Port properties"), Evaluate=true);
    parameter Real zetaLarge(min=0) = 1e5
        "Large pressure loss factor if mass flows out of empty pipe port"
      annotation(Dialog(tab="Advanced", group="Port properties", enable=stiffCharacteristicForEmptyPort));
    parameter SI.MassFlowRate m_flow_small(min=0) = system.m_flow_small
        "Regularization range at zero mass flow rate"
      annotation(Dialog(tab="Advanced", group="Port properties", enable=stiffCharacteristicForEmptyPort));

    // Tank properties
    SI.Volume V(stateSelect=StateSelect.never) "Actual tank volume";
    Medium.EnthalpyFlowRate H_flow_top[nTopPorts]
        "Enthalpy flow rates from the top ports in to the tank";
    Medium.EnthalpyFlowRate port_b_H_flow_bottom[nPorts]
        "Enthalpy flow rates from the bottom ports in to the tank";
    Medium.MassFlowRate mXi_flow_top[nTopPorts, Medium.nXi]
        "Substance mass flow rates from the top ports into the tank";
    Medium.MassFlowRate port_b_mXi_flow_bottom[nPorts, Medium.nXi]
        "Substance mass flow rates from the bottom ports into the tank";
    Medium.MassFlowRate mC_flow_top[nTopPorts, Medium.nC]
        "Trace substance mass flow rates from the top ports into the tank";
    Medium.MassFlowRate port_b_mC_flow_bottom[nPorts, Medium.nC]
        "Trace substance mass flow rates from the bottom ports into the tank";
    // Passive rectangular-weir spill at the tank rim; no liquid leaves below height.
    parameter SI.Length spillWidth(min=Modelica.Constants.small) = 2*sqrt(Modelica.Constants.pi*crossArea)
      "Effective rim width, defaulting to the circumference of a circular tank";
    parameter Real spillDischargeCoefficient(min=0, max=1) = 0.6;
    Modelica.Fluid.Interfaces.FluidPort_b spillPort(redeclare package Medium = Medium)
      "One-way liquid spill to a separate atmospheric sink";
    output SI.VolumeFlowRate spill_volumeFlowRate "Liquid volume spilled per second";
    output SI.MassFlowRate spill_m_flow "Liquid mass spilled per second";
    output SI.Mass spill_mass(start=0, fixed=true) "Cumulative spilled mass";
  protected
      SI.Area bottomArea[nPorts];
      SI.Diameter ports_emptyPipeHysteresis[nPorts];
      SI.Length levelAbovePort[nPorts] "Height of fluid over bottom ports";
      Boolean ports_m_flow_out[nPorts](each start = true, each fixed=true);
      Boolean aboveLevel[nPorts] "= true, if level >= ports[i].height";
      Real zetas_out[nPorts];
      Modelica.Blocks.Interfaces.RealInput portsData_diameter[nPorts] = portsData.diameter if nPorts > 0;
      Modelica.Blocks.Interfaces.RealInput portsData_diameter2[nPorts];
      Modelica.Blocks.Interfaces.RealInput portsData_height[nPorts] = portsData.height if nPorts > 0;
      Modelica.Blocks.Interfaces.RealInput portsData_height2[nPorts];
  equation
    spill_volumeFlowRate = (2/3)*spillDischargeCoefficient*spillWidth*sqrt(2*Modelica.Constants.g_n)
      *noEvent(max(level - height, 0))^1.5;
    spill_m_flow = medium.d*spill_volumeFlowRate;
    der(spill_mass) = spill_m_flow;
    spillPort.m_flow = -spill_m_flow;
    spillPort.h_outflow = medium.h;
    spillPort.Xi_outflow = medium.Xi;
    spillPort.C_outflow = C;
    assert(m>=0, "Mass in tank is zero");

    // Compute constant data
    connect(portsData_diameter, portsData_diameter2);
    connect(portsData_height,portsData_height2);

    for i in 1:nPorts loop
        bottomArea[i]=Constants.pi*(portsData_diameter2[i]/2)^2;
        ports_emptyPipeHysteresis[i] = portsData_diameter2[i]*hysteresisFactor;
    end for;

    // Only one connection allowed to a port to avoid unwanted ideal mixing
  /*
for i in 1:nTopPorts loop
  assert(cardinality(topPorts[i]) <= 1,"
topPorts[" + String(i) + "] of volume can at most be connected to one component.
If two or more connections are present, ideal mixing takes
place with these connections which is usually not the intention
of the modeller.
");
end for;

for i in 1:nPorts loop
  assert(cardinality(ports[i]) <= 1,"
ports[" + String(i) + "] of volume can at most be connected to one component.
If two or more connections are present, ideal mixing takes
place with these connections which is usually not the intention
of the modeller.
");
end for;
*/

    // Total quantities
    medium.p = p_ambient;
    V = crossArea*level + V0 "Volume of fluid";

    // Mass balances
    mb_flow = sum(topPorts.m_flow) + sum(ports.m_flow) - spill_m_flow;
    for i in 1:Medium.nXi loop
      mbXi_flow[i] = sum(mXi_flow_top[:,i]) + sum(port_b_mXi_flow_bottom[:,i]) - spill_m_flow*medium.Xi[i];
    end for;
    for i in 1:Medium.nC loop
      mbC_flow[i]  = sum(mC_flow_top[:,i])  + sum(port_b_mC_flow_bottom[:,i]) - spill_m_flow*C[i];
    end for;

    // Energy balance
    Hb_flow = sum(H_flow_top) + sum(port_b_H_flow_bottom) - spill_m_flow*medium.h;
    Qb_flow = heatTransfer.Q_flows[1];
    if Medium.singleState or energyDynamics == Types.Dynamics.SteadyState then
      Wb_flow = 0
          "Mechanical work is neglected, since also neglected in medium model (otherwise unphysical small temperature change, if tank level changes)";
    else
      Wb_flow = -p_ambient*der(V);
    end if;

    // Properties at top ports
      for i in 1:nTopPorts loop
         // It is assumed that fluid flows only from one of the top ports in to the tank and never vice versa
         H_flow_top[i]     = topPorts[i].m_flow*actualStream(topPorts[i].h_outflow);
         mXi_flow_top[i,:] = topPorts[i].m_flow*actualStream(topPorts[i].Xi_outflow);
         mC_flow_top[i,:]  = topPorts[i].m_flow*actualStream(topPorts[i].C_outflow);
         topPorts[i].p     = p_ambient;
         topPorts[i].h_outflow = h_start;
         topPorts[i].Xi_outflow = X_start[1:Medium.nXi];
         topPorts[i].C_outflow  = C_start;
  /*
       assert(topPorts[i].m_flow > -1, "Mass flows out of tank via topPorts[" + String(i) + "]\n" +
                                         "This indicates a wrong model");
*/
      end for;

    // Properties at bottom ports
      for i in 1:nPorts loop
         port_b_H_flow_bottom[i]   = ports[i].m_flow*actualStream(ports[i].h_outflow);
         port_b_mXi_flow_bottom[i,:] = ports[i].m_flow*actualStream(ports[i].Xi_outflow);
         port_b_mC_flow_bottom[i,:]  = ports[i].m_flow*actualStream(ports[i].C_outflow);
         aboveLevel[i] = level >= (portsData_height2[i] + ports_emptyPipeHysteresis[i])
                         or pre(aboveLevel[i]) and level >= (portsData_height2[i] - ports_emptyPipeHysteresis[i]);
         levelAbovePort[i] = if aboveLevel[i] then level - portsData_height2[i] else 0;
         ports[i].h_outflow = medium.h;
         ports[i].Xi_outflow = medium.Xi;
         ports[i].C_outflow  = C;

         if stiffCharacteristicForEmptyPort then
            // If port is above fluid level, use large zeta if fluid flows out of port (= small mass flow rate)
            zetas_out[i] = 1 + (if aboveLevel[i] then 0 else zetaLarge);
            ports[i].p = p_ambient + levelAbovePort[i]*system.g*medium.d
                                 + Modelica.Fluid.Utilities.regSquare2(ports[i].m_flow, m_flow_small,
                                       lossConstant_D_zeta(portsData_diameter2[i], 0.01)/medium.d,
                                       lossConstant_D_zeta(portsData_diameter2[i], zetas_out[i])/medium.d);
            ports_m_flow_out[i] = false;

         else
            // Handling according to Remelhe/Poschlad
            ports_m_flow_out[i] = (pre(ports_m_flow_out[i]) and not ports[i].p>p_ambient)
                                       or ports[i].m_flow < -1e-6;
           if aboveLevel[i] then
               ports[i].p = p_ambient + levelAbovePort[i]*system.g*medium.d -
                                 smooth(2,noEvent(if ports[i].m_flow < 0 then ports[i].m_flow^2/
                                       (2*medium.d*bottomArea[i]^2) else 0));
           else
              if pre(ports_m_flow_out[i]) then
                 ports[i].m_flow = 0;
              else
                 ports[i].p = p_ambient;
              end if;
           end if;
            zetas_out[i] =0;
         end if;
       end for;

  initial equation
      for i in 1:nPorts loop
         pre(aboveLevel[i]) = level_start >= portsData_height2[i];
      end for;

      if massDynamics == Types.Dynamics.FixedInitial then
        level = level_start;
      elseif massDynamics == Types.Dynamics.SteadyStateInitial then
        der(level) = 0;
      end if;

  equation
      connect(heatPort, heatTransfer.heatPorts[1]) annotation (Line(
          points={{-100,0},{-87,0},{-87,0},{-74,0}}, color={191,0,0}));
  end TankWithTopPorts;

  model TankWithEvaporator
    "Tank with Heating and Evaporation"
    import Modelica.Fluid.Examples.AST_BatchPlant.BaseClasses.Init;
    replaceable package Medium = Modelica.Media.Water.WaterIF97_ph
      constrainedby Modelica.Media.Interfaces.PartialTwoPhaseMedium
      "Medium in the component"
      annotation (choicesAllMatching=true);
  // parameter for Tank
    parameter SI.Area crossArea "Tank area";
    parameter SI.Area top_pipeArea[n_TopPorts] "Area of outlet pipe";
    parameter SI.Area side_pipeArea[n_SidePorts] "Area of outlet pipe";
    parameter SI.Area bottom_pipeArea[n_BottomPorts] "Area of outlet pipe";
    parameter SI.Height height = 10 "Height of Tank";
    parameter SI.Volume V0=0 "Volume of the liquid when the level is zero";
    constant SI.Acceleration g=Modelica.Constants.g_n;
    parameter SI.Height side_heights[n_SidePorts]=zeros(n_SidePorts) "Side heights";
    parameter SI.Height bottom_heights[n_BottomPorts]=zeros(n_BottomPorts) "Bottom heights";
    parameter SI.Height top_heights[n_TopPorts]=fill(height, n_TopPorts) "Top heights";
    parameter SI.Height level_start "Initial tank level"
      annotation(Dialog(tab="Initialization"));
    parameter Modelica.Fluid.Examples.AST_BatchPlant.BaseClasses.Init
      initType = Init.GuessValues
      "Initialization option"
      annotation(Dialog(tab = "Initialization"));
    parameter Boolean use_T_start=true
      "= true, if T_start is used, otherwise h_start" annotation(Dialog(tab = "Initialization"), Evaluate = true);
    parameter Medium.Temperature T_start=if use_T_start then 293.15 else
        Medium.temperature_phX(p_ambient, h_start, X_start)
      "Start value of temperature"
      annotation(Dialog(tab = "Initialization", enable = use_T_start));
    parameter Medium.SpecificEnthalpy h_start=if use_T_start then Medium.specificEnthalpy_pTX(
        p_ambient, T_start, X_start[1:Medium.nXi]) else 1e4
      "Start value of specific enthalpy"
      annotation(Dialog(tab = "Initialization", enable = not use_T_start));
    parameter Medium.MassFraction X_start[Medium.nX]=Medium.reference_X
      "Start value of mass fractions m_i/m"
      annotation (Dialog(tab="Initialization", enable=Medium.nXi > 0));
    parameter Medium.AbsolutePressure p_ambient=101325
      "Tank surface pressure";
    parameter Medium.Temperature T_ambient=293.15 "Tank surface Temperature";
    parameter Integer n_TopPorts=1 "Number of Top connectors";
    parameter Integer n_SidePorts=1 "Number of side connectors";
    parameter Integer n_BottomPorts=1 "Number of bottom connectors";
    Medium.BaseProperties medium(
      preferredMediumStates=true,
      p(start=p_ambient),
      T(start=T_start),
      Xi(start=X_start[1:Medium.nXi]));
    SI.Height level(
      stateSelect=StateSelect.prefer,
      min=0) "Level height of tank";
    SI.Volume V(stateSelect=StateSelect.never) "Actual tank volume";
    SI.Energy U "Internal energy of tank volume";
    Real m(unit="kg") "Mass of tank volume";
    Real mXi[Medium.nXi](each unit="kg")
      "Component masses of the independent substances";
  // additional variables
    Real H_flow_BottomPorts[n_BottomPorts];
    Real H_flow_SidePorts[n_SidePorts];
    Real H_flow_TopPorts[n_TopPorts];
    Real m_flow_BottomPorts[n_BottomPorts];
    Real m_flow_SidePorts[n_SidePorts];
    Real m_flow_TopPorts[n_TopPorts];

    Real m_flow_BottomPorts_pos[n_BottomPorts];
    Real m_flow_SidePorts_pos[n_SidePorts];
    Real m_flow_TopPorts_pos[n_TopPorts];
    Real m_flow_pos;
    Medium.MassFlowRate mXi_flow_topPorts[n_TopPorts,Medium.nXi];
    Medium.MassFlowRate mXi_flowBottomPorts[n_BottomPorts,Medium.nXi];
    Medium.MassFlowRate mXi_flow_sidePorts[n_SidePorts,Medium.nXi];

  // Connectors and InnerTanks
    Modelica.Fluid.Interfaces.FluidPort_b BottomFluidPort[n_BottomPorts](
      redeclare package Medium = Medium,
      m_flow(each start=0))
      annotation (Placement(transformation(
          origin={-100,-102},
          extent={{-10,-10},{10,10}},
          rotation=90)));
    Modelica.Fluid.Interfaces.FluidPort_a TopFluidPort[n_TopPorts](
      redeclare package Medium = Medium,
      m_flow(each start=0))
      annotation (Placement(transformation(extent={{-110,92},{-90,112}})));
    Modelica.Fluid.Interfaces.FluidPort_b SideFluidPort[n_SidePorts](
      redeclare package Medium = Medium,
      m_flow(each start=0))
      annotation (Placement(transformation(extent={{0,-10},{20,10}})));
    Modelica.Fluid.Examples.AST_BatchPlant.BaseClasses.InnerTank InnerTankTop[n_TopPorts](
      each h=medium.h,
      each p_ambient=p_ambient,
      each d=medium.d,
      each Xi = medium.Xi,
      aboveLevel={level - top_heights[i] for i in 1:n_TopPorts},
      pipeArea={top_pipeArea[i] for i in 1:n_TopPorts},
      redeclare package Medium = Medium)
        annotation (Placement(transformation(extent={{-140,60},{-120,80}})));
    Modelica.Fluid.Examples.AST_BatchPlant.BaseClasses.InnerTank
      InnerTankSide[n_SidePorts](
      each h=medium.h,
      each p_ambient=p_ambient,
      each d=medium.d,
      each Xi = medium.Xi,
      aboveLevel={level - side_heights[i] for i in 1:n_SidePorts},
      pipeArea={side_pipeArea[i] for i in 1:n_SidePorts},
      redeclare package Medium = Medium)
        annotation (Placement(transformation(extent={{-20,0},{0,20}})));
    Modelica.Fluid.Examples.AST_BatchPlant.BaseClasses.InnerTank
      InnerTankBottom[n_BottomPorts](
      each h=medium.h,
      each p_ambient=p_ambient,
      each d=medium.d,
      each Xi = medium.Xi,
      aboveLevel={level - bottom_heights[i] for i in 1:n_BottomPorts},
      pipeArea={bottom_pipeArea[i] for i in 1:n_BottomPorts},
      redeclare package Medium = Medium)
        annotation (Placement(transformation(extent={{-80,-80},{-60,-60}})));
    Modelica.Fluid.Interfaces.FluidPort_b Condensed(redeclare package Medium =
          Medium)
      annotation (Placement(transformation(extent={{192,50},{212,70}})));

    // Heat transfer through boundary
    replaceable model HeatTransfer =
        Modelica.Fluid.Vessels.BaseClasses.HeatTransfer.IdealHeatTransfer
      constrainedby
      Modelica.Fluid.Vessels.BaseClasses.HeatTransfer.PartialVesselHeatTransfer
      "Wall heat transfer"
        annotation (Dialog(tab="Assumptions", group="Heat transfer",enable=use_HeatTransfer),choicesAllMatching=true);
    HeatTransfer heatTransfer(
      redeclare package Medium = Medium,
      final n=1,
      final states = {medium.state},
      surfaceAreas={crossArea+2*sqrt(crossArea*Modelica.Constants.pi)*level},
      final use_k = true)
        annotation (Placement(transformation(
          extent={{-10,-10},{30,30}},
          rotation=90,
          origin={-50,-10})));
    Modelica.Thermal.HeatTransfer.Interfaces.HeatPort_a heatPort
      annotation (Placement(transformation(extent={{-210,-10},{-190,10}})));

  // parameter for Evaporator
    parameter SI.Height min_level_for_heating "Minimum level for heating";

    Medium.SaturationProperties sat
      "State vector to compute saturation properties";
    Medium.SpecificEnthalpy h_v=Medium.dewEnthalpy(sat)
      "Specific enthalpy of vapour";
    Medium.SpecificEnthalpy h_l=Medium.bubbleEnthalpy(sat)
      "Specific enthalpy of liquid";
    Medium.SpecificEnthalpy h "Actual specific enthalpy of liquid";
    Medium.Density rho_v=Medium.dewDensity(sat) "Density in vapour phase";
    Medium.Density rho_l=Medium.bubbleDensity(sat) "Density in liquid phase";
    Medium.Density rho "Actual density in liquid phase";

    // Passive rectangular-weir spill at the tank rim; no liquid leaves below height.
    parameter SI.Length spillWidth(min=Modelica.Constants.small) = 2*sqrt(Modelica.Constants.pi*crossArea)
      "Effective rim width, defaulting to the circumference of a circular tank";
    parameter Real spillDischargeCoefficient(min=0, max=1) = 0.6;
    Modelica.Fluid.Interfaces.FluidPort_b spillPort(redeclare package Medium = Medium)
      "One-way liquid spill to a separate atmospheric sink";
    output SI.VolumeFlowRate spill_volumeFlowRate "Liquid volume spilled per second";
    output SI.MassFlowRate spill_m_flow "Liquid mass spilled per second";
    output SI.Mass spill_mass(start=0, fixed=true) "Cumulative spilled mass";
  equation
    spill_volumeFlowRate = (2/3)*spillDischargeCoefficient*spillWidth*sqrt(2*Modelica.Constants.g_n)
      *noEvent(max(level - height, 0))^1.5;
    spill_m_flow = rho*spill_volumeFlowRate;
    der(spill_mass) = spill_m_flow;
    spillPort.m_flow = -spill_m_flow;
    spillPort.h_outflow = h;
    spillPort.Xi_outflow = medium.Xi;
    spillPort.C_outflow = zeros(Medium.nC);
    H_flow_TopPorts   = InnerTankTop.H_flow;
    m_flow_TopPorts   = InnerTankTop.m_flow;
    mXi_flow_topPorts = InnerTankTop.mXi_flow;

    H_flow_SidePorts   = InnerTankSide.H_flow;
    m_flow_SidePorts   = InnerTankSide.m_flow;
    mXi_flow_sidePorts = InnerTankSide.mXi_flow;

    H_flow_BottomPorts  = InnerTankBottom.H_flow;
    m_flow_BottomPorts  = InnerTankBottom.m_flow;
    mXi_flowBottomPorts = InnerTankBottom.mXi_flow;

    for i in 1:n_BottomPorts loop
      m_flow_BottomPorts_pos[i] = (if m_flow_BottomPorts[i] > 0 then
        m_flow_BottomPorts[i] else 0);
    end for;
    for i in 1:n_SidePorts loop
      m_flow_SidePorts_pos[i] = if m_flow_SidePorts[i] > 0 then m_flow_SidePorts[
        i] else 0;
    end for;
    for i in 1:n_TopPorts loop
      m_flow_TopPorts_pos[i] = if m_flow_TopPorts[i] > 0 then m_flow_TopPorts[i] else
              0;
    end for;
    for i in 1:n_BottomPorts loop
      connect(InnerTankBottom[i].port, BottomFluidPort[i]) annotation (Line(
            points={{-70,-81},{-70,-102},{-100,-102}}, color={0,0,255}));
    end for;
    for i in 1:n_TopPorts loop
      connect(InnerTankTop[i].port, TopFluidPort[i]) annotation (Line(points=
             {{-130,59},{-92,59},{-92,102},{-100,102}}, color={0,0,255}));
    end for;
    for i in 1:n_SidePorts loop
      connect(InnerTankSide[i].port, SideFluidPort[i]) annotation (Line(
            points={{-10,-1},{24,-1},{24,0},{10,0}}, color={0,0,255}));
    end for;

    medium.p = p_ambient;
  // Mass balance
    der(m) = sum(m_flow_BottomPorts) + sum(m_flow_SidePorts) + sum(
      m_flow_TopPorts) + Condensed.m_flow - spill_m_flow;
  // Energy balance

    U = m*medium.h - p_ambient*V "Internal energy of fluid";
    m = V*medium.d "Mass of fluid";
    V = crossArea*level + V0 "Volume of fluid";
    mXi = m*medium.Xi "Mass of fluid components";
    sat.psat = medium.p;
    sat.Tsat = Medium.saturationTemperature(medium.p);

    if noEvent(medium.T < sat.Tsat) then
      if Medium.singleState then
        der(U) = sum(H_flow_BottomPorts) + sum(H_flow_SidePorts) + sum(
          H_flow_TopPorts) + Condensed.m_flow*actualStream(Condensed.h_outflow) - spill_m_flow*h + heatTransfer.Q_flows[1]
          "Mechanical work is neglected";
      else
        der(U) = sum(H_flow_BottomPorts) + sum(H_flow_SidePorts) + sum(
          H_flow_TopPorts) + Condensed.m_flow*actualStream(Condensed.h_outflow) - spill_m_flow*h - p_ambient*der(V) +
          heatTransfer.Q_flows[1];
      end if;
      Condensed.h_outflow = h;
      Condensed.m_flow = 0;
      rho = medium.d;
      h = medium.h;
    else
      if Medium.singleState then
        der(U) = sum(H_flow_BottomPorts) + sum(H_flow_SidePorts) + sum(H_flow_TopPorts)
           + Condensed.m_flow*actualStream(Condensed.h_outflow) - spill_m_flow*h
          "Mechanical work is neglected";
      else
        der(U) = sum(H_flow_BottomPorts) + sum(H_flow_SidePorts) + sum(
          H_flow_TopPorts) + Condensed.m_flow*actualStream(Condensed.h_outflow) - spill_m_flow*h - p_ambient*der(V);
      end if;
      Condensed.h_outflow = h;
      Condensed.m_flow = -heatTransfer.Q_flows[1]/(h_v - h_l);
      rho = rho_l;//Density = liquid Density
      h = h_l;    //Enthalpy = liquid Enthalpy
      if noEvent(heatPort.Q_flow > 0.0) then
        assert(noEvent(abs(m_flow_pos) <= 0.01), "Attempt to fill tank while evaporating.");
      end if;

    end if;

    m_flow_pos = sum(m_flow_TopPorts_pos) + sum(m_flow_SidePorts_pos) + sum(
      m_flow_BottomPorts_pos);

    for i in 1:Medium.nXi loop
         der(mXi[i]) = sum(mXi_flowBottomPorts[:,i]) +
                       sum(mXi_flow_sidePorts[:,i]) +
                       sum(mXi_flow_topPorts[:,i]) - spill_m_flow*medium.Xi[i];
    end for;



    assert(not (heatPort.Q_flow > 0.0 and level <= min_level_for_heating),
      "Attempting to heat an empty tank.");

  initial equation
    if initType == Init.GuessValues then
      // no initial equations
    elseif initType == Init.InitialValues then
      level = level_start;
      if use_T_start then
        medium.T = T_start;
      else
        medium.h = h_start;
      end if;
      medium.Xi = X_start[1:Medium.nXi];
    elseif initType == Init.SteadyStateHydraulic then
      der(level) = 0;
      if use_T_start then
        medium.T = T_start;
      else
        medium.h = h_start;
      end if;
      medium.Xi = X_start[1:Medium.nXi];
    else
      assert(false, "Unsupported initialization option");
    end if;

  equation
    connect(heatPort, heatTransfer.heatPorts[1]) annotation (Line(
        points={{-200,0},{-87,0},{-87,0},{-74,0}}, color={191,0,0}));
  end TankWithEvaporator;
end SpillTanks;
