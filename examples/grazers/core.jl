using Ark
using Random: AbstractRNG, Xoshiro, rand, randn
using Helm: Cmds, Const, Query, Res, ResMut, Schedule, System, before

include("components.jl")
include("resources.jl")
include("systems.jl")

function create_grazers_world(;
    width::Int=120,
    height::Int=100,
    scale::Int=6,
    count::Int=1000,
    seed::Integer=1,
)
    size = WorldSize(width, height, scale)
    growth = GrassGrowth(growth_rate=0.01, feature_size=23.0)
    world = World(Position, Rotation, Energy, Genes, Moving, Grazing)
    add_resource!(world, size)
    add_resource!(world, Tick(0))
    add_resource!(world, SimulationRNG(Xoshiro(seed)))
    add_resource!(world, GrazerInit(count=count))
    add_resource!(world, growth)
    add_resource!(world, GrazerMovement(speed=0.1))
    add_resource!(world, GrazerFeeding(max_grazing=0.025, efficiency=1.0, threshold=0.1))
    add_resource!(
        world,
        GrazerReproduction(max_offspring=10, cross_rate=0.2, mutation_rate=0.01),
    )
    add_resource!(world, ReproductionScratch())
    add_resource!(world, GrazerMetabolism(base_rate=0.005, move_rate=0.01))
    add_resource!(world, make_grass_grid(size, growth))
    return world
end

grazers_startup_schedule() = Schedule(initialize_grazers)

function grazers_update_schedule()
    return Schedule(
        grow_grass,
        move_grazers,
        feed_grazers,
        reproduce_grazers,
        metabolize_grazers,
        remove_dead_grazers,
        before(decide_grazer_state, advance_grazers_tick),
    )
end
