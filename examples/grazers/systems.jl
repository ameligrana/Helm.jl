const GRAZER_MOVING_COMPONENTS = (Position, Rotation, Energy, Genes, Moving)
const GRAZER_GRAZING_COMPONENTS = (Position, Rotation, Energy, Genes, Grazing)

initialize_grazers = System(
    Res(WorldSize),
    Res(GrazerInit),
    ResMut(SimulationRNG),
    Cmds((NewEntityCommand(GRAZER_MOVING_COMPONENTS),)),
) do size, settings, simulation_rng, commands
    rng = simulation_rng.rng
    for _ in 1:settings.count
        new_entity!(
            commands,
            (
                Position(rand(rng) * size.width - 0.01, rand(rng) * size.height - 0.01),
                Rotation(rand(rng) * 2π),
                Energy(rand(rng) * 0.5 + 0.5),
                Genes(
                    max_angle=rand(rng),
                    reverse_prob=rand(rng),
                    move_thresh=rand(rng),
                    graze_thresh=rand(rng),
                    num_offspring=rand(rng),
                    energy_share=rand(rng),
                ),
                Moving(),
            ),
        )
    end
    return nothing
end

grow_grass = System(ResMut(GrassGrid), Res(GrassGrowth)) do grid, settings
    values = grid.grass
    capacity = grid.capacity
    rate = settings.growth_rate
    for j in axes(values, 2), i in axes(values, 1)
        value = values[i, j]
        cap = capacity[i, j]
        value += rate * value * (1.0 - value / cap)
        values[i, j] = clamp(value, 0.0, 1.0)
    end
    return nothing
end

move_grazers = System(
    Res(WorldSize),
    Res(GrazerMovement),
    ResMut(SimulationRNG),
    Query((Position, Rotation, Const(Genes)); with=(Moving,)),
) do size, settings, simulation_rng, query
    rng = simulation_rng.rng
    for (_, positions, rotations, genes) in query
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
                mod(position[1] + settings.speed * cos(rotation) + size.width, size.width - 0.001),
                mod(position[2] + settings.speed * sin(rotation) + size.height, size.height - 0.001),
            )
            rotations[i] = rotation
        end
    end
    return nothing
end

feed_grazers = System(
    ResMut(GrassGrid),
    Res(GrazerFeeding),
    Query((Const(Position), Energy); with=(Grazing,)),
) do grid, settings, query
    grass = grid.grass
    for (_, positions, energies) in query
        for i in eachindex(positions, energies)
            position = positions[i]
            cell_x = floor(Int, position[1]) + 1
            cell_y = floor(Int, position[2]) + 1
            grass_here = grass[cell_x, cell_y]
            if grass_here > settings.threshold + settings.max_grazing
                grass[cell_x, cell_y] = grass_here - settings.max_grazing
                energies[i] = Energy(
                    clamp(
                        energies[i].value + settings.max_grazing * settings.efficiency,
                        0.0,
                        1.0,
                    ),
                )
            end
        end
    end
    return nothing
end

function mutate_gene(
    rng::AbstractRNG,
    mother::Float64,
    father::Float64,
    cross_rate::Float64,
    mutation_rate::Float64,
)
    base = rand(rng) < cross_rate ? father : mother
    return clamp(base + randn(rng) * mutation_rate, 0.0, 1.0)
end

function collect_reproduction_batches!(
    batches::Vector{ReproductionBatch},
    query,
    mates::Vector{Genes},
    settings::GrazerReproduction,
    rng::AbstractRNG,
    grazing::Bool,
)
    for (_, positions, energies, genes) in query
        for i in eachindex(positions, energies, genes)
            energies[i].value >= 1.0 || continue
            gene = genes[i]
            push!(
                batches,
                ReproductionBatch(
                    positions[i],
                    gene,
                    rand(rng, mates),
                    round(Int, settings.max_offspring * gene.num_offspring),
                    gene.energy_share,
                    grazing,
                ),
            )
            energies[i] = Energy(1.0 - gene.energy_share)
        end
    end
    return nothing
end

const reproduction_commands = Cmds(
    (
        NewEntityCommand(GRAZER_MOVING_COMPONENTS),
        NewEntityCommand(GRAZER_GRAZING_COMPONENTS),
    ),
)

