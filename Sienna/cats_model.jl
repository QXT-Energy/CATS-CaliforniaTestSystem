# =============================================================================
# CATS — Security-Constrained Unit Commitment (N-1), single model instance
#
# Solves ONE `DecisionModel` instance. The psy5 original ran a multi-step
# rolling-horizon `Simulation` on PowerSimulations; it is kept outside this
# repository, in the campaign folder's Archive/psi-simulation/.
#
# Run from the repository root (Sienna/ holds this model's environment; the case
# lives in ../CATS_openapi.sns, built by build/build_CATS.jl):
#   julia --project=Sienna Sienna/cats_model.jl
# Size it via CATS_N_GATES, CATS_N_MONITORED, CATS_PTDF_TOL, CATS_SOLVER_PARALLEL,
# CATS_SOLVER_ALGORITHM, CATS_SOLVER_LOG.
# =============================================================================

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

const POM = PowerOperationsModels
const IOM = InfrastructureOptimizationModels
const PSY = PowerSystems
const PNM = PowerNetworkMatrices
const PFS = PowerFlows

# -----------------------------------------------------------------------------
# 1. Configuration.
# -----------------------------------------------------------------------------
const CASE_FILE = joinpath(@__DIR__, "..", "CATS_openapi.sns")
const HORIZON = Hour(2)
# Required even though nothing steps: `auto_transform_time_series!` converts the
# SingleTimeSeries to a Deterministic forecast only when BOTH horizon and interval are
# set, and the model cannot build without that forecast.
const INTERVAL = Hour(1)
const START_HOUR = 17               # evening peak, not off-peak midnight
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
# Problem-size caps. At tol=0.01 a 500 kV contingency's PTDF row is nearly global
# (~2,500 nonzeros on the 5,346-bus reduced network), so each post-contingency
# constraint is dense. The matrix nonzero count scales with N_FLOW_GATES *
# N_MONITORED, and the full non-radial sets (83 x 612) would need ~10 billion
# nonzeros — far beyond 64 GB. We therefore cap BOTH: take the highest-rated
# non-radial 500 kV lines as contingencies and the highest-rated non-radial 230 kV
# lines as the monitored set. Raise these (memory/time permitting) toward the full
# counts; the selection logic is unchanged, only truncated.
const N_FLOW_GATES = parse(Int, get(ENV, "CATS_N_GATES", "5"))
const N_MONITORED = parse(Int, get(ENV, "CATS_N_MONITORED", "50"))
const DUAL_BINDING_TOL = 1e-4       # |dual| above this counts as binding

const RESULTS_ROOT = joinpath(@__DIR__, "results")
const CSV_DIR = joinpath(@__DIR__, "csv_results")
mkpath(RESULTS_ROOT)
mkpath(CSV_DIR)

# -----------------------------------------------------------------------------
# 2. Load the system.
# -----------------------------------------------------------------------------
sys = PSY.from_file(CASE_FILE)

# Read timestamps from the SingleTimeSeries rather than `get_forecast_initial_times`:
# no forecast exists yet, because the conversion happens inside `DecisionModel`.
# `Dates.hour` is qualified because TimeSeries and TimeZones also export `hour`.
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
#
# The PTDF is built here rather than by the model because flow-gate selection needs
# `get_arc_axis` to know which arcs survive the reduction before the model exists.
# The voltage checks run first: they need only the system, and the factorization over
# 8,870 buses is expensive to pay for before discovering a bad voltage constant.
# -----------------------------------------------------------------------------
available_lines = [l for l in PSY.get_components(PSY.Line, sys) if PSY.get_available(l)]

# `get_base_voltage(::Line)` reads both endpoints and errors when they disagree beyond
# PSY's tolerance — unlike the convertible-field getters it takes no unit system,
# because base voltage is always kV.
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

# A Line is "retained" (non-radial, and not collapsed by the degree-two reduction) iff
# its arc survives every reduction. Radial lines are exactly those missing from this set.
const SURVIVING_ARCS = Set(PNM.get_arc_axis(ptdf))

function is_retained(l)
    (fb, tb) = PNM.get_arc_tuple(l)
    return (fb, tb) in SURVIVING_ARCS || (tb, fb) in SURVIVING_ARCS
end

