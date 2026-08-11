abstract type OriginalSystem end

initialize!(::OriginalSystem, ::World) = nothing
update!(::OriginalSystem, ::World) = nothing

mutable struct OriginalGrazersScheduler{S<:Tuple}
    world::World
    systems::S
end

function initialize!(scheduler::OriginalGrazersScheduler)
    add_resource!(scheduler.world, Tick(0))
    for system in scheduler.systems
        initialize!(system, scheduler.world)
    end
    return nothing
end

function update!(scheduler::OriginalGrazersScheduler)
    for system in scheduler.systems
        update!(system, scheduler.world)
    end
    get_resource(scheduler.world, Tick).tick += 1
    return nothing
end
