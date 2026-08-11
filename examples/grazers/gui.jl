using Colors
using CoherentNoise
using GLMakie
using GeometryBasics
using Helm: Scheduler, chain, execute!, shutdown!, startup!, update!

const IS_CI = haskey(ENV, "CI")

struct Window
    screen::GLMakie.Screen
end

mutable struct SimulationSpeed
    speed::Int
end

struct GrassRenderData
    grass::Observable{Matrix{Float64}}
end

struct GrazerRenderData
    positions::Observable{Vector{Position}}
    rotations::Observable{Vector{Float64}}
end

struct GenePlotData
    max_angle::Observable{Vector{Float64}}
    reverse_prob::Observable{Vector{Float64}}
    move_thresh::Observable{Vector{Float64}}
    graze_thresh::Observable{Vector{Float64}}
    num_offspring::Observable{Vector{Float64}}
    energy_share::Observable{Vector{Float64}}
end

GenePlotData() = GenePlotData(
    Observable(Float64[]),
    Observable(Float64[]),
    Observable(Float64[]),
    Observable(Float64[]),
    Observable(Float64[]),
    Observable(Float64[]),
)

function install_coherent_grass_terrain!(world::World)
    size = get_resource(world, WorldSize)
    settings = get_resource(world, GrassGrowth)
    grid = get_resource(world, GrassGrid)
    sampler = fbm_fractal_2d(source=opensimplex2_2d(), octaves=4)
    noise_scale = 1.0 / settings.feature_size
    for x in 1:size.width, y in 1:size.height
        capacity = clamp(sample(sampler, x * noise_scale, y * noise_scale) + 0.33, 0.01, 1.0)
        grid.capacity[x, y] = capacity
        grid.grass[x, y] = capacity
    end
    return nothing
end

function setup_makie!(world::World)
    size = get_resource(world, WorldSize)
    grid = get_resource(world, GrassGrid)
    GLMakie.activate!(
        framerate=60.0,
        vsync=true,
        renderloop=GLMakie.renderloop,
        render_on_demand=false,
        focus_on_show=!IS_CI,
    )

    pixel_size = (size.width * size.scale, size.height * size.scale)
    figure = Figure(
        figure_padding=(2, 15, 2, 2),
        size=(pixel_size[1] + 245, pixel_size[2] + 4),
        backgroundcolor=:white,
    )
    scene = LScene(
        figure[1:3, 1];
        width=pixel_size[1],
        height=pixel_size[2],
        scenekw=(camera=(campixel!), size=pixel_size, backgroundcolor=:black),
    )

    grass_data = GrassRenderData(Observable(grid.grass))
    grass_plot = heatmap!(
        scene,
        0.5:size.width,
        0.5:size.height,
        grass_data.grass;
        colormap=[RGB(0, 0, 0), RGB(0, 0.6, 0)],
        colorrange=(0, 1),
    )
    Makie.transform!(grass_plot; scale=Vec3f(size.scale, size.scale, 1))

    grazer_data = GrazerRenderData(Observable(Position[]), Observable(Float64[]))
    grazer_shape = Polygon(Point2f[(3, 0), (-5, 4), (-3, 0), (-5, -4)])
    grazer_plot = meshscatter!(
        scene,
        grazer_data.positions;
        rotation=grazer_data.rotations,
        marker=grazer_shape,
        color=:white,
        markersize=0.12,
    )
    Makie.transform!(grazer_plot; scale=Vec3f(size.scale, size.scale, 1))

    genes = GenePlotData()
    axes = (
        Axis(
            figure[1, 2];
            title="Search behavior",
            xlabel="Max angle ×90°",
            ylabel="Reverse prob. ×0.1",
            backgroundcolor=:white,
            alignmode=Outside(),
        ),
        Axis(
            figure[2, 2];
            title="Movement thresholds",
            xlabel="Threshold move (rel.)",
            ylabel="Threshold graze",
            backgroundcolor=:white,
            alignmode=Outside(),
        ),
        Axis(
            figure[3, 2];
            title="Reproduction",
            xlabel="#Offspring ×10",
            ylabel="Energy share",
            backgroundcolor=:white,
            alignmode=Outside(),
        ),
    )
    scatter!(axes[1], genes.max_angle, genes.reverse_prob; color=:green, markersize=2)
    scatter!(axes[2], genes.move_thresh, genes.graze_thresh; color=:green, markersize=2)
    scatter!(axes[3], genes.num_offspring, genes.energy_share; color=:green, markersize=2)
    for axis in axes
        xlims!(axis; low=0, high=1)
        ylims!(axis; low=0, high=1)
    end

    screen = display(figure)
    GLMakie.GLFW.SetWindowTitle(screen.glscreen, "Helm grazers demo")
    add_resource!(world, Window(screen))
    add_resource!(world, SimulationSpeed(1))
    add_resource!(world, grass_data)
    add_resource!(world, grazer_data)
    add_resource!(world, genes)
    return nothing
end

update_grass_render = System(ResMut(GrassRenderData)) do data
    notify(data.grass)
    return nothing
end

update_grazer_render = System(
    ResMut(GrazerRenderData),
    Query((Const(Position), Const(Rotation))),
) do data, query
    positions = data.positions[]
    rotations = data.rotations[]
    empty!(positions)
    empty!(rotations)
    for (_, component_positions, component_rotations) in query
        append!(positions, component_positions)
        append!(rotations, component_rotations)
    end
    notify(data.positions)
    notify(data.rotations)
    return nothing
end

update_gene_plots = System(
    Res(Tick),
    ResMut(GenePlotData),
    Query((Const(Genes),)),
) do tick, data, query
    if tick.tick % 60 != 0
        Ark.close!(query)
        return nothing
    end
    vectors = (
        data.max_angle[],
        data.reverse_prob[],
        data.move_thresh[],
        data.graze_thresh[],
        data.num_offspring[],
        data.energy_share[],
    )
    foreach(empty!, vectors)
    for (_, genes) in query
        for gene in genes
            push!(vectors[1], gene.max_angle)
            push!(vectors[2], gene.reverse_prob)
            push!(vectors[3], gene.move_thresh)
            push!(vectors[4], gene.graze_thresh)
            push!(vectors[5], gene.num_offspring)
            push!(vectors[6], gene.energy_share)
        end
    end
    notify(data.max_angle)
    notify(data.reverse_prob)
    notify(data.move_thresh)
    notify(data.graze_thresh)
    notify(data.num_offspring)
    notify(data.energy_share)
    return nothing
end

grazers_render_schedule() =
    Schedule(chain(update_grass_render, update_grazer_render, update_gene_plots))

function run_grazers!(world::World, scheduler::Scheduler)
    try
        startup!(scheduler, world)
        window = get_resource(world, Window)
        speed = get_resource(world, SimulationSpeed)
        frame = Ref(0)
        on(window.screen.render_tick) do _
            for _ in 1:speed.speed
                update!(scheduler, world)
            end
            execute!(scheduler, Val(:render), world)
            frame[] += 1
            if IS_CI && frame[] >= 240
                close(window.screen)
            end
        end
        GLMakie.start_renderloop!(window.screen)
        return wait(window.screen)
    finally
        shutdown!(scheduler, world)
    end
end