# -----------------------------------------------------------------------------
# 4. Flow-gate selection.
#
#    Classify which lines are non-radial FIRST, then build the gates from that set
#    only. Declaring a reduced (radial) line as monitored or outaged would force its
#    buses back into the network and silently undo the reduction.
#      * contingencies = highest-rated NON-RADIAL 500 kV lines -> FixedForcedOutage
#      * monitored     = highest-rated NON-RADIAL 230 kV lines -> watched post-N-1
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
    length(monitored_candidates) n_500kV_total = n_contingency_kv n_230kV_total =
    n_monitor_kv
isempty(gate_lines) && error(
    "No non-radial $(CONTINGENCY_KV) kV lines found — check voltage levels / reduction.",
)
isempty(monitored) &&
    error("No non-radial $(MONITOR_KV) kV lines found to monitor.")

# -----------------------------------------------------------------------------
# 5. Attach one N-1 outage per gate line.
#
#    POM registers these outages on the MODF it derives during
#    `instantiate_network_model!`; because every one of those lines is already
#    non-radial, the reduction is preserved.
# -----------------------------------------------------------------------------
outage_to_gate = Dict{String, String}()
for l in gate_lines
    outage =
        PSY.FixedForcedOutage(; outage_status = 1.0, monitored_components = monitored)
    PSY.add_supplemental_attribute!(sys, l, outage)
    outage_to_gate[string(IOM.IS.get_id(outage))] = PSY.get_name(l)
end

# -----------------------------------------------------------------------------
# 6. Network model. The MODF is derived from the prebuilt PTDF's factorization
#    core, so there is no separate MODF argument and no second reduction.
# -----------------------------------------------------------------------------
network_model = POM.NetworkModel(
    POM.PTDFNetworkModel;
    use_slacks = true,
    network_source = POM.PrebuiltMatrixSource(ptdf),
    evaluations = POM.power_flow_evaluations(PFS.DCPowerFlow()),
)

# -----------------------------------------------------------------------------
# 7. Template. The security behaviour is selected solely by the Line formulation
#    `SecurityConstrainedStaticBranch`, restricted to the 230 kV + 500 kV backbone
#    via `filter_function`.
# -----------------------------------------------------------------------------
template = POM.PowerOperationsProblemTemplate(network_model)
POM.set_device_model!(template, PSY.ThermalStandard, POM.ThermalBasicUnitCommitment)
POM.set_device_model!(template, PSY.RenewableDispatch, POM.RenewableFullDispatch)
POM.set_device_model!(template, PSY.HydroDispatch, POM.HydroDispatchRunOfRiver)
POM.set_device_model!(template, PSY.PowerLoad, POM.StaticPowerLoad)
POM.set_device_model!(template, PSY.TwoWindingTransformer, POM.StaticBranchUnbounded)
# The hydro promotion (HydroTurbine/HydroPumpTurbine) and the interties modelled as
# Source carry ~18 GW, a fifth of the fleet. POM only warns for component types a
# template omits, so leaving them out silently pushes that capacity into the network
# slacks.
#
# Run-of-river rather than a reservoir formulation: the reservoir models
# (HydroEnergyModelReservoir, HydroWaterModelReservoir) build an EnergyBalanceConstraint
# per HydroReservoir and require an inflow series, but the enrichment found inflow data
# for only 14 of the 32 reservoirs — the build fails on the first one without. Every
# turbine does carry `max_active_power`, which is what run-of-river needs, and the 248
# HydroDispatch units above are already modelled this way. Revisit if inflow coverage
# reaches all reservoirs and reservoir scheduling matters over a longer horizon.
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
# 8. Decision model -> build! -> solve!.
# -----------------------------------------------------------------------------
solver = JuMP.optimizer_with_attributes(
    HiGHS.Optimizer,
    "mip_rel_gap" => MIP_GAP,
    "time_limit" => SOLVER_TIME_LIMIT_S,
    "threads" => SOLVER_THREADS,
    "parallel" => SOLVER_PARALLEL,
    "solver" => SOLVER_ALGORITHM,
    # mip_lp_solver is distinct from `solver` — it picks the LP method used for the
    # root + node LP relaxations inside branch-and-bound, which is what actually runs
    # repeatedly for a MIP like this UC problem.
    "mip_lp_solver" => SOLVER_ALGORITHM,
    # HiGHS has no Gurobi-style MIPFocus. The intent of MIPFocus=1 (find feasible
    # integer incumbents quickly — the dual LP needs a feasible commitment) maps to
    # raising the heuristic effort (default 0.05).
    "mip_heuristic_effort" => 0.5,
)

