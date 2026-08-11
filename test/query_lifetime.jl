module QueryLifetimeTests

using Test
using Ark
using Helm

struct LifetimeComponent
    value::Int
end

struct MissingLifetimeResource end

const LIFETIME_QUERY = Helm.Query((Helm.Const(LifetimeComponent),))

function populated_world()
    world = Ark.World(LifetimeComponent)
    Ark.new_entity!(world, (LifetimeComponent(1),))
    return world
end

function entity_count(world)
    return sum(
        length(entities)
        for (entities, _) in Ark.Query(world, (LifetimeComponent,))
    )
end

function consume_query(query)
    count = 0
    for (entities, _) in query
        count += length(entities)
    end
    return count
end

function consume_directly(world)
    return consume_query(Ark.Query(world, LIFETIME_QUERY))
end

function elapsed_ns(f, world, repetitions)
    started = time_ns()
    for _ in 1:repetitions
        f(world)
    end
    return time_ns() - started
end

@testset "System query lifetime" begin
    @testset "ignored query is closed" begin
        world = populated_world()
        system = System(_query -> nothing, LIFETIME_QUERY)

        @test system(world) === nothing
        @test !Ark.is_locked(world)
    end

    @testset "partially iterated query is closed" begin
        world = populated_world()
        saw_batch = Ref(false)
        system = System(LIFETIME_QUERY) do query
            saw_batch[] = iterate(query) !== nothing
            return nothing
        end

        @test system(world) === nothing
        @test saw_batch[]
        @test !Ark.is_locked(world)
    end

    @testset "callback exception closes query" begin
        world = populated_world()
        system = System(LIFETIME_QUERY) do _query
            error("expected query callback failure")
        end

        @test_throws ErrorException system(world)
        @test !Ark.is_locked(world)
    end

    @testset "later argument acquisition failure closes earlier query" begin
        world = populated_world()
        system = System(LIFETIME_QUERY, Res(MissingLifetimeResource)) do _query, _resource
            error("callback must not run")
        end

        @test_throws KeyError system(world)
        @test !Ark.is_locked(world)
    end

    @testset "multiple ignored queries are all closed" begin
        world = populated_world()
        system = System(LIFETIME_QUERY, LIFETIME_QUERY) do _first, _second
            return nothing
        end

        @test system(world) === nothing
        @test !Ark.is_locked(world)
    end

    @testset "queries close before command buffers are applied" begin
        world = populated_world()
        commands = Cmds(((Ark.new_entity!, (LifetimeComponent,)),))
        system = System(LIFETIME_QUERY, commands) do _query, command_buffer
            Ark.new_entity!(command_buffer, (LifetimeComponent(2),))
            return nothing
        end

        @test system(world) === nothing
        @test !Ark.is_locked(world)
        @test entity_count(world) == 2
    end

    @testset "fully iterated query tolerates scoped close" begin
        world = populated_world()
        system = System(consume_query, LIFETIME_QUERY)

        @test system(world) == 1
        @test !Ark.is_locked(world)
        @test system(world) == 1
        @test !Ark.is_locked(world)
    end

    @testset "warm query lifecycle overhead remains bounded" begin
        world = populated_world()
        system = System(consume_query, LIFETIME_QUERY)

        # Compile both paths and stabilize one-time caches before measuring.
        for _ in 1:20
            consume_directly(world)
            system(world)
        end

        direct_allocations = minimum(@allocated(consume_directly(world)) for _ in 1:10)
        system_allocations = minimum(@allocated(system(world)) for _ in 1:10)

        repetitions = 2_000
        direct_times = [elapsed_ns(consume_directly, world, repetitions) for _ in 1:5]
        system_times = [elapsed_ns(system, world, repetitions) for _ in 1:5]
        direct_time = minimum(direct_times)
        system_time = minimum(system_times)

        # The absolute headroom keeps this robust when the baseline is tiny, while
        # the ratio still catches accidental allocation or dispatch regressions.
        @test system_allocations <= direct_allocations + 256
        @test system_time <= 5 * direct_time + 100_000
        @test !Ark.is_locked(world)
    end
end

end
