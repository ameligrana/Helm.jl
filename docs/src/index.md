# Helm.jl

Helm is a scheduler for [Ark.jl](https://github.com/ark-ecs/Ark.jl) systems. A
system declares the components and resources it accesses; Helm uses that
information together with explicit dependencies to compile a safe execution
plan. Independent systems can then run concurrently.

## Installation

Install Helm from its Git repository:

```julia
using Pkg
Pkg.add(url="https://github.com/theplatters/Helm.jl")
```

## A first schedule

The smallest useful system can operate on an Ark resource. `ResMut` tells Helm
that the system writes the resource, so other systems accessing the same type
will be ordered safely.

```@example quickstart
import Ark
using Helm

mutable struct Clock
    tick::Int
end

world = Ark.World()
Ark.add_resource!(world, Clock(0))

advance = System(ResMut(Clock); name=:advance) do clock
    clock.tick += 1
end

schedule = Schedule(advance; name=:game_update)
execute!(SerialExecutor(), schedule, world)

@assert Ark.get_resource(world, Clock).tick == 1
schedule_report(schedule)
```

In an application loop, create an executor once and reuse it instead of using
the two-argument `execute!` convenience method. See [Executing
schedules](@ref) for serial, threaded, automatic, and traced execution.

## How scheduling works

At construction time, a [`Schedule`](@ref) combines two sources of ordering:

1. Explicit relationships created with [`before`](@ref), [`after`](@ref), and
   [`chain`](@ref).
2. Conflicts inferred from component and resource reads and writes.

A write conflicts with any other access in the same domain. Read-only systems
do not conflict with each other. Command buffers are treated conservatively as
world writes because their structural changes are applied after the system
returns.
