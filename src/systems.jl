"""Common supertype for systems and schedule expressions.

It intentionally does not subtype `Function`: any callable Julia object can be a
system.
"""
abstract type AbstractSystem end

struct NoCondition end

"""
    Condition(f, configs...)

A run criterion for a [`System`](@ref) or [`Schedule`](@ref). `f` receives the
arguments described by `configs`, exactly like a system function, and must
return a `Bool`. The associated accesses participate in conflict detection.
"""
struct Condition{F,C<:Tuple{Vararg{SystemConfig}}}
    _f::F
    _configs::C
end

Condition(f, configs::Vararg{SystemConfig}) = Condition(f, configs)

struct EnableFlag
    value::Threads.Atomic{Bool}
end

"""
    System(f, configs...; name=nothing, priority=0, run_if=..., enabled=true)

Wrap a callable as a schedulable system. Before calling `f`, Helm resolves each
configuration in `configs` from the current `Ark.World`. Supported
configurations are [`Query`](@ref), [`Res`](@ref), [`ResMut`](@ref), and
[`Cmds`](@ref).

`name` identifies the system in diagnostics and runtime controls. `priority`
orders otherwise-ready systems but never overrides dependencies. Set `run_if`
to a [`Condition`](@ref), and use `enabled=false` to create a system that is
initially disabled.
"""
struct System{F,C<:Tuple{Vararg{SystemConfig}},R} <: AbstractSystem
    _f::F
    _configs::C
    _run_if::R
    _name::Union{Nothing,Symbol}
    _priority::Int
    _enabled::EnableFlag
end

function System(
    f,
    configs::Vararg{SystemConfig};
    name::Union{Nothing,Symbol}=nothing,
    priority::Integer=0,
    run_if::Union{NoCondition,Condition}=NoCondition(),
    enabled::Bool=true,
)
    return System(
        f,
        configs,
        run_if,
        name,
        Int(priority),
        EnableFlag(Threads.Atomic{Bool}(enabled)),
    )
end

Condition(f, configs::Tuple) = Condition{typeof(f),typeof(configs)}(f, configs)

function _enable_system!(system::System)
    system._enabled.value[] = true
    return system
end

function _disable_system!(system::System)
    system._enabled.value[] = false
    return system
end

"""
    is_enabled(system::System) -> Bool

Return whether `system` is currently enabled.
"""
is_enabled(system::System) = system._enabled.value[]

@inline function fetch_arg(world::Ark.World, q::QueryData)
    return Ark.Query(world, q)
end

@inline function fetch_arg(world::Ark.World, ::ResourceData{D,M}) where {D,M}
    return Ark.get_resource(world, D)
end

@inline function fetch_arg(world::Ark.World, c::Cmds)
    return to_command_buffer(world, c)
end

@inline function _acquire_and_invoke(
    ::Ark.World,
    ::Tuple{},
    args::Tuple,
    command_buffers::Tuple,
    f,
)
    return f(args...), command_buffers
end

@inline function _acquire_and_invoke(
    world::Ark.World,
    configs::Tuple,
    args::Tuple,
    command_buffers::Tuple,
    f,
)
    config = first(configs)
    remaining = Base.tail(configs)
    return _acquire_one(world, config, remaining, args, command_buffers, f)
end

@inline function _acquire_one(
    world::Ark.World,
    config::QueryData,
    remaining::Tuple,
    args::Tuple,
    command_buffers::Tuple,
    f,
)
    query = fetch_arg(world, config)
    try
        return _acquire_and_invoke(world, remaining, (args..., query), command_buffers, f)
    finally
        Ark.close!(query)
    end
end

@inline function _acquire_one(
    world::Ark.World,
    config::Cmds,
    remaining::Tuple,
    args::Tuple,
    command_buffers::Tuple,
    f,
)
    command_buffer = fetch_arg(world, config)
    return _acquire_and_invoke(
        world,
        remaining,
        (args..., command_buffer),
        (command_buffers..., command_buffer),
        f,
    )
end

@inline function _acquire_one(
    world::Ark.World,
    config::SystemConfig,
    remaining::Tuple,
    args::Tuple,
    command_buffers::Tuple,
    f,
)
    arg = fetch_arg(world, config)
    return _acquire_and_invoke(world, remaining, (args..., arg), command_buffers, f)
end

@inline _apply_commands(::Tuple{}) = nothing

