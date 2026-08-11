# Run from the repository root with:
#   julia --threads=auto --project=examples benchmark/scheduler.jl
#
# SCHEDULER_SAMPLES overrides the default sample count.

using Ark
using BenchmarkTools
using Helm
using Printf

const BENCHMARK_WORLD = Ark.World()
const BENCHMARK_SINK = Threads.Atomic{Int}(0)

named_noop(name::Symbol) = System(() -> nothing; name=name)

function work_system(name::Symbol, iterations::Int)
    return System(; name=name) do
        value = 0
        @inbounds for index in 1:iterations
            value = xor(value, index)
        end
        Threads.atomic_xchg!(BENCHMARK_SINK, value)
        return nothing
    end
end

function scheduler_cases()
    singleton = named_noop(:singleton)
    chain_nodes = ntuple(index -> named_noop(Symbol(:chain_, index)), 8)
    wide_nodes = ntuple(index -> named_noop(Symbol(:wide_, index)), 8)

    root = named_noop(:diamond_root)
    left = named_noop(:diamond_left)
    right = named_noop(:diamond_right)
    sink = named_noop(:diamond_sink)
    diamond = Schedule(
        before(root, left),
        before(root, right),
        before(left, sink),
        before(right, sink);
        name=:diamond,
    )

    slow = work_system(:slow, 10_000)
    fast = named_noop(:fast)
    successor = named_noop(:fast_successor)

    return (
        empty=Schedule(; name=:empty),
        singleton=Schedule(singleton; name=:singleton),
        chain=Schedule(chain(chain_nodes...); name=:chain),
        wide=Schedule(wide_nodes...; name=:wide),
        diamond=diamond,
        imbalanced=Schedule(slow, before(fast, successor); name=:imbalanced),
    )
end

function run_scheduler_benchmarks()
    samples = parse(Int, get(ENV, "SCHEDULER_SAMPLES", "1000"))
    samples > 0 || throw(ArgumentError("SCHEDULER_SAMPLES must be positive"))
    cases = scheduler_cases()
    serial = SerialExecutor()
    threaded = Threads.nthreads() > 1 ?
        ThreadedExecutor(workers=Threads.nthreads()) : nothing

    @printf "%-12s %12s %12s %12s\n" "case" "executor" "median ns" "memory B"
    try
        for (name, schedule) in pairs(cases)
            execute!(serial, schedule, BENCHMARK_WORLD)
            benchmark = @benchmarkable execute!($serial, $schedule, $BENCHMARK_WORLD) evals=1
            trial = run(benchmark; samples=samples)
            estimate = BenchmarkTools.median(trial)
            @printf "%-12s %12s %12.1f %12d\n" name "serial" estimate.time estimate.memory

            threaded === nothing && continue
            execute!(threaded, schedule, BENCHMARK_WORLD)
            benchmark = @benchmarkable execute!($threaded, $schedule, $BENCHMARK_WORLD) evals=1
            trial = run(benchmark; samples=samples)
            estimate = BenchmarkTools.median(trial)
            @printf "%-12s %12s %12.1f %12d\n" name "threaded" estimate.time estimate.memory
        end
    finally
        threaded === nothing || Helm.close!(threaded)
    end
    return nothing
end

run_scheduler_benchmarks()
