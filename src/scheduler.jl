abstract type AbstractExecutor end

"""
    SerialExecutor()

An executor that runs each ready system serially in deterministic topological
and priority order.
"""
struct SerialExecutor <: AbstractExecutor end

"""
    TimingRecorder([capacity=0])

Reusable storage for per-system start time, stop time, thread, and run status.
Wrap an executor with [`TracingExecutor`](@ref), execute a schedule, and call
[`timing_report`](@ref) to obtain named records.
"""
mutable struct TimingRecorder
    starts::Vector{UInt64}
    stops::Vector{UInt64}
    threads::Vector{Int}
    ran::Vector{Bool}
end

TimingRecorder(capacity::Integer=0) = TimingRecorder(
    zeros(UInt64, capacity),
    zeros(UInt64, capacity),
    zeros(Int, capacity),
    fill(false, capacity),
)

function _prepare!(recorder::TimingRecorder, count::Int)
    resize!(recorder.starts, count)
    resize!(recorder.stops, count)
    resize!(recorder.threads, count)
    resize!(recorder.ran, count)
    fill!(recorder.starts, 0)
    fill!(recorder.stops, 0)
    fill!(recorder.threads, 0)
    fill!(recorder.ran, false)
    return recorder
end

"""
    timing_report(recorder, schedule)

Return one timing record per system from the most recent traced execution.
Each record contains `name`, `nanoseconds`, `thread`, and `ran`.
"""
function timing_report(recorder::TimingRecorder, schedule::Schedule)
    return [(
        name=schedule._plan.names[id],
        nanoseconds=Int(recorder.stops[id] - recorder.starts[id]),
        thread=recorder.threads[id],
        ran=recorder.ran[id],
    ) for id in eachindex(schedule._systems)]
end

"""
    ThreadedExecutor(; pool=:default, workers=Threads.threadpoolsize(pool))

A reusable worker pool that releases systems when their own dependencies
finish. Call `Helm.close!` when the executor is not owned by a [`Scheduler`](@ref).
The chosen Julia thread pool must have at least `workers` threads.
"""
mutable struct ThreadedExecutor <: AbstractExecutor
    pool::Symbol
    workers::Int
    lock::ReentrantLock
    work_available::Threads.Condition
    execution_done::Threads.Condition
    worker_tasks::Vector{Task}
    dependency_counts::Vector{Int}
    ready::Vector{Int}
    successor_offsets::Vector{Int}
    successors::Vector{Int}
    contexts::Dict{DataType,Any}
    ready_head::Int
    remaining::Int
    active_workers::Int
    context::Any
    exceptions::Vector{Any}
    running::Bool
    cancelled::Threads.Atomic{Bool}
    drain_ready::Bool
    closed::Bool
end

function ThreadedExecutor(; pool::Symbol=:default, workers::Union{Nothing,Integer}=nothing)
    pool in (:default, :interactive) ||
        throw(ArgumentError("thread pool must be :default or :interactive"))
    available = Threads.threadpoolsize(pool)
    workers === nothing && (workers = available)
    workers > 0 || throw(ArgumentError("worker count must be positive"))
    workers <= available || throw(ArgumentError(
        "requested $workers workers from pool $pool, but only $available threads are available"
    ))
    lock = ReentrantLock()
    executor = ThreadedExecutor(
        pool,
        Int(workers),
        lock,
        Threads.Condition(lock),
        Threads.Condition(lock),
        Task[],
        Int[],
        Int[],
        Int[],
        Int[],
        Dict{DataType,Any}(),
        1,
        0,
        0,
        nothing,
        Any[],
        false,
        Threads.Atomic{Bool}(false),
        false,
        false,
    )
    sizehint!(executor.worker_tasks, executor.workers)
    for _ in 1:executor.workers
        task = if pool === :interactive
            Threads.@spawn :interactive _worker_loop!(executor)
        else
            Threads.@spawn :default _worker_loop!(executor)
        end
        push!(executor.worker_tasks, task)
    end
    return executor
end

"""
    AutoExecutor(; pool=:default, workers=nothing, min_parallel_systems=nothing)

A conservative executor that remains serial unless `min_parallel_systems` is
provided and a schedule has enough systems and parallel width. Supply a
threshold measured for the application; there is no generally sound static
crossover point.
"""
struct AutoExecutor{T<:Union{Nothing,ThreadedExecutor}} <: AbstractExecutor
    serial::SerialExecutor
    threaded::T
    min_parallel_systems::Int
