using PowerSystems
using PowerFlowFileParser
import PowerOpenAPIModels
using CSV
using DataFrames
using Dates
using TimeSeries
using JLD2
using JSON
using Random
rng = Xoshiro(123)

function _draw_storage_efficiency()
    # Uniform in [0.92, 0.98] (0.95 ± 3%), rounded to 2 significant figures.
    return round(0.92 + 0.06 * rand(), digits=2)
end

const PSY = PowerSystems
const PFP = PowerFlowFileParser
const POAM = PowerOpenAPIModels

# psy6 dropped `scaling_factor_multiplier`: a normalized series now *declares* itself instead
# of naming a getter the consumer must resolve. `unit_system = CU` says the values are per unit
# on the component's own base; `quantity_kind` names what they scale to. `units` stays nothing
# because a per-unit basis is not a units label. Mirrors PowerSystemCaseBuilder's `per_unit_of`.
per_unit_of(quantity_kind::AbstractString) =
    (unit_system = PSY.CU, units = nothing, quantity_kind = quantity_kind)

include(joinpath(@__DIR__, "parse_matpower.jl"))
include(joinpath(@__DIR__, "generator_types.jl"))
BASE_DIR = joinpath(@__DIR__, "..")

VALIDITY_CHECKS = true

DATA_DIR = joinpath(BASE_DIR, "data")
additional_fields(::Type{T}) where T<:StaticInjection = Dict{Symbol, Any}()

additional_fields(::Type{RenewableDispatch}) = Dict{Symbol, Any}(
    :power_factor => 0.95,
    :operation_cost => RenewableGenerationCost(nothing),
)

additional_fields(::Type{HydroDispatch}) = Dict{Symbol, Any}(
    :operation_cost => HydroGenerationCost(nothing),
)

additional_fields(::Type{Source}) = Dict{Symbol, Any}(
    :operation_cost => ImportExportCost(nothing),
)

additional_fields(::Type{EnergyReservoirStorage}) = Dict{Symbol, Any}(
    :storage_technology_type => StorageTech.LIB,
    :storage_capacity => 0.0,
    :storage_level_limits => (0.0, 1.0),
    :initial_storage_capacity_level => 0.0,
    :input_active_power_limits => (0.0, 0.0),
    :output_active_power_limits => (0.0, 0.0),
    :efficiency => (1.0, 1.0),
)

# most things have a prime mover type...
function maybe_add_prime_mover_type!(
    d::Dict{Symbol, Any},
    pm_type::PSY.PrimeMovers,
    ::Type{<:StaticInjection}
)
    d[:prime_mover_type] = pm_type
end

# ...except for imports and SCs.
maybe_add_prime_mover_type!(
    ::Dict{Symbol, Any},
    ::PSY.PrimeMovers,
    ::Type{<:Union{Source, SynchronousCondenser}}
) = nothing

"""
A somewhat hacky way of converting a ThermalStandard generator to another type of generator.
"""
function try_convert(T::Type{<:StaticInjection}, gen::ThermalStandard, pm_type::PSY.PrimeMovers)
    commonKeys = intersect(fieldnames(ThermalStandard), fieldnames(T))
    old_data = Dict(key=>getfield(gen, key) for key ∈ commonKeys)
    delete!.((old_data,), (:operation_cost, :internal, :prime_mover_type))
    maybe_add_prime_mover_type!(old_data, pm_type, T)
    return T(;
        old_data...,
        additional_fields(T)...
    )
end

"""
Rename `gen` to `new_name` in `system`, preserving every other field exactly. A no-op if
`gen` already carries `new_name` (imports and synchronous condensers, which the EIA
enrichment never renames). The renamed component gets a fresh `InfrastructureSystemsInternal`
(new UUID), matching the convention `try_convert` below already uses when it reconstructs a
component under a new identity.
"""
function rename_generator!(system::System, gen::ThermalStandard, new_name::AbstractString)
    if get_name(gen) == new_name
        return gen
    end
    old_data = Dict(key => getfield(gen, key) for key in fieldnames(ThermalStandard))
    delete!(old_data, :internal)
    old_data[:name] = new_name
    remove_component!(system, gen)
    renamed = ThermalStandard(; old_data...)
    add_component!(system, renamed)
    return renamed
end

"""
No extra fields needed to promote `gen` into a HydroTurbine.
"""
_extra_hydro_fields(::Type{HydroTurbine}, ::HydroDispatch) = Dict{Symbol, Any}()

"""
HydroPumpTurbine has four fields with no HydroDispatch analog and no default value:
`active_power_limits_pump` (this dataset carries no per-unit EIA pump nameplate, so the pump
range is assumed symmetric to the unit's own turbine active_power_limits -- a guess, recorded
in the audit report), `outflow_limits` (no source; left unconstrained), and
`powerhouse_elevation` (the design's relative-datum convention: 0.0, matching HydroTurbine's
own default).
"""
function _extra_hydro_fields(::Type{HydroPumpTurbine}, gen::HydroDispatch)
    return Dict{Symbol, Any}(
        :active_power_limits_pump => getfield(gen, :active_power_limits),
        :outflow_limits => nothing,
        :powerhouse_elevation => 0.0,
    )
end

"""
Convert `gen::HydroDispatch` into a HydroTurbine or HydroPumpTurbine, carrying over every
shared physical field (bus, active/reactive power, ratings, power limits, ramp/time limits,
base_power, operation_cost). `status`/`time_at_status` are dropped rather than copied:
HydroDispatch.status is a commitment Bool, HydroPumpTurbine.status is an unrelated
HydroPumpTurbineStatus mode flag (same field name, incompatible type), and HydroTurbine has
no such field at all.

The result is not yet attached to a HydroReservoir -- see `attach_hydro_reservoirs!` below;
neither HydroTurbine nor HydroPumpTurbine is meaningful without one.
"""
function promote_hydro(
    T::Type{<:Union{HydroTurbine, HydroPumpTurbine}},
    gen::HydroDispatch,
    pm_type::PSY.PrimeMovers,
)
    common_keys = intersect(fieldnames(HydroDispatch), fieldnames(T))
    old_data = Dict(key => getfield(gen, key) for key in common_keys)
    delete!.((old_data,), (:internal, :prime_mover_type, :status, :time_at_status))
    old_data[:prime_mover_type] = pm_type
    return T(; old_data..., _extra_hydro_fields(T, gen)...)
end

function hydro_target_type(target_type::AbstractString)
    if target_type == "HydroTurbine"
        return HydroTurbine
    elseif target_type == "HydroPumpTurbine"
        return HydroPumpTurbine
    else
        error("Unknown hydro target_type \"$target_type\" in hydro_units.csv")
    end
end

"""
Stage 4 of the EIA hydro enrichment (data/hydro_units.csv): promote every unit marked
`promoted == true` from HydroDispatch into a HydroTurbine or HydroPumpTurbine per its
`target_type` column. Carries any attached GeographicInfo across the type change, since
`remove_component!`/`add_component!` (required for a type change) does not do so on its own.
Returns a name -> component map of the promoted units for `attach_hydro_reservoirs!`.
"""
function promote_hydro_units!(system::System, hydro_df::DataFrame)
    promoted_units = Dict{String, Union{HydroTurbine, HydroPumpTurbine}}()
    for row in eachrow(hydro_df)
        row.promoted || continue
        name = row.new_name
        gen = get_component(HydroDispatch, system, name)
        isnothing(gen) && error(
            "hydro_units.csv marks \"$name\" (PlantCode $(row.PlantCode)) as promoted, but " *
            "no HydroDispatch by that name exists in the system.",
        )
        T = hydro_target_type(row.target_type)
        # String(...): the enum's own String constructor requires a concrete String, not
        # CSV.jl's InlineStrings short-string types (String3/String7/...) -- verified this
        # throws a MethodError ("cannot convert ... to Int64") without the conversion.
        pm_type = PrimeMovers(String(row.eia_pm))

        geo_attrs = collect(get_supplemental_attributes(GeographicInfo, gen))
        for geo in geo_attrs
            remove_supplemental_attribute!(system, gen, geo)
        end
        remove_component!(system, gen)
        turbine = promote_hydro(T, gen, pm_type)
        add_component!(system, turbine)
        for geo in geo_attrs
            add_supplemental_attribute!(system, turbine, geo)
        end
        promoted_units[name] = turbine
    end
    return promoted_units