model = POM.DecisionModel(
    template,
    sys;
    optimizer = solver,
    initial_time = INITIAL_DATE,
    horizon = HORIZON,
    interval = INTERVAL,
    check_numerical_bounds = false,
    initialize_model = false,
    direct_mode_optimizer = true,
    optimizer_solve_log_print = get(ENV, "CATS_SOLVER_LOG", "0") == "1",
    calculate_conflict = false,
    name = "CATS_SCUC",
)

status = POM.build!(model; output_dir = RESULTS_ROOT, console_level = Logging.Info)
if status != IOM.ModelBuildStatus.BUILT
    error("build! returned $(status), expected ModelBuildStatus.BUILT")
end

POM.solve!(model)
outputs = IOM.OptimizationProblemOutputs(model)

# -----------------------------------------------------------------------------
# 9. Dual analysis + CSV export.
# -----------------------------------------------------------------------------
let stats = IOM.read_optimizer_stats(outputs)
    @info "Solver performance" solver = SOLVER_ALGORITHM parallel = SOLVER_PARALLEL threads =
        SOLVER_THREADS
    for r in eachrow(stats)
        gap = hasproperty(stats, :relative_gap) ? r.relative_gap : missing
        nodes = hasproperty(stats, :node_count) ? r.node_count : missing
        @info "  solve" solve_time = round(r.solve_time; sigdigits = 4) objective =
            round(r.objective_value; sigdigits = 6) relative_gap = gap node_count = nodes
    end
end

"""Read every stored dual whose name starts with `prefix`; return a DataFrame of
   (series, peak_abs_dual), taking the peak |dual| over time per series. FlowRate and
   PostContingencyFlowRate are two-sided, so the store holds separate `__lb` / `__ub`
   containers; merging by |dual| picks the active side, which carries the nonzero."""
function peak_abs_duals(res, prefix)
    names = filter(n -> startswith(n, prefix), string.(IOM.list_dual_names(res)))
    peaks = Dict{String, Float64}()
    for nm in names
        df = IOM.read_dual(res, nm)
        for sub in groupby(df, :name)
            key = string(first(sub.name))
            p = maximum(abs.(Float64.(sub.value)); init = 0.0)
            peaks[key] = max(get(peaks, key, 0.0), p)
        end
    end
    out = DataFrame(; series = collect(keys(peaks)), peak_abs_dual = collect(values(peaks)))
    sort!(out, :peak_abs_dual; rev = true)
    return names, out
end

function write_dual_report(res, prefix, csv_name, label; top_n, transform, describe)
    names, df = peak_abs_duals(res, prefix)
    df = transform(df)
    df.binding = df.peak_abs_dual .> DUAL_BINDING_TOL
    CSV.write(joinpath(CSV_DIR, csv_name), df)
    @info label sources = names n_series = nrow(df) n_binding = count(df.binding) n_never =
        count(.!df.binding)
    for r in eachrow(first(df[df.binding, :], top_n))
        @info "  " * describe(r) * " : peak |dual| = " *
              "$(round(r.peak_abs_dual; sigdigits = 4)) \$/MWh"
    end
    return df
end

# POM keys post-contingency containers by the tuple (outage_id, monitored_name, t); the
# flattened `:name` written to the store joins the first two with IOM's "__" delimiter.
# A label without the separator means that encoding changed — error rather than map it to
# a misleading contingency name.
function split_post(series)
    parts = split(series, "__"; limit = 2)
    if length(parts) != 2
        error(
            "post-contingency dual series \"$(series)\" carries no \"__\" separator; " *
            "IOM's tuple-column encoding changed and split_post needs updating",
        )
    end
    outage_id, monitored_name = parts
    return get(outage_to_gate, outage_id, outage_id), monitored_name
end

@info "Dual containers available" containers = string.(IOM.list_dual_names(outputs))

write_dual_report(
    outputs,
    "FlowRateConstraint__Line",
    "base_case_flow_duals.csv",
    "Base-case FlowRateConstraint";
    top_n = 15,
    transform = df -> rename(df, :series => :line),
    describe = r -> "base  $(r.line)",
)

write_dual_report(
    outputs,
    "PostContingencyFlowRateConstraint__Line",
    "post_contingency_flow_duals.csv",
    "Post-contingency FlowRateConstraint";
    top_n = 20,
    transform = function (df)
        splits = split_post.(df.series)
        df.contingency_line = first.(splits)
        df.monitored_line = last.(splits)
        return select(df, :contingency_line, :monitored_line, :peak_abs_dual)
    end,
    describe = r -> "post  $(r.contingency_line)  ⟶  $(r.monitored_line)",
)

@info "Done." results = RESULTS_ROOT duals_csv = CSV_DIR
