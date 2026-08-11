include("core.jl")

function main()
    world = create_original_grazers_world()
    scheduler = create_original_grazers_scheduler(world)
    initialize!(scheduler)
    for _ in 1:240
        update!(scheduler)
    end
    return world
end

main()
