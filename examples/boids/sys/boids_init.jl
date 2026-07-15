struct BoidsInit
    count::Int
end

BoidsInit(;
    count::Int = 100,
) = BoidsInit(count)

initialize_boids = System(Res(WorldSize), Res(BoidsInit), Cmds((new_entities!, (Position, Velocity, Rotation, Neighbors, UpdateStep)))) do world_size, boids_init, cmds

    new_entities!(
        cmds, boids_init.count,
        (Position, Velocity, Rotation, Neighbors, UpdateStep),
    ) do (_, positions, velocities, rotations, neighbors, updates)
        for i in eachindex(positions, rotations)
            positions[i] = Position(Point2f(rand() * world_size.width, rand() * world_size.height))

            ang = rand() * 2 * π
            rotations[i] = Rotation(ang)
            velocities[i] = Velocity(rotation_to_direction(ang, 0.1))
            neighbors[i] = Neighbors()
            updates[i] = UpdateStep(rand(0:29))
        end
    end
end
