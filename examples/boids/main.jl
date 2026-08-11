using Ark
using GeometryBasics
using GLMakie
using Helm: AutoExecutor, Cmds, Const, Query, Res, ResMut, Schedule, Scheduler, System
using Helm: chain, shutdown!, startup!, update!

include("util.jl")
include("components.jl")
include("resources.jl")
include("sys/mouse.jl")
include("sys/boids_init.jl")
include("sys/boids_neighbors.jl")
include("sys/boids_movement.jl")
include("sys/boids_plot.jl")

const IS_CI = haskey(ENV, "CI")

advance_tick = System(ResMut(Tick)) do tick
  tick.tick += 1
  return nothing
end

function setup_makie(world_size::WorldSize)
  GLMakie.activate!(
    framerate=60.0,
    vsync=true,
    renderloop=GLMakie.renderloop,
    render_on_demand=false,
    focus_on_show=!IS_CI,
  )
  scene = Scene(
    camera=campixel!,
    size=(world_size.width, world_size.height),
    backgroundcolor=:black,
  )
  boid_shape = Polygon(Point2f[(2, 0), (-3, 4), (-1, 0), (-3, -4)])
  data = PlotData()
  meshscatter!(
    scene,
    data.positions;
    rotation=data.rotations,
    marker=boid_shape,
    color=:white,
    markersize=1,
  )
  screen = display(scene)
  GLMakie.GLFW.SetWindowTitle(screen.glscreen, "Boids demo")
  return Window(screen, scene), data
end

function run!(world::World, scheduler::Scheduler)
  try
    startup!(scheduler, world)
    window = get_resource(world, Window)
    frame = Ref(0)
    on(window.screen.render_tick) do _
      update!(scheduler, world)
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

function main()
  size = WorldSize(1280, 720)
  window, plot_data = setup_makie(size)
  world = World(Position, Velocity, Rotation, Neighbors, UpdateStep; allow_mutable=true)

  add_resource!(world, size)
  add_resource!(world, window)
  add_resource!(world, plot_data)
  add_resource!(world, Mouse(0.0, 0.0, false))
  add_resource!(world, Tick(0))
  add_resource!(world, BoidsInit(count=1000))
  add_resource!(world, BoidsNeighbors(max_distance=20))
  add_resource!(world, Grid(size.width, size.height, 20))
  add_resource!(
    world,
    BoidsMovement(
      avoid_factor=0.1,
      avoid_distance=6.0,
      cohesion_factor=0.002,
      align_factor=0.005,
      min_speed=0.5,
      max_speed=1.0,
      margin=150.0,
      margin_factor=0.1,
      mouse_radius=200.0,
      mouse_avoid_factor=1.0,
    ),
  )

  scheduler = Scheduler(
    startup=Schedule(chain(initialize_boids, install_mouse_handler); name=:startup),
    update=Schedule(
      chain(
        update_grid,
        update_neighbors,
        update_movement,
        update_rotations,
        update_plot,
        advance_tick,
      );
      name=:update,
    ),
    executor=AutoExecutor(),
  )
  return run!(world, scheduler)
end

main()
