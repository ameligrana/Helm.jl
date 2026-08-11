abstract type AbstractSystem <: Function end


struct System{T, C <: Tuple{Vararg{SystemConfig}}} <: AbstractSystem
    _f::T
    _configs::C
end

function System(f::F, configs::Vararg{SystemConfig, N}) where {F <: Function, N}
    return System(f, configs)
end

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
        return _acquire_and_invoke(
            world,
            remaining,
            (args..., query),
            command_buffers,
            f,
        )
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
    return _acquire_and_invoke(
        world,
        remaining,
        (args..., arg),
        command_buffers,
        f,
    )
end

@inline _apply_commands(::Tuple{}) = nothing

@inline function _apply_commands(command_buffers::Tuple)
    Ark.apply!(first(command_buffers))
    _apply_commands(Base.tail(command_buffers))
    return nothing
end

function (sys::System)(world::Ark.World)
    return_value, command_buffers =
        _acquire_and_invoke(world, sys._configs, (), (), sys._f)
    _apply_commands(command_buffers)
    return return_value
end


@generated function reads(sys::System{T, C}) where {T, C}
    all_reads = DataType[]

    for config_type in C.parameters
        for r_sym in reads(config_type)
            push!(all_reads, r_sym)
        end
    end

    unique_reads = Tuple(unique(all_reads))
    return :($unique_reads)
end


@generated function writes(sys::System{T, C}) where {T, C}
    all_writes = DataType[]

    for config_type in C.parameters
        for w_sym in writes(config_type)
            push!(all_writes, w_sym)
        end
    end

    unique_writes = Tuple(unique(all_writes))
    return :($unique_writes)
end
