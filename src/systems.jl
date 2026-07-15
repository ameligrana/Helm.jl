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

@inline function fetch_arg(world::Ark.World, r::ResourceData)
    return Ark.get_resource(world, r._datatype)
end

@inline function fetch_arg(world::Ark.World, c::Cmds)
    return to_command_buffer(world, c)
end


@generated function (sys::System{T, C})(world::Ark.World) where {T, C}
    N = length(C.parameters)

    fetch_exprs = [:(arg_ $ i = fetch_arg(world, sys._configs[$i])) for i in 1:N]

    sys_args = [:(arg_ $ i) for i in 1:N]

    apply_exprs = Expr[]
    for i in 1:N
        if C.parameters[i] <: Cmds
            push!(apply_exprs, :(Ark.apply!(world, arg_ $ i)))
        end
    end

    return quote
        $(fetch_exprs...)

        return_value = sys._f($(sys_args...))

        $(apply_exprs...)

        return return_value
    end
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
