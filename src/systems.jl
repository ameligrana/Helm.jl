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


function (sys::System)(world::Ark.World)
    args = map(sys._configs) do config
        fetch_arg(world, config)
    end

    return_value = sys._f(args...)
    for (config, arg) in zip(sys._configs, args)
        config isa Cmds && Ark.apply!(arg)
    end
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
