using Test
using Ark
import Helm

module HeadlessBoidsExample

using Ark
using Helm: Cmds, Const, Query, Res, ResMut, System

# Ark already depends on StaticArrays. Reusing it here keeps this test headless
# without adding GeometryBasics to Helm's package dependencies.
const Point2f = Ark.StaticArrays.SVector{2,Float32}

include(joinpath(@__DIR__, "..", "examples", "boids", "components.jl"))
include(joinpath(@__DIR__, "..", "examples", "boids", "util.jl"))

struct WorldSize
    width::Int
    height::Int
end

mutable struct Mouse
    x::Float64
    y::Float64
    inside::Bool
end

struct Grid
    entities::Array{Vector{Entity},2}
    rows::Int
    cols::Int
    cell_size::Int
end

function Grid(width::Int, height::Int, max_distance::Int)
    rows = ceil(Int, height / max_distance)
    cols = ceil(Int, width / max_distance)
    entities = [Entity[] for _ in 1:rows, _ in 1:cols]
    return Grid(entities, rows, cols, max_distance)
end

function cell(grid::Grid, point::Point2f)
    row = floor(Int, point[2] / grid.cell_size) + 1
    column = floor(Int, point[1] / grid.cell_size) + 1
    return clamp(row, 1, grid.rows), clamp(column, 1, grid.cols)
end

struct Tick
    tick::Int
end

include(joinpath(@__DIR__, "..", "examples", "boids", "sys", "boids_init.jl"))
include(joinpath(@__DIR__, "..", "examples", "boids", "sys", "boids_neighbors.jl"))
include(joinpath(@__DIR__, "..", "examples", "boids", "sys", "boids_movement.jl"))

end

const B = HeadlessBoidsExample

function entity_components(world, component_types)
    result = Dict{Ark.Entity,Any}()
    for (entities, columns...) in Ark.Query(world, component_types)
        for i in eachindex(entities)
            result[entities[i]] = tuple((column[i] for column in columns)...)
        end
    end
    return result
end

function reference_velocity(position, velocity, neighbors, settings, size, mouse)
    avoid_distance_sq = settings.avoid_distance^2
    close_x, close_y = 0.0, 0.0
    average_x, average_y = 0.0, 0.0
    average_vx, average_vy = 0.0, 0.0

    for (other_position, other_velocity) in neighbors
        if B.distance_sq(position, other_position) <= avoid_distance_sq
            close_x += position[1] - other_position[1]
            close_y += position[2] - other_position[2]
        end
        average_x += other_position[1]
        average_y += other_position[2]
        average_vx += other_velocity[1]
        average_vy += other_velocity[2]
    end

    vx, vy = velocity[1], velocity[2]
    if !isempty(neighbors)
        average_x /= length(neighbors)
        average_y /= length(neighbors)
        average_vx /= length(neighbors)
        average_vy /= length(neighbors)
        close_x, close_y = B.normalize(close_x, close_y)

        vx += close_x * settings.avoid_factor +
              (average_vx - velocity[1]) * settings.align_factor +
              (average_x - position[1]) * settings.cohesion_factor
        # This deliberately preserves the reference example's vel[1] quirk.
        vy += close_y * settings.avoid_factor +
              (average_vy - velocity[1]) * settings.align_factor +
              (average_y - position[2]) * settings.cohesion_factor
    end

    if mouse.inside
        distance_sq = B.distance_sq(B.Point2f(mouse.x, mouse.y), position)
        if distance_sq < settings.mouse_radius^2
            factor = 1 - sqrt(distance_sq) / settings.mouse_radius
            dx, dy = B.normalize(position[1] - mouse.x, position[2] - mouse.y)
            # The old implementation uses avoid_factor, not mouse_avoid_factor.
            vx += dx * settings.avoid_factor * factor
            vy += dy * settings.avoid_factor * factor
        end
    end

    if position[1] < settings.margin
        factor = 1 - position[1] / settings.margin
        vx += settings.margin_factor * factor^2
    elseif position[1] > size.width - settings.margin
        factor = 1 - (size.width - position[1]) / settings.margin
        vx -= settings.margin_factor * factor^2
    end
    if position[2] < settings.margin
        factor = 1 - position[2] / settings.margin
        vy += settings.margin_factor * factor^2
    elseif position[2] > size.height - settings.margin
        factor = 1 - (size.height - position[2]) / settings.margin
        vy -= settings.margin_factor * factor^2
    end

    speed = sqrt(vx^2 + vy^2)
    if speed < settings.min_speed
        vx = vx / speed * settings.min_speed
        vy = vy / speed * settings.min_speed
    elseif speed > settings.max_speed
        vx = vx / speed * settings.max_speed
        vy = vy / speed * settings.max_speed
    end
    return B.Point2f(vx, vy)
