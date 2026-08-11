using Test
using Ark
import Helm
using Random: rand

module HeadlessGrazersExample

using Ark
using Helm

include(joinpath(@__DIR__, "..", "examples", "grazers", "core.jl"))

end

const G = HeadlessGrazersExample

function grazer_rows(world)
    rows = NamedTuple[]
    for (entities, positions, rotations, energies, genes) in Ark.Query(
        world,
        (G.Position, G.Rotation, G.Energy, G.Genes),
    )
        for i in eachindex(entities)
            push!(rows, (
                entity=entities[i],
                position=positions[i],
                rotation=rotations[i],
                energy=energies[i],
                genes=genes[i],
            ))
        end
    end
    return rows
end

function test_genes(;
    max_angle=0.25,
    reverse_prob=0.1,
    move_thresh=0.5,
    graze_thresh=0.4,
    num_offspring=0.2,
    energy_share=0.4,
)
    return G.Genes(
        max_angle=Float64(max_angle),
        reverse_prob=Float64(reverse_prob),
        move_thresh=Float64(move_thresh),
        graze_thresh=Float64(graze_thresh),
        num_offspring=Float64(num_offspring),
        energy_share=Float64(energy_share),
    )
end

function marker_counts(world)
    moving = sum(
        (length(entities) for (entities,) in Ark.Query(world, (); with=(G.Moving,)));
        init=0,
    )
    grazing = sum(
        (length(entities) for (entities,) in Ark.Query(world, (); with=(G.Grazing,)));
        init=0,
    )
    return moving, grazing
end

function stage_contains(stage, system)
    return any(candidate -> candidate === system, stage)
end

