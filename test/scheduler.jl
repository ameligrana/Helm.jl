module SchedulerTests

using Test
using Ark
using Helm

struct CallableSystem
    calls::Base.RefValue{Int}
end

function (callable::CallableSystem)()
    callable.calls[] += 1
    return nothing
end

mutable struct SchedulerState
    value::Int
end

mutable struct SharedAccessIdentity
    value::Int
end

function serial_scheduler(; startup=Schedule(; name=:startup),
                            update=Schedule(; name=:update),
                            fixed_update=Schedule(; name=:fixed_update),
                            shutdown=Schedule(; name=:shutdown),
                            phases=NamedTuple())
    return Scheduler(
        startup=startup,
        update=update,
        fixed_update=fixed_update,
        shutdown=shutdown,
        phases=phases,
        executor=SerialExecutor(),
    )
end

@testset "Scheduler" begin
    @testset "callable structs and metadata" begin
        calls = Ref(0)
        callable = CallableSystem(calls)
        system = System(callable; name=:callable, priority=7)
        schedule = Schedule(system; name=:callables)

        @test execute!(SerialExecutor(), schedule, Ark.World()) === nothing
        @test calls[] == 1
    end

    @testset "named lifecycle phases" begin
        events = Symbol[]
        startup = System(() -> push!(events, :startup); name=:initialize)
        update = System(() -> push!(events, :update); name=:advance)
        fixed = System(() -> push!(events, :fixed); name=:physics)
        shutdown = System(() -> push!(events, :shutdown); name=:cleanup)
        scheduler = serial_scheduler(
            startup=Schedule(startup; name=:startup),
            update=Schedule(update; name=:update),
            fixed_update=Schedule(fixed; name=:fixed_update),
            shutdown=Schedule(shutdown; name=:shutdown),
        )
        world = Ark.World()

        @test startup!(scheduler, world) === nothing
        @test update!(scheduler, world) === nothing
        @test fixed_update!(scheduler, world) === nothing
        @test shutdown!(scheduler, world) === nothing
        @test events == [:startup, :update, :fixed, :shutdown]
    end

    @testset "custom phase Val and Symbol dispatch" begin
        calls = Ref(0)
        render = System(() -> (calls[] += 1); name=:render_system)
        scheduler = serial_scheduler(
            phases=(render=Schedule(render; name=:render),),
        )
        world = Ark.World()

        @test execute!(scheduler, Val(:render), world) === nothing
        @test execute!(scheduler, :render, world) === nothing
        @test calls[] == 2
        @test_throws Exception execute!(scheduler, :missing, world)
    end

    @testset "priority is only a ready-node tie breaker" begin
        order = Symbol[]
        low = System(() -> push!(order, :low); name=:low, priority=-10)
        normal = System(() -> push!(order, :normal); name=:normal)
        high = System(() -> push!(order, :high); name=:high, priority=10)

        execute!(SerialExecutor(), Schedule(low, high, normal), Ark.World())
        @test order == [:high, :normal, :low]

        empty!(order)
        # Dependencies win even when a successor has the highest priority.
        execute!(
            SerialExecutor(),
            Schedule(before(low, high), normal),
            Ark.World(),
        )
        @test findfirst(==(:low), order) < findfirst(==(:high), order)
    end

    @testset "conditions and enable flags" begin
        world = Ark.World()
        Ark.add_resource!(world, SchedulerState(0))
        calls = Ref(0)
        condition = Helm.Condition(Res(SchedulerState)) do state
            state.value > 0
        end
        conditional = System(() -> (calls[] += 1); name=:conditional, run_if=condition)
        scheduler = serial_scheduler(update=Schedule(conditional; name=:update))

        update!(scheduler, world)
        @test calls[] == 0

        Ark.get_resource(world, SchedulerState).value = 1
        update!(scheduler, world)
        @test calls[] == 1

        disable!(scheduler, :update, :conditional)
        update!(scheduler, world)
        @test calls[] == 1

        enable!(scheduler, :update, :conditional)
        update!(scheduler, world)
        @test calls[] == 2

        initially_disabled = System(() -> (calls[] += 1);
                                    name=:initially_disabled,
                                    enabled=false)
        disabled_schedule = Schedule(initially_disabled; name=:disabled)
        disabled_scheduler = serial_scheduler(update=disabled_schedule)
        execute!(SerialExecutor(), disabled_schedule, world)
        @test calls[] == 2
        enable!(disabled_scheduler, :update, :initially_disabled)
        execute!(SerialExecutor(), disabled_schedule, world)
        @test calls[] == 3
    end

    @testset "condition accesses participate in conflicts" begin
        predicate = Helm.Condition(_state -> true, Res(SchedulerState))
        conditional = System(() -> nothing;
                             name=:conditional_reader,
                             run_if=predicate)
        writer = System(_state -> nothing, ResMut(SchedulerState); name=:writer)
        schedule = Schedule(writer, conditional; name=:condition_conflict)

        @test map(length, get_execution_order(schedule)) == [1, 1]
    end

    @testset "component and resource access keys are distinct" begin
        component_writer = System(
            _query -> nothing,
            Helm.Query((SharedAccessIdentity,));
            name=:component_writer,
        )
        resource_writer = System(
            _resource -> nothing,
            ResMut(SharedAccessIdentity);
            name=:resource_writer,
        )
        schedule = Schedule(component_writer, resource_writer; name=:access_domains)

        @test map(length, get_execution_order(schedule)) == [2]
    end

    @testset "skips release dependents" begin
        events = Symbol[]
        skipped = System(() -> push!(events, :skipped);
                         name=:skipped,
                         run_if=Helm.Condition(() -> false))
        dependent = System(() -> push!(events, :dependent); name=:dependent)
        schedule = Schedule(before(skipped, dependent); name=:skip_release)

        execute!(SerialExecutor(), schedule, Ark.World())
        @test events == [:dependent]
    end

    @testset "duplicate names are rejected" begin
        first = System(() -> nothing; name=:duplicate)
        second = System(() -> nothing; name=:duplicate)
        @test_throws ArgumentError Schedule(first, second; name=:invalid)
    end

    @testset "cycles are rejected" begin
        first = System(() -> nothing; name=:first)
        second = System(() -> nothing; name=:second)
        @test_throws Exception Schedule(
            before(first, second),
            before(second, first);
            name=:cyclic,
        )
    end

    @testset "builders compile immutable schedule snapshots" begin
        events = Symbol[]
        first = System(() -> push!(events, :first); name=:first)
        second = System(() -> push!(events, :second); name=:second)
        builder = ScheduleBuilder(name=:built)

        add_system!(builder, first)
        first_snapshot = compile_schedule(builder)
        add_system!(builder, second)
        second_snapshot = compile_schedule(builder)

        world = Ark.World()
        execute!(SerialExecutor(), first_snapshot, world)
        @test events == [:first]

        empty!(events)
        execute!(SerialExecutor(), second_snapshot, world)
        @test events == [:first, :second]
    end

    @testset "compiled plans remove transitive edges" begin
        first = System(() -> nothing; name=:first)
        second = System(() -> nothing; name=:second)
        third = System(() -> nothing; name=:third)
        schedule = Schedule(
            before(first, second),
            before(second, third),
            before(first, third);
            name=:reduced,
        )

        @test schedule_report(schedule).edges == 2
        @test map(only, get_execution_order(schedule)) == [first, second, third]
    end

    @testset "serial warm execution allocates no memory" begin
        calls = Ref(0)
        system = System(() -> (calls[] += 1); name=:allocation_probe)
        schedule = Schedule(system; name=:allocation_probe)
        executor = SerialExecutor()
        world = Ark.World()

        execute!(executor, schedule, world)
        execute!(executor, schedule, world)
        @test @allocated(execute!(executor, schedule, world)) == 0
        @test calls[] == 3
    end

    @testset "threaded warm execution allocates no memory" begin
        if Threads.nthreads() == 1
            @test true
        else
            # Distinct closure sites deliberately produce heterogeneous system
            # types, matching normal application schedules.
            schedule = Schedule(
                System(() -> nothing; name=:allocation_probe_1),
                System(() -> nothing; name=:allocation_probe_2),
                System(() -> nothing; name=:allocation_probe_3),
                System(() -> nothing; name=:allocation_probe_4);
                name=:threaded_allocation_probe,
            )
            alternate = Schedule(
                System(() -> nothing; name=:alternate_1),
                System(() -> nothing; name=:alternate_2);
                name=:alternate_allocation_probe,
            )
            executor = ThreadedExecutor(workers=min(4, Threads.nthreads()))
            world = Ark.World()
            try
                execute!(executor, schedule, world)
                execute!(executor, alternate, world)
                execute!(executor, schedule, world)
                execute!(executor, alternate, world)
                @test @allocated(execute!(executor, schedule, world)) == 0
                @test @allocated(begin
                    execute!(executor, alternate, world)
                    execute!(executor, schedule, world)
                end) == 0
            finally
                Helm.close!(executor)
            end
        end
    end

    @testset "threaded serial fast path is non-reentrant" begin
        if Threads.nthreads() == 1
            @test true
        else
            entered = Threads.Atomic{Bool}(false)
            release = Threads.Atomic{Bool}(false)
            blocking = System(name=:blocking) do
                entered[] = true
                timedwait(() -> release[], 2.0; pollint=0.001) === :ok ||
                    error("serial fast-path test was not released")
                return nothing
            end
            schedule = Schedule(blocking; name=:serial_fast_path)
            executor = ThreadedExecutor(workers=2)
            first_execution = Threads.@spawn execute!(executor, schedule, Ark.World())
            try
                timedwait(() -> entered[], 2.0; pollint=0.001) === :ok ||
                    error("serial fast-path execution did not start")
                @test_throws ArgumentError execute!(executor, schedule, Ark.World())
                @test_throws ArgumentError Helm.close!(executor)
            finally
                release[] = true
                wait(first_execution)
                Helm.close!(executor)
            end
        end
    end

    @testset "threaded dependency-driven release and reuse" begin
        if Threads.nthreads() == 1
            @test true
        else
            world = Ark.World()
            slow_started = Threads.Atomic{Bool}(false)
            slow_finished = Threads.Atomic{Bool}(false)
            successor_started = Threads.Atomic{Bool}(false)
            successor_saw_slow_running = Threads.Atomic{Bool}(false)
            fast = System(name=:fast) do
                timedwait(() -> slow_started[], 2.0; pollint=0.001) === :ok ||
                    error("slow sibling did not start")
                return nothing
            end
            slow = System(name=:slow) do
                slow_started[] = true
                timedwait(() -> successor_started[], 2.0; pollint=0.001) === :ok ||
                    error("successor was not released while its sibling ran")
                slow_finished[] = true
                return nothing
            end
            successor = System(name=:successor) do
                successor_started[] = true
                successor_saw_slow_running[] = slow_started[] && !slow_finished[]
                return nothing
            end
            schedule = Schedule(slow, before(fast, successor); name=:imbalanced)
            executor = ThreadedExecutor(workers=2)
            try
                execute!(executor, schedule, world)
                @test successor_saw_slow_running[]

                sibling_started = Threads.Atomic{Bool}(false)
                sibling_finished = Threads.Atomic{Bool}(false)
                later_ran = Threads.Atomic{Bool}(false)
                failure = System(name=:failure) do
                    timedwait(() -> sibling_started[], 2.0; pollint=0.001) === :ok ||
                        error("sibling did not start")
                    error("expected executor failure")
                end
                sibling = System(name=:sibling) do
                    sibling_started[] = true
                    sleep(0.02)
                    sibling_finished[] = true
                    return nothing
                end
                later = System(() -> (later_ran[] = true); name=:later)
                failing_schedule = Schedule(
                    before(failure, later),
                    before(sibling, later),
                )
                @test_throws Exception execute!(executor, failing_schedule, world)
                @test sibling_finished[]
                @test !later_ran[]

                calls = Threads.Atomic{Int}(0)
                recovery = System(() -> (Threads.atomic_add!(calls, 1); nothing);
                                  name=:recovery)
                execute!(executor, Schedule(recovery), world)
                @test calls[] == 1
            finally
                Helm.close!(executor)
            end
        end
    end

    @testset "cancellation stops the serial chain fast path" begin
        if Threads.nthreads() == 1
            @test true
        else
            first_started = Threads.Atomic{Bool}(false)
            release_first = Threads.Atomic{Bool}(false)
            second_ran = Threads.Atomic{Bool}(false)
            first = System(name=:first) do
                first_started[] = true
                timedwait(() -> release_first[], 2.0; pollint=0.001) === :ok ||
                    error("cancelled chain was not released")
                return nothing
            end
            second = System(() -> (second_ran[] = true); name=:second)
            schedule = Schedule(chain(first, second); name=:cancelled_chain)
            executor = ThreadedExecutor(workers=2)
            execution = Threads.@spawn execute!(executor, schedule, Ark.World())
            try
                timedwait(() -> first_started[], 2.0; pollint=0.001) === :ok ||
                    error("cancelled chain did not start")
                @test cancel!(executor)
                release_first[] = true
                wait(execution)
                @test !second_ran[]
            finally
                release_first[] = true
                istaskdone(execution) || wait(execution)
                Helm.close!(executor)
            end
        end
    end

    @testset "cancellation during a phase condition prevents ready work" begin
        if Threads.nthreads() == 1
            @test true
        else
            condition_started = Threads.Atomic{Bool}(false)
            release_condition = Threads.Atomic{Bool}(false)
            calls = Threads.Atomic{Int}(0)
            condition = Helm.Condition() do
                condition_started[] = true
                timedwait(() -> release_condition[], 2.0; pollint=0.001) === :ok ||
                    error("cancelled phase condition was not released")
                return true
            end
            schedule = Schedule(
                System(() -> (Threads.atomic_add!(calls, 1); nothing); name=:first),
                System(() -> (Threads.atomic_add!(calls, 1); nothing); name=:second);
                name=:condition_cancellation,
                run_if=condition,
            )
            executor = ThreadedExecutor(workers=2)
            execution = Threads.@spawn execute!(executor, schedule, Ark.World())
            try
                timedwait(() -> condition_started[], 2.0; pollint=0.001) === :ok ||
                    error("phase condition did not start")
                @test cancel!(executor)
                release_condition[] = true
                wait(execution)
                @test calls[] == 0
            finally
                release_condition[] = true
                istaskdone(execution) || wait(execution)
                Helm.close!(executor)
            end
        end
    end

    @testset "executor configuration validation" begin
        @test_throws ArgumentError ThreadedExecutor(workers=0)
        @test_throws ArgumentError ThreadedExecutor(pool=:not_a_pool)
    end

    @testset "AutoExecutor smoke" begin
        calls = Ref(0)
        schedule = Schedule(System(() -> (calls[] += 1); name=:automatic);
                            name=:automatic)
        executor = AutoExecutor()
        scheduler = Scheduler((update=schedule,); executor=executor)

        @test executor.threaded === nothing
        @test update!(scheduler, Ark.World()) === nothing
        @test calls[] == 1
        Helm.close!(scheduler)
    end

    @testset "scheduler execution is non-reentrant" begin
        scheduler_ref = Ref{Any}()
        world = Ark.World()
        recursive = System(name=:recursive) do
            update!(scheduler_ref[], world)
            return nothing
        end
        scheduler = Scheduler(
            (update=Schedule(recursive; name=:update),);
            executor=SerialExecutor(),
        )
        scheduler_ref[] = scheduler

        @test_throws Exception update!(scheduler, world)
        disable!(scheduler, :update, :recursive)
        @test update!(scheduler, world) === nothing
    end

    @testset "mutation is rejected during execution" begin
        scheduler_ref = Ref{Any}()
        guarded = System(name=:guarded) do
            disable!(scheduler_ref[], :update, :guarded)
            return nothing
        end
        scheduler = Scheduler(
            (update=Schedule(guarded; name=:update),);
            executor=SerialExecutor(),
        )
        scheduler_ref[] = scheduler

        @test_throws Exception update!(scheduler, Ark.World())
        @test is_enabled(guarded)
        disable!(scheduler, :update, :guarded)
        @test !is_enabled(guarded)
        @test update!(scheduler, Ark.World()) === nothing
    end

    @testset "diagnostic smoke tests" begin
        reader = System(_state -> nothing, Res(SchedulerState); name=:reader)
        writer = System(_state -> nothing, ResMut(SchedulerState); name=:writer)
        schedule = Schedule(reader, writer; name=:diagnostics)

        report = schedule_report(schedule)
        explanation = explain_conflict(schedule, :reader, :writer)
        dot = to_dot(schedule)

        @test occursin("diagnostics", string(report))
        @test explanation.conflicts
        @test !isempty(explanation.accesses)
        @test occursin("digraph", dot)
        @test occursin("reader", dot)
        @test occursin("writer", dot)

        world = Ark.World()
        Ark.add_resource!(world, SchedulerState(0))
        recorder = TimingRecorder()
        execute!(TracingExecutor(SerialExecutor(), recorder), schedule, world)
        timings = timing_report(recorder, schedule)
        @test getproperty.(timings, :name) == [:reader, :writer]
        @test all(getproperty.(timings, :ran))
        @test all(getproperty.(timings, :nanoseconds) .>= 0)

        if Threads.nthreads() > 1
            wide = Schedule(ntuple(64) do id
                System(() -> nothing; name=Symbol(:traced_, id))
            end...; name=:wide_trace)
            threaded = ThreadedExecutor(workers=min(4, Threads.nthreads()))
            traced = TracingExecutor(threaded, TimingRecorder())
            try
                for _ in 1:50
                    execute!(traced, wide, world)
                    @test all(traced.recorder.ran)
                end
            finally
                Helm.close!(traced)
            end
        end
    end

    @testset "shutdown closes the owned executor" begin
        scheduler = Scheduler(
            (shutdown=Schedule(; name=:shutdown),);
            executor=SerialExecutor(),
        )
        world = Ark.World()
        @test shutdown!(scheduler, world) === nothing
        @test_throws ArgumentError execute!(scheduler, :shutdown, world)

        if Threads.nthreads() > 1
            threaded_scheduler = Scheduler(
                (shutdown=Schedule(; name=:shutdown),);
                executor=ThreadedExecutor(workers=2),
            )
            world = Ark.World()
            @test shutdown!(threaded_scheduler, world) === nothing
            @test_throws ArgumentError execute!(threaded_scheduler, :shutdown, world)
        end
    end

    @testset "execute! compatibility" begin
        calls = Ref(0)
        schedule = Schedule(System(() -> (calls[] += 1); name=:compatibility))
        @test execute!(schedule, Ark.World()) === nothing
        @test calls[] == 1
    end
end

end
