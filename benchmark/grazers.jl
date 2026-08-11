# Run from the repository root with:
#   julia --threads=auto --project=examples benchmark/grazers.jl
#
# GRAZERS_COUNT, GRAZERS_WIDTH, GRAZERS_HEIGHT, GRAZERS_FRAMES,
# GRAZERS_SAMPLES, GRAZERS_WORKERS, and GRAZERS_SEED override the defaults below.
# The compatibility case intentionally creates an executor per frame, matching
# the examples before they adopted a reusable Scheduler.

using BenchmarkTools
import Helm
using Printf

module OriginalGrazersBenchmark

include(joinpath(@__DIR__, "..", "examples", "grazers-original", "core.jl"))

function make_case(count::Int, width::Int, height::Int, seed::Int)
    world = create_original_grazers_world(
        width=width,
        height=height,
        seed=seed,
    )
    scheduler = create_original_grazers_scheduler(world; count=count)
    initialize!(scheduler)
    return scheduler
end

function run_frames!(scheduler::OriginalGrazersScheduler, frames::Int)
    for _ in 1:frames
        update!(scheduler)
    end
    return nothing
end

function state_summary(scheduler::OriginalGrazersScheduler)
    world = scheduler.world
    entity_count = 0
    total_energy = 0.0
    for (entities, energies) in Query(world, (Energy,))
        entity_count += length(entities)
        total_energy += sum(energy.value for energy in energies; init=0.0)
    end
    return (
        entity_count=entity_count,
        total_energy=total_energy,
        total_grass=sum(get_resource(world, GrassGrid).grass),
        tick=get_resource(world, Tick).tick,
    )
end

end


module HelmGrazersBenchmark

using Helm

include(joinpath(@__DIR__, "..", "examples", "grazers", "core.jl"))

struct BenchmarkCase{W,S,O}
    world::W
    schedule::S
    execution_order::O
end

struct SchedulerCase{W,S}
    world::W
    scheduler::S
end

function make_case(count::Int, width::Int, height::Int, seed::Int)
    world = create_grazers_world(
        width=width,
        height=height,
        count=count,
        seed=seed,
    )
    Helm.execute!(Helm.SerialExecutor(), grazers_startup_schedule(), world)
    schedule = grazers_update_schedule()
    return BenchmarkCase(world, schedule, Helm.get_execution_order(schedule))
end

function make_scheduler_case(
    count::Int,
    width::Int,
    height::Int,
    seed::Int,
    executor,
)
    world = create_grazers_world(
        width=width,
        height=height,
        count=count,
        seed=seed,
    )
    scheduler = Helm.Scheduler(
        startup=grazers_startup_schedule(),
        update=grazers_update_schedule(),
        executor=executor,
    )
    Helm.startup!(scheduler, world)
    return SchedulerCase(world, scheduler)
end

function run_compatibility_frames!(case::BenchmarkCase, frames::Int)
    for _ in 1:frames
        Helm.execute!(case.schedule, case.world)
    end
    return nothing
end

function run_scheduler_frames!(case::SchedulerCase, frames::Int)
    for _ in 1:frames
        Helm.update!(case.scheduler, case.world)
    end
    return nothing
end

function close!(case::SchedulerCase)
    Helm.shutdown!(case.scheduler, case.world)
    return nothing
end

function run_serial_frames!(case::BenchmarkCase, frames::Int)
    for _ in 1:frames
        for stage in case.execution_order
            for system in stage
                system(case.world)
            end
        end
    end
    return nothing
end

function state_summary(world)
    entity_count = 0
    total_energy = 0.0
    for (entities, energies) in Ark.Query(world, (Energy,))
        entity_count += length(entities)
        total_energy += sum(energy.value for energy in energies; init=0.0)
    end
    return (
        entity_count=entity_count,
        total_energy=total_energy,
        total_grass=sum(Ark.get_resource(world, GrassGrid).grass),
        tick=Ark.get_resource(world, Tick).tick,
    )
end

state_summary(case::Union{BenchmarkCase,SchedulerCase}) = state_summary(case.world)

end


function positive_env_int(name::String, default::Int)
    value = parse(Int, get(ENV, name, string(default)))
    value > 0 || throw(ArgumentError("$name must be greater than zero"))
    return value
end

function median_frame_ns(trial, frames::Int)
    return BenchmarkTools.median(trial).time / frames
end

function print_frame_time(label::String, nanoseconds::Real)
    @printf "  %-24s %8.3f ms\n" label nanoseconds / 1e6
end

