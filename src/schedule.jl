struct Schedule{N, T <: Tuple{Vararg{AbstractSystem, N}}}
    _systems::T
    _dependency_graph::Gr.SimpleDiGraph{Int64}
    _execution_stages::Vector{Vector{Int}}
end

struct SystemChain{N, T <: Tuple{Vararg{AbstractSystem, N}}} <: AbstractSystem
    _systems::T
end

function chain(systems::AbstractSystem...)
    return SystemChain(systems)
end

struct SystemDependency{T <: AbstractSystem, U <: AbstractSystem} <: AbstractSystem
    _before::T
    _after::U
end

function after(s::AbstractSystem, u::AbstractSystem)
    return SystemDependency(u, s)
end

function before(s::AbstractSystem, u::AbstractSystem)
    return SystemDependency(s, u)
end

function extract_unique_systems!(sys::System, flat_list, id_map)
    if !haskey(id_map, sys)
        push!(flat_list, sys)
        id_map[sys] = length(flat_list) # ID is simply its index in the flat list
    end
    return nothing
end

function extract_unique_systems!(chain::SystemChain, flat_list, id_map)
    for s in chain._systems
        extract_unique_systems!(s, flat_list, id_map)
    end
    return nothing
end

function extract_unique_systems!(dep::SystemDependency, flat_list, id_map)
    extract_unique_systems!(dep._before, flat_list, id_map)
    extract_unique_systems!(dep._after, flat_list, id_map)
    return nothing
end
# Helper to build edges. Returns (entry_nodes, exit_nodes) for any block
function build_edges!(sys::System, graph, id_map)
    id = id_map[sys]
    return ([id], [id])
end

function build_edges!(chain::SystemChain, graph, id_map)
    entries = Int[]
    prev_exits = Int[]

    for (i, s) in enumerate(chain._systems)
        curr_entries, curr_exits = build_edges!(s, graph, id_map)

        if i == 1
            entries = curr_entries
        end

        # Connect all exits of the previous block to all entries of this block
        for u in prev_exits
            for v in curr_entries
                Gr.add_edge!(graph, u, v)
            end
        end
        prev_exits = curr_exits
    end

    return (entries, prev_exits)
end

function build_edges!(dep::SystemDependency, graph, id_map)
    before_entries, before_exits = build_edges!(dep._before, graph, id_map)
    after_entries, after_exits = build_edges!(dep._after, graph, id_map)

    # Wire `before` -> `after`
    for u in before_exits
        for v in after_entries
            Gr.add_edge!(graph, u, v)
        end
    end

    return (before_entries, after_exits)
end

function Schedule(systems::AbstractSystem...)

    flat_list = System[]
    id_map = IdDict{System, Int}()

    # First Pass: Extract all unique leaf systems and assign IDs
    for s in systems
        extract_unique_systems!(s, flat_list, id_map)
    end

    #second pass: construct dependency graph
    graph = Gr.SimpleDiGraph{Int}(length(flat_list))


    for s in systems
        build_edges!(s, graph, id_map)
    end

    # Third Pass: Automatic Dependency Discovery
    for i in 1:length(flat_list)
        for j in (i + 1):length(flat_list)
            s1 = flat_list[i]
            s2 = flat_list[j]

            if conflicts(s1, s2)
                # If they conflict, and no explicit path exists, add an edge i -> j
                # to maintain original argument order as a tie-breaker.
                if !Gr.has_path(graph, i, j) && !Gr.has_path(graph, j, i)
                    Gr.add_edge!(graph, i, j)
                end
            end
        end
    end


    stages = topological_sort_in_layers(graph)

    return Schedule(Tuple(flat_list), graph, stages)
end


