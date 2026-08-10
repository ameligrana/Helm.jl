struct BoidsNeighbors
    max_distance::Int
end

BoidsNeighbors(; max_distance::Int) = BoidsNeighbors(max_distance)

update_grid = System(ResMut(Grid), Query((Const(Position),))) do grid, query
    for row in axes(grid.entities, 1), column in axes(grid.entities, 2)
        empty!(grid.entities[row, column])
    end

    for (entities, positions) in query
        for i in eachindex(entities, positions)
            row, column = cell(grid, positions[i].p)
            push!(grid.entities[row, column], entities[i])
        end
    end
    return nothing
end

update_neighbors = System(
    Res(Tick),
    Res(Grid),
    Res(BoidsNeighbors),
    Query((Const(Position), Neighbors, Const(UpdateStep))),
) do ticks, grid, settings, query
    tick = ticks.tick
    max_distance_sq = Float64(settings.max_distance * settings.max_distance)

    for (entities, positions, neighbors, updates) in query
        for i in eachindex(entities, positions, neighbors, updates)
            tick % 30 == updates[i].step || continue

            entity = entities[i]
            position = positions[i]
            neighbor_entities = neighbors[i].n
            empty!(neighbor_entities)
            row, column = cell(grid, position.p)

            for candidate_row in max(row - 1, 1):min(row + 1, grid.rows)
                for candidate_column in max(column - 1, 1):min(column + 1, grid.cols)
                    for candidate in grid.entities[candidate_row, candidate_column]
                        candidate == entity && continue
                        has_components(query, candidate, (Position,)) || continue
                        candidate_position, = get_components(query, candidate, (Position,))
                        if distance_sq(position.p, candidate_position.p) <= max_distance_sq
                            push!(neighbor_entities, candidate)
                        end
                    end
                end
            end
        end
    end
    return nothing
end