function benchmark_grazers()
    count = positive_env_int("GRAZERS_COUNT", 1000)
    width = positive_env_int("GRAZERS_WIDTH", 120)
    height = positive_env_int("GRAZERS_HEIGHT", 100)
    frames = positive_env_int("GRAZERS_FRAMES", 20)
    samples = positive_env_int("GRAZERS_SAMPLES", 20)
    workers = positive_env_int("GRAZERS_WORKERS", Threads.threadpoolsize(:default))
    workers <= Threads.threadpoolsize(:default) || error(
        "GRAZERS_WORKERS exceeds the available default-pool thread count",
    )
    seed = parse(Int, get(ENV, "GRAZERS_SEED", "1234"))

    # Compile each path before BenchmarkTools begins collecting samples.
    original_warmup = OriginalGrazersBenchmark.make_case(count, width, height, seed)
    OriginalGrazersBenchmark.run_frames!(original_warmup, frames)
    serial_warmup = HelmGrazersBenchmark.make_case(count, width, height, seed)
    HelmGrazersBenchmark.run_serial_frames!(serial_warmup, frames)
    compatibility_warmup = HelmGrazersBenchmark.make_case(count, width, height, seed)
    HelmGrazersBenchmark.run_compatibility_frames!(compatibility_warmup, frames)
    scheduler_auto_warmup = HelmGrazersBenchmark.make_scheduler_case(
        count,
        width,
        height,
        seed,
        Helm.AutoExecutor(),
    )
    HelmGrazersBenchmark.run_scheduler_frames!(scheduler_auto_warmup, frames)
    scheduler_threaded_warmup = HelmGrazersBenchmark.make_scheduler_case(
        count,
        width,
        height,
        seed,
        Helm.ThreadedExecutor(workers=workers),
    )
    HelmGrazersBenchmark.run_scheduler_frames!(scheduler_threaded_warmup, frames)

    original_summary = OriginalGrazersBenchmark.state_summary(original_warmup)
    serial_summary = HelmGrazersBenchmark.state_summary(serial_warmup)
    compatibility_summary = HelmGrazersBenchmark.state_summary(compatibility_warmup)
    scheduler_auto_summary = HelmGrazersBenchmark.state_summary(scheduler_auto_warmup)
    scheduler_threaded_summary = HelmGrazersBenchmark.state_summary(scheduler_threaded_warmup)
    for summary in (
        serial_summary,
        compatibility_summary,
        scheduler_auto_summary,
        scheduler_threaded_summary,
    )
        summary.entity_count == original_summary.entity_count ||
            error("grazers implementations produced different entity counts during validation")
        summary.tick == original_summary.tick ||
            error("grazers implementations advanced time differently during validation")
        isapprox(summary.total_energy, original_summary.total_energy; rtol=1e-12) ||
            error("grazers implementations produced different total energy during validation")
        isapprox(summary.total_grass, original_summary.total_grass; rtol=1e-12) ||
            error("grazers implementations produced different grass state during validation")
    end
    HelmGrazersBenchmark.close!(scheduler_auto_warmup)
    HelmGrazersBenchmark.close!(scheduler_threaded_warmup)

    stages = map(length, compatibility_warmup.execution_order)
    println("Grazers benchmark")
    println("  grazers: $count")
    println("  grass grid: $(width)x$(height)")
    println("  frames per sample: $frames")
    println("  samples: $samples")
    println("  Julia threads: $(Threads.nthreads())")
    println("  scheduler workers: $workers")
    println("  Helm stage widths: $stages")
    println("  full-batch state validation: passed")

    original = @benchmark OriginalGrazersBenchmark.run_frames!(case, $frames) setup = (
        case = OriginalGrazersBenchmark.make_case($count, $width, $height, $seed)
    ) evals = 1 samples = samples

    helm_serial = @benchmark HelmGrazersBenchmark.run_serial_frames!(case, $frames) setup = (
        case = HelmGrazersBenchmark.make_case($count, $width, $height, $seed)
    ) evals = 1 samples = samples

    helm_compatibility = @benchmark HelmGrazersBenchmark.run_compatibility_frames!(case, $frames) setup = (
        case = HelmGrazersBenchmark.make_case($count, $width, $height, $seed)
    ) evals = 1 samples = samples

    scheduler_auto = @benchmark HelmGrazersBenchmark.run_scheduler_frames!(case, $frames) setup = (
        case = HelmGrazersBenchmark.make_scheduler_case(
            $count,
            $width,
            $height,
            $seed,
            Helm.AutoExecutor(),
        )
    ) teardown = (HelmGrazersBenchmark.close!(case)) evals = 1 samples = samples

    scheduler_threaded = @benchmark HelmGrazersBenchmark.run_scheduler_frames!(case, $frames) setup = (
        case = HelmGrazersBenchmark.make_scheduler_case(
            $count,
            $width,
            $height,
            $seed,
            Helm.ThreadedExecutor(workers=$workers),
        )
    ) teardown = (HelmGrazersBenchmark.close!(case)) evals = 1 samples = samples

    original_ns = median_frame_ns(original, frames)
    helm_serial_ns = median_frame_ns(helm_serial, frames)
    helm_compatibility_ns = median_frame_ns(helm_compatibility, frames)
    scheduler_auto_ns = median_frame_ns(scheduler_auto, frames)
    scheduler_threaded_ns = median_frame_ns(scheduler_threaded, frames)

    println("\ngrazers-original (sequential)")
    display(original)
    println("\ngrazers Helm (forced serial)")
    display(helm_serial)
    println("\ngrazers Helm (compatibility execute!)")
    display(helm_compatibility)
    println("\ngrazers Helm (Scheduler + AutoExecutor, serial policy)")
    display(scheduler_auto)
    println("\ngrazers Helm (Scheduler + persistent ThreadedExecutor)")
    display(scheduler_threaded)

    println("\nMedian per frame")
    print_frame_time("original", original_ns)
    print_frame_time("Helm serial", helm_serial_ns)
    print_frame_time("Helm compatibility", helm_compatibility_ns)
    print_frame_time("Scheduler auto", scheduler_auto_ns)
    print_frame_time("Scheduler threaded", scheduler_threaded_ns)
    @printf "Compatibility / new Scheduler:      %.3fx\n" helm_compatibility_ns / scheduler_auto_ns
    @printf "Compatibility / persistent threads: %.3fx\n" helm_compatibility_ns / scheduler_threaded_ns
    @printf "Scheduler auto / threaded:          %.3fx\n" scheduler_auto_ns / scheduler_threaded_ns
    @printf "Original / Scheduler auto:          %.3fx\n" original_ns / scheduler_auto_ns
    return (; original, helm_serial, helm_compatibility, scheduler_auto, scheduler_threaded)
end

benchmark_grazers()
