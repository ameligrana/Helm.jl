# Executing schedules

Executors determine how ready systems run. Own and reuse an executor in an
application loop; constructing a fresh threaded pool on every frame defeats
most of the benefit.

## Choosing an executor

- [`SerialExecutor`](@ref) is deterministic and has the least overhead for
  small schedules.
- [`ThreadedExecutor`](@ref) owns reusable worker tasks and can run independent
  systems concurrently. Start Julia with multiple threads, for example
  `julia --threads=auto --project=.`.
- [`AutoExecutor`](@ref) stays serial by default. Give it an application-specific
  `min_parallel_systems` threshold only after measuring a useful crossover.

```@example executor
import Ark
using Helm

world = Ark.World()
schedule = Schedule(System(() -> nothing; name=:work))
executor = ThreadedExecutor(workers=1)

try
    for _ in 1:3
        execute!(executor, schedule, world)
    end
finally
    Helm.close!(executor)
end
nothing
```

The convenience form `execute!(schedule, world)` chooses an executor for one
call and closes it afterward. It is useful for scripts, tests, and setup phases.

## Timing systems

Wrap any executor in [`TracingExecutor`](@ref) to populate a reusable
[`TimingRecorder`](@ref).

```@example tracing
import Ark
using Helm

work = System(() -> sum(1:100); name=:work)
schedule = Schedule(work; name=:profiled)
recorder = TimingRecorder()
executor = TracingExecutor(SerialExecutor(), recorder)

execute!(executor, schedule, Ark.World())
report = timing_report(recorder, schedule)

@assert only(report).name == :work
@assert only(report).ran
nothing
```

Timing values are elapsed nanoseconds measured around each callable. Treat them
as profiling observations, not as a benchmarking substitute.

## Lifecycle phases

[`Scheduler`](@ref) groups schedules into conventional lifecycle phases and can
also hold custom phases. It owns the supplied executor.

```@example scheduler
import Ark
using Helm

events = Symbol[]
startup = Schedule(
    System(() -> push!(events, :startup); name=:initialize);
    name=:startup,
)
update = Schedule(
    System(() -> push!(events, :update); name=:advance);
    name=:update,
)
shutdown = Schedule(
    System(() -> push!(events, :shutdown); name=:cleanup);
    name=:shutdown,
)

scheduler = Scheduler(
    startup=startup,
    update=update,
    shutdown=shutdown,
    executor=SerialExecutor(),
)
world = Ark.World()

startup!(scheduler, world)
update!(scheduler, world)
shutdown!(scheduler, world) # also closes the scheduler's executor

@assert events == [:startup, :update, :shutdown]
nothing
```

Custom schedules passed as `phases=(render=render_schedule,)` are executed with
`execute!(scheduler, :render, world)`.

## Enabling and disabling systems

Named systems can be toggled while a scheduler is idle:

```julia
disable!(scheduler, :update, :expensive_system)
@assert !is_enabled(expensive_system)
enable!(scheduler, :update, :expensive_system)
```

Disabling or failing a condition skips that system's callable, not the graph
node; downstream systems can still execute. [`cancel!`](@ref) can request that
a running `ThreadedExecutor` stop releasing further work. It does not interrupt
systems that are already running.