@testset "Headless grazers Helm port" begin
    @testset "deterministic initialization" begin
        first = G.create_grazers_world(width=12, height=9, count=32, seed=123)
        second = G.create_grazers_world(width=12, height=9, count=32, seed=123)

        first_grid = Ark.get_resource(first, G.GrassGrid)
        @test size(first_grid.capacity) == (12, 9)
        @test first_grid.grass == first_grid.capacity
        @test all(0.01 .<= first_grid.capacity .<= 1.0)

        Helm.execute!(G.grazers_startup_schedule(), first)
        Helm.execute!(G.grazers_startup_schedule(), second)
        first_rows = grazer_rows(first)
        second_rows = grazer_rows(second)

        @test length(first_rows) == 32
        @test map(row -> row.position, first_rows) == map(row -> row.position, second_rows)
        @test map(row -> row.rotation, first_rows) == map(row -> row.rotation, second_rows)
        @test map(row -> row.energy, first_rows) == map(row -> row.energy, second_rows)
        @test map(row -> row.genes, first_rows) == map(row -> row.genes, second_rows)
        @test all(first_rows) do row
            position = row.position
            genes = row.genes
            return -0.01 <= position[1] < 12.0 &&
                   -0.01 <= position[2] < 9.0 &&
                   0.0 <= row.rotation < 2π &&
                   0.5 <= row.energy.value <= 1.0 &&
                   all(
                       0.0 <= value <= 1.0 for value in (
                           genes.max_angle,
                           genes.reverse_prob,
                           genes.move_thresh,
                           genes.graze_thresh,
                           genes.num_offspring,
                           genes.energy_share,
                       )
                   )
        end
        @test marker_counts(first) == (32, 0)
    end

    @testset "grass growth matches the logistic update" begin
        world = G.create_grazers_world(width=4, height=3, count=0)
        grid = Ark.get_resource(world, G.GrassGrid)
        settings = Ark.get_resource(world, G.GrassGrowth)
        grid.grass .= grid.capacity .* 0.35
        grid.grass[1, 1] = 0.0
        before = copy(grid.grass)
        expected = clamp.(
            before .+ settings.growth_rate .* before .* (1.0 .- before ./ grid.capacity),
            0.0,
            1.0,
        )

        G.grow_grass(world)

        @test grid.grass ≈ expected
        @test grid.grass[1, 1] == 0.0
    end

    @testset "movement matches the original formula and filters grazing entities" begin
        world = G.create_grazers_world(width=10, height=8, count=0, seed=77)
        moving_genes = test_genes(max_angle=0.6, reverse_prob=0.0)
        moving = Ark.new_entity!(
            world,
            (G.Position(2.5, 3.5), G.Rotation(0.4), G.Energy(0.8), moving_genes, G.Moving()),
        )
        grazing = Ark.new_entity!(
            world,
            (
                G.Position(6.0, 2.0),
                G.Rotation(1.2),
                G.Energy(0.7),
                test_genes(),
                G.Grazing(),
            ),
        )
        rng = copy(Ark.get_resource(world, G.SimulationRNG).rng)
        speed = Ark.get_resource(world, G.GrazerMovement).speed
        expected_rotation = mod(0.4 + (rand(rng) * 2.0 - 1.0) * moving_genes.max_angle * 0.5π, 2π)
        reverse_draw = rand(rng)
        reverse_draw * 10.0 < moving_genes.reverse_prob &&
            (expected_rotation = mod(expected_rotation + π, 2π))
        expected_position = G.Position(
            mod(2.5 + speed * cos(expected_rotation) + 10, 10 - 0.001),
            mod(3.5 + speed * sin(expected_rotation) + 8, 8 - 0.001),
        )

        G.move_grazers(world)

        moving_position, moving_rotation =
            Ark.get_components(world, moving, (G.Position, G.Rotation))
        grazing_position, grazing_rotation =
            Ark.get_components(world, grazing, (G.Position, G.Rotation))
        @test moving_rotation ≈ expected_rotation
        @test moving_position ≈ expected_position
        @test grazing_position == G.Position(6.0, 2.0)
        @test grazing_rotation == 1.2
    end

    @testset "feeding and metabolism preserve reference behavior" begin
        world = G.create_grazers_world(width=5, height=5, count=0)
        grid = Ark.get_resource(world, G.GrassGrid)
        feeding = Ark.get_resource(world, G.GrazerFeeding)
        metabolism = Ark.get_resource(world, G.GrazerMetabolism)
        grazing = Ark.new_entity!(
            world,
            (G.Position(1.2, 2.1), G.Rotation(0.0), G.Energy(0.6), test_genes(), G.Grazing()),
        )
        moving = Ark.new_entity!(
            world,
            (G.Position(3.2, 1.1), G.Rotation(0.0), G.Energy(0.6), test_genes(), G.Moving()),
        )
        grid.grass[2, 3] = 0.5

        G.feed_grazers(world)
        grazing_energy, = Ark.get_components(world, grazing, (G.Energy,))
        @test grid.grass[2, 3] ≈ 0.5 - feeding.max_grazing
        @test grazing_energy.value ≈ 0.6 + feeding.max_grazing * feeding.efficiency

        G.metabolize_grazers(world)
        grazing_energy, = Ark.get_components(world, grazing, (G.Energy,))
        moving_energy, = Ark.get_components(world, moving, (G.Energy,))
        @test grazing_energy.value ≈
              0.6 + feeding.max_grazing * feeding.efficiency - metabolism.base_rate
        @test moving_energy.value ≈ 0.6 - metabolism.move_rate
    end

    @testset "command-buffer lifecycle systems apply structural changes safely" begin
        world = G.create_grazers_world(width=6, height=6, count=0, seed=9)
        grid = Ark.get_resource(world, G.GrassGrid)
        grid.grass .= 0.0

        moving = Ark.new_entity!(
            world,
            (
                G.Position(1.2, 1.2),
                G.Rotation(0.0),
                G.Energy(0.5),
                test_genes(graze_thresh=0.4),
                G.Moving(),
            ),
        )
        grazing = Ark.new_entity!(
            world,
            (
                G.Position(3.2, 3.2),
                G.Rotation(0.0),
                G.Energy(0.5),
                test_genes(graze_thresh=0.8, move_thresh=0.5),
                G.Grazing(),
            ),
        )
        dead = Ark.new_entity!(
            world,
            (
                G.Position(4.2, 4.2),
                G.Rotation(0.0),
                G.Energy(0.0),
                test_genes(),
                G.Moving(),
            ),
        )
        grid.grass[2, 2] = 0.9

        G.decide_grazer_state(world)
        @test Ark.has_components(world, moving, (G.Grazing,))
        @test !Ark.has_components(world, moving, (G.Moving,))
        @test Ark.has_components(world, grazing, (G.Moving,))
        @test !Ark.has_components(world, grazing, (G.Grazing,))

        count_before_mortality = length(grazer_rows(world))
        G.remove_dead_grazers(world)
        rows_after_mortality = grazer_rows(world)
        @test length(rows_after_mortality) == count_before_mortality - 1
        @test !Ark.is_alive(world, dead)
        @test all(row -> row.entity != dead, rows_after_mortality)

        parent = Ark.new_entity!(
            world,
            (
                G.Position(2.2, 2.2),
                G.Rotation(0.0),
                G.Energy(1.0),
                test_genes(num_offspring=0.2, energy_share=0.4),
                G.Moving(),
            ),
        )
        before_count = length(grazer_rows(world))
        scratch = Ark.get_resource(world, G.ReproductionScratch)
        mates = scratch.mates
        batches = scratch.batches
        G.reproduce_grazers(world)
        after_rows = grazer_rows(world)
        parent_energy, = Ark.get_components(world, parent, (G.Energy,))
        @test Ark.get_resource(world, G.ReproductionScratch) === scratch
        @test scratch.mates === mates
        @test scratch.batches === batches
        @test !isempty(scratch.mates)
        @test !isempty(scratch.batches)
        @test length(after_rows) == before_count + 2
        @test parent_energy.value ≈ 0.6
        @test count(row -> row.entity != parent && row.energy.value ≈ 0.2, after_rows) >= 2
        @test all(after_rows) do row
            genes = row.genes
            all(
                0.0 <= value <= 1.0 for value in (
                    genes.max_angle,
                    genes.reverse_prob,
                    genes.move_thresh,
                    genes.graze_thresh,
                    genes.num_offspring,
                    genes.energy_share,
                )
            )
        end

        G.reproduce_grazers(world)
        @test scratch.mates === mates
        @test scratch.batches === batches
        @test length(scratch.mates) == length(after_rows)
        @test isempty(scratch.batches)
    end

    @testset "update schedule exposes real system-level parallelism" begin
        stages = Helm.get_execution_order(G.grazers_update_schedule())
        @test map(length, stages) == [2, 1, 1, 1, 1, 1, 1]
        @test stage_contains(stages[1], G.grow_grass)
        @test stage_contains(stages[1], G.move_grazers)
        @test stage_contains(stages[2], G.feed_grazers)
        @test stage_contains(stages[3], G.reproduce_grazers)
        @test stage_contains(stages[4], G.metabolize_grazers)
        @test stage_contains(stages[5], G.remove_dead_grazers)
        @test stage_contains(stages[6], G.decide_grazer_state)
        @test stage_contains(stages[7], G.advance_grazers_tick)
    end

    @testset "multi-frame threaded smoke run" begin
        world = G.create_grazers_world(width=16, height=12, count=24, seed=2026)
        Helm.execute!(G.grazers_startup_schedule(), world)
        schedule = G.grazers_update_schedule()
        for _ in 1:5
            Helm.execute!(schedule, world)
        end

        rows = grazer_rows(world)
        size = Ark.get_resource(world, G.WorldSize)
        moving, grazing = marker_counts(world)
        @test Ark.get_resource(world, G.Tick).tick == 5
        @test !isempty(rows)
        @test moving + grazing == length(rows)
        @test all(rows) do row
            0.0 <= row.position[1] < size.width &&
                0.0 <= row.position[2] < size.height &&
                0.0 <= row.rotation < 2π &&
                0.0 <= row.energy.value <= 1.0
        end
    end
end