@inline function _apply_commands(command_buffers::Tuple)
    Ark.apply!(first(command_buffers))
    _apply_commands(Base.tail(command_buffers))
    return nothing
end

@inline function _invoke(system::System, world::Ark.World)
    return_value, command_buffers =
        _acquire_and_invoke(world, system._configs, (), (), system._f)
    _apply_commands(command_buffers)
    return return_value
end

(system::System)(world::Ark.World) = _invoke(system, world)

@inline _criterion_passes(::NoCondition, ::Ark.World) = true

@inline function _criterion_passes(condition::Condition, world::Ark.World)
    value, command_buffers =
        _acquire_and_invoke(world, condition._configs, (), (), condition._f)
    _apply_commands(command_buffers)
    value isa Bool || throw(ArgumentError("a run condition must return Bool, got $(typeof(value))"))
    return value
end

@inline function _run_system!(system::System, world::Ark.World)
    system._enabled.value[] || return false
    _criterion_passes(system._run_if, world) || return false
    _invoke(system, world)
    return true
end

reads(condition::Condition) = reads_from_config_tuple(typeof(condition._configs))
writes(condition::Condition) = writes_from_config_tuple(typeof(condition._configs))
reads(::NoCondition) = ()
writes(::NoCondition) = ()

reads(::Type{<:Condition{F,C}}) where {F,C} = reads_from_config_tuple(C)
writes(::Type{<:Condition{F,C}}) where {F,C} = writes_from_config_tuple(C)
reads(::Type{NoCondition}) = ()
writes(::Type{NoCondition}) = ()

function reads(system::System)
    return Tuple(unique((reads_from_config_tuple(typeof(system._configs))..., reads(system._run_if)...)))
end

function writes(system::System)
    return Tuple(unique((writes_from_config_tuple(typeof(system._configs))..., writes(system._run_if)...)))
end

function reads(::Type{<:System{F,C,R}}) where {F,C,R}
    return Tuple(unique((reads_from_config_tuple(C)..., reads(R)...)))
end

function writes(::Type{<:System{F,C,R}}) where {F,C,R}
    return Tuple(unique((writes_from_config_tuple(C)..., writes(R)...)))
end

function reads_from_config_tuple(::Type{C}) where {C<:Tuple}
    all_reads = Any[]
    for config_type in C.parameters
        append!(all_reads, reads(config_type))
    end
    return Tuple(unique(all_reads))
end

function writes_from_config_tuple(::Type{C}) where {C<:Tuple}
    all_writes = Any[]
    for config_type in C.parameters
        append!(all_writes, writes(config_type))
    end
    return Tuple(unique(all_writes))
end

# Access identities used only while compiling. Keeping these domains separate
# prevents a resource type from aliasing a component with the same Julia type.
struct ComponentAccess{T} end
struct ResourceAccess{T} end
struct WorldAccess end

_config_accesses(::Type{<:QueryData{R,W}}) where {R,W} = (
    Tuple(ComponentAccess{T} for T in R.parameters),
    Tuple(ComponentAccess{T} for T in W.parameters),
    false,
)

_config_accesses(::Type{<:ResourceData{T,false}}) where {T} =
    ((ResourceAccess{T},), (), false)
_config_accesses(::Type{<:ResourceData{T,true}}) where {T} =
    ((), (ResourceAccess{T},), false)
_config_accesses(::Type{<:Cmds}) = ((), (), true)

function _tuple_accesses(::Type{C}) where {C<:Tuple}
    read_keys = DataType[]
    write_keys = DataType[]
    world_write = false
    for config_type in C.parameters
        config_reads, config_writes, config_world_write = _config_accesses(config_type)
        append!(read_keys, config_reads)
        append!(write_keys, config_writes)
        world_write |= config_world_write
    end
    return unique(read_keys), unique(write_keys), world_write
end

_condition_accesses(::Type{NoCondition}) = (DataType[], DataType[], false)
_condition_accesses(::Type{<:Condition{F,C}}) where {F,C} = _tuple_accesses(C)

function _system_accesses(::Type{<:System{F,C,R}}) where {F,C,R}
    reads1, writes1, world1 = _tuple_accesses(C)
    reads2, writes2, world2 = _condition_accesses(R)
    return unique((reads1..., reads2...)), unique((writes1..., writes2...)), world1 | world2
end

_uses_commands(system::System) = last(_system_accesses(typeof(system)))