function conflicts(s1::AbstractSystem, s2::AbstractSystem)
    # Command buffers are applied before a system returns and can change the
    # world's entity/component structure. They therefore cannot overlap with
    # any other access to the world, regardless of the command types recorded.
    if _uses_commands(s1) || _uses_commands(s2)
        return true
    end

    r1, w1 = reads(s1), writes(s1)
    r2, w2 = reads(s2), writes(s2)

    return !isempty(intersect(w1, r2)) ||
        !isempty(intersect(w1, w2)) ||
        !isempty(intersect(r1, w2))
end

_uses_commands(sys::System) = any(config -> config isa Cmds, sys._configs)
_uses_commands(chain::SystemChain) = any(_uses_commands, chain._systems)
_uses_commands(dep::SystemDependency) =
    _uses_commands(dep._before) || _uses_commands(dep._after)

function topological_sort_in_layers(graph::Gr.SimpleDiGraph{Int})
    in_degrees = [length(Gr.inneighbors(graph, i)) for i in 1:Gr.nv(graph)]
    ready_nodes = [i for i in 1:Gr.nv(graph) if in_degrees[i] == 0]

    stages = Vector{Vector{Int}}()

    while !isempty(ready_nodes)
        push!(stages, ready_nodes)

        next_ready = Int[]
        for node in ready_nodes
            for neighbor in Gr.outneighbors(graph, node)
                in_degrees[neighbor] -= 1
                if in_degrees[neighbor] == 0
                    push!(next_ready, neighbor)
                end
            end
        end
        ready_nodes = next_ready
    end

    if sum(length, stages; init=0) != Gr.nv(graph)
        error("Cycle detected in scheduling graph! Cannot execute systems.")
    end

    return stages
end

function get_execution_order(schedule::Schedule)
    return [[schedule._systems[id] for id in stage] for stage in schedule._execution_stages]
end

reads(::Type{<:System{T, C}}) where {T, C} = reads_from_config_tuple(C)
writes(::Type{<:System{T, C}}) where {T, C} = writes_from_config_tuple(C)

function reads_from_config_tuple(::Type{C}) where {C <: Tuple}
    all_reads = Any[]
    for config_type in C.parameters
        for r_type in reads(config_type)
            push!(all_reads, r_type)
        end
    end
    return Tuple(unique(all_reads))
end

function writes_from_config_tuple(::Type{C}) where {C <: Tuple}
    all_writes = Any[]
    for config_type in C.parameters
        for w_type in writes(config_type)
            push!(all_writes, w_type)
        end
    end
    return Tuple(unique(all_writes))
end


reads(::Type{<:SystemChain{N, T}}) where {N, T} = reads_from_systems_tuple(T)

@generated function reads(chain::SystemChain{N, T}) where {N, T}
    return :($(reads_from_systems_tuple(T)))
end

function reads_from_systems_tuple(::Type{T}) where {T <: Tuple}
    all_reads = Any[]
    for sys_type in T.parameters
        # This will now successfully find reads(::Type{<:System})!
        for r_type in reads(sys_type)
            push!(all_reads, r_type)
        end
    end
    return Tuple(unique(all_reads))
end


writes(::Type{<:SystemChain{N, T}}) where {N, T} = writes_from_systems_tuple(T)

@generated function writes(chain::SystemChain{N, T}) where {N, T}
    return :($(writes_from_systems_tuple(T)))
end

function writes_from_systems_tuple(::Type{T}) where {T <: Tuple}
    all_writes = Any[]
    for sys_type in T.parameters
        for w_type in writes(sys_type)
            push!(all_writes, w_type)
        end
    end
    return Tuple(unique(all_writes))
end


reads(::Type{<:SystemDependency{U, V}}) where {U, V} = Tuple(unique((reads(U)..., reads(V)...)))

@generated function reads(dep::SystemDependency{U, V}) where {U, V}
    return :($(reads(U)..., reads(V)...))
end

writes(::Type{<:SystemDependency{U, V}}) where {U, V} = Tuple(unique((writes(U)..., writes(V)...)))

@generated function writes(dep::SystemDependency{U, V}) where {U, V}
    return :($(writes(U)..., writes(V)...))
end
