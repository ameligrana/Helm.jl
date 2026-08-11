using Helm: AutoExecutor, Scheduler

include("core.jl")
include("gui.jl")

function main()
    world = create_grazers_world()
    install_coherent_grass_terrain!(world)
    scheduler = Scheduler(
        startup=grazers_startup_schedule(),
        update=grazers_update_schedule(),
        phases=(render=grazers_render_schedule(),),
        executor=AutoExecutor(),
    )
    setup_makie!(world)
    return run_grazers!(world, scheduler)
end

main()