end

"""hydro_reservoirs.csv's own `turbine_type` column already applies the design's head-band
rule (verified: every one of the 32 real rows carries FRANCIS/PELTON/KAPLAN) -- read it
directly rather than recomputing it here, so there is exactly one place that rule lives."""
apply_turbine_type!(turbine::HydroTurbine, turbine_type::AbstractString) =
    set_turbine_type!(turbine, HydroTurbineType(String(turbine_type)))

"""HydroPumpTurbine has no `turbine_type` field (verified in
PowerSystems.jl/src/models/generated/HydroPumpTurbine.jl): the design's head-band assignment
rule is inapplicable to it, so this is a documented no-op rather than an error."""
apply_turbine_type!(::HydroPumpTurbine, turbine_type::AbstractString) = nothing

"""`inflow_m3s` is the mean 2019 daily inflow from CDEC sensor 76 or a USGS NWIS gauge, real
for 14 of the 32 reservoirs. The other 18 have no flow gauge and stay blank rather than being
estimated from basin neighbours; those default to 0.0 here."""
_reservoir_inflow_m3ph(inflow_m3s::Missing) = 0.0
_reservoir_inflow_m3ph(inflow_m3s::Real) = inflow_m3s * 3600.0  # m^3/s -> m^3/h

"""
Stage 5 of the EIA hydro enrichment (data/hydro_reservoirs.csv): build one HydroReservoir per
promoted plant and wire the plant's promoted turbines into `downstream_turbines`.
`upstream_reservoirs` is left empty everywhere -- cascade topology (Big Creek, Pit River) is
deferred by design decision, not oversight.

Every HydroPumpTurbine therefore ends up with only the single (upper) reservoir this stage
builds, not the second (lower) reservoir its own docstring calls for: no source in this
dataset identifies a paired lower reservoir for any of the 13 promoted PS units, and inventing
one would be a fabrication rather than an approximation. This is a known model
simplification, not a bug -- flagged here and in the final report.
"""
function attach_hydro_reservoirs!(
    system::System,
    reservoirs_df::DataFrame,
    hydro_df::DataFrame,
    promoted_units::Dict{String, <:Union{HydroTurbine, HydroPumpTurbine}},
)
    plant_code_to_names = Dict{Int, Vector{String}}()
    for row in eachrow(hydro_df)
        row.promoted || continue
        push!(get!(plant_code_to_names, row.PlantCode, String[]), row.new_name)
    end

    for row in eachrow(reservoirs_df)
        plant_code = row.eia_plant_code
        names = get(plant_code_to_names, plant_code, String[])
        isempty(names) && error(
            "hydro_reservoirs.csv has a reservoir for EIA plant code $plant_code " *
            "(\"$(row.reservoir_name)\"), but hydro_units.csv has no promoted unit at that " *
            "plant code.",
        )
        turbines = [promoted_units[name] for name in names]
        max_storage = row.storage_level_max_m3
        inflow = _reservoir_inflow_m3ph(row.inflow_m3s)

        reservoir = HydroReservoir(;
            name = row.reservoir_name,
            available = true,
            storage_level_limits = (min = row.storage_level_min_m3, max = max_storage),
            initial_level = row.initial_level_m3 / max_storage,
            spillage_limits = nothing,
            inflow = inflow,
            # No outflow source anywhere in scope (only inflow is in the field-mapping table);
            # long-run mass-balance assumption, recorded as a gap in the final report.
            outflow = inflow,
            level_targets = nothing,
            intake_elevation = row.intake_elevation_m,
            head_to_volume_factor = LinearFunctionData(row.head_to_volume_slope),
            evaporative_loss = row.evaporative_loss,
            downstream_turbines = Vector{PSY.HydroUnit}(turbines),
            level_data_type = ReservoirDataType.USABLE_VOLUME,
        )
        add_component!(system, reservoir)

        for turbine in turbines
            apply_turbine_type!(turbine, row.turbine_type)
        end
    end
    return
end

"""
One CombinedCycleBlock's `configuration` must be a single value, but a handful of blocks in
generator_plants.csv carry more than one distinct `cc_configuration` across their member rows
(several raw EIA Unit Codes were folded into a single group_index upstream). Resolves each
block to its most common configuration (ties broken alphabetically) and `@warn`s every block
where this happens, so the substitution is visible rather than silently picked.
"""
function resolve_cc_configurations(plants_df::DataFrame)
    cc_rows = plants_df[plants_df.plant_type .== "CombinedCycleBlock", :]
    resolved = Dict{Tuple{Int, Int}, CombinedCycleConfiguration}()
    for block_rows in groupby(cc_rows, [:PlantCode, :group_index])
        plant_code = block_rows.PlantCode[1]
        group_index = block_rows.group_index[1]
        counts = Dict{String, Int}()
        for c in block_rows.cc_configuration
            counts[c] = get(counts, c, 0) + 1
        end
        chosen = first(sort(collect(counts); by = kv -> (-kv[2], kv[1])))[1]
        if length(counts) > 1
            @warn "Combined-cycle block \"$(block_rows.plant_name[1])\" (PlantCode " *
                "$plant_code, group $group_index) carries $(length(counts)) distinct " *
                "cc_configuration values in generator_plants.csv ($counts); using " *
                "\"$chosen\" (the most common)"
        end
        resolved[(plant_code, group_index)] = CombinedCycleConfiguration(String(chosen))
    end
    return resolved
end

"""
Stage 3 of the EIA enrichment (data/generator_plants.csv): attach one PowerPlant supplemental
attribute per PlantCode per plant_type. HydroPowerPlant is attached only for `promoted`
plants: `add_supplemental_attribute!(sys, ::HydroDispatch, ::HydroPowerPlant, ...)` throws
unconditionally in this psy6 checkout (plant_attribute.jl:604), and generator_plants.csv
marks every hydro unit's plant_type as HydroPowerPlant regardless of promotion -- so
unpromoted plants are skipped here rather than attempted and failed.
"""
function attach_plant_groups!(
    system::System,
    plants_df::DataFrame,
    promoted_plant_codes::Set{Int},
)
    thermal_plants = Dict{Int, ThermalPowerPlant}()
    renewable_plants = Dict{Int, RenewablePowerPlant}()
    hydro_plants = Dict{Int, HydroPowerPlant}()
    cc_blocks = Dict{Tuple{Int, Int}, CombinedCycleBlock}()
    cc_configs = resolve_cc_configurations(plants_df)

    for row in eachrow(plants_df)
        plant_code = row.PlantCode
        plant_type = row.plant_type
        gen = get_component(StaticInjection, system, row.new_name)
        isnothing(gen) && error(
            "generator_plants.csv references \"$(row.new_name)\" (PlantCode $plant_code), " *
            "which is not in the system.",
        )

        if plant_type == "ThermalPowerPlant"
            plant = get!(thermal_plants, plant_code) do
                ThermalPowerPlant(; name = row.plant_name)
            end
            add_supplemental_attribute!(system, gen, plant; shaft_number = row.group_index)
        elseif plant_type == "RenewablePowerPlant"
            plant = get!(renewable_plants, plant_code) do
                RenewablePowerPlant(; name = row.plant_name)
            end
            add_supplemental_attribute!(system, gen, plant, row.group_index)
        elseif plant_type == "HydroPowerPlant"
            plant_code in promoted_plant_codes || continue
            plant = get!(hydro_plants, plant_code) do
                HydroPowerPlant(; name = row.plant_name)
            end
            add_supplemental_attribute!(system, gen, plant, row.group_index)
        elseif plant_type == "CombinedCycleBlock"
            block_key = (plant_code, row.group_index)
            block = get!(cc_blocks, block_key) do
                CombinedCycleBlock(;
                    name = "$(row.plant_name)_block$(row.group_index)",
                    configuration = cc_configs[block_key],
                )
            end
            add_supplemental_attribute!(system, gen, block; hrsg_number = 1)
        else
            error(
                "Unknown plant_type \"$plant_type\" in generator_plants.csv for " *
                "$(row.new_name)",
            )
        end
    end
    return
end

function fix_missings!(data::Vector{Union{Float64, Missing}})
    last_valid = 0.0
    for i in eachindex(data)
        if ismissing(data[i]) || isnan(data[i])
            data[i] = last_valid
        else
            last_valid = data[i]
        end
    end
