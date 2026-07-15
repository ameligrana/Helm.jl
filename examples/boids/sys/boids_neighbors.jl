struct BoidsNeighbors <: System
    max_distance::Int
end

BoidsNeighbors(;
    max_distance::Int,
) = BoidsNeighbors(max_distance)

initialize_grid = System(Res(WorldSize), Res(BoidsNeighbors), Cmds) do size, s, cmds
    add_resource!(cmds, Grid(size.width, size.height, s.max_distance))
end

update_grid = System(ResMut(Grid), Query((Position,))) do grid, q
    grid = get_resource(world, Grid)

    for i in 1:grid.rows, j in 1:grid.cols
        resize!(grid.entities[i, j], 0)
    end

    for (entities, positions) in q
        for i in eachindex(entities, positions)
            row, col = cell(grid, positions[i].p)
            push!(grid.entities[row, col], entities[i])
        end
    end
end

update_neighbors = System(Res(Tick), Res(BoidsNeighbors), Query((Position, Mut(Neighbors), UpdateStep))) do ticks, s, q


    tick = ticks.tick
    max_dist_sq = Float64(s.max_distance * s.max_distance)

    for (entities1, positions1, neighbors, updates) in q
        for i in eachindex(positions1, neighbors, updates)
            if tick % 30 != updates[i].step
                continue
            end
            pos1 = positions1[i]
            entity1 = entities1[i]
            neigh = neighbors[i]
            resize!(neigh.n, 0)

            row, col = cell(grid, pos1.p)

            for r in max(row - 1, 1):min(row + 1, grid.rows), c in max(col - 1, 1):min(col + 1, grid.cols)
                candidates = grid.entities[r, c]
                for entity2 in candidates
                    if entity1 == entity2
                        continue
                    end
                    pos2, = get_components(world, entity2, (Position,))
                    if distance_sq(pos1.p, pos2.p) <= max_dist_sq
                        push!(neigh.n, entity2)
                    end
                end
            end
        end
    end
    return
end
