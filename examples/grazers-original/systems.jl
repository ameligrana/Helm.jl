struct GrazerInit <: OriginalSystem
    count::Int
end

GrazerInit(; count::Int=100) = GrazerInit(count)

function initialize!(system::GrazerInit, world::World)
    size = get_resource(world, WorldSize)
    rng = get_resource(world, SimulationRNG).rng
    new_entities!(world, system.count, (Position, Rotation, Energy, Genes, Moving)) do (
        entities,
        positions,
        rotations,
        energies,
        genes,
        moving_tags,
    )
        for i in eachindex(positions)
            positions[i] = Position(
                rand(rng) * size.width - 0.01,
                rand(rng) * size.height - 0.01,
            )
            rotations[i] = Rotation(rand(rng) * 2π)
            energies[i] = Energy(rand(rng) * 0.5 + 0.5)
            genes[i] = Genes(
                max_angle=rand(rng),
                reverse_prob=rand(rng),
                move_thresh=rand(rng),
                graze_thresh=rand(rng),
                num_offspring=rand(rng),
                energy_share=rand(rng),
            )
        end
    end
    return nothing
end

struct GrassGrowth <: OriginalSystem
    growth_rate::Float64
    feature_size::Float64
end

GrassGrowth(; growth_rate::Float64=0.01, feature_size::Float64=25.0) =
    GrassGrowth(growth_rate, feature_size)

function initialize!(system::GrassGrowth, world::World)
    add_resource!(
        world,
        make_grass_grid(get_resource(world, WorldSize), system.feature_size),
    )
    return nothing
end

function update!(system::GrassGrowth, world::World)
    grid = get_resource(world, GrassGrid)
    values = grid.grass
    for j in axes(values, 2), i in axes(values, 1)
        value = values[i, j]
        cap = grid.capacity[i, j]
        value += system.growth_rate * value * (1.0 - value / cap)
        values[i, j] = clamp(value, 0.0, 1.0)
    end
    return nothing
end

struct GrazerMovement <: OriginalSystem
    speed::Float64
end

GrazerMovement(; speed::Float64=0.1) = GrazerMovement(speed)

function update!(system::GrazerMovement, world::World)
    size = get_resource(world, WorldSize)
    rng = get_resource(world, SimulationRNG).rng
    for (_, positions, rotations, genes) in
        Query(world, (Position, Rotation, Genes); with=(Moving,))
        for i in eachindex(positions, rotations, genes)
            rotation = rotations[i]
            position = positions[i]
            gene = genes[i]
            max_angle = gene.max_angle * 0.5π
            rotation = mod(rotation + (rand(rng) * 2.0 - 1.0) * max_angle, 2π)
            if rand(rng) * 10.0 < gene.reverse_prob
                rotation = mod(rotation + π, 2π)
            end
            positions[i] = Position(
                mod(position[1] + system.speed * cos(rotation) + size.width, size.width - 0.001),
                mod(position[2] + system.speed * sin(rotation) + size.height, size.height - 0.001),
            )
            rotations[i] = rotation
        end
    end
    return nothing
end

struct GrazerFeeding <: OriginalSystem
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

function update!(system::GrazerFeeding, world::World)
    grass = get_resource(world, GrassGrid).grass
    for (_, positions, energies) in Query(world, (Position, Energy); with=(Grazing,))
        for i in eachindex(positions, energies)
            position = positions[i]
            cell_x = floor(Int, position[1]) + 1
            cell_y = floor(Int, position[2]) + 1
            grass_here = grass[cell_x, cell_y]
            if grass_here > system.threshold + system.max_grazing
                grass[cell_x, cell_y] = grass_here - system.max_grazing
                energies[i] = Energy(
                    clamp(
                        energies[i].value + system.max_grazing * system.efficiency,
                        0.0,
                        1.0,
                    ),
                )
            end
        end
    end
    return nothing
end

struct Reproduction
    mother::Entity
    father::Entity
    offspring::Int
    energy::Float64
end

struct GrazerReproduction <: OriginalSystem
    max_offspring::Int
    cross_rate::Float64
    mutation_rate::Float64
    to_reproduce::Vector{Reproduction}
    mates::Vector{Entity}
end

function GrazerReproduction(;
    max_offspring::Int,
    cross_rate::Float64,
    mutation_rate::Float64,
)
    return GrazerReproduction(
        max_offspring,
        cross_rate,
        mutation_rate,
        Reproduction[],
        Entity[],
    )
end

function mutate(
    rng::AbstractRNG,
    mother::Float64,
    father::Float64,
    cross::Float64,
    rate::Float64,
)
    base = rand(rng) < cross ? father : mother
    return clamp(base + randn(rng) * rate, 0.0, 1.0)
end