end

function AutoExecutor(
    ; pool::Symbol=:default,
    workers::Union{Nothing,Integer}=nothing,
    min_parallel_systems::Union{Nothing,Integer}=nothing,
)
    pool in (:default, :interactive) ||
        throw(ArgumentError("thread pool must be :default or :interactive"))
    available = Threads.threadpoolsize(pool)
    workers === nothing && (workers = available)
    workers > 0 || throw(ArgumentError("worker count must be positive"))
    workers <= available || throw(ArgumentError(
        "requested $workers workers from pool $pool, but only $available threads are available"
    ))
    if min_parallel_systems === nothing
        # There is no sound static crossover for arbitrary user systems. Stay
        # serial until the application supplies a measured threshold.
        return AutoExecutor(SerialExecutor(), nothing, typemax(Int))
    end
    min_parallel_systems > 0 ||
        throw(ArgumentError("min_parallel_systems must be positive"))
    threaded = available > 1 ? ThreadedExecutor(; pool=pool, workers=workers) : nothing
    return AutoExecutor(SerialExecutor(), threaded, Int(min_parallel_systems))
end

"""
    TracingExecutor(executor, recorder)

Decorate an executor so each schedule execution populates `recorder` with
per-system timing data.
"""
struct TracingExecutor{E<:AbstractExecutor,R<:TimingRecorder} <: AbstractExecutor
    executor::E
    recorder::R
end

mutable struct ExecutionContext{S,W}
    schedule::S
    world::W
end

mutable struct TracedExecutionContext{S,W,R}
    schedule::S
    world::W
    recorder::R
end

function _execution_context!(
    executor::ThreadedExecutor,
    schedule::S,
    world::W,
    ::Nothing,
) where {S,W}
    context_type = ExecutionContext{S,W}
    context = get(executor.contexts, context_type, nothing)
    if context isa ExecutionContext{S,W}
        context.schedule = schedule
        context.world = world
        executor.context = context
        return context
    end
    context = ExecutionContext(schedule, world)
    executor.contexts[context_type] = context
    executor.context = context
    return context
end

function _execution_context!(
    executor::ThreadedExecutor,
    schedule::S,
    world::W,
    recorder::R,
) where {S,W,R<:TimingRecorder}
    context_type = TracedExecutionContext{S,W,R}
    context = get(executor.contexts, context_type, nothing)
    if context isa TracedExecutionContext{S,W,R}
        context.schedule = schedule
        context.world = world
        context.recorder = recorder
        executor.context = context
        return context
    end
    context = TracedExecutionContext(schedule, world, recorder)
    executor.contexts[context_type] = context
    executor.context = context
    return context
end

@generated function _run_schedule_node!(
    schedule::Schedule{N},
    world::Ark.World,
    id::Int,
) where {N}
    calls = [:(id == $index &&
               return _run_system!(getfield(schedule._systems, $index), world))
             for index in 1:N]
    return quote
        $(calls...)
        throw(BoundsError(schedule._systems, id))
    end
end

@inline function _run_context_node!(context::ExecutionContext, id::Int)
    return _run_schedule_node!(context.schedule, context.world, id)
end

@inline function _run_context_node!(context::TracedExecutionContext, id::Int)
    recorder = context.recorder
    recorder.threads[id] = Threads.threadid()
    recorder.starts[id] = time_ns()
    try
        recorder.ran[id] = _run_schedule_node!(context.schedule, context.world, id)
        return recorder.ran[id]
    finally
        recorder.stops[id] = time_ns()
    end
end

