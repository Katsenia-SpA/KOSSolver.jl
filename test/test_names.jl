# The JuMP names do not reach KOS (KOS.jl gives it generic names): odd, empty or repeated names change nothing, and
# the result is the same, bit for bit, as that of the model without names. Also: the empty model, a row without
# terms, the objective constant, -0.0 and extreme numbers pass exactly through the LP text.

module TestNames

using Test
using JuMP
import MathOptInterface as MOI
import KOS

const NOMBRES = ["x y", "∀ñ", "", "1abc", "a:b", "x[1]", "end", "inf", "-", "\\ comment", "a\nb", "x y"]

function modelo(con_nombres::Bool)
    m = Model(KOS.Optimizer)
    n = length(NOMBRES)
    x = @variable(m, [1:n], lower_bound = 0, upper_bound = 10)
    for j in 1:n
        con_nombres && set_name(x[j], NOMBRES[j])
    end
    cs = ConstraintRef[]
    for i in 1:n
        c = @constraint(m, sum(((i * j) % 7 - 3) * x[j] for j in 1:n) <= 5 + i)
        con_nombres && set_name(c, NOMBRES[end-i+1])
        push!(cs, c)
    end
    @objective(m, Max, sum(((3j) % 5 + 1) * x[j] for j in 1:n) + 0.125)
    return m, x, cs
end

function test_nombres()
    m1, x1, c1 = modelo(true)
    m2, x2, c2 = modelo(false)
    optimize!(m1)
    optimize!(m2)
    @test termination_status(m1) == MOI.OPTIMAL
    @test objective_value(m1) === objective_value(m2)
    @test value.(x1) == value.(x2)
    @test dual.(c1) == dual.(c2)
    @test name(x1[1]) == "x y"
    @test name(c1[1]) == NOMBRES[end]
end

function test_vacio()
    m = Model(KOS.Optimizer)
    optimize!(m)
    @test termination_status(m) == MOI.OPTIMAL
    @test objective_value(m) == 0.0
    m = Model(KOS.Optimizer)
    @objective(m, Min, 7.5)
    optimize!(m)
    @test termination_status(m) == MOI.OPTIMAL
    @test objective_value(m) == 7.5
end

function test_fila_vacia()
    m = Model(KOS.Optimizer)
    @variable(m, x >= 1)
    c = @constraint(m, 0 * x >= -1)
    @objective(m, Min, x)
    optimize!(m)
    @test termination_status(m) == MOI.OPTIMAL
    @test value(c) == 0.0
    @test value(x) == 1.0
    # empty and infeasible
    m = Model(KOS.Optimizer)
    @variable(m, x >= 1)
    @constraint(m, 0 * x >= 1)
    optimize!(m)
    @test termination_status(m) == MOI.INFEASIBLE
end

# the numbers pass exactly: what KOS writes of the copied model has the same bits
function test_numeros_exactos()
    vals = [0.1, 1 / 3, nextfloat(1.0), 5.0e-324, 1.7976931348623157e308 / 1e10, -2.0^-1074, 123456789.0123456789]
    m = Model(KOS.Optimizer)
    n = length(vals)
    @variable(m, x[1:n])
    for j in 1:n
        set_lower_bound(x[j], -vals[j] - 1)
        set_upper_bound(x[j], abs(vals[j]) + 1)
    end
    @constraint(m, r, sum(vals[j] * x[j] for j in 1:n) in MOI.Interval(0.1, 0.30000000000000004))
    @constraint(m, s, x[1] - x[2] >= -0.0)
    @objective(m, Min, sum(vals[j] * x[j] for j in 1:n) - 1 / 3)
    optimize!(m)
    o = unsafe_backend(m)
    ruta = tempname() * ".lp"
    KOS.write_model(o, ruta)
    texto = read(ruta, String)
    rm(ruta)
    # KOS reads back its own LP output with the same bits: each number of the model is in the text, with its bits
    numeros = Set{UInt64}()
    for t in split(texto, r"[\s:<=>]+")
        v = tryparse(Float64, t)
        v === nothing || push!(numeros, reinterpret(UInt64, abs(v)))
    end
    for v in vcat(vals, [0.1, 0.30000000000000004, 1 / 3])
        @test reinterpret(UInt64, abs(v)) in numeros
    end
    @test termination_status(m) in (MOI.OPTIMAL, MOI.ALMOST_OPTIMAL)
    # the objective constant goes into the KOS model: the KOS objective includes it
    z = KOS._kos_objective(KOS.kos_model(o))
    @test z === objective_value(m)
end

# the starting values are ignored (the C API does not take starting points): the model solves the same
function test_arranques()
    m = Model(KOS.Optimizer)
    @variable(m, 0 <= x <= 2, start = 1.5)
    @variable(m, y >= 0, Int, start = 3)
    c = @constraint(m, x + y >= 2.5)
    set_start_value(c, 2.5)
    @objective(m, Min, x + 2y)
    optimize!(m)
    # y = 0 does not fit (x ≤ 2); y = 1 and x = 1.5
    @test termination_status(m) == MOI.OPTIMAL
    @test objective_value(m) == 3.5
end

function runtests()
    @testset "names and text" begin
        test_arranques()
        test_nombres()
        test_vacio()
        test_fila_vacia()
        test_numeros_exactos()
    end
end

end
