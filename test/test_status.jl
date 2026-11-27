# The statuses: the table of the 17 KOS statuses and the real limits (iterations, time, work, objective, nodes,
# solutions, objective target, gap targets, interruption), infeasibility with its Farkas certificate, unboundedness
# with its ray, and the parameters.

module TestStatus

using Test
using JuMP
import MathOptInterface as MOI
import KOSSolver

# the numbers of kos.h and what they mean in MOI
const TABLA = [
    0 => MOI.OPTIMIZE_NOT_CALLED, 1 => MOI.OPTIMAL, 2 => MOI.ALMOST_OPTIMAL, 3 => MOI.INFEASIBLE,
    4 => MOI.DUAL_INFEASIBLE, 5 => MOI.DUAL_INFEASIBLE, 6 => MOI.INFEASIBLE_OR_UNBOUNDED, 7 => MOI.ITERATION_LIMIT,
    8 => MOI.TIME_LIMIT, 9 => MOI.OBJECTIVE_LIMIT, 10 => MOI.OTHER_LIMIT, 11 => MOI.NODE_LIMIT,
    12 => MOI.SOLUTION_LIMIT, 13 => MOI.OBJECTIVE_LIMIT, 14 => MOI.OTHER_LIMIT, 15 => MOI.INTERRUPTED,
    16 => MOI.OTHER_ERROR, 17 => MOI.OTHER_ERROR, -1 => MOI.OTHER_ERROR,
]

function test_tabla()
    for (k, v) in TABLA
        @test KOSSolver.termination_status_of(k) == v
    end
    for k in 0:16
        @test KOSSolver.status_string(k) == KOSSolver._ESTADOS[k+1]
    end
end

# an n × n transportation LP with fixed data (it needs tens of iterations)
function transporte(n = 15)
    m = Model(KOSSolver.Optimizer)
    @variable(m, x[1:n, 1:n] >= 0)
    @constraint(m, [i = 1:n], sum(x[i, :]) <= 10 + mod(7i, 5))
    @constraint(m, [j = 1:n], sum(x[:, j]) >= 8 + mod(3j, 4))
    @objective(m, Min, sum(mod(13i + 7j, 17) * x[i, j] + 1 for i in 1:n, j in 1:n))
    return m
end

# optimize! with a watchdog: if it has not finished in `plazo` seconds, another task interrupts it (with julia -t 2
# or more), so a test does not hang if a limit does not reach KOS (each case of these tests finishes in under a
# second)
function optimiza_con_vigia!(m; plazo = 15.0)
    o = unsafe_backend(m)
    listo = Threads.Atomic{Bool}(false)
    vigia = if Threads.nthreads() >= 2
        Threads.@spawn begin
            t0 = time()
            while !listo[] && time() - t0 < plazo
                Libc.systemsleep(0.05)
            end
            listo[] || KOSSolver.interrupt!(o)
        end
    end
    try
        optimize!(m)
    finally
        listo[] = true
        vigia === nothing || wait(vigia)
    end
end

# a hard MIP with fixed data (of the "market share" kind): equalities with binaries and slacks that are minimized
function mercado(filas = 4, n = 32)
    m = Model(KOSSolver.Optimizer)
    @variable(m, x[1:n], Bin)
    @variable(m, s[1:filas] >= 0)
    @variable(m, t[1:filas] >= 0)
    a(i, j) = mod(37 * i * j + 11 * j + 5i, 100)
    for i in 1:filas
        b = div(sum(a(i, j) for j in 1:n), 2)
        @constraint(m, sum(a(i, j) * x[j] for j in 1:n) + s[i] - t[i] == b)
    end
    @objective(m, Min, sum(s) + sum(t))
    return m
end