function update!(system::GrazerReproduction, world::World)
    empty!(system.to_reproduce)
    empty!(system.mates)
    rng = get_resource(world, SimulationRNG).rng

    for (entities,) in Query(world, (); with=(Energy,))
        append!(system.mates, entities)
    end
    for (entities, energies, genes) in Query(world, (Energy, Genes))
        for i in eachindex(entities, energies, genes)
            if energies[i].value >= 1.0
                gene = genes[i]
                push!(
                    system.to_reproduce,
                    Reproduction(
                        entities[i],
                        rand(rng, system.mates),
                        round(Int, system.max_offspring * gene.num_offspring),
                        gene.energy_share,
                    ),
                )
                energies[i] = Energy(1.0 - gene.energy_share)
            end
        end
    end

    for reproduction in system.to_reproduce
        child_energy = reproduction.energy / reproduction.offspring
        mother, = get_components(world, reproduction.mother, (Genes,))
        father, = get_components(world, reproduction.father, (Genes,))
        for _ in 1:reproduction.offspring
            child = copy_entity!(world, reproduction.mother)
            genes = Genes(
                max_angle=mutate(
                    rng,
                    mother.max_angle,
                    father.max_angle,
                    system.cross_rate,
                    system.mutation_rate,
                ),
                reverse_prob=mutate(
                    rng,
                    mother.reverse_prob,
                    father.reverse_prob,
                    system.cross_rate,
                    system.mutation_rate,
                ),
                move_thresh=mutate(
                    rng,
                    mother.move_thresh,
                    father.move_thresh,
                    system.cross_rate,
                    system.mutation_rate,
                ),
                graze_thresh=mutate(
                    rng,
                    mother.graze_thresh,
                    father.graze_thresh,
                    system.cross_rate,
                    system.mutation_rate,
                ),
                num_offspring=mutate(
                    rng,
                    mother.num_offspring,
                    father.num_offspring,
                    system.cross_rate,
                    system.mutation_rate,
                ),
                energy_share=mutate(
                    rng,
                    mother.energy_share,
                    father.energy_share,
                    system.cross_rate,
                    system.mutation_rate,
                ),
            )
            set_components!(
                world,
                child,
                (Energy(child_energy), Rotation(rand(rng) * 2π), genes),
            )
        end
    end
    return nothing
end

struct GrazerMetabolism <: OriginalSystem
    base_rate::Float64
    move_rate::Float64
end

GrazerMetabolism(; base_rate::Float64=0.005, move_rate::Float64=0.025) =
    GrazerMetabolism(base_rate, move_rate)

function update!(system::GrazerMetabolism, world::World)
    for (_, energies) in Query(world, (Energy,); with=(Grazing,))
        for i in eachindex(energies)
            energies[i] = Energy(clamp(energies[i].value - system.base_rate, 0.0, 1.0))
        end
    end
    for (_, energies) in Query(world, (Energy,); with=(Moving,))
        for i in eachindex(energies)
            energies[i] = Energy(clamp(energies[i].value - system.move_rate, 0.0, 1.0))
        end
    end
    return nothing
end

struct GrazerMortality <: OriginalSystem end

initialize!(::GrazerMortality, world::World) =
    add_resource!(world, GrazerMortalityCommands(world))

function update!(::GrazerMortality, world::World)
    commands = get_resource(world, GrazerMortalityCommandsType).commands
    for (entities, energies) in Query(world, (Energy,))
        for i in eachindex(entities, energies)
            energies[i].value <= 0.0 && remove_entity!(commands, entities[i])
        end
    end
    apply!(commands)
    return nothing
end

struct GrazerDecision <: OriginalSystem end

initialize!(::GrazerDecision, world::World) =
    add_resource!(world, GrazerDecisionCommands(world))

function update!(::GrazerDecision, world::World)
    commands = get_resource(world, GrazerDecisionCommandsType).commands
    grass = get_resource(world, GrassGrid).grass
    for (entities, positions, genes) in Query(world, (Position, Genes); with=(Moving,))
        for i in eachindex(entities, positions, genes)
            position = positions[i]
            cell_x = floor(Int, position[1]) + 1
            cell_y = floor(Int, position[2]) + 1
            if grass[cell_x, cell_y] > genes[i].graze_thresh
                exchange_components!(
                    commands,
                    entities[i];
                    add=(Grazing(),),
                    remove=(Moving,),
                )
            end
        end
    end
    for (entities, positions, genes) in Query(world, (Position, Genes); with=(Grazing,))
        for i in eachindex(entities, positions, genes)
            position = positions[i]
            cell_x = floor(Int, position[1]) + 1
            cell_y = floor(Int, position[2]) + 1
            gene = genes[i]
            if grass[cell_x, cell_y] < gene.graze_thresh * gene.move_thresh
                exchange_components!(
                    commands,
                    entities[i];
                    add=(Moving(),),
                    remove=(Grazing,),
                )
            end
        end
    end
    apply!(commands)
    return nothing
end
