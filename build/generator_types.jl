"""Contains all the mappings for generator data parsing from MATPOWER format."""

# Fallback only: generators with an EIA match (data/generator_prime_movers.csv, `eia_pm`
# column) get their prime mover from that lookup instead. This dict now only ever gets
# consulted for the 1769 EIA-unmatched rows -- synchronous condensers and imports -- both
# of which map to OT and are dropped by maybe_add_prime_mover_type! regardless.
const PM_TYPE_DICT = Dict{String, PSY.PrimeMovers.Value}(
    "Conventional Hydroelectric" => PrimeMovers.HA,
    "Hydroelectric Pumped Storage" => PrimeMovers.HY,

    "Solar Photovoltaic" => PrimeMovers.PVe,
    "Solar Thermal without Energy Storage" => PrimeMovers.PVe,

    "Onshore Wind Turbine" => PrimeMovers.WT,

    "Batteries" => PrimeMovers.BA,

    "Municipal Solid Waste" => PrimeMovers.ST,
    "Other Waste Biomass" => PrimeMovers.ST,
    "Petroleum Liquids" => PrimeMovers.IC,
    "Geothermal" => PrimeMovers.ST,
    "Nuclear" => PrimeMovers.ST,
    "Wood/Wood Waste Biomass" => PrimeMovers.ST,
    "Conventional Steam Coal" => PrimeMovers.ST,
    "Petroleum Coke" => PrimeMovers.ST,
    "Natural Gas Fired Combustion Turbine" => PrimeMovers.GT,
    "Natural Gas Internal Combustion Engine" => PrimeMovers.IC,
    "Natural Gas Fired Combined Cycle" => PrimeMovers.CT,
    "Natural Gas Steam Turbine" => PrimeMovers.ST,
    "Other Natural Gas" => PrimeMovers.OT,

    # no prime mover type--handled as SynchronousCondenser and Source structs--but still
    # included here for code flow simplicity.
    "Synchronous Condenser" => PrimeMovers.OT,
    "IMPORT" => PrimeMovers.OT,

    "All Other" => PrimeMovers.OT,
    "Landfill Gas" => PrimeMovers.OT,
    "Other Gases" => PrimeMovers.OT
)