function test_lp_limites()
    m = transporte()
    optimize!(m)
    @test termination_status(m) == MOI.OPTIMAL
    @test raw_status(m) == "optimal"
    z = objective_value(m)
    for (param, valor, estado, crudo) in (("iteration_limit", 1, MOI.ITERATION_LIMIT, "iteration_limit"),
                                          ("work_limit", 0, MOI.OTHER_LIMIT, "work_limit"),
                                          ("time_limit", 0, MOI.TIME_LIMIT, "time_limit"),
                                          # from a cold start, like every solve of KOSSolver.jl: KOS proves that the
                                          # optimum is past the limit
                                          ("objective_upper_limit", z / 2, MOI.OBJECTIVE_LIMIT, "objective_limit"))
        m = transporte()
        set_attribute(m, param, valor)
        optimize!(m)
        @test termination_status(m) == estado
        @test raw_status(m) == crudo
        @test primal_status(m) == MOI.NO_SOLUTION
        @test result_count(m) == 0
    end
end

# with JuMP, each optimize! copies the model to a new KOS model (KOSSolver.jl is not incremental: the MOI cache hands it
# the whole model): solving again after changing a parameter gives the same, bit for bit, as a new model with that
# parameter, and does not continue from the previous solve
function test_resolver_otra_vez()
    m = transporte()
    set_attribute(m, "iteration_limit", 1)
    optimize!(m)
    @test termination_status(m) == MOI.ITERATION_LIMIT
    set_attribute(m, "iteration_limit", "automatic")
    optimize!(m)
    @test termination_status(m) == MOI.OPTIMAL
    nuevo = transporte()
    set_attribute(nuevo, "iteration_limit", 1)
    set_attribute(nuevo, "iteration_limit", "automatic")
    optimize!(nuevo)
    @test objective_value(m) === objective_value(nuevo)
    @test simplex_iterations(m) == simplex_iterations(nuevo)
    @test value.(all_variables(m)) == value.(all_variables(nuevo))
    # a change of the model: another copy, with the change
    z = objective_value(m)
    set_upper_bound(all_variables(m)[1], 0.0)
    optimize!(m)
    @test termination_status(m) == MOI.OPTIMAL
    @test value(all_variables(m)[1]) == 0.0
    @test objective_value(m) >= z - 1e-9
end

function test_mip_limites()
    for (param, valor, estado, crudo) in (
        ("node_limit", 1, MOI.NODE_LIMIT, "node_limit"),
        ("solution_limit", 1, MOI.SOLUTION_LIMIT, "solution_limit"),
        ("work_limit", 0.05, MOI.OTHER_LIMIT, "work_limit"),
        ("time_limit", 0.2, MOI.TIME_LIMIT, "time_limit"),
        ("objective_target", 1e9, MOI.OBJECTIVE_LIMIT, "target_reached"),
        ("mip_gap_targets", "0g1i-100g", MOI.OTHER_LIMIT, "gap_after_nodes"),
    )
        m = mercado()
        # a safety limit (the time test changes it) and the watchdog
        set_attribute(m, "time_limit", 30)
        set_attribute(m, param, valor)
        optimiza_con_vigia!(m)
        @test termination_status(m) == estado
        @test raw_status(m) == crudo
        if primal_status(m) == MOI.FEASIBLE_POINT
            @test result_count(m) == 1
            @test dual_status(m) == MOI.NO_SOLUTION
            # the objective and the bound of a minimizing MIP: bound ≤ incumbent
            @test objective_bound(m) <= objective_value(m) + 1e-9
            @test relative_gap(m) >= 0
            @test node_count(m) >= 1
        else
            @test result_count(m) == 0
        end
    end
end

# the interruption from another task on another thread (julia -t 2 or more)
function test_interrupcion()
    if Threads.nthreads() < 2
        @test_skip "needs julia -t 2"
        return
    end
    m = mercado(6, 40)
    set_attribute(m, "time_limit", 60)
    o = unsafe_backend(m)
    listo = Threads.Atomic{Bool}(false)
    # a system sleep, without the event loop (which does not advance while thread 1 is in kos_solve)
    tarea = Threads.@spawn begin
        Libc.systemsleep(0.5)
        KOSSolver.interrupt!(o)
        listo[] = true
    end
    t0 = time()
    optimize!(m)
    wait(tarea)
    @test listo[]
    @test termination_status(m) == MOI.INTERRUPTED
    @test raw_status(m) == "interrupted"
    @test time() - t0 < 30
