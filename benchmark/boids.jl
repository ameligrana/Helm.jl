# Run from the repository root with:
#   julia --threads=auto --project=examples benchmark/boids.jl
#
# BOIDS_COUNT, BOIDS_FRAMES, BOIDS_SAMPLES, and BOIDS_SEED can override the
# defaults printed by the benchmark.

using BenchmarkTools
using Printf

module OriginalBoidsBenchmark

using Ark
using GeometryBasics: Point2f
using Random

abstract type System end

function initialize!(::System, ::Ark.World)
    return nothing
end

function update!(::System, ::Ark.World)
    return nothing
end

include(joinpath(@__DIR__, "..", "examples", "boids-original", "util.jl"))
include(joinpath(@__DIR__, "..", "examples", "boids-original", "components.jl"))

struct WorldSize
    width::Int
    height::Int
end

mutable struct Mouse
    x::Float64
    y::Float64
    inside::Bool
end

mutable struct Tick
    tick::Int
end

struct Grid
    entities::Array{Vector{Ark.Entity},2}
    rows::Int
    cols::Int
    cell_size::Int
end

function Grid(width::Int, height::Int, max_distance::Int)
    rows = ceil(Int, height / max_distance)
    columns = ceil(Int, width / max_distance)
    entities = [Ark.Entity[] for _ in 1:rows, _ in 1:columns]
    return Grid(entities, rows, columns, max_distance)
end

function cell(grid::Grid, point::Point2f)
    row = floor(Int, point[2] / grid.cell_size) + 1
    column = floor(Int, point[1] / grid.cell_size) + 1
    return clamp(row, 1, grid.rows), clamp(column, 1, grid.cols)
end

include(joinpath(@__DIR__, "..", "examples", "boids-original", "sys", "boids_init.jl"))
include(joinpath(@__DIR__, "..", "examples", "boids-original", "sys", "boids_neighbors.jl"))
include(joinpath(@__DIR__, "..", "examples", "boids-original", "sys", "boids_movement.jl"))

struct BenchmarkCase{W,N,M}
    world::W
    neighbors::N
    movement::M
end

function make_case(boid_count::Int, seed::Int)
    Random.seed!(seed)
    world = Ark.World(
        Position,
        Velocity,
        Rotation,
        Neighbors,
        UpdateStep;
        allow_mutable=true,
    )
    size = WorldSize(1000, 700)
    Ark.add_resource!(world, size)
    Ark.add_resource!(world, Mouse(0.0, 0.0, false))
    Ark.add_resource!(world, Tick(0))

    neighbors = BoidsNeighbors(max_distance=18)
    movement = BoidsMovement(
        avoid_factor=0.1,
        avoid_distance=6.0,
        cohesion_factor=0.002,
        align_factor=0.005,
        min_speed=0.5,
        max_speed=1.0,
        margin=150.0,
        margin_factor=0.1,
        mouse_radius=200.0,
        mouse_avoid_factor=1.0,
    )

    initialize!(BoidsInit(count=boid_count), world)
    initialize!(neighbors, world)
    return BenchmarkCase(world, neighbors, movement)
end

function run_frames!(case::BenchmarkCase, frames::Int)
    tick = Ark.get_resource(case.world, Tick)
    for _ in 1:frames
        update!(case.neighbors, case.world)
        update!(case.movement, case.world)
        tick.tick += 1
    end
    return nothing
end

end

module HelmBoidsBenchmark

using Ark
using GeometryBasics: Point2f
import Helm
using Helm: Cmds, Const, Query, Res, ResMut, System
using Random

include(joinpath(@__DIR__, "..", "examples", "boids", "util.jl"))
include(joinpath(@__DIR__, "..", "examples", "boids", "components.jl"))

struct WorldSize
    width::Int
    height::Int
end

mutable struct Mouse
    x::Float64
    y::Float64
    inside::Bool
end

mutable struct Tick
    tick::Int
end

struct Grid
    entities::Array{Vector{Ark.Entity},2}
    rows::Int
    cols::Int
    cell_size::Int
end

function Grid(width::Int, height::Int, max_distance::Int)
    rows = ceil(Int, height / max_distance)
    columns = ceil(Int, width / max_distance)
    entities = [Ark.Entity[] for _ in 1:rows, _ in 1:columns]
    return Grid(entities, rows, columns, max_distance)
end

