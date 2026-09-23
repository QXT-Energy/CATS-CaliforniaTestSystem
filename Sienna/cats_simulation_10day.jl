# =============================================================================
# CATS — Security-Constrained Unit Commitment (N-1), 10-day rolling Simulation
#
# `cats_model.jl` solves one `DecisionModel` instance. This script wraps the same
# template in a PowerSimulations `Simulation` to test multi-step rolling-horizon
# execution: one day-ahead UC solve per day, `CATS_SIM_STEPS` days back to back.
#
# This repo's own Sienna/Project.toml does not depend on PowerSimulations. Run this
# script against the environment that already builds PSI + POM + IOM + PSY + PNM +
# PowerFlows together — psy6/PowerSimulations.jl's test env (HiGHS included):
#   julia --project=/home/jdlara/Sienna_work/psy6/PowerSimulations.jl/test \
#       Sienna/cats_simulation_10day.jl
# Size it via CATS_N_GATES, CATS_N_MONITORED, CATS_PTDF_TOL, CATS_SOLVER_PARALLEL,
# CATS_SOLVER_ALGORITHM, CATS_SOLVER_LOG, CATS_SIM_STEPS, CATS_SIM_HORIZON_HOURS,
# CATS_SIM_INTERVAL_HOURS, CATS_SIM_START_HOUR.
# =============================================================================

using PowerSimulations
using PowerOperationsModels
using InfrastructureOptimizationModels
using PowerSystems
using PowerNetworkMatrices
using PowerFlows
using DataFrames
using CSV
using Dates
using Logging
using JuMP
using HiGHS

const PSI = PowerSimulations
const POM = PowerOperationsModels
const IOM = InfrastructureOptimizationModels
const PSY = PowerSystems
const PNM = PowerNetworkMatrices
const PFS = PowerFlows

# -----------------------------------------------------------------------------
# 1. Configuration.
# -----------------------------------------------------------------------------
const CASE_DIR = joinpath(@__DIR__, "..", "CATS_openapi")
const START_HOUR = parse(Int, get(ENV, "CATS_SIM_START_HOUR", "0"))  # day-ahead cadence
const STEPS = parse(Int, get(ENV, "CATS_SIM_STEPS", "10"))
const HORIZON = Hour(parse(Int, get(ENV, "CATS_SIM_HORIZON_HOURS", "24")))
const INTERVAL = Hour(parse(Int, get(ENV, "CATS_SIM_INTERVAL_HOURS", "24")))
const MIP_GAP = 0.01
const SOLVER_TIME_LIMIT_S = 600.0
const SOLVER_THREADS = 18
const SOLVER_PARALLEL = get(ENV, "CATS_SOLVER_PARALLEL", "on")       # "choose" | "on" | "off"
const SOLVER_ALGORITHM = get(ENV, "CATS_SOLVER_ALGORITHM", "hipo")   # "choose" | "simplex" | "hipo" | "ipm"

# Sparsification tolerance for the PTDF rows (absolute cutoff on a
# distribution-factor coefficient). Smaller = more accurate, denser rows. The MODF
# inherits it: POM derives the MODF from this PTDF's factorization core.
const PTDF_TOL = parse(Float64, get(ENV, "CATS_PTDF_TOL", "0.01"))

const MODELED_KV = 230.0            # security constraints apply at or above this
const CONTINGENCY_KV = 500.0
const MONITOR_KV = 230.0
# Same problem-size caps as cats_model.jl — see that file for the derivation.
const N_FLOW_GATES = parse(Int, get(ENV, "CATS_N_GATES", "5"))
const N_MONITORED = parse(Int, get(ENV, "CATS_N_MONITORED", "50"))

const SIM_NAME = "CATS_10day"
const SIM_ROOT = joinpath(@__DIR__, "results")
mkpath(SIM_ROOT)

# -----------------------------------------------------------------------------
# 2. Load the system.
# -----------------------------------------------------------------------------
sys = PSY.from_file(PSY.System, CASE_DIR)

# Read timestamps from the SingleTimeSeries rather than `get_forecast_initial_times`:
# no forecast exists yet, because the conversion happens inside `DecisionModel`.
function pick_initial_time(system, target_hour)
    owner = first(PSY.get_components(PSY.has_time_series, PSY.PowerLoad, system))
    stamps =
        PSY.get_time_series_timestamps(PSY.SingleTimeSeries, owner, "max_active_power")
    idx = findfirst(t -> Dates.hour(t) == target_hour, stamps)
    if isnothing(idx)
        return error(
            "No timestamp at hour $(target_hour); " *
            "available hours: $(sort(unique(Dates.hour.(stamps))))",
        )
    end
    return stamps[idx]
end

const INITIAL_DATE = pick_initial_time(sys, START_HOUR)

# -----------------------------------------------------------------------------
# 3. Line classification, voltage pre-check, then the reduced PTDF.
#    (Identical to cats_model.jl — see that file for the full rationale.)
# -----------------------------------------------------------------------------
available_lines = [l for l in PSY.get_components(PSY.Line, sys) if PSY.get_available(l)]

function at_voltage(l, kv)
    return isapprox(PSY.get_base_voltage(l), kv; rtol = 0.05)
end

n_contingency_kv = count(l -> at_voltage(l, CONTINGENCY_KV), available_lines)
n_monitor_kv = count(l -> at_voltage(l, MONITOR_KV), available_lines)
iszero(n_contingency_kv) &&
    error("No available $(CONTINGENCY_KV) kV lines — check CONTINGENCY_KV.")
iszero(n_monitor_kv) && error("No available $(MONITOR_KV) kV lines — check MONITOR_KV.")

const REDUCTIONS = [PNM.RadialReduction(), PNM.DegreeTwoReduction()]