end

function test_infactible()
    m = Model(KOSSolver.Optimizer)
    @variable(m, 0 <= x <= 1)
    @variable(m, 0 <= y <= 1)
    @constraint(m, c, x + y >= 3)
    @objective(m, Min, x + y)
    optimize!(m)
    @test termination_status(m) == MOI.INFEASIBLE
    @test primal_status(m) == MOI.NO_SOLUTION
    @test dual_status(m) == MOI.INFEASIBILITY_CERTIFICATE
    @test result_count(m) == 1
    # the MOI dual ray: d ≥ 0 on the ≥ row, −Σ Aᵀd = 0 with the bounds, −Σ bᵀd > 0
    dc = dual(c)
    dxu, dyu = dual(UpperBoundRef(x)), dual(UpperBoundRef(y))
    dxl, dyl = dual(LowerBoundRef(x)), dual(LowerBoundRef(y))
    @test dc > 0
    @test dxu <= 0 && dyu <= 0
    @test isapprox(dc + dxu + dxl, 0; atol = 1e-9)
    @test isapprox(dc + dyu + dyl, 0; atol = 1e-9)
    @test 3dc + dxu + dyu > 0
    @test isapprox(dual_objective_value(m), 3dc + dxu + dyu; atol = 1e-9)
    # when maximizing, the same certificate and the dual objective with the other sign
    @objective(m, Max, x + y)
    optimize!(m)
    @test termination_status(m) == MOI.INFEASIBLE
    @test dual(c) == dc
    @test isapprox(dual_objective_value(m), -(3dc + dxu + dyu); atol = 1e-9)
end

function test_no_acotada()
    m = Model(KOSSolver.Optimizer)
    @variable(m, x >= 0)
    @variable(m, y >= 0)
    @constraint(m, c, x - y <= 1)
    @constraint(m, c2, x + 2y >= -5)
    @objective(m, Max, x + y)
    optimize!(m)
    @test termination_status(m) == MOI.DUAL_INFEASIBLE
    @test primal_status(m) == MOI.INFEASIBILITY_CERTIFICATE
    rx, ry = value(x), value(y)
    @test rx >= 0 && ry >= 0
    @test rx - ry <= 1e-9
    @test rx + ry > 0
    @test isapprox(value(c), rx - ry; atol = 1e-12)
    # the activity of a ray is a_i r (positive here: x + 2y grows along the ray)
    @test isapprox(value(c2), rx + 2ry; atol = 1e-12)
    @test value(c2) > 0
    @test isapprox(objective_value(m), rx + ry; atol = 1e-12)
end

# a MIP with a solution and an unbounded relaxation: KOS "unbounded", MOI DUAL_INFEASIBLE with its point
function test_mip_no_acotado()
    m = Model(KOSSolver.Optimizer)
    @variable(m, x >= 0, Int)
    @variable(m, y >= 0)
    @constraint(m, x + y >= 1.5)
    @objective(m, Max, x + y)
    optimize!(m)
    @test termination_status(m) in (MOI.DUAL_INFEASIBLE, MOI.INFEASIBLE_OR_UNBOUNDED)
    if raw_status(m) == "unbounded"
        @test primal_status(m) == MOI.FEASIBLE_POINT
    end
end

