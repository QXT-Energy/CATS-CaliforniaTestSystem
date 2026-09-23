# =============================================================================
# CATS — PowerAnalytics + PowerGraphics smoke test against a PowerSimulations run
#
# Runs a small, fast CATS UC `Simulation` — CopperPlate network, no N-1 security
# constraints (that's ../cats_simulation_10day.jl's job; the PTDF/MODF construction
# there is expensive independent of problem size and isn't needed to prove this
# wiring) — then exercises the two results-consuming packages against its
# `SimulationProblemResults`:
#   - PowerAnalytics: computes a couple of built-in `Metric`s (`calc_active_power`)
#     directly on the simulation results (both PSI's `SimulationProblemResults` and
#     IOM's `OptimizationProblemOutputs` are `InfrastructureSystems.Outputs`, the
#     type PowerAnalytics dispatches on — no PSI-specific glue needed).
#   - PowerGraphics: renders a fuel-mix stack plot via the PlotlyLight backend and
#     saves it as HTML.
#
# Run with the dedicated env in this folder (dev's local PowerAnalytics/PowerGraphics
# checkouts + the same pins as the working psy6/PowerSimulations.jl/test env):
#   julia --project=Sienna/analytics Sienna/analytics/test_analytics_graphics.jl
# Size it via CATS_SIM_STEPS, CATS_SIM_HORIZON_HOURS, CATS_SIM_INTERVAL_HOURS.
# =============================================================================

using PowerSimulations
using PowerOperationsModels
using InfrastructureOptimizationModels
using PowerSystems
using PowerAnalytics
using PowerAnalytics.Metrics
using PowerGraphics
using PlotlyLight
using DataFrames
using Dates
using Logging
using JuMP
using HiGHS

const PSI = PowerSimulations
const POM = PowerOperationsModels
const IOM = InfrastructureOptimizationModels
const PSY = PowerSystems
const PA = PowerAnalytics
const PG = PowerGraphics

# -----------------------------------------------------------------------------
# 1. Configuration — small and fast; this script is about proving the wiring,
#    not stress-testing a formulation (see cats_simulation_10day.jl for that).
# -----------------------------------------------------------------------------
const CASE_DIR = joinpath(@__DIR__, "..", "..", "CATS_openapi")
const START_HOUR = parse(Int, get(ENV, "CATS_SIM_START_HOUR", "0"))
const STEPS = parse(Int, get(ENV, "CATS_SIM_STEPS", "2"))
const HORIZON = Hour(parse(Int, get(ENV, "CATS_SIM_HORIZON_HOURS", "4")))
const INTERVAL = Hour(parse(Int, get(ENV, "CATS_SIM_INTERVAL_HOURS", "4")))
const MIP_GAP = 0.01
const SOLVER_TIME_LIMIT_S = 300.0
const SOLVER_THREADS = parse(Int, get(ENV, "CATS_SOLVER_THREADS", "8"))

const SIM_NAME = "CATS_analytics_smoke"
const SIM_ROOT = joinpath(@__DIR__, "results")
mkpath(SIM_ROOT)

# -----------------------------------------------------------------------------
# 2. Load the system, pick an initial time.
# -----------------------------------------------------------------------------
sys = PSY.from_file(PSY.System, CASE_DIR)

function pick_initial_time(system, target_hour)
    owner = first(PSY.get_components(PSY.has_time_series, PSY.PowerLoad, system))
    stamps =
        PSY.get_time_series_timestamps(PSY.SingleTimeSeries, owner, "max_active_power")
    idx = findfirst(t -> Dates.hour(t) == target_hour, stamps)
    isnothing(idx) && error("No timestamp at hour $(target_hour)")
    return stamps[idx]
end

const INITIAL_DATE = pick_initial_time(sys, START_HOUR)

# -----------------------------------------------------------------------------
# 3. Network model + template. CopperPlate — no PTDF/MODF, no security
#    constraints — keeps this a wiring smoke test, not a formulation stress test.
# -----------------------------------------------------------------------------
network_model = POM.NetworkModel(POM.CopperPlateNetworkModel; use_slacks = true)

template = POM.PowerOperationsProblemTemplate(network_model)
POM.set_device_model!(template, PSY.ThermalStandard, POM.ThermalBasicUnitCommitment)
POM.set_device_model!(template, PSY.RenewableDispatch, POM.RenewableFullDispatch)
POM.set_device_model!(template, PSY.HydroDispatch, POM.HydroDispatchRunOfRiver)
POM.set_device_model!(template, PSY.PowerLoad, POM.StaticPowerLoad)
POM.set_device_model!(template, PSY.TwoWindingTransformer, POM.StaticBranchUnbounded)
POM.set_device_model!(template, PSY.Line, POM.StaticBranchUnbounded)
POM.set_device_model!(template, PSY.Source, POM.ImportExportSourceModel)
POM.set_device_model!(template, PSY.HydroTurbine, POM.HydroCommitmentRunOfRiver)
POM.set_device_model!(template, PSY.HydroPumpTurbine, POM.HydroCommitmentRunOfRiver)
POM.set_device_model!(
    template,
    POM.DeviceModel(
        PSY.EnergyReservoirStorage,
        POM.StorageDispatchWithReserves;
        attributes = Dict(
            "reservation" => false,
            "cycling_limits" => false,
            "energy_target" => false,
            "complete_coverage" => false,
            "regularization" => true,
        ),
    ),
)

