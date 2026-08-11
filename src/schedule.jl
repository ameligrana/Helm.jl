struct SystemChain{N,T<:Tuple{Vararg{AbstractSystem,N}}} <: AbstractSystem
    _systems::T
end

chain(systems::AbstractSystem...) = SystemChain(systems)

struct SystemDependency{T<:AbstractSystem,U<:AbstractSystem} <: AbstractSystem
    _before::T
    _after::U
end

after(system::AbstractSystem, dependency::AbstractSystem) =
    SystemDependency(dependency, system)
before(system::AbstractSystem, dependency::AbstractSystem) =
    SystemDependency(system, dependency)

"""Compact access masks retained for diagnostics and executor specialization."""
struct AccessMasks
    component_reads::Matrix{UInt64}
    component_writes::Matrix{UInt64}
    resource_reads::Matrix{UInt64}
    resource_writes::Matrix{UInt64}
    world_writes::BitVector
    component_types::Vector{DataType}
    resource_types::Vector{DataType}
end

"""Immutable execution metadata compiled from a schedule expression."""
struct CompiledSchedule{N,O<:NTuple{N,Int}}
    successor_offsets::Vector{Int}
    successors::Vector{Int}
    dependency_counts::Vector{Int}
    topological_order::O
    critical_path_ranks::Vector{Int}
    names::Vector{Symbol}
    priorities::Vector{Int}
    stages::Vector{Vector{Int}}
    accesses::AccessMasks
    max_width::Int
end

struct Schedule{N,T<:Tuple{Vararg{System,N}},P<:CompiledSchedule{N},R}
    _systems::T
    _plan::P
    _name::Symbol
    _run_if::R
end

schedule_name(schedule::Schedule) = schedule._name

function extract_unique_systems!(system::System, flat_list, id_map)
    if !haskey(id_map, system)
        push!(flat_list, system)
        id_map[system] = length(flat_list)
    end
    return nothing
end

function extract_unique_systems!(system_chain::SystemChain, flat_list, id_map)
    for system in system_chain._systems
        extract_unique_systems!(system, flat_list, id_map)
    end
    return nothing
end

function extract_unique_systems!(dependency::SystemDependency, flat_list, id_map)
    extract_unique_systems!(dependency._before, flat_list, id_map)
    extract_unique_systems!(dependency._after, flat_list, id_map)
    return nothing
end

function build_edges!(system::System, graph, id_map)
    id = id_map[system]
    return ([id], [id])
end

function build_edges!(system_chain::SystemChain, graph, id_map)
    isempty(system_chain._systems) && return (Int[], Int[])
    entries = Int[]
    previous_exits = Int[]
    for (index, system) in enumerate(system_chain._systems)
        current_entries, current_exits = build_edges!(system, graph, id_map)
        index == 1 && (entries = current_entries)
        for source in previous_exits, destination in current_entries
            Gr.add_edge!(graph, source, destination)
        end
        previous_exits = current_exits
    end
    return entries, previous_exits
end

function build_edges!(dependency::SystemDependency, graph, id_map)
    before_entries, before_exits = build_edges!(dependency._before, graph, id_map)
    after_entries, after_exits = build_edges!(dependency._after, graph, id_map)
    for source in before_exits, destination in after_entries
        Gr.add_edge!(graph, source, destination)
    end
    return before_entries, after_exits
end

function _validate_acyclic(graph)
    !Gr.is_cyclic(graph) ||
        throw(ArgumentError("cycle detected in schedule dependencies"))
    return nothing
end

function _has_intersection(first_keys, second_keys)
    for key in first_keys
        key in second_keys && return true
    end
    return false
end

function conflicts(first::System, second::System)
    first_reads, first_writes, first_world = _system_accesses(typeof(first))
    second_reads, second_writes, second_world = _system_accesses(typeof(second))
    (first_world || second_world) && return true
    return _has_intersection(first_writes, second_reads) ||
           _has_intersection(first_writes, second_writes) ||
           _has_intersection(first_reads, second_writes)
end

function _stable_ready_sort!(nodes, systems)
    sort!(nodes; by=id -> (-systems[id]._priority, id), alg=Base.Sort.MergeSort)
    return nodes
end