reproduce_grazers = System(
    Res(GrazerReproduction),
    ResMut(ReproductionScratch),
    ResMut(SimulationRNG),
    Query((Const(Genes),)),
    Query((Const(Position), Energy, Const(Genes)); with=(Moving,)),
    Query((Const(Position), Energy, Const(Genes)); with=(Grazing,)),
    reproduction_commands,
) do settings, scratch, simulation_rng, mate_query, moving_query, grazing_query, commands
    rng = simulation_rng.rng
    mates = scratch.mates
    batches = scratch.batches
    empty!(mates)
    empty!(batches)

    for (_, genes) in mate_query
        append!(mates, genes)
    end

    isempty(mates) || collect_reproduction_batches!(
        batches,
        moving_query,
        mates,
        settings,
        rng,
        false,
    )
    isempty(mates) || collect_reproduction_batches!(
        batches,
        grazing_query,
        mates,
        settings,
        rng,
        true,
    )

    for batch in batches
        child_energy = batch.energy / batch.offspring
        for _ in 1:batch.offspring
            genes = Genes(
                max_angle=mutate_gene(
                    rng,
                    batch.mother.max_angle,
                    batch.father.max_angle,
                    settings.cross_rate,
                    settings.mutation_rate,
                ),
                reverse_prob=mutate_gene(
                    rng,
                    batch.mother.reverse_prob,
                    batch.father.reverse_prob,
                    settings.cross_rate,
                    settings.mutation_rate,
                ),
                move_thresh=mutate_gene(
                    rng,
                    batch.mother.move_thresh,
                    batch.father.move_thresh,
                    settings.cross_rate,
                    settings.mutation_rate,
                ),
                graze_thresh=mutate_gene(
                    rng,
                    batch.mother.graze_thresh,
                    batch.father.graze_thresh,
                    settings.cross_rate,
                    settings.mutation_rate,
                ),
                num_offspring=mutate_gene(
                    rng,
                    batch.mother.num_offspring,
                    batch.father.num_offspring,
                    settings.cross_rate,
                    settings.mutation_rate,
                ),
                energy_share=mutate_gene(
                    rng,
                    batch.mother.energy_share,
                    batch.father.energy_share,
                    settings.cross_rate,
                    settings.mutation_rate,
                ),
            )
            values = (
                batch.position,
                Rotation(rand(rng) * 2π),
                Energy(child_energy),
                genes,
            )
            if batch.grazing
                new_entity!(commands, (values..., Grazing()))
            else
                new_entity!(commands, (values..., Moving()))
            end
        end
    end
    return nothing
end

metabolize_grazers = System(
    Res(GrazerMetabolism),
    Query((Energy,); with=(Grazing,)),
    Query((Energy,); with=(Moving,)),
) do settings, grazing_query, moving_query
    for (_, energies) in grazing_query
        for i in eachindex(energies)
            energies[i] = Energy(clamp(energies[i].value - settings.base_rate, 0.0, 1.0))
        end
    end
    for (_, energies) in moving_query
        for i in eachindex(energies)
            energies[i] = Energy(clamp(energies[i].value - settings.move_rate, 0.0, 1.0))
        end
    end
    return nothing
end

remove_dead_grazers = System(
    Query((Const(Energy),)),
    Cmds((RemoveEntityCommand(),)),
) do query, commands
    for (entities, energies) in query
        for i in eachindex(entities, energies)
            energies[i].value <= 0.0 && remove_entity!(commands, entities[i])
        end
    end
    return nothing
end

decide_grazer_state = System(
    Res(GrassGrid),
    Query((Const(Position), Const(Genes)); with=(Moving,)),
    Query((Const(Position), Const(Genes)); with=(Grazing,)),
    Cmds(
        (
            ExchangeComponentsCommand(add=(Grazing,), remove=(Moving,)),
            ExchangeComponentsCommand(add=(Moving,), remove=(Grazing,)),
        ),
    ),
) do grid, moving_query, grazing_query, commands
    grass = grid.grass
    for (entities, positions, genes) in moving_query
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
    for (entities, positions, genes) in grazing_query
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
    return nothing
end

advance_grazers_tick = System(ResMut(Tick)) do tick
    tick.tick += 1
    return nothing
end
