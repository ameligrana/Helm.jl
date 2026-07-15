using Test
using Helm

# Mock components for testing
struct Comp1 end
struct Comp2 end
struct Comp3 end

# Define systems with different access patterns
sys_r1 = Helm.System(_q -> nothing, Query((Const(Comp1),)))
sys_r2 = Helm.System(_q -> nothing, Query((Const(Comp2),)))
sys_w1 = Helm.System(_q -> nothing, Query((Comp1,)))
sys_w2 = Helm.System(_q -> nothing, Query((Comp2,)))
sys_r1_r2 = Helm.System(_q -> nothing, Query((Const(Comp1), Const(Comp2))))

@testset "Parallel Scheduling" begin
  @testset "Completely Independent Systems" begin
    # r1 and r2 read different components
    s = Schedule(sys_r1, sys_r2)
    stages = get_execution_order(s)

    @test length(stages) == 1
    @test length(stages[1]) == 2
    @test sys_r1 in stages[1]
    @test sys_r2 in stages[1]
  end

  @testset "Read-Write Conflict" begin
    # w1 writes Comp1, r1 reads Comp1
    # Order should be W1 -> R1 because W1 was first in arguments
    s = Schedule(sys_w1, sys_r1)
    stages = get_execution_order(s)

    @test length(stages) == 2
    @test stages[1] == [sys_w1]
    @test stages[2] == [sys_r1]
  end

  @testset "Write-Write Conflict" begin
    # w1 writes Comp1, another system also writes Comp1
    sys_w1_alt = Helm.System(_q -> nothing, Query((Comp1,)))
    s = Schedule(sys_w1, sys_w1_alt)
    stages = get_execution_order(s)

    @test length(stages) == 2
    @test stages[1] == [sys_w1]
    @test stages[2] == [sys_w1_alt]
  end

  @testset "Mixed Parallelism" begin
    # W1 conflicts with R1
    # R2 is independent of both
    # Schedule(W1, R1, R2)
    # W1 -> R1
    # R2 has no dependencies.
    # Stage 1: [W1, R2]
    # Stage 2: [R1]
    s = Schedule(sys_w1, sys_r1, sys_r2)
    stages = get_execution_order(s)

    @test length(stages) == 2
    @test sys_w1 in stages[1]
    @test sys_r2 in stages[1]
    @test stages[2] == [sys_r1]
  end

  @testset "Explicit Dependencies with Parallelism" begin
    # R1 and R2 are independent, but we force R1 -> R2
    s = Schedule(before(sys_r1, sys_r2))
    stages = get_execution_order(s)

    @test length(stages) == 2
    @test stages[1] == [sys_r1]
    @test stages[2] == [sys_r2]
  end

  @testset "Complex Chain and Parallel" begin
    # Chain(W1, R1) and R2
    # W1 -> R1
    # R2 is independent
    s = Schedule(chain(sys_w1, sys_r1), sys_r2)
    stages = get_execution_order(s)

    @test length(stages) == 2
    @test sys_w1 in stages[1]
    @test sys_r2 in stages[1]
    @test stages[2] == [sys_r1]
  end
end
