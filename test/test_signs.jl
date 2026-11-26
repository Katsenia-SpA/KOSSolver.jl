# The signs of the duals against values computed by hand: minimizing and maximizing, ≤, ≥, = and interval rows, and
# variable bounds (GreaterThan, LessThan, Interval, EqualTo). The MOI convention does not depend on the sense: the
# dual of a ≥ row is ≥ 0 and that of a ≤ row is ≤ 0; maximizing −f gives the same duals as minimizing f.
# JuMP.reduced_cost and JuMP.shadow_price do depend on the sense.

module TestSigns

using Test
using JuMP
import MathOptInterface as MOI
import KOS

const TOL = 1e-9

# A (min): min 2x + 3y, c1: x + y ≥ 4, c2: x ≤ 3, x, y ≥ 0. Optimum x = 3, y = 1, z = 9.
# ∂z/∂b1 = 3, ∂z/∂u2 = −1: MOI duals 3 (≥) and −1 (≤); the reduced costs, 0.
function test_min_le_ge()
    m = Model(KOS.Optimizer)
    @variable(m, x >= 0)
    @variable(m, y >= 0)
    @constraint(m, c1, x + y >= 4)
    @constraint(m, c2, x <= 3)
    @objective(m, Min, 2x + 3y)
    optimize!(m)
    @test termination_status(m) == MOI.OPTIMAL
    @test isapprox(objective_value(m), 9; atol = TOL)
    @test isapprox(dual(c1), 3; atol = TOL)
    @test isapprox(dual(c2), -1; atol = TOL)
    @test isapprox(dual(LowerBoundRef(x)), 0; atol = TOL)
    @test isapprox(dual(LowerBoundRef(y)), 0; atol = TOL)
    # JuMP.shadow_price: how much the objective improves when relaxing (when minimizing, it goes down: negative)
    @test isapprox(shadow_price(c1), -3; atol = TOL)
    @test isapprox(shadow_price(c2), -1; atol = TOL)
    @test isapprox(dual_objective_value(m), 9; atol = TOL)
end

# B (max): max 2x + 3y, c1: x + y ≤ 4, c2: x ≥ 1, 0 ≤ y ≤ 2. Optimum x = 2, y = 2, z = 10.
# ∂z/∂b1 = 2 (KOS y = 2), c2 inactive, the bound y ≤ 2 is worth 3 − 2 = 1 (KOS d = 1). MOI: −2 on c1 (≤), 0 on c2
# and −1 on the upper bound of y; JuMP.reduced_cost(y) = 1.
function test_max_le_ge_bound()
    m = Model(KOS.Optimizer)
    @variable(m, x >= 0)
    @variable(m, 0 <= y <= 2)
    @constraint(m, c1, x + y <= 4)
    @constraint(m, c2, x >= 1)
    @objective(m, Max, 2x + 3y)
    optimize!(m)
    @test termination_status(m) == MOI.OPTIMAL
    @test isapprox(objective_value(m), 10; atol = TOL)
    @test isapprox(value(x), 2; atol = TOL)
    @test isapprox(dual(c1), -2; atol = TOL)
    @test isapprox(dual(c2), 0; atol = TOL)
    @test isapprox(dual(UpperBoundRef(y)), -1; atol = TOL)
    @test isapprox(dual(LowerBoundRef(y)), 0; atol = TOL)
    @test isapprox(reduced_cost(y), 1; atol = TOL)
    @test isapprox(reduced_cost(x), 0; atol = TOL)
    @test isapprox(shadow_price(c1), 2; atol = TOL)
    @test isapprox(dual_objective_value(m), 10; atol = TOL)
end

# C: e: x + y = 2, iv: 0 ≤ x − y ≤ 1, x and y free. min 3x + y: x = y = 1, z = 4; ∂z/∂b(e) = 2 and ∂z/∂l(iv) = 1.
# max −3x − y: the same MOI duals (2 and 1) and z = −4.
function test_eq_interval(sentido)
    m = Model(KOS.Optimizer)
    @variable(m, x)
    @variable(m, y)
    @constraint(m, e, x + y == 2)
    @constraint(m, iv, 0 <= x - y <= 1)
    if sentido == MOI.MIN_SENSE
        @objective(m, Min, 3x + y)
    else
        @objective(m, Max, -3x - y)
    end
    optimize!(m)
    z = sentido == MOI.MIN_SENSE ? 4 : -4
    @test termination_status(m) == MOI.OPTIMAL
    @test isapprox(objective_value(m), z; atol = TOL)
    @test isapprox(dual(e), 2; atol = TOL)
    @test isapprox(dual(iv), 1; atol = TOL)
    @test isapprox(dual_objective_value(m), z; atol = TOL)
    @test isapprox(value(x - y), 0; atol = TOL)
end