# Ramp fractions (of Pmax, per minute). The original numbered WECC table cited in
# DURATION_LIMIT_DICT below could not be located online; coal/CC/SC values here are
# corrected against RTS-GMLC's public per-unit gen.csv
# (github.com/GridMod/RTS-GMLC/blob/master/RTS_Data/SourceData/gen.csv) instead.
const RAMP_LIMIT_DICT = Dict(
    (PrimeMovers.ST, ThermalFuels.COAL) => (up = 0.0194, down = 0.0194), # RTS-GMLC STEAM/Coal (155 MW unit; 3 units range 1.14-2.63%/min)

    (PrimeMovers.CA, ThermalFuels.NATURAL_GAS) => (up = 0.0117, down = 0.0117), # RTS-GMLC CC/NG (355 MW units)
    (PrimeMovers.CT, ThermalFuels.NATURAL_GAS) => (up = 0.0673, down = 0.0673), # RTS-GMLC CT/NG (55 MW units)
    (PrimeMovers.GT, ThermalFuels.NATURAL_GAS) => (up = 0.0673, down = 0.0673), # RTS-GMLC has one simple-cycle-gas category (CT/NG); same source as above
    (PrimeMovers.ST, ThermalFuels.NATURAL_GAS) => (up = 0.0194, down = 0.0194), # no NG-fired steam unit in RTS-GMLC; approximated from the coal steam-turbine figure (boiler/turbine dynamics, not fuel, dominate steam-cycle ramp)

    # Not from WECC or RTS-GMLC: ballpark estimates (see DURATION_LIMIT_DICT). RTS-GMLC's
    # generic nuclear entry ramps at 5%/min -- ~500x faster than the value below -- but that
    # reflects a generic test-system assumption, not how the US nuclear fleet is actually
    # operated (near-must-run, essentially no load-following). Intentionally left
    # unmatched to RTS-GMLC; documented here as a known, deliberate outlier.
    (PrimeMovers.ST, ThermalFuels.NUCLEAR) => (up = 0.0001, down = 0.0001),
    (PrimeMovers.ST, ThermalFuels.GEOTHERMAL) => (up = 0.01, down = 0.01), # no geothermal unit in RTS-GMLC or other source found; unverified estimate, left as-is

    # Below: gaps opened up by the EIA prime-mover enrichment (data/generator_prime_movers.csv).
    # GT and CT previously only ever paired with NATURAL_GAS (the only FuelType that used to
    # map to them); EIA prime movers now reclassify some Petroleum Liquids/Landfill Gas/Other
    # Waste Biomass/Other Gases units as GT or CT too. Ramp/duration physics for a simple- or
    # combined-cycle turbine are governed by the turbine hardware, not the fuel, so these reuse
    # the existing NATURAL_GAS figures for the same prime mover.
    (PrimeMovers.GT, ThermalFuels.RESIDUAL_FUEL_OIL) => (up = 0.0673, down = 0.0673),
    (PrimeMovers.GT, ThermalFuels.MUNICIPAL_WASTE) => (up = 0.0673, down = 0.0673),
    (PrimeMovers.GT, ThermalFuels.OTHER_GAS) => (up = 0.0673, down = 0.0673),
    (PrimeMovers.CT, ThermalFuels.MUNICIPAL_WASTE) => (up = 0.0673, down = 0.0673),
    (PrimeMovers.CA, ThermalFuels.MUNICIPAL_WASTE) => (up = 0.0117, down = 0.0117),
    (PrimeMovers.CA, ThermalFuels.OTHER_GAS) => (up = 0.0117, down = 0.0117),

    # CS (single-shaft combined cycle): no RTS-GMLC or WECC single-shaft figure exists;
    # approximated from the CA/combined-cycle-steam figure above, since a single-shaft unit's
    # ramp is likewise governed by the shared steam cycle, not the fuel.
    (PrimeMovers.CS, ThermalFuels.NATURAL_GAS) => (up = 0.0117, down = 0.0117),

    # BT (binary-cycle geothermal): no RTS-GMLC or WECC figure; approximated from the ST/
    # GEOTHERMAL figure above (binary-cycle plants ramp similarly to geothermal steam plants
    # absent better data).
    (PrimeMovers.BT, ThermalFuels.GEOTHERMAL) => (up = 0.01, down = 0.01),

    # FC (fuel cell): median unit here is ~1.1 MW (Bloom Energy-class, behind-the-meter);
    # electrochemical generation ramps far faster than any combustion prime mover. Unverified
    # estimate reflecting that fast-ramp character, not a cited source.
    (PrimeMovers.FC, ThermalFuels.MUNICIPAL_WASTE) => (up = 1.0, down = 1.0),
    (PrimeMovers.FC, ThermalFuels.NATURAL_GAS) => (up = 1.0, down = 1.0),
)

const PSY_TO_WECC_DICT = Dict(
    (PrimeMovers.ST, ThermalFuels.COAL) => "CLLIG",

    (PrimeMovers.CA, ThermalFuels.NATURAL_GAS) => "CC",
    (PrimeMovers.CT, ThermalFuels.NATURAL_GAS) => "SC",
    (PrimeMovers.GT, ThermalFuels.NATURAL_GAS) => "SC",
    (PrimeMovers.ST, ThermalFuels.NATURAL_GAS) => "GS",
    # not from WECC: my own invented abbreviations.
    (PrimeMovers.ST, ThermalFuels.GEOTHERMAL) => "GEO",
    (PrimeMovers.ST, ThermalFuels.NUCLEAR) => "NUC",

    # See the matching comments in RAMP_LIMIT_DICT above for the rationale behind each of
    # these (EIA prime-mover enrichment gap-fill).
    (PrimeMovers.GT, ThermalFuels.RESIDUAL_FUEL_OIL) => "SC",
    (PrimeMovers.GT, ThermalFuels.MUNICIPAL_WASTE) => "SC",
    (PrimeMovers.GT, ThermalFuels.OTHER_GAS) => "SC",
    (PrimeMovers.CT, ThermalFuels.MUNICIPAL_WASTE) => "SC",
    (PrimeMovers.CA, ThermalFuels.MUNICIPAL_WASTE) => "CC",
    (PrimeMovers.CA, ThermalFuels.OTHER_GAS) => "CC",
    (PrimeMovers.CS, ThermalFuels.NATURAL_GAS) => "CC",
    (PrimeMovers.BT, ThermalFuels.GEOTHERMAL) => "GEO",
    (PrimeMovers.FC, ThermalFuels.MUNICIPAL_WASTE) => "FC",
    (PrimeMovers.FC, ThermalFuels.NATURAL_GAS) => "FC",
)


