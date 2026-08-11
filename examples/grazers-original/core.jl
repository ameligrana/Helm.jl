using Ark
using Random: AbstractRNG, Xoshiro, rand, randn

include("components.jl")
include("resources.jl")
include("scheduler.jl")
include("systems.jl")

function create_original_grazers_world(;
    width::Int=120,
    height::Int=100,
    scale::Int=6,
    seed::Integer=1,
)
    world = new_grazer_world()
    add_resource!(world, WorldSize(width, height, scale))
    add_resource!(world, SimulationRNG(Xoshiro(seed)))
    return world
end

function create_original_grazers_scheduler(world::World; count::Int=1000)
    return OriginalGrazersScheduler(
        world,
        (
            GrazerInit(count=count),
            GrassGrowth(growth_rate=0.01, feature_size=23.0),
            GrazerMovement(speed=0.1),
            GrazerFeeding(max_grazing=0.025, efficiency=1.0, threshold=0.1),
            GrazerReproduction(max_offspring=10, cross_rate=0.2, mutation_rate=0.01),
            GrazerMetabolism(base_rate=0.005, move_rate=0.01),
            GrazerMortality(),
            GrazerDecision(),
        ),
    )
end
