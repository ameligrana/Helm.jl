struct Scheduler
    _schedules::Vector{Schedule}
end

"""
    execute!(schedule::Schedule, world::Ark.World)

Run every system in `schedule` against `world`.

Dependency stages are executed in order. Systems in the same stage run on
separate Julia tasks when multiple threads are available; the stage completes
before the next one starts. A singleton stage runs directly to avoid task
overhead. If a system throws, all tasks in its stage are joined and later
stages are not executed.
"""
function execute!(schedule::Schedule, world::Ark.World)
    for stage in schedule._execution_stages
        _execute_stage!(schedule._systems, stage, world)
    end
    return nothing
end

function _execute_stage!(systems::Tuple, stage::Vector{Int}, world::Ark.World)
    if length(stage) == 1
        systems[only(stage)](world)
    elseif Threads.nthreads() == 1
        for id in stage
            systems[id](world)
        end
    else
        Threads.@sync for id in stage
            Threads.@spawn systems[id](world)
        end
    end
    return nothing
end