ptdf = PNM.VirtualPTDF(sys; tol = PTDF_TOL, network_reductions = REDUCTIONS)

const SURVIVING_ARCS = Set(PNM.get_arc_axis(ptdf))

function is_retained(l)
    (fb, tb) = PNM.get_arc_tuple(l)
    return (fb, tb) in SURVIVING_ARCS || (tb, fb) in SURVIVING_ARCS
end

# -----------------------------------------------------------------------------
# 4. Flow-gate selection.
# -----------------------------------------------------------------------------
contingency_candidates =
    [l for l in available_lines if at_voltage(l, CONTINGENCY_KV) && is_retained(l)]
monitored_candidates =
    [l for l in available_lines if at_voltage(l, MONITOR_KV) && is_retained(l)]

function by_descending_rating(l)
    return -PSY.get_rating(l, PSY.SU)
end

gate_lines = first(sort(contingency_candidates; by = by_descending_rating), N_FLOW_GATES)
monitored = first(sort(monitored_candidates; by = by_descending_rating), N_MONITORED)

@info "Flow gates (N-1)" n_contingencies = length(gate_lines) n_monitored =
    length(monitored) n_nonradial_500kV = length(contingency_candidates) n_nonradial_230kV =
    length(monitored_candidates)
isempty(gate_lines) && error(
    "No non-radial $(CONTINGENCY_KV) kV lines found — check voltage levels / reduction.",
)
isempty(monitored) &&
    error("No non-radial $(MONITOR_KV) kV lines found to monitor.")

# -----------------------------------------------------------------------------
# 5. Attach one N-1 outage per gate line.
# -----------------------------------------------------------------------------
for l in gate_lines
    outage =
        PSY.FixedForcedOutage(; outage_status = 1.0, monitored_components = monitored)
    PSY.add_supplemental_attribute!(sys, l, outage)
end

# -----------------------------------------------------------------------------
# 6. Network model.
# -----------------------------------------------------------------------------
network_model = POM.NetworkModel(
    POM.PTDFNetworkModel;
    use_slacks = true,
    network_source = POM.PrebuiltMatrixSource(ptdf),
    evaluations = POM.power_flow_evaluations(PFS.DCPowerFlow()),
)

# -----------------------------------------------------------------------------
# 7. Template. (Identical device-model choices to cats_model.jl.)
# -----------------------------------------------------------------------------
template = POM.PowerOperationsProblemTemplate(network_model)
POM.set_device_model!(template, PSY.ThermalStandard, POM.ThermalBasicUnitCommitment)
POM.set_device_model!(template, PSY.RenewableDispatch, POM.RenewableFullDispatch)
POM.set_device_model!(template, PSY.HydroDispatch, POM.HydroDispatchRunOfRiver)
POM.set_device_model!(template, PSY.PowerLoad, POM.StaticPowerLoad)
POM.set_device_model!(template, PSY.TwoWindingTransformer, POM.StaticBranchUnbounded)
POM.set_device_model!(template, PSY.Source, POM.ImportExportSourceModel)
POM.set_device_model!(template, PSY.HydroTurbine, POM.HydroCommitmentRunOfRiver)
POM.set_device_model!(template, PSY.HydroPumpTurbine, POM.HydroCommitmentRunOfRiver)
POM.set_device_model!(
    template,
    POM.DeviceModel(
        PSY.Line,
        POM.SecurityConstrainedStaticBranch;
        use_slacks = true,
        duals = DataType[POM.FlowRateConstraint, POM.PostContingencyFlowRateConstraint],
        attributes = Dict(
            "filter_function" => x -> PSY.get_base_voltage(x) >= MODELED_KV,
        ),
    ),
)
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
# 8. Simulation: one day-ahead DecisionModel, run for STEPS days.
# -----------------------------------------------------------------------------
solver = JuMP.optimizer_with_attributes(
    HiGHS.Optimizer,
    "mip_rel_gap" => MIP_GAP,
    "time_limit" => SOLVER_TIME_LIMIT_S,
    "threads" => SOLVER_THREADS,
    "parallel" => SOLVER_PARALLEL,
    "solver" => SOLVER_ALGORITHM,
    "mip_lp_solver" => SOLVER_ALGORITHM,
    "mip_heuristic_effort" => 0.5,
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
    optimizer_solve_log_print = get(ENV, "CATS_SOLVER_LOG", "0") == "1",
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
if build_status != PSI.SimulationBuildStatus.BUILT
    error("build!(sim) returned $(build_status), expected SimulationBuildStatus.BUILT")
end

execute_status = PSI.execute!(sim)
if execute_status != PSI.RunStatus.SUCCESSFULLY_FINALIZED
    error("execute!(sim) returned $(execute_status), expected RunStatus.SUCCESSFULLY_FINALIZED")
end

# -----------------------------------------------------------------------------
# 9. Per-step solver performance.
# -----------------------------------------------------------------------------
results = PSI.SimulationResults(sim)
res = PSI.get_decision_problem_results(results, "SCUC")
stats = IOM.read_optimizer_stats(res)
@info "Solver performance" solver = SOLVER_ALGORITHM parallel = SOLVER_PARALLEL threads =
    SOLVER_THREADS steps = STEPS horizon = HORIZON interval = INTERVAL
for (i, r) in enumerate(eachrow(stats))
    gap = hasproperty(stats, :relative_gap) ? r.relative_gap : missing
    nodes = hasproperty(stats, :node_count) ? r.node_count : missing
    @info "  step $(i)" solve_time = round(r.solve_time; sigdigits = 4) objective =
        round(r.objective_value; sigdigits = 6) relative_gap = gap node_count = nodes
end

@info "Done." simulation_dir = PSI.get_simulation_dir(sim)
