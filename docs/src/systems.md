# Systems and data access

A [`System`](@ref) wraps any callable and a sequence of argument
configurations. When the system runs, Helm resolves those arguments from the
current `Ark.World` in declaration order.

| Configuration | Injected value | Scheduled access |
|:--|:--|:--|
| `Query((Position,))` | Ark query | write `Position` |
| `Query((Const(Position),))` | Ark query | read `Position` |
| `Res(Settings)` | resource | read `Settings` |
| `ResMut(State)` | resource | write `State` |
| `Cmds(...)` | command buffer | world write |

## Component queries

Plain component types in a query are writable. [`Const`](@ref) marks a
component read-only. Filters passed with `with` and `without` affect which
archetypes match without adding returned columns.

```@example component-query
import Ark
using Helm

struct Position
    x::Float64
end

struct Velocity
    x::Float64
end


world = Ark.World(Position, Velocity)
Ark.new_entity!(world, (Position(1.0), Velocity(0.5)))

move = System(Query((Position, Const(Velocity))); name=:move) do query
    for (_, positions, velocities) in query
        for i in eachindex(positions, velocities)
            positions[i] = Position(positions[i].x + velocities[i].x)
        end
    end
end

observed = Ref(0.0)
inspect = System(Query((Const(Position),)); name=:inspect) do query
    for (_, positions) in query
        observed[] = only(positions).x
    end
end

execute!(SerialExecutor(), Schedule(chain(move, inspect)), world)
@assert observed[] == 1.5
nothing
```

Helm scopes each injected query to the system call and closes it automatically,
including after partial iteration or an exception. Do not retain an injected
query after the callable returns.

## Resources and run conditions

Conditions use the same injection mechanism as systems. Their accesses also
participate in conflict detection.

```@example conditions
import Ark
using Helm

mutable struct GameState
    running::Bool
    frames::Int
end

world = Ark.World()
Ark.add_resource!(world, GameState(true, 0))

while_running = Helm.Condition(Res(GameState)) do state
    state.running
end

count_frame = System(
    ResMut(GameState);
    name=:count_frame,
    run_if=while_running,
) do state
    state.frames += 1
end

execute!(SerialExecutor(), Schedule(count_frame), world)
@assert Ark.get_resource(world, GameState).frames == 1
nothing
```

A condition must return `Bool`. If it returns `false`, Helm skips the callable,
but its dependants can still become ready.

## Deferred structural changes

Use [`Cmds`](@ref) for changes that cannot be applied while queries hold the
world locked. The specification fixes the supported command shapes when the
system is constructed; the injected Ark buffer provides the usual Ark command
methods.

```@example commands
import Ark
using Helm

struct Health
    value::Int
end

world = Ark.World(Health)
create_health = Cmds(((Ark.new_entity!, (Health,)),))

spawn = System(create_health; name=:spawn) do commands
    Ark.new_entity!(commands, (Health(100),))
end

execute!(SerialExecutor(), Schedule(spawn), world)

count = 0
for (entities, _) in Ark.Query(world, (Health,))
    global count += length(entities)
end
@assert count == 1
nothing
```