end

fix_missings!(::Vector{Float64}) = nothing # no-op

attach_cost!(gen::ThermalStandard, cost::CostCurve) =
    set_operation_cost!(gen, ThermalGenerationCost(cost, 0.0, 0, 0.0))

attach_cost!(gen::ThermalStandard, ::Nothing) =
    set_operation_cost!(gen, ThermalGenerationCost(nothing))

attach_cost!(gen::RenewableDispatch, cost::CostCurve) =
    set_operation_cost!(gen, RenewableGenerationCost(cost))

attach_cost!(gen::RenewableDispatch, ::Nothing) =
    set_operation_cost!(gen, RenewableGenerationCost(nothing))

attach_cost!(gen::HydroDispatch, cost::CostCurve) =
    set_operation_cost!(gen, HydroGenerationCost(cost, 0.0))

attach_cost!(gen::HydroDispatch, ::Nothing) =
    set_operation_cost!(gen, HydroGenerationCost(nothing))

attach_cost!(gen::Union{HydroTurbine, HydroPumpTurbine}, cost::CostCurve) =
    set_operation_cost!(gen, HydroGenerationCost(cost, 0.0))

attach_cost!(gen::Union{HydroTurbine, HydroPumpTurbine}, ::Nothing) =
    set_operation_cost!(gen, HydroGenerationCost(nothing))

attach_cost!(gen::Source, cost::CostCurve) =
    set_operation_cost!(gen, ImportExportCost(; import_offer_curves = cost))

attach_cost!(gen::Source, ::Nothing) =
    set_operation_cost!(gen, ImportExportCost(; import_offer_curves = zero(CostCurve)))

attach_cost!(gen::EnergyReservoirStorage, cost::CostCurve) =
    set_operation_cost!(gen, StorageCost(cost, cost, 0, 0.0, 0, 0, 0))

attach_cost!(gen::EnergyReservoirStorage, ::Nothing) =
    set_operation_cost!(gen, StorageCost())

# Tag every field of a MinMax/UpDown NamedTuple as natural units for the psy6 setters.
_mw(nt::NamedTuple) = map(x -> x * u"MW", nt)

# Ramp limits carry MW per minute, not MW: the setter's unit category is `MW minute⁻¹`
# and rejects a bare-power tag.
_mw_per_min(nt::NamedTuple) = map(x -> x * u"MW/minute", nt)

function convert_to_battery(system::System,
    gen::StaticInjection,
    k_p::Float64,
    k_e::Float64 = 2.0
)
    battery_gen = try_convert(EnergyReservoirStorage, gen, PrimeMovers.BA)
    remove_component!(system, gen)
    add_component!(system, battery_gen)
    rating = get_rating(battery_gen, PSY.NU)
    set_base_power!(battery_gen, rating*k_p) # set base power to k_p * rating, so that active power limits are (0, rating)
    set_rating!(battery_gen, 1.0 * PSY.CU) # rescale rating to 1.0 of the new device base.
    set_storage_capacity!(battery_gen, k_e * PSY.CU) # k_e is hours of duration at rated power
    set_active_power!(battery_gen, 0.0 * u"MW")
    set_initial_storage_capacity_level!(battery_gen, 0.0)
    p_max = 0.98 * rating * k_p
    p_limits = _mw((min = 0.0, max = p_max))
    set_input_active_power_limits!(battery_gen, p_limits)
    set_output_active_power_limits!(battery_gen, p_limits)
    η = _draw_storage_efficiency()
    set_efficiency!(battery_gen, (in = η, out = η))
    q_limits = _mw((min = -p_max, max = p_max))
    set_reactive_power!(battery_gen, 0.0 * u"MW")
    set_reactive_power_limits!(battery_gen, q_limits)
end

# RAMP_LIMIT_DICT holds WECC fractions of device capacity per minute. Ramps are assigned
# before rebase_base_power!, while base_power is still the MATPOWER system base (100 MVA)
# for every generator, so tagging those fractions CU would resolve them against 100 MVA and
# give every unit the same absolute MW/min. Scale by the unit's own Pmax instead.
_ramp_mw(fraction::NamedTuple, max_power::Float64) = _mw_per_min(map(x -> x * max_power, fraction))

"""
MATPOWER gives every generator the same base_power (the system's baseMVA), so `rating`
and other per-unit-of-device fields are meaningless. Rebase each device's own base_power
to its physical apparent-power rating (sqrt(Pmax^2+Qmax^2)), then re-apply the physical
values through the setters so natural-units getters are unchanged, while the raw
per-unit-of-device fields land near [0, 1].
"""
rebase_base_power!(::StaticInjection) = nothing

function rebase_base_power!(gen::Union{ThermalStandard, HydroDispatch})
    active_power = get_active_power(gen, PSY.NU)
    reactive_power = get_reactive_power(gen, PSY.NU)
    p_limits = get_active_power_limits(gen, PSY.NU)
    q_limits = get_reactive_power_limits(gen, PSY.NU)
    ramp_limits = get_ramp_limits(gen, PSY.NU)
    q_max = isnothing(q_limits) ? 0.0 : q_limits.max
    new_base_power = sqrt(p_limits.max^2 + q_max^2)

    set_base_power!(gen, new_base_power)
    set_rating!(gen, new_base_power * u"MW")
    set_active_power!(gen, active_power * u"MW")
    set_reactive_power!(gen, reactive_power * u"MW")
    set_active_power_limits!(gen, _mw(p_limits))
    isnothing(q_limits) || set_reactive_power_limits!(gen, _mw(q_limits))
    isnothing(ramp_limits) || set_ramp_limits!(gen, _mw_per_min(ramp_limits))
end

function rebase_base_power!(gen::RenewableDispatch)
    active_power = get_active_power(gen, PSY.NU)
    reactive_power = get_reactive_power(gen, PSY.NU)
    q_limits = get_reactive_power_limits(gen, PSY.NU)
    new_base_power = get_rating(gen, PSY.NU)

    set_base_power!(gen, new_base_power)
    set_rating!(gen, new_base_power * u"MW")
    set_active_power!(gen, active_power * u"MW")
    set_reactive_power!(gen, reactive_power * u"MW")
    isnothing(q_limits) || set_reactive_power_limits!(gen, _mw(q_limits))
end

function rebase_base_power!(gen::SynchronousCondenser)
    reactive_power = get_reactive_power(gen, PSY.NU)
    q_limits = get_reactive_power_limits(gen, PSY.NU)
    losses = get_active_power_losses(gen, PSY.NU)
    new_base_power = get_rating(gen, PSY.NU)

    set_base_power!(gen, new_base_power)
    set_rating!(gen, new_base_power * u"MW")
    set_reactive_power!(gen, reactive_power * u"MW")
    isnothing(q_limits) || set_reactive_power_limits!(gen, _mw(q_limits))
    set_active_power_losses!(gen, losses * u"MW")
end

function rebase_base_power!(gen::Source)
    active_power = get_active_power(gen, PSY.NU)
    reactive_power = get_reactive_power(gen, PSY.NU)
    p_limits = get_active_power_limits(gen, PSY.NU)
    q_limits = get_reactive_power_limits(gen, PSY.NU)
    q_max = isnothing(q_limits) ? 0.0 : q_limits.max
    new_base_power = sqrt(max(abs(p_limits.min), abs(p_limits.max))^2 + q_max^2)

    set_base_power!(gen, new_base_power)
    set_active_power!(gen, active_power * u"MW")
    set_reactive_power!(gen, reactive_power * u"MW")
    set_active_power_limits!(gen, _mw(p_limits))
    isnothing(q_limits) || set_reactive_power_limits!(gen, _mw(q_limits))
end

# MATPOWER gives every one of the 1743 synchronous condensers the same ±200 MVAr placeholder
# (Pmax = 0, no distinct value anywhere in the file), so the retained fleet carries no
# information about reactive need at any bus. fixed_admittance_candidates.csv measured what
# they actually inject: a median of 0.064 MVAr against that 200 MVAr nameplate.
const CURTAILED_CONDENSER_MVAR = 100.0

"""
Component names become serialization keys and result-file columns, so reduce an Appendix A
substation label to word characters: "Mesa 500/230 kV" would otherwise carry a path separator.
"""
function _component_label(name::AbstractString)
    return strip(replace(name, r"[^A-Za-z0-9]+" => "_"), '_')