# D: r: x + y ≤ 4.5, 0 ≤ x ≤ 3 (Interval), 1 ≤ y ≤ 2. min −3x − 2y: x = 3 (at its upper bound), y = 1.5,
# z = −12; KOS y(r) = −2, d(x) = −1. MOI: −2 on r and −1 on the interval of x, in both senses (max 3x + 2y).
function test_interval_bound(sentido)
    m = Model(KOS.Optimizer)
    @variable(m, x)
    @variable(m, 1 <= y <= 2)
    cx = @constraint(m, x in MOI.Interval(0.0, 3.0))
    @constraint(m, r, x + y <= 4.5)
    if sentido == MOI.MIN_SENSE
        @objective(m, Min, -3x - 2y)
    else
        @objective(m, Max, 3x + 2y)
    end
    optimize!(m)
    s = sentido == MOI.MIN_SENSE ? 1 : -1
    @test termination_status(m) == MOI.OPTIMAL
    @test isapprox(objective_value(m), -12s; atol = TOL)
    @test isapprox(value(x), 3; atol = TOL)
    @test isapprox(value(y), 1.5; atol = TOL)
    @test isapprox(dual(r), -2; atol = TOL)
    @test isapprox(dual(cx), -1; atol = TOL)
    @test isapprox(dual(LowerBoundRef(y)), 0; atol = TOL)
    @test isapprox(dual(UpperBoundRef(y)), 0; atol = TOL)
    # JuMP.reduced_cost does not look at an Interval variable constraint (only LowerBoundRef, UpperBoundRef and
    # FixRef)
    @test isapprox(dual_objective_value(m), -12s; atol = TOL)
end

# E: a fixed variable (EqualTo) and an active lower bound. min x + 2y, x + y ≥ 3, x == 1, y ≥ 0: y = 2, z = 5;
# ∂z/∂b = 2, the dual of x == 1 is 1 − 2 = −1, the bound of y is not active. Maximizing −x − 2y, the same.
function test_fixed(sentido)
    m = Model(KOS.Optimizer)
    @variable(m, x == 1)
    @variable(m, y >= 0)
    @constraint(m, c, x + y >= 3)
    if sentido == MOI.MIN_SENSE
        @objective(m, Min, x + 2y)
    else
        @objective(m, Max, -x - 2y)
    end
    optimize!(m)
    @test termination_status(m) == MOI.OPTIMAL
    @test isapprox(dual(c), 2; atol = TOL)
    @test isapprox(dual(FixRef(x)), -1; atol = TOL)
    @test isapprox(dual(LowerBoundRef(y)), 0; atol = TOL)
end

# F: the active lower bound with a positive reduced cost. min x + y, x + 2y ≥ 2, x, y ≥ 0: y = 1, x = 0, z = 1;
# ∂z/∂b = 0.5; the dual of x ≥ 0 is 1 − 0.5 = 0.5 (≥ 0). Maximizing −x − y, the same in MOI.
function test_lower_bound(sentido)
    m = Model(KOS.Optimizer)
    @variable(m, x >= 0)
    @variable(m, y >= 0)
    @constraint(m, c, x + 2y >= 2)
    if sentido == MOI.MIN_SENSE
        @objective(m, Min, x + y)
    else
        @objective(m, Max, -x - y)
    end
    optimize!(m)
    s = sentido == MOI.MIN_SENSE ? 1 : -1
    @test termination_status(m) == MOI.OPTIMAL
    @test isapprox(dual(c), 0.5; atol = TOL)
    @test isapprox(dual(LowerBoundRef(x)), 0.5; atol = TOL)
    @test isapprox(dual(LowerBoundRef(y)), 0; atol = TOL)
    @test isapprox(reduced_cost(x), 0.5s; atol = TOL)
end

# G: the MOI duals are σ times those of KOS, bit for bit, and those of the bounds σ d. The rows go to KOS by type
# (LessThan, GreaterThan, EqualTo, Interval): c2 (≤) is row 1 and c1 (≥) row 2.
function test_raw_relation(sentido)
    m = Model(KOS.Optimizer)
    @variable(m, 0 <= x <= 3)
    @variable(m, y >= 1)
    @constraint(m, c1, x + y >= 2.5)
    @constraint(m, c2, 2x - y <= 1.25)
    @objective(m, sentido, sentido == MOI.MIN_SENSE ? 1.5x + 0.25y : -1.5x - 0.25y)
    optimize!(m)
    o = unsafe_backend(m)
    p = KOS.kos_model(o)
    yk = KOS._kos_vector(:kos_get_duals, p, 2)
    dk = KOS._kos_vector(:kos_get_reduced_costs, p, 2)
    σ = sentido == MOI.MIN_SENSE ? 1.0 : -1.0
    @test dual(c2) === σ * yk[1]
    @test dual(c1) === σ * yk[2]
    @test dual(LowerBoundRef(x)) + dual(UpperBoundRef(x)) === σ * dk[1] + 0.0
    @test dual(LowerBoundRef(y)) === σ * dk[2]
end

function runtests()
    @testset "signs" begin
        test_min_le_ge()
        test_max_le_ge_bound()
        for s in (MOI.MIN_SENSE, MOI.MAX_SENSE)
            test_eq_interval(s)
            test_interval_bound(s)
            test_fixed(s)
            test_lower_bound(s)
            test_raw_relation(s)
        end
    end
end

end