function test_parametros()
    m = Model(KOSSolver.Optimizer)
    set_attribute(m, "presolve", true)
    @test get_attribute(m, "presolve") == "on"
    set_attribute(m, "primal_tolerance", 1e-9)
    @test get_attribute(m, "primal_tolerance") == "1e-9"
    set_attribute(m, "profile", "stable")
    @test get_attribute(m, "profile") == "stable"
    set_time_limit_sec(m, 12.5)
    @test time_limit_sec(m) == 12.5
    set_time_limit_sec(m, nothing)
    @test time_limit_sec(m) === nothing
    set_attribute(m, MOI.RelativeGapTolerance(), 0.01)
    @test get_attribute(m, MOI.RelativeGapTolerance()) == 0.01
    set_attribute(m, MOI.AbsoluteGapTolerance(), 0.5)
    @test get_attribute(m, MOI.AbsoluteGapTolerance()) == 0.5
    set_attribute(m, MOI.NumberOfThreads(), 2)
    @test get_attribute(m, MOI.NumberOfThreads()) == 2
    @test_throws MOI.UnsupportedAttribute set_attribute(m, "no_such_parameter", 1)
    @test_throws KOSSolver.KOSError set_attribute(m, "primal_tolerance", 5.0)
    # the message without the repeated code: "invalid_value: invalid value ..." once
    e = try
        set_attribute(m, "threads", -3)
        nothing
    catch err
        err
    end
    @test e isa KOSSolver.KOSError
    @test e.name == "invalid_value"
    @test !startswith(e.message, "invalid_value")
    @test count("invalid_value", sprint(showerror, e)) == 1
    @test_throws KOSSolver.KOSError set_attribute(m, "profile", "no_such_profile")
    @test_throws ArgumentError set_attribute(m, "presolve", [1])
    # the ones set, in their order
    o = unsafe_backend(m)
    @test KOSSolver.parameters(o)[1] == ("presolve" => "on")
    @test KOSSolver.parameters(o)[3] == ("profile" => "stable")
    @test "time_limit" in KOSSolver.parameter_names()
    @test solver_name(m) == "KOS"
end