end

"""
Apply the reactive resources listed in the CAISO Board-Approved 2025-2026 ISO Transmission
Plan, Appendix A section 3, sited on the nearest CATS bus by `data/reactive_resources.csv`.

Two changes, in this order:

 1. Every `SynchronousCondenser` already in the system is a MATPOWER placeholder, and is
    curtailed to `CURTAILED_CONDENSER_MVAR`. Running before step 2 is what keeps the real
    Appendix A units at their true ratings.
 2. The 18 shunt capacitor banks (3,666 MVAr), 10 real synchronous condensers (1,818 MVAr),
    and 3 SVCs (1,105 MVAr) are added. CATS models no bulk shunt compensation at all
    otherwise, and had no dynamic support beyond the placeholders.

The SVCs are built as `SynchronousCondenser` for simplicity — both give continuously variable
dynamic reactive support, and CATS has no SVC representation. `data/reactive_resources.csv`
keeps `technology` (what Appendix A says) separate from `component_type` (what is built), so
the substitution stays visible.
"""
# Every value in this system that came from outside the MATPOWER file has a citable origin, and
# the retrieval dates are fixed rather than `now()` so a rebuild is reproducible.
const EIA_RETRIEVED = DateTime("2026-08-17T00:00:00")

"""
Build one `DataSource` per (publisher, field group, confidence). IS shares a single
supplemental-attribute instance across every component it describes, so ~2200 components carry
provenance through about ten objects rather than one each.
"""
function _data_source(organization, dataset, url, version, confidence, fields)
    return DataSource(;
        organization = organization,
        retrieved_at = EIA_RETRIEVED,
        dataset = dataset,
        url = url,
        version = version,
        confidence = confidence,
        recorded_by = "CATS EIA enrichment (build/hydro_enrichment)",
        fields = fields,
    )
end

"""
Record where this system's non-MATPOWER data came from, using IS `DataSource` supplemental
attributes. Ten shared instances cover the EIA-derived generator identity, the CAISO reactive
inventory, and each reservoir field group, with the weaker provenance (dam-height head fallback,
defaulted initial level) carried as its own low-confidence source rather than blended into the
strong ones.
"""
function attach_data_sources!(system::System, names_df::DataFrame, reservoirs_df::DataFrame)
    eia = _data_source(
        "U.S. Energy Information Administration", "EIA-860 (2019), Schedule 3",
        "https://www.eia.gov/electricity/data/eia860/", "2019 final", "high",
        ["name", "prime_mover_type"],
    )
    caiso_url = "https://www.caiso.com/documents/board-approved-2025-2026-transmission-plan-appendix-a-system-data.pdf"
    caiso_shunt = _data_source(
        "California ISO", "Board-Approved 2025-2026 ISO Transmission Plan, Appendix A, section 3",
        caiso_url, "May 2026", "high", ["Y"],
    )
    caiso_dynamic = _data_source(
        "California ISO", "Board-Approved 2025-2026 ISO Transmission Plan, Appendix A, section 3",
        caiso_url, "May 2026", "high", ["rating", "reactive_power_limits"],
    )
    nid = _data_source(
        "U.S. Army Corps of Engineers", "National Inventory of Dams",
        "https://nid.sec.usace.army.mil", "2026 public FeatureServer", "high",
        ["storage_level_limits"],
    )
    eha = _data_source(
        "Oak Ridge National Laboratory", "EHA Unit Database FY2026 / HILARRI v4",
        "https://hydrosource.ornl.gov", "FY2026", "medium",
        ["intake_elevation", "head_to_volume_factor"],
    )
    eha_fallback = _data_source(
        "U.S. Army Corps of Engineers", "National Inventory of Dams (dam height used as head proxy)",
        "https://nid.sec.usace.army.mil", "2026 public FeatureServer", "low",
        ["intake_elevation", "head_to_volume_factor"],
    )
    cdec_level = _data_source(
        "California Department of Water Resources", "CDEC reservoir storage, sensor 15, 2019-01-01",
        "https://cdec.water.ca.gov", "2019", "high", ["initial_level"],
    )
    default_level = _data_source(
        "CATS enrichment default", "50% of storage_level_limits; no CDEC station for this reservoir",
        "", "2026-08-17", "low", ["initial_level"],
    )
    cdec_inflow = _data_source(
        "California Department of Water Resources", "CDEC reservoir inflow, sensor 76, 2019 daily",
        "https://cdec.water.ca.gov", "2019", "high", ["inflow"],
    )
    usgs_inflow = _data_source(
        "U.S. Geological Survey", "NWIS daily values, parameter 00060, 2019",
        "https://waterservices.usgs.gov/nwis/dv/", "2019", "medium", ["inflow"],
    )

    attached = 0
    for row in eachrow(names_df)
        component = get_component(Component, system, row.new_name)
        isnothing(component) && continue
        add_supplemental_attribute!(system, component, eia)
        attached += 1
    end
    for capacitor in get_components(x -> startswith(get_name(x), "ShuntCapacitor_"), FixedAdmittance, system)
        add_supplemental_attribute!(system, capacitor, caiso_shunt)
        attached += 1
    end
    for condenser in get_components(
        x -> startswith(get_name(x), "SynchronousCondenser_") || startswith(get_name(x), "SVC_"),
        SynchronousCondenser, system,
    )
        add_supplemental_attribute!(system, condenser, caiso_dynamic)
        attached += 1
    end

    for row in eachrow(reservoirs_df)
        reservoir = get_component(HydroReservoir, system, row.reservoir_name)
        isnothing(reservoir) && error(
            "hydro_reservoirs.csv names \"$(row.reservoir_name)\", which is not in the system",
        )
        add_supplemental_attribute!(system, reservoir, nid)
        attached += 1
        if row.head_is_fallback
            add_supplemental_attribute!(system, reservoir, eha_fallback)
        else
            add_supplemental_attribute!(system, reservoir, eha)
        end
        if row.initial_is_default
            add_supplemental_attribute!(system, reservoir, default_level)
        else
            add_supplemental_attribute!(system, reservoir, cdec_level)
        end
        attached += 2
        source = row.inflow_source
        if !ismissing(source) && occursin("CDEC", source)
            add_supplemental_attribute!(system, reservoir, cdec_inflow)
            attached += 1
        elseif !ismissing(source) && occursin("USGS", source)
            add_supplemental_attribute!(system, reservoir, usgs_inflow)
            attached += 1
        end
    end

    @info "Attached $attached DataSource associations across " *
          "$(length(get_supplemental_attributes(DataSource, system))) shared DataSource attributes"
    return system
end

"""
Attach the 2019 daily reservoir inflow series from `data/hydro_inflow_2019_daily.csv`.

POM reads this series by the name `"inflow"`
(`PowerOperationsModels/src/static_injector_models/hydro_generation.jl:368`). Values are stored
in **m³/h**, matching the unit PSY documents for the `inflow` field itself, and carry no scaling
multiplier: POM's default formulation applies a multiplier of 1.0. Note that
`HydroEnergyModelReservoir` and `HydroWaterFactorModel` instead multiply by `get_inflow(d)` and
expect a normalised series — the two conventions cannot both be served by one series, so this
targets the default.

Daily gauge readings are held constant across each day's 24 hours to match the hourly epoch the
rest of the system uses. Short gaps — days the source agent dropped because CDEC reported a
negative value — are filled by carrying the previous reading forward, and the per-reservoir
count is logged rather than left implicit.
"""
function attach_reservoir_inflow_time_series!(system::System, daily_file::AbstractString)
    if !isfile(daily_file)
        error("no reservoir inflow series at $daily_file; run build/hydro_enrichment/derive_inflows.py")
    end
    daily = CSV.read(daily_file, DataFrame)
    timestamps = range(DateTime("2019-01-01T00:00:00"); step = Hour(1), length = 24 * 365)
    days = Date(2019, 1, 1):Day(1):Date(2019, 12, 31)

    attached = 0
    filled_total = 0
    for group in groupby(daily, :reservoir_name)
        name = first(group.reservoir_name)
        reservoir = get_component(HydroReservoir, system, name)
        if isnothing(reservoir)
            error("hydro_inflow_2019_daily.csv names \"$name\", which is not in the system")
        end
        by_day = Dict(Date(row.date) => row.inflow_m3s for row in eachrow(group))

        hourly = Vector{Float64}(undef, length(timestamps))
        carried = 0.0
        have_carried = false
        filled = 0
        for (index, day) in enumerate(days)
            if haskey(by_day, day)
                carried = by_day[day]
                have_carried = true
            else
                filled += 1
                # A leading gap has nothing to carry forward, so reach back from the first
                # reading that does exist rather than emitting a zero.
                if !have_carried
                    carried = by_day[minimum(keys(by_day))]
                    have_carried = true
                end
            end
            hourly[((index - 1) * 24 + 1):(index * 24)] .= carried * 3600.0
        end

        add_time_series!(system, reservoir, SingleTimeSeries(;
            name = "inflow",
            data = TimeArray(collect(timestamps), hourly),
        ))
        attached += 1
        filled_total += filled
        if filled > 0
            @info "  $name: $filled of 365 days carried forward"
        end
    end

    @info "Attached inflow time series to $attached of " *
          "$(length(get_components(HydroReservoir, system))) reservoirs " *
          "($filled_total days carried forward in total)"
    return system
