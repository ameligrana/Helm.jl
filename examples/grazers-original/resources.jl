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

struct GrazerMortalityCommands{B<:CommandBuffer}
    commands::B
end

GrazerMortalityCommands(world::World) =
    GrazerMortalityCommands(CommandBuffer(world, (RemoveEntityCommand(),)))

struct GrazerDecisionCommands{B<:CommandBuffer}
    commands::B
end

function GrazerDecisionCommands(world::World)
    return GrazerDecisionCommands(
        CommandBuffer(
            world,
            (
                ExchangeComponentsCommand(add=(Grazing,), remove=(Moving,)),
                ExchangeComponentsCommand(add=(Moving,), remove=(Grazing,)),
            ),
        ),
    )
end

new_grazer_world() = World(Position, Rotation, Energy, Genes, Moving, Grazing)

const GRAZER_COMMAND_TYPES = let world = new_grazer_world()
    (
        mortality=typeof(GrazerMortalityCommands(world)),
        decision=typeof(GrazerDecisionCommands(world)),
    )
end

const GrazerMortalityCommandsType = GRAZER_COMMAND_TYPES.mortality
const GrazerDecisionCommandsType = GRAZER_COMMAND_TYPES.decision

function make_grass_grid(size::WorldSize, feature_size::Float64)
    capacity = zeros(Float64, size.width, size.height)
    noise_scale = 1.0 / feature_size
    for x in 1:size.width, y in 1:size.height
        terrain =
            0.20 * sin(x * noise_scale) +
            0.13 * cos(y * noise_scale * 1.7) +
            0.08 * sin((x + y) * noise_scale * 3.1) +
            0.04 * cos((2x - y) * noise_scale * 5.3)
        capacity[x, y] = clamp(terrain + 0.33, 0.01, 1.0)
    end
    return GrassGrid(capacity, copy(capacity))
end