function _topological_layers(graph, systems)
    node_count = Gr.nv(graph)
    dependency_counts = [Gr.indegree(graph, id) for id in 1:node_count]
    ready = _stable_ready_sort!(findall(iszero, dependency_counts), systems)
    stages = Vector{Vector{Int}}()
    order = Int[]
    while !isempty(ready)
        push!(stages, copy(ready))
        append!(order, ready)
        next_ready = Int[]
        for id in ready
            for successor in Gr.outneighbors(graph, id)
                dependency_counts[successor] -= 1
                dependency_counts[successor] == 0 && push!(next_ready, successor)
            end
        end
        ready = _stable_ready_sort!(next_ready, systems)
    end
    length(order) == node_count || throw(ArgumentError("cycle detected in schedule dependencies"))
    return stages, order
end

function _transitive_reduction!(graph)
    # Graphs.jl deliberately remains a cold-path detail. Removing an edge and
    # checking reachability is simple and robust for the small DAGs builders
    # typically compile.
    for edge in collect(Gr.edges(graph))
        source, destination = Gr.src(edge), Gr.dst(edge)
        Gr.rem_edge!(graph, source, destination)
        Gr.has_path(graph, source, destination) || Gr.add_edge!(graph, source, destination)
    end
    return graph
end

function _effective_names(systems)
    names = Vector{Symbol}(undef, length(systems))
    explicitly_named = Set{Symbol}()
    for (id, system) in enumerate(systems)
        if system._name === nothing
            candidate = Symbol("system_", id)
            while candidate in explicitly_named
                candidate = Symbol("_", candidate)
            end
            names[id] = candidate
        else
            system._name in explicitly_named &&
                throw(ArgumentError("duplicate system name: $(system._name)"))
            push!(explicitly_named, system._name)
            names[id] = system._name
        end
    end
    length(unique(names)) == length(names) ||
        throw(ArgumentError("generated and explicit system names collide"))
    return names
end

function _mask_matrix(keys_by_system, keys)
    words = cld(length(keys), 64)
    matrix = zeros(UInt64, length(keys_by_system), words)
    key_ids = Dict(key => id for (id, key) in enumerate(keys))
    for (system_id, system_keys) in enumerate(keys_by_system), key in system_keys
        bit_id = key_ids[key]
        word_id = ((bit_id - 1) >>> 6) + 1
        matrix[system_id, word_id] |= UInt64(1) << ((bit_id - 1) & 63)
    end
    return matrix
end

function _compile_access_masks(systems)
    reads_by_system = Vector{Vector{DataType}}(undef, length(systems))
    writes_by_system = similar(reads_by_system)
    world_writes = falses(length(systems))
    component_keys = DataType[]
    resource_keys = DataType[]
    for (id, system) in enumerate(systems)
        system_reads, system_writes, world_write = _system_accesses(typeof(system))
        reads_by_system[id] = collect(system_reads)
        writes_by_system[id] = collect(system_writes)
        world_writes[id] = world_write
        for key in (system_reads..., system_writes...)
            if key <: ComponentAccess
                key in component_keys || push!(component_keys, key)
            elseif key <: ResourceAccess
                key in resource_keys || push!(resource_keys, key)
            end
        end
    end
    component_reads = [filter(key -> key <: ComponentAccess, keys) for keys in reads_by_system]
    component_writes = [filter(key -> key <: ComponentAccess, keys) for keys in writes_by_system]
    resource_reads = [filter(key -> key <: ResourceAccess, keys) for keys in reads_by_system]
    resource_writes = [filter(key -> key <: ResourceAccess, keys) for keys in writes_by_system]
    component_types = DataType[key.parameters[1] for key in component_keys]
    resource_types = DataType[key.parameters[1] for key in resource_keys]
    return AccessMasks(
        _mask_matrix(component_reads, component_keys),
        _mask_matrix(component_writes, component_keys),
        _mask_matrix(resource_reads, resource_keys),
        _mask_matrix(resource_writes, resource_keys),
        world_writes,
        component_types,
        resource_types,
    )
end