function _worker_loop!(executor::ThreadedExecutor)
    while true
        lock(executor.lock)
        while !executor.closed &&
              (!executor.running || executor.ready_head > length(executor.ready) ||
               (executor.cancelled[] && !executor.drain_ready))
            wait(executor.work_available)
        end
        if executor.closed
            unlock(executor.lock)
            return nothing
        end
        id = executor.ready[executor.ready_head]
        executor.ready_head += 1
        executor.active_workers += 1
        context = executor.context
        unlock(executor.lock)

        failure = nothing
        try
            # Workers outlive schedules and may therefore execute callable
            # methods defined after the worker task's world age. Crossing the
            # boundary here is required for reusable executors.
            Base.invokelatest(_run_context_node!, context, id)
        catch exception
            failure = (exception, catch_backtrace())
        end

        lock(executor.lock)
        executor.active_workers -= 1
        if failure === nothing && !executor.cancelled[]
            first_index = executor.successor_offsets[id]
            last_index = executor.successor_offsets[id + 1] - 1
            for index in first_index:last_index
                successor = executor.successors[index]
                executor.dependency_counts[successor] -= 1
                executor.dependency_counts[successor] == 0 && push!(executor.ready, successor)
            end
            executor.remaining -= 1
            executor.ready_head <= length(executor.ready) &&
                notify(executor.work_available; all=true)
        elseif failure !== nothing
            push!(executor.exceptions, failure)
            executor.cancelled[] = true
            executor.drain_ready = true
            # Jobs which were already ready are siblings, not dependants of
            # the failed node. Drain them to match `@sync` semantics while
            # suppressing all further successor release.
            notify(executor.work_available; all=true)
        end
        if executor.remaining == 0 ||
           (executor.cancelled[] && executor.active_workers == 0 &&
            executor.ready_head > length(executor.ready))
            notify(executor.execution_done; all=true)
        end
        unlock(executor.lock)
    end
end

function _execute_serial!(schedule::Schedule, world::Ark.World)
    _criterion_passes(schedule._run_if, world) || return nothing
    for id in schedule._plan.topological_order
        _run_schedule_node!(schedule, world, id)
    end
    return nothing
end

function _execute_serial!(schedule::Schedule, world::Ark.World, recorder::TimingRecorder)
    _prepare!(recorder, length(schedule._systems))
    _criterion_passes(schedule._run_if, world) || return nothing
    context = TracedExecutionContext(schedule, world, recorder)
    for id in schedule._plan.topological_order
        _run_context_node!(context, id)
    end
    return nothing
end

function _execute_threaded!(
    executor::ThreadedExecutor,
    schedule::Schedule,
    world::Ark.World,
    recorder::Union{Nothing,TimingRecorder}=nothing,
)
    lock(executor.lock)
    if executor.closed
        unlock(executor.lock)
        throw(ArgumentError("threaded executor is closed"))
    elseif executor.running
        unlock(executor.lock)
        throw(ArgumentError("threaded executor execution is non-reentrant"))
    end
    executor.running = true
    executor.cancelled[] = false
    executor.drain_ready = false
    empty!(executor.exceptions)
    unlock(executor.lock)

    try
        node_count = length(schedule._systems)
        recorder === nothing || _prepare!(recorder, node_count)
        _criterion_passes(schedule._run_if, world) || return nothing
        executor.cancelled[] && return nothing
        node_count == 0 && return nothing
        context = _execution_context!(executor, schedule, world, recorder)
        if executor.workers == 1 || schedule._plan.max_width <= 1
            return _execute_serial_without_phase_condition!(executor, context)
        end

        failures = nothing
        lock(executor.lock)
        try
            resize!(executor.dependency_counts, node_count)
            copyto!(executor.dependency_counts, schedule._plan.dependency_counts)
            empty!(executor.ready)
            for id in schedule._plan.topological_order
                executor.dependency_counts[id] == 0 && push!(executor.ready, id)
            end
            executor.ready_head = 1
            executor.remaining = node_count
            executor.active_workers = 0
            executor.context = context
            executor.successor_offsets = schedule._plan.successor_offsets
            executor.successors = schedule._plan.successors
            if executor.cancelled[] && !executor.drain_ready
                # Cancellation may race with the unlocked condition-to-queue
                # transition. Retire the newly published queue before workers
                # or the completion wait can observe it.
                executor.ready_head = length(executor.ready) + 1
            else
                notify(executor.work_available; all=true)
            end
            while executor.remaining != 0 &&
                  !(executor.cancelled[] && executor.active_workers == 0 &&
                    executor.ready_head > length(executor.ready))
                wait(executor.execution_done)
            end
            if !isempty(executor.exceptions)
                failures = Any[CapturedException(exception, backtrace) for
                               (exception, backtrace) in executor.exceptions]
            end
        finally
            unlock(executor.lock)
        end
        failures === nothing || throw(CompositeException(failures))
    finally
        lock(executor.lock)
        try
            executor.running = false
            executor.cancelled[] = false
            executor.drain_ready = false
        finally
            unlock(executor.lock)
        end
    end
    return nothing
