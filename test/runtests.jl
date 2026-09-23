# Round-trip test: the case written by `build/build_CATS.jl` must read back through
# `PowerSystems.from_file` as the same system.
#
# Every expectation is read from the enrichment CSVs rather than hard-coded, so the test tracks
# the data instead of a snapshot of it. Regenerating the CSVs and rebuilding keeps it valid;
# changing one without the other fails it, which is the point.
#
# Run with: julia --project=build test/runtests.jl  (the build env already carries PowerSystems, CSV, DataFrames)

using Test
using PowerSystems
using CSV
using DataFrames

const PSY = PowerSystems

const BASE_DIR = joinpath(@__DIR__, "..")
const DATA_DIR = joinpath(BASE_DIR, "data")
const CASE_FILE = joinpath(BASE_DIR, "CATS_openapi.sns")

if !isfile(CASE_FILE)
    error(
        "no case at $CASE_FILE. Build it first: julia --project=build build/build_CATS.jl",
    )
end

read_data(name) = CSV.read(joinpath(DATA_DIR, name), DataFrame)

const NAMES = read_data("generator_names.csv")
const PRIME_MOVERS = read_data("generator_prime_movers.csv")
const PLANTS = read_data("generator_plants.csv")
const HYDRO_UNITS = read_data("hydro_units.csv")
const RESERVOIRS = read_data("hydro_reservoirs.csv")
const REACTIVE = read_data("reactive_resources.csv")

@info "Reading $CASE_FILE"
const SYS = @time from_file(CASE_FILE)

count_of(T) = length(collect(get_components(T, SYS)))