function _compile_plan(systems, graph)
    _transitive_reduction!(graph)
    stages, order = _topological_layers(graph, systems)
    node_count = length(systems)
    dependency_counts = [Gr.indegree(graph, id) for id in 1:node_count]
    successor_offsets = Vector{Int}(undef, node_count + 1)
    successors = Int[]
    successor_offsets[1] = 1
    for id in 1:node_count
        neighbors = collect(Gr.outneighbors(graph, id))
        _stable_ready_sort!(neighbors, systems)
        append!(successors, neighbors)
        successor_offsets[id + 1] = length(successors) + 1
    end
    critical_path_ranks = ones(Int, node_count)
    for id in Iterators.reverse(order)
        range = successor_offsets[id]:(successor_offsets[id + 1] - 1)
        isempty(range) || (critical_path_ranks[id] = 1 + maximum(
            critical_path_ranks[successors[index]] for index in range
        ))
    end
    names = _effective_names(systems)
    priorities = Int[system._priority for system in systems]
    return CompiledSchedule(
        successor_offsets,
        successors,
        dependency_counts,
        Tuple(order),
        critical_path_ranks,
        names,
        priorities,
        stages,
        _compile_access_masks(systems),
        isempty(stages) ? 0 : maximum(length, stages),
    )
end

function Schedule(
    expressions::AbstractSystem...;
    name::Symbol=:schedule,
    run_if::Union{NoCondition,Condition}=NoCondition(),
)
    flat_list = System[]
    id_map = IdDict{Any,Int}()
    for expression in expressions
        extract_unique_systems!(expression, flat_list, id_map)
    end
    systems = Tuple(flat_list)
    graph = Gr.SimpleDiGraph{Int}(length(systems))
    for expression in expressions
        build_edges!(expression, graph, id_map)
    end
    _validate_acyclic(graph)
    for first_id in 1:length(systems), second_id in (first_id + 1):length(systems)
        if conflicts(systems[first_id], systems[second_id]) &&
           !Gr.has_path(graph, first_id, second_id) &&
           !Gr.has_path(graph, second_id, first_id)
            Gr.add_edge!(graph, first_id, second_id)
        end
    end
    _validate_acyclic(graph)
    plan = _compile_plan(systems, graph)
    return Schedule(systems, plan, name, run_if)
end

function get_execution_order(schedule::Schedule)
    return [[schedule._systems[id] for id in stage] for stage in schedule._plan.stages]
end

mutable struct ScheduleBuilder
    systems::Vector{AbstractSystem}
    name::Symbol
    run_if::Union{NoCondition,Condition}
end

ScheduleBuilder(; name::Symbol=:schedule, run_if::Union{NoCondition,Condition}=NoCondition()) =
    ScheduleBuilder(AbstractSystem[], name, run_if)

function add_system!(builder::ScheduleBuilder, expression::AbstractSystem)
    push!(builder.systems, expression)
    return builder
end

compile_schedule(builder::ScheduleBuilder) =
    Schedule(builder.systems...; name=builder.name, run_if=builder.run_if)

function _system_id(schedule::Schedule, name::Symbol)
    id = findfirst(==(name), schedule._plan.names)
    id === nothing && throw(KeyError(name))
    return id
end

function explain_conflict(schedule::Schedule, first_name::Symbol, second_name::Symbol)
    first_id = _system_id(schedule, first_name)
    second_id = _system_id(schedule, second_name)
    first_reads, first_writes, first_world = _system_accesses(typeof(schedule._systems[first_id]))
    second_reads, second_writes, second_world = _system_accesses(typeof(schedule._systems[second_id]))
    shared = unique(DataType[
        intersect(first_writes, second_reads)...,
        intersect(first_writes, second_writes)...,
        intersect(first_reads, second_writes)...,
    ])
    return (
        conflicts=first_world || second_world || !isempty(shared),
        world=first_world || second_world,
        accesses=shared,
    )
end


function schedule_report(schedule::Schedule)
    plan = schedule._plan
    return (
        name=schedule._name,
        systems=length(schedule._systems),
        edges=length(plan.successors),
        stages=length(plan.stages),
        max_width=plan.max_width,
        names=copy(plan.names),
        critical_path=isempty(plan.critical_path_ranks) ? 0 : maximum(plan.critical_path_ranks),
    )
end

function to_dot(schedule::Schedule)
    io = IOBuffer()
    write_dot(io, schedule)
    return String(take!(io))
end

function write_dot(io::IO, schedule::Schedule)
    plan = schedule._plan
    println(io, "digraph \"", Base.escape_string(String(schedule._name)), "\" {")
    for (id, name) in enumerate(plan.names)
        println(io, "  n", id, " [label=\"", Base.escape_string(String(name)), "\"];")
    end
    for source in eachindex(schedule._systems)
        for index in plan.successor_offsets[source]:(plan.successor_offsets[source + 1] - 1)
            println(io, "  n", source, " -> n", plan.successors[index], ";")
        end
    end
    println(io, "}")
    return io
end