end

function movement_settings(; avoid_factor=0.2, mouse_avoid_factor=9.0)
    return B.BoidsMovement(
        avoid_factor=avoid_factor,
        avoid_distance=6.0,
        align_factor=0.1,
        cohesion_factor=0.01,
        min_speed=0.0,
        max_speed=100.0,
        margin=0.0,
        margin_factor=0.0,
        mouse_radius=20.0,
        mouse_avoid_factor=mouse_avoid_factor,
    )
end

function add_simulation_resources!(world; tick=0, max_distance=5, mouse=B.Mouse(0.0, 0.0, false))
    size = B.WorldSize(100, 100)
    Ark.add_resource!(world, size)
    Ark.add_resource!(world, B.BoidsNeighbors(max_distance=max_distance))
    Ark.add_resource!(world, B.Grid(size.width, size.height, max_distance))
    Ark.add_resource!(world, B.Tick(tick))
    Ark.add_resource!(world, movement_settings())
    Ark.add_resource!(world, mouse)
    return world
end

@testset "Headless boids Helm rewrite" begin
    @testset "command-buffer initialization" begin
        world = Ark.World(B.Position, B.Velocity, B.Rotation, B.Neighbors, B.UpdateStep; allow_mutable=true)
        Ark.add_resource!(world, B.WorldSize(100, 80))
        Ark.add_resource!(world, B.BoidsInit(count=4))

        finish_startup = Helm.System(Helm.Res(B.WorldSize)) do _
            return nothing
        end
        startup = Helm.Schedule(Helm.chain(B.initialize_boids, finish_startup))
        for stage in Helm.get_execution_order(startup), system in stage
            system(world)
        end

        count = sum(
            length(entities)
            for (entities, _...) in Ark.Query(
                world,
                (B.Position, B.Velocity, B.Rotation, B.Neighbors, B.UpdateStep),
            )
        )
        @test count == 4
    end

    @testset "query-scoped random access honors permissions" begin
        world = Ark.World(B.Position, B.Velocity, B.Neighbors, B.UpdateStep; allow_mutable=true)
        entity = Ark.new_entity!(world, (
            B.Position(B.Point2f(1, 2)),
            B.Velocity(B.Point2f(3, 4)),
            B.Neighbors(),
            B.UpdateStep(0),
        ))

        query = Ark.Query(world, (B.Position, B.Velocity, Ark.Const(B.UpdateStep)))
        @test Ark.has_components(query, entity, (B.Position, B.Velocity))
        @test Ark.get_components(query, entity, (B.Position, B.Velocity)) == (
            B.Position(B.Point2f(1, 2)),
            B.Velocity(B.Point2f(3, 4)),
        )
        @test Ark.set_components!(query, entity, (B.Position(B.Point2f(4, 6)),)) ==
              (B.Position(B.Point2f(4, 6)),)
        @test_throws ArgumentError Ark.set_components!(query, entity, (B.UpdateStep(1),))
        Ark.close!(query)
    end

    @testset "grid population and staggered neighbor selection" begin
        world = Ark.World(B.Position, B.Velocity, B.Rotation, B.Neighbors, B.UpdateStep; allow_mutable=true)
        add_simulation_resources!(world; tick=7, max_distance=5)

        first = Ark.new_entity!(world, (
            B.Position(B.Point2f(10, 10)), B.Velocity(B.Point2f(1, 0)),
            B.Rotation(0.0), B.Neighbors(), B.UpdateStep(7),
        ))
        staggered = Ark.new_entity!(world, (
            B.Position(B.Point2f(13, 14)), B.Velocity(B.Point2f(0, 2)),
            B.Rotation(0.0), B.Neighbors([first]), B.UpdateStep(8),
        ))
        distant = Ark.new_entity!(world, (
            B.Position(B.Point2f(80, 80)), B.Velocity(B.Point2f(-1, 0)),
            B.Rotation(0.0), B.Neighbors(), B.UpdateStep(7),
        ))

        B.update_grid(world)
        grid = Ark.get_resource(world, B.Grid)
        @test B.cell(grid, B.Point2f(10, 10)) == B.cell(grid, B.Point2f(13, 14))
        @test grid.entities[B.cell(grid, B.Point2f(10, 10))...] == [first, staggered]
        @test grid.entities[B.cell(grid, B.Point2f(80, 80))...] == [distant]

        B.update_neighbors(world)
        values = entity_components(world, (B.Neighbors,))
        @test values[first][1].n == [staggered]
        @test values[distant][1].n == Ark.Entity[]
        @test values[staggered][1].n == [first] # not this tick: preserve old value
    end

    @testset "movement matches reference quirks" begin
        world = Ark.World(B.Position, B.Velocity, B.Rotation, B.Neighbors, B.UpdateStep; allow_mutable=true)
        add_simulation_resources!(world)
        first = Ark.new_entity!(world, (
            B.Position(B.Point2f(10, 10)), B.Velocity(B.Point2f(1, 0)),
            B.Rotation(0.0), B.Neighbors(), B.UpdateStep(0),
        ))
        second = Ark.new_entity!(world, (
            B.Position(B.Point2f(13, 14)), B.Velocity(B.Point2f(0, 2)),
            B.Rotation(0.0), B.Neighbors(), B.UpdateStep(0),
        ))
        Ark.set_components!(world, first, (B.Neighbors([second]),))

        settings = Ark.get_resource(world, B.BoidsMovement)
        expected_velocity = reference_velocity(
            B.Point2f(10, 10), B.Point2f(1, 0),
            [(B.Point2f(13, 14), B.Point2f(0, 2))], settings,
            Ark.get_resource(world, B.WorldSize), Ark.get_resource(world, B.Mouse),
        )
        B.update_movement(world)
        position, velocity = Ark.get_components(world, first, (B.Position, B.Velocity))
        @test velocity.v[1] ≈ expected_velocity[1]
        @test velocity.v[2] ≈ expected_velocity[2]
        @test position.p[1] ≈ 10 + expected_velocity[1]
        @test position.p[2] ≈ 10 + expected_velocity[2]
        @test expected_velocity[2] ≈ -0.02 # locks in Y alignment against vel[1]
    end

    @testset "mouse avoidance retains avoid_factor" begin
        world = Ark.World(B.Position, B.Velocity, B.Rotation, B.Neighbors, B.UpdateStep; allow_mutable=true)
        add_simulation_resources!(world; mouse=B.Mouse(0.0, 10.0, true))
        entity = Ark.new_entity!(world, (
            B.Position(B.Point2f(10, 10)), B.Velocity(B.Point2f(1, 0)),
            B.Rotation(0.0), B.Neighbors(), B.UpdateStep(0),
        ))
        B.update_movement(world)
        velocity, = Ark.get_components(world, entity, (B.Velocity,))
        @test velocity.v[1] ≈ 1.1
        @test velocity.v[2] ≈ 0.0
    end

    @testset "rotation and Helm schedule execution order" begin
        world = Ark.World(B.Position, B.Velocity, B.Rotation, B.Neighbors, B.UpdateStep; allow_mutable=true)
        add_simulation_resources!(world; tick=7)
        entity = Ark.new_entity!(world, (
            B.Position(B.Point2f(20, 20)), B.Velocity(B.Point2f(0, 2)),
            B.Rotation(0.0), B.Neighbors(), B.UpdateStep(7),
        ))

        schedule = Helm.Schedule(Helm.chain(B.update_grid, B.update_neighbors, B.update_movement, B.update_rotations))
        stages = Helm.get_execution_order(schedule)
        @test map(only, stages) == [B.update_grid, B.update_neighbors, B.update_movement, B.update_rotations]
        for stage in stages, system in stage
            system(world)
        end

        position, velocity, rotation = Ark.get_components(world, entity, (B.Position, B.Velocity, B.Rotation))
        @test position.p == B.Point2f(20, 22)
        @test velocity.v == B.Point2f(0, 2)
        @test rotation.r ≈ pi / 2
    end
end