end

function _execute_serial_without_phase_condition!(executor, context)
    for id in context.schedule._plan.topological_order
        executor.cancelled[] && return nothing
        _run_context_node!(context, id)
    end
    return nothing
end

"""
    execute!(executor, schedule, world)
    execute!(schedule, world[, executor])

Execute `schedule` against `world`. Explicit executors can be reused across
frames. The two-argument convenience form creates and closes an executor for
that call.
"""
execute!(::SerialExecutor, schedule::Schedule, world::Ark.World) =
    _execute_serial!(schedule, world)

execute!(executor::ThreadedExecutor, schedule::Schedule, world::Ark.World) =
    _execute_threaded!(executor, schedule, world)

function execute!(executor::AutoExecutor, schedule::Schedule, world::Ark.World)
    if executor.threaded !== nothing &&
       schedule._plan.max_width > 1 &&
       length(schedule._systems) >= executor.min_parallel_systems
        return _execute_threaded!(executor.threaded, schedule, world)
    end
    return _execute_serial!(schedule, world)
end

function execute!(tracing::TracingExecutor{<:SerialExecutor}, schedule::Schedule, world::Ark.World)
    return _execute_serial!(schedule, world, tracing.recorder)
end

function execute!(tracing::TracingExecutor{<:ThreadedExecutor}, schedule::Schedule, world::Ark.World)
    return _execute_threaded!(tracing.executor, schedule, world, tracing.recorder)
end

function execute!(tracing::TracingExecutor{<:AutoExecutor}, schedule::Schedule, world::Ark.World)
    executor = tracing.executor
    if executor.threaded !== nothing &&
       schedule._plan.max_width > 1 &&
       length(schedule._systems) >= executor.min_parallel_systems
        return _execute_threaded!(executor.threaded, schedule, world, tracing.recorder)
    end
    return _execute_serial!(schedule, world, tracing.recorder)
end

execute!(schedule::Schedule, world::Ark.World, executor::AbstractExecutor) =
    execute!(executor, schedule, world)

function execute!(schedule::Schedule, world::Ark.World)
    # Preserve the historical parallel behavior of this convenience API.
    # Performance-sensitive loops should own and reuse an explicit executor.
    executor = Threads.threadpoolsize(:default) > 1 && schedule._plan.max_width > 1 ?
        ThreadedExecutor() : SerialExecutor()
    try
        return execute!(executor, schedule, world)
    finally
        close!(executor)
    end
end

"""
    cancel!(executor::ThreadedExecutor) -> Bool

Request cancellation of a running threaded execution. Return `true` when an
execution was active, or `false` otherwise. Already-running systems are not
interrupted.
"""
function cancel!(executor::ThreadedExecutor)
    lock(executor.lock)
    try
        executor.running || return false
        executor.cancelled[] = true
        if isempty(executor.exceptions)
            executor.drain_ready = false
            executor.ready_head = length(executor.ready) + 1
        end
        notify(executor.execution_done; all=true)
        notify(executor.work_available; all=true)
        return true
    finally
        unlock(executor.lock)
    end
end

"""
    Helm.close!(executor)
    Helm.close!(scheduler)

Release worker tasks and other resources owned by an executor or scheduler.
Closing is idempotent, but a threaded executor or scheduler cannot be closed
while it is running. [`shutdown!`](@ref) closes its scheduler automatically.
"""
close!(::SerialExecutor) = nothing
close!(::Nothing) = nothing

function close!(executor::ThreadedExecutor)
    lock(executor.lock)
    if executor.running
        unlock(executor.lock)
        throw(ArgumentError("cannot close a threaded executor while it is running"))
    end
    if executor.closed
        unlock(executor.lock)
        return nothing
    end
    executor.closed = true
    executor.context = nothing
    empty!(executor.contexts)
    notify(executor.work_available; all=true)
    unlock(executor.lock)
    foreach(wait, executor.worker_tasks)
    return nothing
end

close!(executor::AutoExecutor) = close!(executor.threaded)
close!(executor::TracingExecutor) = close!(executor.executor)

"""
    Scheduler(; startup, update, fixed_update, shutdown, phases, executor)
    Scheduler(phases::NamedTuple; executor=AutoExecutor())

A named phase coordinator. The keyword constructor provides conventional
`:startup`, `:update`, `:fixed_update`, and `:shutdown` phases and accepts
additional schedules in `phases`. A scheduler owns its executor and closes it
after [`shutdown!`](@ref).
"""
mutable struct Scheduler{P<:NamedTuple,E<:AbstractExecutor}
    _phases::P
    _executor::E
    _running::Threads.Atomic{Bool}
    _closed::Bool