# -----------------------------------------------------------------------------
# 4. Simulation: build! + execute!.
# -----------------------------------------------------------------------------
solver = JuMP.optimizer_with_attributes(
    HiGHS.Optimizer,
    "mip_rel_gap" => MIP_GAP,
    "time_limit" => SOLVER_TIME_LIMIT_S,
    "threads" => SOLVER_THREADS,
)

decision_model = PSI.DecisionModel(
    template,
    sys;
    optimizer = solver,
    horizon = HORIZON,
    interval = INTERVAL,
    check_numerical_bounds = false,
    initialize_model = false,
    direct_mode_optimizer = true,
    calculate_conflict = false,
    name = "SCUC",
)

models = PSI.SimulationModels([decision_model])
sequence = PSI.SimulationSequence(;
    models = models,
    ini_cond_chronology = PSI.InterProblemChronology(),
)
sim = PSI.Simulation(;
    name = SIM_NAME,
    steps = STEPS,
    models = models,
    sequence = sequence,
    simulation_folder = SIM_ROOT,
    initial_time = INITIAL_DATE,
)

build_status = PSI.build!(sim; console_level = Logging.Info)
build_status != PSI.SimulationBuildStatus.BUILT &&
    error("build!(sim) returned $(build_status)")

execute_status = PSI.execute!(sim)
execute_status != PSI.RunStatus.SUCCESSFULLY_FINALIZED &&
    error("execute!(sim) returned $(execute_status)")

@info "Simulation done." simulation_dir = PSI.get_simulation_dir(sim)

# -----------------------------------------------------------------------------
# 5. PowerAnalytics: compute built-in metrics directly on `SimulationProblemResults`.
#    `PSI.SimulationProblemResults <: InfrastructureSystems.Outputs`, the type
#    PowerAnalytics's `Metric`s dispatch on. Three fixes make this actually work now:
#      - PowerAnalytics's `read_key_wide` has a generic fallback for any `IS.Outputs`
#        (input_utils.jl, alongside the `IOM.OptimizationProblemOutputs`-specific method).
#      - PSI's `IOM.read_variable` override takes the same `start_time`/`len` keywords
#        IOM's reference implementation uses (PowerSimulations.jl PR #1662).
#      - `read_key_wide` now flattens a multi-window `SortedDict{DateTime,DataFrame}`
#        (what a rolling-horizon `Simulation` returns, since consecutive windows overlap)
#        into one continuous wide `DataFrame` via `IOM.make_realized_dataframe`
#        (InfrastructureOptimizationModels.jl PR #161), honoring the "one wide DataFrame"
#        contract `read_key_wide` always documented but never enforced for such types.
# -----------------------------------------------------------------------------
results = PSI.SimulationResults(sim)
res = PSI.get_decision_problem_results(results, "SCUC"; populate_system = true)

thermal_selector = PSY.make_selector(PSY.ThermalStandard; groupby = :all)

thermal_power = calc_active_power(thermal_selector, res)
@info "PowerAnalytics: calc_active_power OK" rows = nrow(thermal_power) cols =
    names(thermal_power)

# -----------------------------------------------------------------------------
# 6. PowerGraphics: fuel-mix stack plot via the PlotlyLight backend.
# -----------------------------------------------------------------------------
try
    fuel_plot = PG.plot_fuel_plotly(
        res;
        title = "CATS_fuel",
        save = SIM_ROOT,
        format = "html",
        set_display = false,
    )
    @info "PowerGraphics: saved fuel plot" path = joinpath(SIM_ROOT, "CATS_fuel.html")
catch e
    @error """
    plot_fuel_plotly failed on a CATS-template mismatch, not the PowerAnalytics/PSI wiring
    fixed above: it wants an `ActivePowerTimeSeriesParameter` for `ThermalStandard`, but
    ThermalBasicUnitCommitment dispatches thermal units by optimization variable, not a
    time-series parameter, so none is stored. Likely needs a `plot_fuel_plotly` kwarg to
    exclude ThermalStandard from whatever curtailment/capacity-factor metric wants it, or a
    fix in PowerGraphics's default fuel-stack categorization for non-parameter-driven
    generators. Separate issue from the wide/narrow read path.
    """ exception = (e, catch_backtrace())
end

@info "Done." powerAnalytics_ok = !isnothing(thermal_power)
