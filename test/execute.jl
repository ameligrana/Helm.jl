module ExecuteTests

using Test
using Ark
using Helm

mutable struct ExecutionResource
    value::Int
end

struct ExecutionComponent
    value::Int
end

struct TestCommand
    entity::Ark.Entity
    value::Int
end

function Ark.apply!(world::Ark.World, command::TestCommand)
    Ark.set_components!(world, command.entity, (ExecutionComponent(command.value),))
    return nothing
end

@testset "Schedule execution" begin
    @testset "empty schedules and return values" begin
        world = Ark.World()
        @test execute!(Schedule(), world) === nothing

        calls = Threads.Atomic{Int}(0)
        returns_value = System() do
            Threads.atomic_add!(calls, 1)
            return 42
        end

        @test execute!(Schedule(returns_value), world) === nothing
        @test calls[] == 1
    end

    @testset "each system runs once" begin
        world = Ark.World()
        calls = Threads.Atomic{Int}(0)
        systems = ntuple(4) do system_id
            System() do
                Threads.atomic_add!(calls, 1)
                system_id # Give each system a distinct captured value.
                return nothing
            end
        end

        execute!(Schedule(systems...), world)
        @test calls[] == length(systems)
    end

    @testset "dependency order and stage barriers" begin
        world = Ark.World()
        completed = Threads.Atomic{Int}(0)
        final_observation = Threads.Atomic{Int}(-1)

        first = System() do
            Threads.atomic_add!(completed, 1)
            return nothing
        end
        second = System() do
            Threads.atomic_add!(completed, 1)
            return nothing
        end
        final = System() do
            final_observation[] = completed[]
            return nothing
        end

        schedule = Schedule(before(first, final), before(second, final))
        @test length(get_execution_order(schedule)) == 2
        execute!(schedule, world)

        @test completed[] == 2
        @test final_observation[] == 2

        order = Int[]
        ordered_first = System(() -> push!(order, 1))
        ordered_second = System(() -> push!(order, 2))
        execute!(Schedule(chain(ordered_first, ordered_second)), world)
        @test order == [1, 2]
    end

    @testset "independent systems overlap on multithreaded runtimes" begin
        if Threads.nthreads() == 1
            @test true # The single-threaded inline path is covered by the other tests.
        else
            world = Ark.World()
            started = Threads.Atomic{Int}(0)
            overlap_observed = Threads.Atomic{Int}(0)

            function overlapping_system()
                Threads.atomic_add!(started, 1)
                status = timedwait(() -> started[] == 2, 5.0; pollint=0.001)
                if status === :ok
                    overlap_observed[] = 1
                end
                status === :ok || error("independent systems did not overlap")
                return nothing
            end

            first = System(() -> overlapping_system())
            second = System(() -> overlapping_system())
            schedule = Schedule(first, second)
            @test length(only(get_execution_order(schedule))) == 2

            execute!(schedule, world)
            @test overlap_observed[] == 1
            @test started[] == 2
        end
    end

    @testset "conflicting mutable access is serialized" begin
        world = Ark.World()
        Ark.add_resource!(world, ExecutionResource(0))
        active = Threads.Atomic{Int}(0)
        concurrent_access = Threads.Atomic{Int}(0)

        function mutate_resource(resource)
            previously_active = Threads.atomic_add!(active, 1)
            previously_active == 0 || (concurrent_access[] = 1)
            yield()
            resource.value += 1
            Threads.atomic_add!(active, -1)
            return nothing
        end

        first = System(resource -> mutate_resource(resource), ResMut(ExecutionResource))
        second = System(resource -> mutate_resource(resource), ResMut(ExecutionResource))
        schedule = Schedule(first, second)
        @test map(length, get_execution_order(schedule)) == [1, 1]

        execute!(schedule, world)
        @test Ark.get_resource(world, ExecutionResource).value == 2
        @test concurrent_access[] == 0
    end

    @testset "command-buffer systems are serialized" begin
        world = Ark.World(ExecutionComponent)
        commands = Cmds((Ark.NewEntityCommand((ExecutionComponent,)),))
        create_first = System(commands) do buffer
            Ark.new_entity!(buffer, (ExecutionComponent(1),))
            return nothing
        end
        create_second = System(commands) do buffer
            Ark.new_entity!(buffer, (ExecutionComponent(2),))
            return nothing
        end
        query_ran = Threads.Atomic{Int}(0)
        query_system = System(Helm.Query((Helm.Const(ExecutionComponent),))) do query
            query_ran[] = 1
            Ark.close!(query)
            return nothing
        end

        schedule = Schedule(create_first, query_system, create_second)
        @test map(length, get_execution_order(schedule)) == [1, 1, 1]
        execute!(schedule, world)

        entity_count = sum(
            length(entities)
            for (entities, _) in Ark.Query(world, (ExecutionComponent,))
        )
        @test entity_count == 2
        @test query_ran[] == 1
    end

    @testset "command buffers accept Ark specs and record! arbitrary commands" begin
        world = Ark.World(ExecutionComponent)
        commands = Cmds((
            Ark.NewEntityCommand((ExecutionComponent,)),
            TestCommand,
        ))
        spawn_and_record = System(commands) do buffer
            entity = Ark.new_entity!(buffer, (ExecutionComponent(0),))
            Ark.record!(buffer, TestCommand(entity, 7))
            return nothing
        end

        execute!(Schedule(spawn_and_record), world)

        entity_count = sum(
            length(entities)
            for (entities, _) in Ark.Query(world, (ExecutionComponent,))
        )
        total_value = sum(
            values[1].value
            for (_, values) in Ark.Query(world, (ExecutionComponent,))
        )
        @test entity_count == 1
        @test total_value == 7
    end

    @testset "errors stop later stages" begin
        world = Ark.World()
        later_ran = Threads.Atomic{Int}(0)
        failure = System(() -> error("expected execute! failure"))
        later = System(() -> (later_ran[] = 1))

        @test_throws ErrorException execute!(Schedule(chain(failure, later)), world)
        @test later_ran[] == 0
    end

    @testset "parallel-stage errors join siblings" begin
        if Threads.nthreads() == 1
            @test true
        else
            world = Ark.World()
            sibling_finished = Threads.Atomic{Int}(0)
            later_ran = Threads.Atomic{Int}(0)
            failure = System(() -> error("expected parallel failure"))
            sibling = System() do
                yield()
                sibling_finished[] = 1
                return nothing
            end
            later = System(() -> (later_ran[] = 1))
            schedule = Schedule(before(failure, later), before(sibling, later))

            @test_throws CompositeException execute!(schedule, world)
            @test sibling_finished[] == 1
            @test later_ran[] == 0
        end
    end
end

end