end

function Scheduler(
    ; startup::Schedule=Schedule(; name=:startup),
    update::Schedule=Schedule(; name=:update),
    fixed_update::Schedule=Schedule(; name=:fixed_update),
    shutdown::Schedule=Schedule(; name=:shutdown),
    phases::NamedTuple=NamedTuple(),
    executor::AbstractExecutor=AutoExecutor(),
)
    conventional = (; startup, update, fixed_update, shutdown)
    overlap = intersect(keys(conventional), keys(phases))
    isempty(overlap) || throw(ArgumentError("duplicate scheduler phases: $(join(overlap, ", "))"))
    return Scheduler(
        merge(conventional, phases),
        executor,
        Threads.Atomic{Bool}(false),
        false,
    )
end

Scheduler(phases::NamedTuple; executor::AbstractExecutor=AutoExecutor()) =
    Scheduler(phases, executor, Threads.Atomic{Bool}(false), false)

@inline _phase(phases::NamedTuple, ::Val{name}) where {name} = getproperty(phases, name)

function execute!(scheduler::Scheduler, phase::Val, world::Ark.World)
    Threads.atomic_cas!(scheduler._running, false, true) == false ||
        throw(ArgumentError("scheduler execution is non-reentrant"))
    try
        scheduler._closed && throw(ArgumentError("scheduler is closed"))
        schedule = _phase(scheduler._phases, phase)
        return execute!(scheduler._executor, schedule, world)
    finally
        scheduler._running[] = false
    end
end

execute!(scheduler::Scheduler, phase::Symbol, world::Ark.World) =
    execute!(scheduler, Val(phase), world)
execute!(scheduler::Scheduler, world::Ark.World, phase::Union{Val,Symbol}) =
    execute!(scheduler, phase, world)

"""Execute the scheduler's `:startup` phase."""
startup!(scheduler::Scheduler, world::Ark.World) = execute!(scheduler, Val(:startup), world)

"""Execute the scheduler's `:update` phase."""
update!(scheduler::Scheduler, world::Ark.World) = execute!(scheduler, Val(:update), world)

"""Execute the scheduler's `:fixed_update` phase."""
fixed_update!(scheduler::Scheduler, world::Ark.World) =
    execute!(scheduler, Val(:fixed_update), world)

"""
    shutdown!(scheduler, world)

Execute the scheduler's `:shutdown` phase and close its owned executor, even
if the phase throws.
"""
function shutdown!(scheduler::Scheduler, world::Ark.World)
    try
        return execute!(scheduler, Val(:shutdown), world)
    finally
        close!(scheduler)
    end
end

"""
    enable!(scheduler, phase, system_name)

Enable a named system while the scheduler is idle.
"""
function enable!(scheduler::Scheduler, phase::Symbol, system_name::Symbol)
    Threads.atomic_cas!(scheduler._running, false, true) == false ||
        throw(ArgumentError("scheduler mutation is only allowed while idle"))
    try
        schedule = _phase(scheduler._phases, Val(phase))
        _enable_system!(schedule._systems[_system_id(schedule, system_name)])
    finally
        scheduler._running[] = false
    end
    return scheduler
end

"""
    disable!(scheduler, phase, system_name)

Disable a named system while the scheduler is idle. Its dependants remain
eligible to run.
"""
function disable!(scheduler::Scheduler, phase::Symbol, system_name::Symbol)
    Threads.atomic_cas!(scheduler._running, false, true) == false ||
        throw(ArgumentError("scheduler mutation is only allowed while idle"))
    try
        schedule = _phase(scheduler._phases, Val(phase))
        _disable_system!(schedule._systems[_system_id(schedule, system_name)])
    finally
        scheduler._running[] = false
    end
    return scheduler
end

function close!(scheduler::Scheduler)
    Threads.atomic_cas!(scheduler._running, false, true) == false ||
        throw(ArgumentError("cannot close a scheduler while it is running"))
    try
        scheduler._closed && return nothing
        close!(scheduler._executor)
        scheduler._closed = true
    finally
        scheduler._running[] = false
    end
    return nothing
end