# data that JuMP lets through or that are built with MOI directly: a clear error before reaching KOS
function test_datos_invalidos()
    for (que, arma) in (
        ("NaN coefficient", (src, x) -> MOI.add_constraint(src, 1.0 * x + NaN * x, MOI.GreaterThan(1.0))),
        ("Inf coefficient", (src, x) -> MOI.add_constraint(src, Inf * x, MOI.LessThan(1.0))),
        ("NaN bound", (src, x) -> MOI.add_constraint(src, 1.0 * x, MOI.LessThan(NaN))),
        ("NaN variable bound", (src, x) -> MOI.add_constraint(src, x, MOI.GreaterThan(NaN))),
        ("Inf cost", (src, x) -> MOI.set(src, MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}(), Inf * x)),
        ("NaN constant", (src, x) -> MOI.set(src, MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}(),
                                              1.0 * x + NaN)),
    )
        src = MOI.Utilities.Model{Float64}()
        x = MOI.add_variable(src)
        MOI.set(src, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        arma(src, x)
        o = KOSSolver.Optimizer()
        @test_throws ArgumentError MOI.copy_to(o, src)
        # the copy that fails leaves the optimizer empty
        @test MOI.is_empty(o)
    end
    # a constant in the function of a constraint: the MOI error (JuMP moves it to the set)
    src = MOI.Utilities.Model{Float64}()
    x = MOI.add_variable(src)
    MOI.add_constraint(src, 1.0 * x + 2.0, MOI.LessThan(1.0))
    @test_throws MOI.ScalarFunctionConstantNotZero MOI.copy_to(KOSSolver.Optimizer(), src)
    # quadratic terms: MOI.copy_to rejects them, and JuMP, with the optimizer attached, already when they are added
    src = MOI.Utilities.Model{Float64}()
    x = MOI.add_variable(src)
    MOI.set(src, MOI.ObjectiveSense(), MOI.MIN_SENSE)
    MOI.set(src, MOI.ObjectiveFunction{MOI.ScalarQuadraticFunction{Float64}}(), 1.0 * x * x)
    @test_throws MOI.UnsupportedAttribute MOI.copy_to(KOSSolver.Optimizer(), src)
    src = MOI.Utilities.Model{Float64}()
    x = MOI.add_variable(src)
    MOI.add_constraint(src, 1.0 * x * x, MOI.LessThan(1.0))
    @test_throws MOI.UnsupportedConstraint MOI.copy_to(KOSSolver.Optimizer(), src)
    m = Model(KOSSolver.Optimizer)
    @variable(m, x)
    for intento in (() -> @constraint(m, x^2 <= 1), () -> @objective(m, Min, x^2))
        mensaje = try
            intento()
            ""
        catch e
            sprint(showerror, e)
        end
        @test occursin("not support", mensaje)
    end
end


# the result statuses according to the KOS status, with the status set by hand in the optimizer
function test_estados_de_resultados()
    o = KOSSolver.Optimizer()
    o.resuelto = true
    o.num_columnas = 1
    o.num_filas = 1
    o.x = [1.0]
    o.actividad = [1.0]
    o.duales = [2.0]
    o.reducidos = [0.0]
    o.objetivo = 3.0
    o.estado = 1
    @test MOI.get(o, MOI.PrimalStatus()) == MOI.FEASIBLE_POINT
    @test MOI.get(o, MOI.DualStatus()) == MOI.FEASIBLE_POINT
    @test MOI.get(o, MOI.ResultCount()) == 1
    o.estado = 2
    @test MOI.get(o, MOI.TerminationStatus()) == MOI.ALMOST_OPTIMAL
    @test MOI.get(o, MOI.PrimalStatus()) == MOI.NEARLY_FEASIBLE_POINT
    @test MOI.get(o, MOI.DualStatus()) == MOI.NEARLY_FEASIBLE_POINT
    @test MOI.get(o, MOI.RawStatusString()) == "optimal_flagged"
    @test MOI.get(o, MOI.PrimalStatus(2)) == MOI.NO_SOLUTION
    # a MIP with an incumbent: feasible point, no duals
    o.estado = 10
    o.es_mip = true
    o.duales = nothing
    o.reducidos = nothing
    @test MOI.get(o, MOI.TerminationStatus()) == MOI.OTHER_LIMIT
    @test MOI.get(o, MOI.PrimalStatus()) == MOI.FEASIBLE_POINT
    @test MOI.get(o, MOI.DualStatus()) == MOI.NO_SOLUTION
    # no solution and no certificate
    o.x = nothing
    o.actividad = nothing
    o.farkas = missing
    o.rayo = missing
    @test MOI.get(o, MOI.PrimalStatus()) == MOI.NO_SOLUTION
    @test MOI.get(o, MOI.ResultCount()) == 0
    o.resuelto = false
    @test MOI.get(o, MOI.TerminationStatus()) == MOI.OPTIMIZE_NOT_CALLED
end

# the objective constant, with both signs and both senses
function test_constante()
    for (sentido, k) in ((MOI.MIN_SENSE, 5.25), (MOI.MIN_SENSE, -5.25), (MOI.MAX_SENSE, 5.25), (MOI.MAX_SENSE, -5.25))
        m = Model(KOSSolver.Optimizer)
        @variable(m, 1 <= x <= 2)
        @objective(m, sentido, 3x + k)
        optimize!(m)
        z = (sentido == MOI.MIN_SENSE ? 3 : 6) + k
        @test objective_value(m) == z
        @test dual_objective_value(m) == z
    end
end

# binaries (ZeroOne without other bounds: [0, 1]) and integers
function test_binarias()
    m = Model(KOSSolver.Optimizer)
    @variable(m, x, Bin)
    @variable(m, y, Bin)
    @variable(m, -3.5 <= z <= 2.5, Int)
    @constraint(m, x + y <= 1.5)
    @objective(m, Min, x - y + z)
    optimize!(m)
    @test termination_status(m) == MOI.OPTIMAL
    @test value(x) == 0.0 && value(y) == 1.0 && value(z) == -3.0
    @test objective_value(m) == -4.0
    @objective(m, Max, x + y + z)
    optimize!(m)
    @test objective_value(m) == 3.0
end

# the conflict: the IIS of KOS on an infeasible LP; a MIP with a feasible relaxation and no solution,
# NO_CONFLICT_FOUND; a feasible model, NO_CONFLICT_EXISTS; before optimize!, the MOI error
function test_conflicto()
    m = Model(KOSSolver.Optimizer)
    @variable(m, x >= 0)
    @variable(m, y >= 0)
    @variable(m, z >= 0)
    c = @constraint(m, x + y <= -1)
    d = @constraint(m, x + z <= 5)
    @test_throws ErrorException compute_conflict!(m)
    optimize!(m)
    @test termination_status(m) == MOI.INFEASIBLE
    compute_conflict!(m)
    @test get_attribute(m, MOI.ConflictStatus()) == MOI.CONFLICT_FOUND
    @test get_attribute(c, MOI.ConstraintConflictStatus()) == MOI.IN_CONFLICT
    @test get_attribute(LowerBoundRef(x), MOI.ConstraintConflictStatus()) == MOI.IN_CONFLICT
    @test get_attribute(LowerBoundRef(y), MOI.ConstraintConflictStatus()) == MOI.IN_CONFLICT
    @test get_attribute(d, MOI.ConstraintConflictStatus()) == MOI.NOT_IN_CONFLICT
    @test get_attribute(LowerBoundRef(z), MOI.ConstraintConflictStatus()) == MOI.NOT_IN_CONFLICT
    # a binary: the side of [0, 1] that ZeroOne gives
    m = Model(KOSSolver.Optimizer)
    @variable(m, b, Bin)
    @variable(m, -5 <= w <= 5)
    e = @constraint(m, b >= 2)
    optimize!(m)
    compute_conflict!(m)
    @test get_attribute(m, MOI.ConflictStatus()) == MOI.CONFLICT_FOUND
    @test get_attribute(e, MOI.ConstraintConflictStatus()) == MOI.IN_CONFLICT
    @test get_attribute(BinaryRef(b), MOI.ConstraintConflictStatus()) == MOI.IN_CONFLICT
    @test get_attribute(LowerBoundRef(w), MOI.ConstraintConflictStatus()) == MOI.NOT_IN_CONFLICT
    # a MIP infeasible by integrality (feasible relaxation)
    m = Model(KOSSolver.Optimizer)
    @variable(m, 0 <= k <= 10, Int)
    @constraint(m, 2k == 3)
    optimize!(m)
    @test termination_status(m) == MOI.INFEASIBLE
    compute_conflict!(m)
    @test get_attribute(m, MOI.ConflictStatus()) == MOI.NO_CONFLICT_FOUND
    # no solution in the last solve (a limit): NO_CONFLICT_FOUND, even though the LP is feasible
    for (param, valor) in (("iteration_limit", 1), ("time_limit", 0), ("work_limit", 0))
        m = transporte()
        set_attribute(m, param, valor)
        optimize!(m)
        @test result_count(m) == 0
        compute_conflict!(m)
        @test get_attribute(m, MOI.ConflictStatus()) == MOI.NO_CONFLICT_FOUND
    end
    # feasible ones
    m = Model(KOSSolver.Optimizer)
    @variable(m, 0 <= v <= 1)
    @constraint(m, v >= 0.5)
    optimize!(m)
    compute_conflict!(m)
    @test get_attribute(m, MOI.ConflictStatus()) == MOI.NO_CONFLICT_EXISTS
    set_integer(v)
    optimize!(m)
    compute_conflict!(m)
    @test get_attribute(m, MOI.ConflictStatus()) == MOI.NO_CONFLICT_EXISTS
end

function runtests()
    @testset "status" begin
        test_conflicto()
        test_tabla()
        test_estados_de_resultados()
        test_constante()
        test_binarias()
        test_lp_limites()
        test_resolver_otra_vez()
        test_mip_limites()
        test_interrupcion()
        test_infactible()
        test_no_acotada()
        test_mip_no_acotado()
        test_parametros()
        test_datos_invalidos()
    end
end

end