end

function add_caiso_reactive_resources!(system::System)
    curtailed = 0
    for condenser in get_components(SynchronousCondenser, system)
        set_rating!(condenser, CURTAILED_CONDENSER_MVAR * u"MW")
        set_reactive_power_limits!(
            condenser,
            _mw((min = -CURTAILED_CONDENSER_MVAR, max = CURTAILED_CONDENSER_MVAR)),
        )
        curtailed += 1
    end
    @info "Curtailed $curtailed placeholder synchronous condensers to " *
          "±$CURTAILED_CONDENSER_MVAR MVAr"

    resources = CSV.read(joinpath(DATA_DIR, "reactive_resources.csv"), DataFrame)
    buses = Dict(get_number(bus) => bus for bus in get_components(ACBus, system))
    base_power = get_base_power(system)
    capacitor_mvar = 0.0
    condenser_mvar = 0.0
    capacitors = 0
    condensers = 0

    for row in eachrow(resources)
        bus = get(buses, row[:bus], nothing)
        if isnothing(bus)
            error("reactive_resources.csv references bus $(row[:bus]), which is not in the system")
        end
        label = _component_label(row[:substation])
        prefix = row[:name_prefix]
        mvar = row[:mvar_per_unit]
        if row[:component_type] == "FixedAdmittance"
            add_component!(system, FixedAdmittance(;
                name = "$(prefix)_$label",
                available = true,
                bus = bus,
                Y = complex(0.0, mvar / base_power),
            ))
            capacitors += 1
            capacitor_mvar += mvar
        elseif row[:component_type] == "SynchronousCondenser"
            for unit in 1:row[:n_units]
                # base_power = the unit's own MVAr rating, so the device-base 1.0 values
                # below read back as ±mvar in natural units.
                add_component!(system, SynchronousCondenser(;
                    name = "$(prefix)_$(label)_$unit",
                    available = true,
                    bus = bus,
                    reactive_power = 0.0,
                    rating = 1.0,
                    reactive_power_limits = (min = -1.0, max = 1.0),
                    base_power = mvar,
                    active_power_losses = 0.0,
                ))
                condensers += 1
                condenser_mvar += mvar
            end
        else
            error("unknown component_type $(row[:component_type]) in reactive_resources.csv")
        end
    end

    @info "Added $capacitors CAISO shunt capacitor banks ($(round(Int, capacitor_mvar)) MVAr) " *
          "and $condensers dynamic units ($(round(Int, condenser_mvar)) MVAr), the latter " *
          "including the 3 SVCs modelled as synchronous condensers"
    return system
end