function get_size(WECC_key::String, maxPower::Float64)
    if WECC_key in ("CC", "SC")
        if maxPower <= 90
            return "LE90"
        else
            return "GT90"
        end
    elseif WECC_key in ("GEO", "NUC", "FC")
        return "ANY"
    elseif WECC_key == "CLLIG"
        if maxPower <= 300
            return "SMALL"
        elseif maxPower <= 900
            return "LARGE"
        else
            return "SUPER"
        end
    elseif WECC_key == "GS"
        return "REH"  # default to reheat
    end
    @assert false "Unexpected input to get_size: $WECC_key, $maxPower"
    return "NONE"
end

const DURATION_LIMIT_DICT = Dict(
    # The original numbered WECC table this used to cite could not be located online.
    # Where RTS-GMLC's public per-unit gen.csv (github.com/GridMod/RTS-GMLC) has a matching
    # unit type/size, values below are corrected against it; where it doesn't, the original
    # WECC-cited value is kept, noted below.
    ("CLLIG", "SMALL") => (up = 8.0, down = 6.0), # WECC (1) Small coal; RTS-GMLC 76MW & 155MW coal units: up=8h both, down=4h/8h (midpoint used)
    ("CLLIG", "LARGE") => (up = 24.0, down = 48.0), # WECC (2) Large coal; RTS-GMLC 350MW coal unit: up=24h, down=48h
    ("CLLIG", "SUPER") => (up = 24.0, down = 48.0), # WECC (3) Super-critical coal; no RTS-GMLC unit >900MW -- mirrors LARGE as the best available estimate
    ("CC", "GT90") => (up = 8.0, down = 4.5), # WECC (7) Typical CC; RTS-GMLC 355MW CC/NG units
    ("CC", "LE90") => (up = 2.0, down = 4.0), # WECC (7) Typical CC, modified; no RTS-GMLC CC unit <=90MW -- original WECC-cited value kept
    ("GS", "NONR") => (up = 2.0, down = 4.0), # Gas steam non-reheat -> WECC (4); no NG-fired steam unit in RTS-GMLC -- original WECC-cited value kept
    ("GS", "REH") => (up = 2.0, down = 4.0), # Gas steam reheat boiler -> WECC (4); same as above
    ("GS", "SUP") => (up = 2.0, down = 4.0), # Gas-steam supercritical -> WECC (4); same as above
    ("SC", "GT90") => (up = 1.0, down = 1.0), # Simple-cycle greater than 90 MW -> WECC (5) Large-frame Gas CT; no RTS-GMLC unit >90MW -- original WECC-cited value kept
    ("SC", "LE90") => (up = 2.2, down = 2.2), # Simple-cycle less than 90 MW -> WECC (6) Aero derivative CT; RTS-GMLC 55MW CT/NG units
    # Not from WECC or RTS-GMLC: ballpark estimates given by Jose. RTS-GMLC's generic
    # nuclear entry uses 24h/48h (treating nuclear as a normal cyclable unit); kept far more
    # conservative here since the US nuclear fleet is essentially must-run between
    # refueling outages, not load-following. Documented here as a known, deliberate outlier.
    ("GEO", "ANY") => (up = 1000, down = 300), # no geothermal unit in RTS-GMLC or other source found; unverified estimate, left as-is
    ("NUC", "ANY") => (up = 8000, down = 8000),
    # FC (fuel cell): near-instantaneous electrochemical response; unverified estimate, not a
    # cited source -- see the FC comment in RAMP_LIMIT_DICT above.
    ("FC", "ANY") => (up = 0.1, down = 0.1),
)

const OTHER_TYPES = ("Synchronous Condenser", "IMPORT", "All Other")

const FUELS_DICT = Dict(
    # simpler to handle Natural Gas types by looking for "Natural Gas" substring
    "Municipal Solid Waste" => ThermalFuels.MUNICIPAL_WASTE,
    "Other Waste Biomass" => ThermalFuels.MUNICIPAL_WASTE,
    "Petroleum Liquids" => ThermalFuels.RESIDUAL_FUEL_OIL,
    "Geothermal" => ThermalFuels.GEOTHERMAL,
    "Nuclear" => ThermalFuels.NUCLEAR,
    "Wood/Wood Waste Biomass" => ThermalFuels.WOOD_WASTE_SOLIDS,
    "Conventional Steam Coal" => ThermalFuels.COAL,
    "Petroleum Coke" => ThermalFuels.PETROLEUM_COKE,
    "Landfill Gas" => ThermalFuels.MUNICIPAL_WASTE,
    "Other Gases" => ThermalFuels.OTHER_GAS
)
