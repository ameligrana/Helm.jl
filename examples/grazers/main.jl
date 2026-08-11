include("core.jl")
include("gui.jl")

function main()
    world = create_grazers_world()
    install_coherent_grass_terrain!(world)
    execute!(grazers_startup_schedule(), world)
    setup_makie!(world)
    return run_grazers!(world, grazers_update_schedule(), grazers_render_schedule())
end

main()