function cell(grid::Grid, point::Point2f)
    row = floor(Int, point[2] / grid.cell_size) + 1
    column = floor(Int, point[1] / grid.cell_size) + 1
    return clamp(row, 1, grid.rows), clamp(column, 1, grid.cols)
end

include(joinpath(@__DIR__, "..", "examples", "boids", "sys", "boids_init.jl"))
include(joinpath(@__DIR__, "..", "examples", "boids", "sys", "boids_neighbors.jl"))
include(joinpath(@__DIR__, "..", "examples", "boids", "sys", "boids_movement.jl"))

advance_tick = Helm.System(Helm.ResMut(Tick)) do tick
    tick.tick += 1
    return nothing
end

struct BenchmarkCase{W,S}
    world::W
    schedule::S
end

function make_case(boid_count::Int, seed::Int)
    Random.seed!(seed)
    world = Ark.World(
        Position,
        Velocity,
        Rotation,
        Neighbors,
        UpdateStep;
        allow_mutable=true,
    )
    size = WorldSize(1000, 700)
    Ark.add_resource!(world, size)
    Ark.add_resource!(world, Mouse(0.0, 0.0, false))
    Ark.add_resource!(world, Tick(0))
    Ark.add_resource!(world, BoidsInit(count=boid_count))
    Ark.add_resource!(world, BoidsNeighbors(max_distance=18))
    Ark.add_resource!(world, Grid(size.width, size.height, 18))
    Ark.add_resource!(
        world,
        BoidsMovement(
            avoid_factor=0.1,
            avoid_distance=6.0,
            cohesion_factor=0.002,
            align_factor=0.005,
            min_speed=0.5,
            max_speed=1.0,
            margin=150.0,
            margin_factor=0.1,
            mouse_radius=200.0,
            mouse_avoid_factor=1.0,
        ),
    )

    Helm.execute!(Helm.Schedule(initialize_boids), world)
    schedule = Helm.Schedule(
        Helm.chain(
            update_grid,
            update_neighbors,
            update_movement,
            update_rotations,
            advance_tick,
        ),
    )
    return BenchmarkCase(world, schedule)
end

function run_frames!(case::BenchmarkCase, frames::Int)
    for _ in 1:frames
        Helm.execute!(case.schedule, case.world)
    end
    return nothing
end

end

function positive_env_int(name::String, default::Int)
    value = parse(Int, get(ENV, name, string(default)))
    value > 0 || throw(ArgumentError("$name must be greater than zero"))
    return value
end

function benchmark_boids()
    boid_count = positive_env_int("BOIDS_COUNT", 1000)
    # Thirty frames cover one complete staggered neighbor-update cycle.
    frames = positive_env_int("BOIDS_FRAMES", 30)
    samples = positive_env_int("BOIDS_SAMPLES", 20)
    seed = parse(Int, get(ENV, "BOIDS_SEED", "1234"))

    # Compile both pipelines before BenchmarkTools starts collecting samples.
    OriginalBoidsBenchmark.run_frames!(
        OriginalBoidsBenchmark.make_case(boid_count, seed),
        1,
    )
    HelmBoidsBenchmark.run_frames!(HelmBoidsBenchmark.make_case(boid_count, seed), 1)

    println("Boids benchmark")
    println("  boids:  $boid_count")
    println("  frames per sample: $frames")
    println("  samples: $samples")
    println("  Julia threads: $(Threads.nthreads())")

    original = @benchmark OriginalBoidsBenchmark.run_frames!(case, $frames) setup = (
        case = OriginalBoidsBenchmark.make_case($boid_count, $seed)
    ) evals = 1 samples = samples

    helm = @benchmark HelmBoidsBenchmark.run_frames!(case, $frames) setup = (
        case = HelmBoidsBenchmark.make_case($boid_count, $seed)
    ) evals = 1 samples = samples

    original_ns = BenchmarkTools.median(original).time / frames
    helm_ns = BenchmarkTools.median(helm).time / frames

    println("\nboids-original")
    display(original)
    println("\nboids (Helm)")
    display(helm)
    println()
    @printf "Median per frame: original %.3f ms, Helm %.3f ms\n" original_ns / 1e6 helm_ns / 1e6
    @printf "Relative speed: %.3fx (original / Helm)\n" original_ns / helm_ns
    return (; original, helm)
end

benchmark_boids()