function build_CATS_system(;
    matpower_file::String = "$BASE_DIR/MATPOWER/CaliforniaTestSystem.m",
    generator_csv::String = "$BASE_DIR/GIS/CATS_gens.csv", # oh I think the problem is that we've changed this for the
    # simplified system.
    buses_csv::String = "$BASE_DIR/GIS/CATS_buses.csv",
    lines_json::String = "$BASE_DIR/GIS/CATS_lines.json",
    timeseries_csv::String = joinpath(DATA_DIR, "HourlyProduction2019.csv"),
    load_timeseries::String = joinpath(DATA_DIR, "Load_Agg_Post_Assignment_v3_latest.csv"),
    remove_scs::Bool = true,
)
    if !isfile(timeseries_csv) || !isfile(load_timeseries)
        error("Data directory $DATA_DIR does not contain expected data. Run " *
            "`data/download_data.sh` (requires `pip install gdown`) to fetch " *
            "time series (HourlyProduction2019.csv) and load " *
            "(Load_Agg_Post_Assignment_v3_latest.csv) data."
        )
    end

    # OpenAPISystem already holds a built SystemDocument, so no JSON round-trip is needed.
    pm = PFP.PowerModelsData(matpower_file)
    oapi = PFP.build_openapi_system(pm; unit_system = "DEVICE_BASE")
    doc = PFP.get_document(oapi)
    POAM.validate_document(doc)
    system = from_openapi(System, doc)

    n_buses = length(get_components(Bus, system))
    n_gens = length(get_components(ThermalStandard, system))
    # n_loads = length(get_components(PowerLoad, system))
    gen_csv = CSV.read(generator_csv, DataFrame)
    gen_df = generator_data_to_dataframe(matpower_file)

    # EIA enrichment inputs (data/*.csv). All five are row_index-keyed to the same 2123
    # EIA-matched generators (see the design doc); hydro_reservoirs.csv is produced by a
    # concurrent process and is required, not optional -- see the isfile check below.
    names_df = CSV.read(joinpath(DATA_DIR, "generator_names.csv"), DataFrame)
    prime_movers_df = CSV.read(joinpath(DATA_DIR, "generator_prime_movers.csv"), DataFrame)
    plants_df = CSV.read(joinpath(DATA_DIR, "generator_plants.csv"), DataFrame)
    hydro_df = CSV.read(joinpath(DATA_DIR, "hydro_units.csv"), DataFrame)
    reservoirs_file = joinpath(DATA_DIR, "hydro_reservoirs.csv")
    if !isfile(reservoirs_file)
        error("Data directory $DATA_DIR does not contain hydro_reservoirs.csv (Stage 5 of " *
            "the EIA hydro enrichment). Regenerate it via build/hydro_enrichment/ before " *
            "running the build.")
    end
    reservoirs_df = CSV.read(reservoirs_file, DataFrame)

    row_to_new_name = Dict{Int, String}(row.row_index => row.new_name for row in eachrow(names_df))
    # String(...): PrimeMovers' String constructor requires a concrete String, not CSV.jl's
    # InlineStrings short-string types (String3/String7/...) that eia_pm is read as.
    row_to_eia_pm = Dict{Int, PSY.PrimeMovers}(
        row.row_index => PrimeMovers(String(row.eia_pm)) for row in eachrow(prime_movers_df)
    )

    # STEP 2's per-column time series filter needs to identify solar units by their original
    # CATS fuel type, not by prime mover -- see the col_to_type_and_kwargs comment below.
    solar_names = Set{String}(
        row.new_name for row in eachrow(prime_movers_df) if occursin("Solar", row.FuelType)
    )
    solar_thermal_names = Set{String}(
        row.new_name for row in eachrow(prime_movers_df)
        if row.FuelType == "Solar Thermal without Energy Storage"
    )

    scs_convert_df = CSV.read(joinpath(BASE_DIR, "data", "scs_to_storage.csv"), DataFrame)
    scs_convert = Set{String}([replace(x, " " => "-") for x in scs_convert_df.generator])
    scs_df = CSV.read(joinpath(BASE_DIR, "data", "scs_to_keep.csv"), DataFrame)
    scs_keep = Set{String}([replace(x, " " => "-") for x in scs_df.generator])
    fa_df = CSV.read(joinpath(BASE_DIR, "data", "fixed_admittance_candidates.csv"), DataFrame)
    scs_to_fixed_admittance = Dict{String, Float64}(
        replace(row.generator, " " => "-") => row.median_nonzero for row in eachrow(fa_df)
    )
    original_sc_count = 0
    converted_scs = 0
    kept_sc_count = 0
    fixed_admittance_count = 0

    # STEP 1: fix gen types. All are parsed as ThermalStandard, but some are hydro or renewable.
    for (i, row) in enumerate(eachrow(gen_csv))
        gen_name = "gen-$(i)"
        gen = get_component(ThermalStandard, system, gen_name)
        @assert !isnothing(gen) "Generator $gen_name not found in system."
        gen_type  = row[:FuelType]

        # Stage 1 of the EIA enrichment: rename EIA-matched units at construction. SCs and
        # imports have no EIA match and keep their positional gen-N name (data/generator_names.csv
        # only has rows for the 2123 matched units).
        final_name = get(row_to_new_name, i, gen_name)
        if final_name != gen_name
            gen = rename_generator!(system, gen, final_name)
        end

        # Stage 2: EIA prime mover replaces PM_TYPE_DICT wherever a match exists; SCs/imports
        # (no CSV row) fall back to the original CATS-fuel-type-keyed lookup.
        if haskey(row_to_eia_pm, i)
            pm_type = row_to_eia_pm[i]
        else
            pm_type = PM_TYPE_DICT[gen_type]
        end
        if occursin("Hydroelectric", gen_type)
            hydro_gen = try_convert(HydroDispatch, gen, pm_type)
            remove_component!(system, gen)
            add_component!(system, hydro_gen)
        elseif occursin("Solar", gen_type) || occursin("Wind", gen_type)
            renewable_gen = try_convert(RenewableDispatch, gen, pm_type)
            remove_component!(system, gen)
            add_component!(system, renewable_gen)
        elseif gen_type == "IMPORT"
            import_gen = try_convert(Source, gen, pm_type)
            remove_component!(system, gen)
            add_component!(system, import_gen)
        elseif gen_type == "Synchronous Condenser"
            original_sc_count += 1
            # the SCs-to-keep list here is subject to manual tuning: run on HPC,
            # penalizing reactive power at SCs to CSV. See write_sc_bus.jl for details.
            # there's a handful of the "keep" ones that could be converted to fixed admittance,
            # --see fixed_admittance_candidates.csv--but it's only ~25 of 150.
            if gen_name ∈ scs_convert
                convert_to_battery(system, gen, 3.0, round(3.0 + clamp(randn(rng), -1, 1)))
                converted_scs += 1
            elseif haskey(scs_to_fixed_admittance, gen_name)
                fa_bus = get_bus(gen)
                Q_median = scs_to_fixed_admittance[gen_name]
                remove_component!(system, gen)
                fa = FixedAdmittance(;
                    name = gen_name,
                    available = true,
                    bus = fa_bus,
                    Y = complex(0.0, Q_median / get_base_power(system)),
                )
                add_component!(system, fa)
                fixed_admittance_count += 1
            elseif gen_name ∈ scs_keep
                sc_gen = try_convert(SynchronousCondenser, gen, pm_type)
                remove_component!(system, gen)
                add_component!(system, sc_gen)
                kept_sc_count += 1
            else
                @warn("removed synchronous condenser $(get_name(gen))")
                remove_component!(system, gen)
            end
        elseif occursin("Batteries", gen_type)
            convert_to_battery(system, gen, 3.0, round(3.0 + clamp(randn(rng), -1, 1)))
        else
            # the rest remain ThermalStandard
            # fields unique to thermal: fuel type, ramp limits, time limits
            set_prime_mover_type!(gen, pm_type)
            if occursin("Natural Gas", gen_type)
                set_fuel!(gen, ThermalFuels.NATURAL_GAS)
            elseif gen_type in OTHER_TYPES
                set_fuel!(gen, ThermalFuels.OTHER)
            else
                set_fuel!(gen, FUELS_DICT[gen_type])
            end

            pm_type = get_prime_mover_type(gen)
            fuel_type = get_fuel(gen)
            maxPower = get_max_active_power(gen, PSY.NU)

            if (pm_type, fuel_type) in keys(RAMP_LIMIT_DICT)
                WECC_string = PSY_TO_WECC_DICT[(pm_type, fuel_type)]
                size_string = get_size(WECC_string, maxPower)
                ramp = RAMP_LIMIT_DICT[(pm_type, fuel_type)]
                set_ramp_limits!(gen, _ramp_mw(ramp, maxPower))
                set_time_limits!(gen, DURATION_LIMIT_DICT[(WECC_string, size_string)])
            elseif pm_type == PrimeMovers.ST
                # Other steam turbine movers use the same scheme as coal
                size_string = get_size("CLLIG", maxPower)
                ramp = RAMP_LIMIT_DICT[(PrimeMovers.ST, ThermalFuels.COAL)]
                set_ramp_limits!(gen, _ramp_mw(ramp, maxPower))
                set_time_limits!(gen, DURATION_LIMIT_DICT[("CLLIG", size_string)])
            elseif pm_type in (PrimeMovers.IC, PrimeMovers.OT)
                # No explicit entries for IC engines or "other" - use conservative values
                # TODO CoPilot generated: are these reasonable?
                set_ramp_limits!(gen, _ramp_mw((up = 0.01, down = 0.01), maxPower))
                set_time_limits!(gen, (up = 1.0, down = 1.0))
            end
        end

        # comp may be different than gen if we converted it. Re-fetch by final_name: renamed
        # units (Stage 1) no longer live under gen_name.
        if gen_type == "Synchronous Condenser" && !(gen_name in scs_keep) && !(gen_name in scs_convert)
            continue
        end
        comp  = get_component(StaticInjection, system, final_name)
        if !(comp isa Source) && !(comp isa SynchronousCondenser) && !(comp isa EnergyReservoirStorage) && !(comp isa FixedAdmittance)
            # Same pm_type computed above (eia_pm-derived where available) -- not a fresh
            # PM_TYPE_DICT lookup, which would silently clobber the Stage 2 prime mover.
            set_prime_mover_type!(comp, pm_type)
        elseif comp isa SynchronousCondenser && gen_name in scs_convert
            set_prime_mover_type!(comp, PrimeMovers.BA)
        end

        rebase_base_power!(comp)

        # some data validity checks on the specific row
        # (if it's a system wide check, put it outside the for loop)
        if VALIDITY_CHECKS
            matpower_row = gen_df[i, :]
            if !(comp isa SynchronousCondenser || comp isa EnergyReservoirStorage || comp isa FixedAdmittance)
                @assert isapprox(get_active_power(comp, PSY.NU), row[:Pg])
                @assert isapprox(row[:Pmax], matpower_row[:Pmax])
                @assert isapprox(row[:Pmin], matpower_row[:Pmin])
            end
            if !(gen_name in scs_convert) && !(comp isa FixedAdmittance)
                @assert isapprox(get_reactive_power(comp, PSY.NU), row[:Qg])
                @assert isapprox(row[:Pg], matpower_row[:Pg])
                @assert isapprox(row[:Qg], matpower_row[:Qg])

                # @assert isapprox(get_reactive_power_limits(comp).max, row[:Qmax]) get_reactive_power_limits(comp).max, row[:Qmax]
                # @assert isapprox(get_reactive_power_limits(comp).min, row[:Qmin])
            end

            if !(comp isa RenewableDispatch) && !(comp isa SynchronousCondenser) && !(comp isa EnergyReservoirStorage) && !(comp isa FixedAdmittance)
                comp_p_limits = get_active_power_limits(comp, PSY.NU)
                @assert isapprox(comp_p_limits.max, row[:Pmax])
                @assert isapprox(comp_p_limits.min, row[:Pmin])
            end
        end

        # Attach geographic info to generator
        if !ismissing(row[:Lat]) && !ismissing(row[:Lon])
            geo_info = GeographicInfo(;
                geo_json = Dict{String, Any}(
                    "type" => "Point",
                    "coordinates" => [row[:Lon], row[:Lat]],
                ),
            )
            add_supplemental_attribute!(system, comp, geo_info)
        end
    end

    @assert converted_scs == length(scs_convert)
    @assert kept_sc_count == length(scs_keep) - length(scs_to_fixed_admittance)
    @assert fixed_admittance_count == length(scs_to_fixed_admittance)
    if VALIDITY_CHECKS
        # check first one -- "gen-1" is renamed (Stage 1) to its EIA name, since it's one of
        # the 2123 EIA-matched units.
        @assert n_gens == nrow(gen_csv)
        first_gen_name = get(row_to_new_name, 1, "gen-1")
        first_gen = get_component(StaticInjection, system, first_gen_name)
        @assert first_gen isa HydroDispatch
        @assert isapprox(get_reactive_power_limits(first_gen, PSY.NU).max, 18.7771429)
        @assert get_number(get_bus(first_gen)) == 745
        # check last non-SC non-import generator (also renamed).
        n_imports = length(get_components(Source, system))
        last_gen_index = n_gens - n_imports - original_sc_count
        last_gen_name = get(row_to_new_name, last_gen_index, "gen-$(last_gen_index)")
        last_gen = get_component(StaticInjection, system, last_gen_name)
        @assert last_gen isa RenewableDispatch && get_prime_mover_type(last_gen) == PrimeMovers.PVe

        first_import = get_component(Source, system, "gen-$(last_gen_index + 1)")
        @assert !isnothing(first_import)

        # Check that all gas-fueled ThermalStandard generators have ramp limits and min down time
        #for gen in get_components(ThermalStandard, system)
        #    if get_fuel(gen) == ThermalFuels.NATURAL_GAS
        #        ramp = get_ramp_limits(gen)
        #        @assert ramp.up > 0.0 "Gas generator $(get_name(gen)) has zero ramp up limit"
        #        @assert ramp.down > 0.0 "Gas generator $(get_name(gen)) has zero ramp down limit"
        #        time_lim = get_time_limits(gen)
        #        @assert time_lim.down > 0.0 "Gas generator $(get_name(gen)) has zero min down time"
        #    end
        #end
    end

    # STEP 1B: hydro reservoir promotion + plant grouping (Stages 3-5 of the EIA
    # enrichment). Hydro promotion must run before plant grouping: HydroPowerPlant can only
    # be attached to a HydroTurbine/HydroPumpTurbine, never a HydroDispatch (see
    # attach_plant_groups! docstring).
    promoted_units = promote_hydro_units!(system, hydro_df)
    attach_hydro_reservoirs!(system, reservoirs_df, hydro_df, promoted_units)

    promoted_plant_codes =
        Set{Int}(row.PlantCode for row in eachrow(hydro_df) if row.promoted)
    attach_plant_groups!(system, plants_df, promoted_plant_codes)

    # STEP 2: attach timeseries data
    if !isempty(solar_thermal_names)
        @warn "The 12 solar-thermal units below get the Solar column's photovoltaic (PV) " *
            "time series, standing in for a solar-thermal profile that does not exist in " *
            "this dataset (no solar-thermal column in HourlyProduction2019.csv). This is a " *
            "deliberate, accepted compromise -- see 'Solar thermal keeps the PV profile' in " *
            "the design doc. Affected units: $(join(sort(collect(solar_thermal_names)), ", "))"
    end

    col_to_type_and_kwargs = Dict(
        # Keyed on the CATS FuelType (via solar_names/solar_thermal_names, built above from
        # generator_prime_movers.csv), not :prime_mover_type: the 12 solar-thermal units are
        # now ST (Stage 2), not PVe, and would otherwise silently lose their PV time series.
        "Solar" => (RenewableDispatch, Dict()),
        "Wind" => (RenewableDispatch, Dict(:prime_mover_type => PrimeMovers.WT)),
        # HydroGen (not HydroDispatch): Stage 4 promotes 93 units to HydroTurbine/
        # HydroPumpTurbine, which must still receive their share of this column's profile.
        "Large Hydro" => (HydroGen, Dict()),
        "Nuclear" => (ThermalStandard, Dict(:fuel => ThermalFuels.NUCLEAR)),
        # here I should really have "fuel not nuclear", but I'll special-case it.
        "Thermal" => (ThermalStandard, Dict()),
        "Imports" => (Source, Dict())
    )
    if isnothing(load_timeseries)
        col_to_type_and_kwargs["Load"] = (PowerLoad, Dict())
    end

    ts_df = CSV.read(timeseries_csv, DataFrame;
        header=1,
        types=(i, name) -> i <= 3 ? String : Float64,
    )

    timestamps = range(DateTime("2019-01-01T00:00:00"); step = Hour(1), length = 24*365)
    @assert length(timestamps) == nrow(ts_df) "Number of timestamps ($(length(timestamps))) " *
        "does not match number of rows in time series data ($(nrow(ts_df)))."
    for (col_name, col_info) in col_to_type_and_kwargs

        comp_type, kwargs = col_info
        if col_name == "Thermal"
            filter_func = comp -> get_fuel(comp) != ThermalFuels.NUCLEAR
        elseif col_name == "Solar"
            filter_func = comp -> get_name(comp) in solar_names
        else
            filter_func = comp -> all(getfield(comp, key) == value for (key, value) in kwargs)
        end
        comps = get_components(filter_func, comp_type, system)

        # values in csv are totals, across all components of that type: we want
        # to rescale per-component by get_max_active_power(comp) / total_max_active_power.
        # so I'll rescale the csv's totals by 1 / total_max_active_power,
        # then rescale per-component by get_max_active_power(comp).

        ts_values = collect(ts_df[!, col_name])
        fix_missings!(ts_values)
        ts_values = convert(Vector{Float64}, ts_values)
        total_max_active_power = sum(get_max_active_power(comp, PSY.NU) for comp in comps)
        ts_values ./= total_max_active_power
        if comp_type != Source
            # imports can be negative (i.e., exports)
            @assert all(ts_values .>= 0.0) "time series goes negative for some time " *
                "steps for $comp_type"
        elseif comp_type != RenewableDispatch && comp_type != Source
            total_min_active_power = sum(get_active_power_limits(comp, PSY.NU).min for comp in comps)
            renormalized_min = total_min_active_power / total_max_active_power
            @assert all(ts_values .>= renormalized_min) "time series goes below min " *
                "generation for some time steps for $comp_type"
        end
        if any(ts_values .> 1.0)
            scale_up = maximum(ts_values)
            @warn "total generation (from time series csv) exceeds total of max active "*
                 "powers for some time steps for $comp_type; multiplying max active " *
                 "powers for those components by $(round(scale_up; sigdigits = 3))"
            ts_values ./= scale_up
            for comp in comps
                p_limits = get_active_power_limits(comp, PSY.NU)
                set_active_power_limits!(
                    comp,
                    _mw((min = p_limits.min, max = p_limits.max * scale_up))
                )
            end
            @assert all(ts_values .<= 1.0)
        end
	    ts = SingleTimeSeries(;
           name = "max_active_power",
           data = TimeArray(timestamps, ts_values),
           per_unit_of("active_power")...,
        )
        add_time_series!(system, comps, ts)

        # data validity check
        if VALIDITY_CHECKS
            # total across comps should match csv value.
            validity_check_row = 9
            total_generation = 0.0
            for comp in comps
                # Select the row in storage; the two-call form would materialize all 8760.
                # psy6 removed the `units` kwarg: the read returns the values as stored
                # (per unit on the device base), so the consumer applies the scaling. The
                # check still compares MW against the CSV total.
                per_unit_value = first(get_time_series_values(
                    SingleTimeSeries,
                    comp,
                    "max_active_power";
                    start_time = timestamps[validity_check_row],
                    len = 1,
                ))
                total_generation += per_unit_value * get_max_active_power(comp, PSY.NU)
            end
            @assert isapprox(total_generation, ts_df[validity_check_row, col_name])
        end
    end
    # all renewables should have time series values
    @assert all(comp -> has_time_series(comp, SingleTimeSeries, "max_active_power"),
                    get_components(RenewableDispatch, system))

    # STEP 2B: attach per-load time series.
    # Try to load from JLD2 first.
    jld2_file = replace(load_timeseries, ".csv" => ".jld2")
    if endswith(load_timeseries, ".jld2")
        jld2_file = load_timeseries
    end

    load_data = nothing
    if isfile(jld2_file)
        println("Loading time series data from JLD2: $jld2_file")
    elseif isfile(load_timeseries)
        # I could load from CSV, but users probably don't actually want to do that.
        @warn("Converting CSV to JLD2 first using convert_load_csv_to_jld2.jl." *
            " (It takes ~10 minutes to load the CSV, versus ~10 seconds for JLD2, " *
            "so writing that intermediate JDL2 file saves significant build time.)")
            include("convert_load_csv_to_jld2.jl")
    end
    load_data = load(jld2_file, "load_data")
    if VALIDITY_CHECKS
        # first row of CSV should match first column of load_data.
        first_row_csv = first(CSV.Rows(load_timeseries; header=false))
        first_row_complex = parse.(ComplexF64, collect(first_row_csv))
        @assert all(isapprox.(view(load_data, :, 1), first_row_complex))
    end
    @assert size(load_data, 2) == n_buses "Number of columns in load time series data " *
        "($(ncol(load_data))) does not match number of buses ($n_buses)"

    increased = 0
    most_increase = 0.0
    time_series_transaction(system) do txn
        for i in 1:n_buses
            load_name = "bus$i"
            load = get_component(PowerLoad, system, load_name)

            row_values = view(load_data, :, i)

            # Early skip for zero loads
            if isnothing(load)
                @assert all(isapprox.(row_values, 0.0; atol=1e-6))
                continue
            else
                @assert get_number(get_bus(load)) == i "expected load $load_name to "*
                    "be at bus $i, got bus $(get_number(get_bus(load)))"
            end

            active_power = real.(row_values)
            reactive_power = imag.(row_values)
            @assert all(active_power .>= 0.0) "Negative real values found for load $load_name"

            power_configs = (
                (active_power, "max_active_power", "active_power",
                 get_max_active_power, set_max_active_power!),
                (abs.(reactive_power), "reactive_power", "reactive_power",
                 get_max_reactive_power, set_max_reactive_power!),
            )

            for (power_values, ts_name, quantity_kind, get_max_fn, set_max_fn!) in power_configs
                max_power = maximum(power_values)
                current_max = get_max_fn(load, PSY.NU)
                if max_power > current_max
                    increased += 1
                    most_increase = max(most_increase, max_power / current_max)
                    set_max_fn!(load, max_power * u"MW")
                    current_max = max_power
                end
                # PSI prefers values to be between 0 and 1.
                power_values ./= current_max
                ts = SingleTimeSeries(;
                    name = ts_name,
                    data = TimeArray(timestamps, power_values),
                    per_unit_of(quantity_kind)...,
                )
                add_time_series!(txn, load, ts)
            end
        end
        if increased > 0
            num_loads = length(get_components(PowerLoad, system))
            @warn "increased max active power for $increased (of $num_loads) loads based "*
                "on load time series; largest increase was by a factor of " *
                "$(round(most_increase; sigdigits=3))"
        end
    end

    # STEP 3: add cost data

    cost_df = cost_data_to_dataframe(matpower_file)
    @assert n_gens == nrow(cost_df) "Number of generators in system ($n_gens) does not "*
        "match number of rows in cost data ($nrow(cost_df))"
    for (i, row) in enumerate(eachrow(cost_df))
        # Renamed units (Stage 1) no longer live under the positional "gen-$(i)" name.
        gen_name = get(row_to_new_name, i, "gen-$(i)")
        comp = get_component(StaticInjection, system, gen_name)
        isnothing(comp) && continue  # skip removed components (e.g., SCs)
        @assert isapprox(row[:startup], 0.0; atol=1e-6)
        @assert isapprox(row[:shutdown], 0.0; atol=1e-6)
        n = row[:n]
        # assume quadratic cost function
        @assert n == 3 "Only quadratic cost functions supported."
        c2 = row[:c2]
        c1 = row[:c1]
        c0 = row[:c0]
        if all(isapprox.((c2, c1, c0), 0.0; atol=1e-6))
            # cost is zero (SCs don't have an operation cost)
            (comp isa SynchronousCondenser || comp isa FixedAdmittance) || attach_cost!(comp, nothing)
            continue
        end

        if comp isa Source
            # ImportExportCost must be piecewise incremental, when we have quadratic.
            # so for simplicity we drop the quadratic term.
            # FIXME they use negative exports to represent imports, whereas we use
            # separate curves...
            function_data = PiecewiseIncrementalCurve(c0, [0.0, 1.0e12], [c1])
            cost_curve = CostCurve(function_data)
            attach_cost!(comp, cost_curve)
        elseif isapprox(c2, 0.0; atol=1e-6)
            function_data = LinearCurve(c1, c0)
            cost_curve = CostCurve(function_data)
            attach_cost!(comp, cost_curve)
        elseif comp isa EnergyReservoirStorage
            vom = LinearCurve(c1, c0)
            cost_curve = CostCurve(vom)
            attach_cost!(comp, cost_curve)
        elseif comp isa HydroGen
            max_power = get_max_active_power(comp, PSY.NU)
            slope = 2*c2*max_power*0.8 + c1
            intercept = c0 - c2*(max_power*0.8)^2
            function_data = LinearCurve(slope, intercept)
            cost_curve = CostCurve(function_data)
            attach_cost!(comp, cost_curve)
        else
            p_limits = get_active_power_limits(comp, PSY.NU)
            p_min = p_limits.min
            p_max = p_limits.max
            points = [(p, c2 * p^2 + c1 * p + c0) for p in range(p_min, p_max; length = 4)]
            function_data = PiecewisePointCurve(points)
            cost_curve = CostCurve(function_data)
            attach_cost!(comp, cost_curve)
        end
    end

    # Verify no components have quadratic cost curve functions
    if VALIDITY_CHECKS
        for comp in get_components(Generator, system)
            cost = get_operation_cost(comp)
            isnothing(cost) && continue
            if cost isa ThermalGenerationCost || cost isa RenewableGenerationCost || cost isa HydroGenerationCost
                vom = get_variable_operation_cost(cost)
                isnothing(vom) && continue
                fd = get_function_data(get_value_curve(vom))
                @assert !(fd isa QuadraticCurve) "Component $(get_name(comp)) has a quadratic cost curve"
            end
        end
    end

    # STEP 4: attach geographic info to buses
    bus_geo_csv = CSV.read(buses_csv, DataFrame)
    bus_geo_lookup = Dict{Int, GeographicInfo}()
    for row in eachrow(bus_geo_csv)
        bus_number = row[:bus_i]
        geo_info = GeographicInfo(;
            geo_json = Dict{String, Any}(
                "type" => "Point",
                "coordinates" => [row[:Lon], row[:Lat]],
            ),
        )
        bus_geo_lookup[bus_number] = geo_info
    end
    buses_with_geo = 0
    for bus in get_components(ACBus, system)
        bus_number = get_number(bus)
        if haskey(bus_geo_lookup, bus_number)
            add_supplemental_attribute!(system, bus, bus_geo_lookup[bus_number])
            buses_with_geo += 1
        end
    end
    @info "Attached GeographicInfo to $buses_with_geo / $(length(get_components(ACBus, system))) buses"

    # STEP 5: attach geographic info to lines
    lines_geo_data = JSON.parsefile(lines_json)
    # Build lookup: (f_bus, t_bus) => Vector of feature geometries
    # Multiple features can exist for the same bus pair (parallel lines)
    line_geo_lookup = Dict{Tuple{Int, Int}, Vector{Dict{String, Any}}}()
    for feature in lines_geo_data["features"]
        props = feature["properties"]
        f_bus = Int(props["f_bus"])
        t_bus = Int(props["t_bus"])
        key = (f_bus, t_bus)
        if !haskey(line_geo_lookup, key)
            line_geo_lookup[key] = Dict{String, Any}[]
        end
        push!(line_geo_lookup[key], feature["geometry"])
    end
    lines_with_geo = 0
    for line in get_components(Line, system)
        arc = get_arc(line)
        f_bus = get_number(get_from(arc))
        t_bus = get_number(get_to(arc))
        geometries = get(line_geo_lookup, (f_bus, t_bus), nothing)
        if isnothing(geometries)
            # Try reversed direction
            geometries = get(line_geo_lookup, (t_bus, f_bus), nothing)
        end
        if !isnothing(geometries) && !isempty(geometries)
            # Use first available geometry (pop to handle parallel lines)
            geom = popfirst!(geometries)
            geo_info = GeographicInfo(; geo_json = geom)
            add_supplemental_attribute!(system, line, geo_info)
            lines_with_geo += 1
        end
    end
    @info "Attached GeographicInfo to $lines_with_geo / $(length(get_components(Line, system))) lines"

    add_caiso_reactive_resources!(system)
    attach_reservoir_inflow_time_series!(
        system, joinpath(DATA_DIR, "hydro_inflow_2019_daily.csv"),
    )
    attach_data_sources!(system, names_df, reservoirs_df)

    return system
end

system = build_CATS_system()
to_file(system, joinpath(BASE_DIR, "CATS_openapi"); power_units = :component_base, force = true)
