# Building schedules

Constructing a [`Schedule`](@ref) compiles an immutable dependency graph.
Systems passed without an explicit relationship are unordered unless their
declared accesses conflict.

## Dependencies and priorities

Use [`before`](@ref) or [`after`](@ref) for a single relationship and
[`chain`](@ref) for a sequence. Expressions can be nested and repeated systems
are included only once.

```@example dependencies
import Ark
using Helm

events = Symbol[]
load = System(() -> push!(events, :load); name=:load)
simulate = System(() -> push!(events, :simulate); name=:simulate)
render = System(() -> push!(events, :render); name=:render)

schedule = Schedule(chain(load, simulate, render); name=:frame)
execute!(SerialExecutor(), schedule, Ark.World())

@assert events == [:load, :simulate, :render]
schedule_report(schedule)
```

A system's `priority` is only a tie breaker among ready nodes. It cannot
override an explicit or inferred dependency.

## Inferred conflicts

Helm distinguishes component access from resource access, even when both use
the same Julia type. The following two writers conflict because they both
declare mutable access to `SimulationState`:

```@example conflicts
using Helm

mutable struct SimulationState
    value::Int
end

integrate = System(_ -> nothing, ResMut(SimulationState); name=:integrate)
reset = System(_ -> nothing, ResMut(SimulationState); name=:reset)
schedule = Schedule(integrate, reset; name=:conflicting_writers)

@assert map(length, get_execution_order(schedule)) == [1, 1]
explain_conflict(schedule, :integrate, :reset)
```

[`get_execution_order`](@ref) exposes topological layers for inspection.
Threaded execution is dependency-driven, however: an individual successor can
start as soon as its own predecessors finish, without waiting for unrelated
work in the same displayed layer.

## Incremental construction

A [`ScheduleBuilder`](@ref) is convenient when plugins or application setup
contribute systems incrementally. Compiling creates a snapshot.

```@example builder
using Helm

builder = ScheduleBuilder(name=:dynamic_update)
add_system!(builder, System(() -> nothing; name=:first))
first_snapshot = compile_schedule(builder)

add_system!(builder, System(() -> nothing; name=:second))
second_snapshot = compile_schedule(builder)

@assert schedule_report(first_snapshot).systems == 1
@assert schedule_report(second_snapshot).systems == 2
nothing
```

## Diagnostics and visualization

[`schedule_report`](@ref) returns compact graph statistics, while
[`explain_conflict`](@ref) identifies shared access keys between named systems.
Use [`to_dot`](@ref) or [`write_dot`](@ref) to send the compiled graph to
[Graphviz](https://graphviz.org/):

```julia
write("schedule.dot", to_dot(schedule))
run(`dot -Tsvg schedule.dot -o schedule.svg`)
```