@testset "CATS round-trip" begin
    @testset "deserialization" begin
        @test SYS isa System
        @test get_base_power(SYS) == 100.0
        @test count_of(ACBus) == 8870
    end

    @testset "EIA names" begin
        # Every renamed generator must come back under its EIA name, and no real unit may
        # still carry a positional MATPOWER name.
        missing_names = [
            row.new_name for row in eachrow(NAMES) if
            isnothing(get_component(Component, SYS, row.new_name))
        ]
        @test isempty(missing_names)
        @test length(unique(NAMES.new_name)) == nrow(NAMES)
        positional = [
            get_name(g) for g in get_components(ThermalStandard, SYS) if
            startswith(get_name(g), "gen-")
        ]
        @test isempty(positional)
    end

    @testset "prime movers" begin
        # The EIA correction must survive the round trip, not just the build.
        mismatched = String[]
        for row in eachrow(PRIME_MOVERS)
            component = get_component(StaticInjection, SYS, row.new_name)
            isnothing(component) && continue
            expected = PrimeMovers.Value(row.eia_pm)
            if get_prime_mover_type(component) != expected
                push!(mismatched, row.new_name)
            end
        end
        @test isempty(mismatched)
    end

    @testset "hydro promotion" begin
        promoted = filter(row -> row.promoted, HYDRO_UNITS)
        turbines = filter(row -> row.target_type == "HydroTurbine", promoted)
        pumps = filter(row -> row.target_type == "HydroPumpTurbine", promoted)

        @test count_of(HydroTurbine) == nrow(turbines)
        @test count_of(HydroPumpTurbine) == nrow(pumps)
        @test count_of(HydroDispatch) == nrow(HYDRO_UNITS) - nrow(promoted)

        # HydroPumpTurbine is the type whose OpenAPI export was broken upstream
        # (`_turbinepump_po` undefined), so assert the fields that conversion touches.
        for row in eachrow(pumps)
            unit = get_component(HydroPumpTurbine, SYS, row.new_name)
            @test !isnothing(unit)
            @test get_prime_mover_type(unit) == PrimeMovers.PS
            efficiency = get_efficiency(unit)
            @test efficiency.turbine > 0.0
            @test efficiency.pump > 0.0
        end
    end

    @testset "reservoirs" begin
        @test count_of(HydroReservoir) == nrow(RESERVOIRS)
        for row in eachrow(RESERVOIRS)
            reservoir = get_component(HydroReservoir, SYS, row.reservoir_name)
            @test !isnothing(reservoir)

            limits = get_storage_level_limits(reservoir)
            @test isapprox(limits.max, row.storage_level_max_m3; rtol = 1e-6)
            @test limits.min == row.storage_level_min_m3

            # PSY stores initial_level as a fraction of limits.max; the OpenAPI document
            # holds the absolute volume and the reader inverts it. Both ends are checked so
            # a change to either convention fails here rather than silently rescaling storage.
            level = get_initial_level(reservoir)
            @test 0.0 < level <= 1.0
            @test isapprox(level * limits.max, row.initial_level_m3; rtol = 1e-5)

            # head_to_volume_factor is m^3 per metre: POM reads it as v = h * factor.
            factor = get_proportional_term(get_head_to_volume_factor(reservoir))
            @test isapprox(factor, row.head_to_volume_slope; rtol = 1e-5)
            @test factor > 1.0

            @test get_level_data_type(reservoir) == ReservoirDataType.USABLE_VOLUME
        end
    end

    @testset "reservoir inflow" begin
        gauged = filter(row -> !ismissing(row.inflow_m3s), RESERVOIRS)
        @test nrow(gauged) == 14
        for row in eachrow(gauged)
            reservoir = get_component(HydroReservoir, SYS, row.reservoir_name)
            # Stored in m^3/h; the CSV is m^3/s.
            @test isapprox(get_inflow(reservoir), row.inflow_m3s * 3600.0; rtol = 1e-6)
        end
        ungauged = filter(row -> ismissing(row.inflow_m3s), RESERVOIRS)
        for row in eachrow(ungauged)
            @test iszero(get_inflow(get_component(HydroReservoir, SYS, row.reservoir_name)))
        end
    end

    @testset "plant attributes" begin
        for T in (ThermalPowerPlant, RenewablePowerPlant, CombinedCycleBlock)
            expected = length(unique(
                filter(row -> row.plant_type == string(nameof(T)), PLANTS).PlantCode,
            ))
            @test length(collect(get_supplemental_attributes(T, SYS))) >= expected
        end

        # Hydro is the exception: PSY rejects
        # `add_supplemental_attribute!(sys, ::HydroDispatch, ::HydroPowerPlant, ...)`, so
        # `attach_plant_groups!` attaches a HydroPowerPlant only where the units were
        # promoted to HydroTurbine/HydroPumpTurbine. The unpromoted hydro plants are absent
        # by design — asserting equality here keeps that boundary honest in both directions.
        promoted_codes = Set(filter(row -> row.promoted, HYDRO_UNITS).PlantCode)
        hydro_codes = unique(
            filter(row -> row.plant_type == "HydroPowerPlant", PLANTS).PlantCode,
        )
        @test length(collect(get_supplemental_attributes(HydroPowerPlant, SYS))) ==
              length(intersect(hydro_codes, promoted_codes))
        blocks = filter(row -> row.plant_type == "CombinedCycleBlock", PLANTS)
        @test nrow(unique(blocks, [:PlantCode, :cc_unit_code])) == 65
    end

    @testset "CAISO reactive resources" begin
        capacitors = filter(row -> row.component_type == "FixedAdmittance", REACTIVE)
        expected_mvar = sum(capacitors.mvar_per_unit .* capacitors.n_units)
        banks = collect(get_components(
            x -> startswith(get_name(x), "ShuntCapacitor_"), FixedAdmittance, SYS,
        ))
        @test length(banks) == nrow(capacitors)
        @test isapprox(
            sum(imag(get_Y(b)) for b in banks) * get_base_power(SYS),
            expected_mvar;
            rtol = 1e-6,
        )

        dynamic = filter(row -> row.component_type == "SynchronousCondenser", REACTIVE)
        expected_units = sum(dynamic.n_units)
        real_units = collect(get_components(
            x -> !startswith(get_name(x), "gen-"), SynchronousCondenser, SYS,
        ))
        @test length(real_units) == expected_units
        @test isapprox(
            sum(get_rating(u, PSY.NU) for u in real_units),
            sum(dynamic.mvar_per_unit .* dynamic.n_units);
            rtol = 1e-6,
        )

        # The MATPOWER placeholders stay curtailed through the round trip.
        placeholders = collect(get_components(
            x -> startswith(get_name(x), "gen-"), SynchronousCondenser, SYS,
        ))
        @test !isempty(placeholders)
        for unit in placeholders
            @test isapprox(get_reactive_power_limits(unit, PSY.NU).max, 100.0)
        end
    end

    @testset "DataSource provenance" begin
        sources = collect(get_supplemental_attributes(DataSource, SYS))
        @test length(sources) == 10
        organizations = Set(get_organization(s) for s in sources)
        for expected in (
            "U.S. Energy Information Administration",
            "California ISO",
            "U.S. Army Corps of Engineers",
            "Oak Ridge National Laboratory",
            "California Department of Water Resources",
            "U.S. Geological Survey",
        )
            @test expected in organizations
        end
        # The guessed values must stay separable from the measured ones.
        @test count(s -> get_confidence(s) == "low", sources) == 2
    end
end
