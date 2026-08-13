struct BoidsInit
    count::Int
end

BoidsInit(; count::Int=100) = BoidsInit(count)

const BOID_COMPONENTS = (Position, Velocity, Rotation, Neighbors, UpdateStep)

initialize_boids = System(
    Res(WorldSize),
    Res(BoidsInit),
    Cmds((NewEntityCommand(BOID_COMPONENTS),)),
) do world_size, settings, commands
    for _ in 1:settings.count
        angle = rand() * 2π
        dx, dy = rotation_to_direction(angle, 0.1)
        new_entity!(
            commands,
            (
                Position(Point2f(rand() * world_size.width, rand() * world_size.height)),
                Velocity(Point2f(dx, dy)),
                Rotation(angle),
                Neighbors(),
                UpdateStep(rand(0:29)),
            ),
        )
    end
    return nothing
end
