struct GrassGrid
    capacity::Matrix{Float64}
    grass::Matrix{Float64}
end

struct WorldSize
    width::Int
    height::Int
    scale::Int
end

mutable struct Tick
    tick::Int
end

mutable struct SimulationRNG
    rng::Xoshiro
end

struct GrazerInit
    count::Int
end

GrazerInit(; count::Int=100) = GrazerInit(count)

struct GrassGrowth
    growth_rate::Float64
    feature_size::Float64
end

GrassGrowth(; growth_rate::Float64=0.01, feature_size::Float64=25.0) =
    GrassGrowth(growth_rate, feature_size)

struct GrazerMovement
    speed::Float64
end

GrazerMovement(; speed::Float64=0.1) = GrazerMovement(speed)

struct GrazerFeeding
    max_grazing::Float64
    efficiency::Float64
    threshold::Float64
end

function GrazerFeeding(;
    max_grazing::Float64=0.05,
    efficiency::Float64=1.0,
    threshold::Float64=0.1,
)
    return GrazerFeeding(max_grazing, efficiency, threshold)
end

struct GrazerReproduction
    max_offspring::Int
    cross_rate::Float64
    mutation_rate::Float64
end

function GrazerReproduction(;
    max_offspring::Int=10,
    cross_rate::Float64=0.2,
    mutation_rate::Float64=0.01,
)
    return GrazerReproduction(max_offspring, cross_rate, mutation_rate)
end

struct ReproductionBatch
    position::Position
    mother::Genes
    father::Genes
    offspring::Int
    energy::Float64
    grazing::Bool
end

mutable struct ReproductionScratch
    mates::Vector{Genes}
    batches::Vector{ReproductionBatch}
end

ReproductionScratch() = ReproductionScratch(Genes[], ReproductionBatch[])

struct GrazerMetabolism
    base_rate::Float64
    move_rate::Float64
end

GrazerMetabolism(; base_rate::Float64=0.005, move_rate::Float64=0.025) =
    GrazerMetabolism(base_rate, move_rate)

function make_grass_grid(size::WorldSize, settings::GrassGrowth)
    capacity = zeros(Float64, size.width, size.height)
    noise_scale = 1.0 / settings.feature_size
    for x in 1:size.width, y in 1:size.height
        # A small deterministic fractal-like terrain keeps the headless core
        # dependency-free while retaining the original demo's patchy grass.
        terrain =
            0.20 * sin(x * noise_scale) +
            0.13 * cos(y * noise_scale * 1.7) +
            0.08 * sin((x + y) * noise_scale * 3.1) +
            0.04 * cos((2x - y) * noise_scale * 5.3)
        capacity[x, y] = clamp(
            terrain + 0.33,
            0.01,
            1.0,
        )
    end
    return GrassGrid(capacity, copy(capacity))
end
