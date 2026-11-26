# The KOS edition and its size limit. Without a license in effect on the machine, the library is the Community
# edition: it solves models of up to 2,000 rows and 2,000 columns, and a larger one gives the KOS error `size_limit`
# (a `KOS.KOSError` in `optimize!`, with the limit and the pricing page in the message) without solving. With a
# license in effect there is no limit. The tests look at `KOS.license_status()` and expect what matches the
# situation of the run; ENV["KOS_JL_EXPECT_LICENSE"] (yes or no) fixes it for whoever runs them in a deliberate setup.

module TestLicense

using Test
using JuMP
import MathOptInterface as MOI
import KOS

estado() = KOS._json(KOS.license_status())

"Whether there is a license in effect on this machine (no size limit)."
en_vigor() = estado()["in_effect"] === true

"The size limit of the edition in effect: (rows, columns), or `nothing` if there is none."
function tope()
    t = estado()["size_limit"]
    return t === nothing ? nothing : (Int(t[1]), Int(t[2]))
end

# a feasible m × n LP: row i is x[i mod n] + 2 x[(7i + 3) mod n] >= 1 + i mod 3, with 0 <= x <= 10
function lp(m, n; entera = false)
    modelo = Model(KOS.Optimizer)
    @variable(modelo, 0 <= x[1:n] <= 10)
    for i in 0:m-1
        @constraint(modelo, x[i%n+1] + 2x[(7i+3)%n+1] >= 1 + i % 3)
    end
    @objective(modelo, Min, sum((1 + (j - 1) % 5) * x[j] for j in 1:n))
    entera && set_integer(x[1])
    return modelo
end

function test_estado()
    e = estado()
    @test e["status"] isa String && e["in_effect"] isa Bool && e["message"] isa String
    @test haskey(e, "edition") && haskey(e, "size_limit") && haskey(e, "release_date")
    if e["in_effect"]
        @test e["size_limit"] === nothing
    else
        @test e["size_limit"] == [2000.0, 2000.0]
    end
    esperada = get(ENV, "KOS_JL_EXPECT_LICENSE", "")
    esperada == "yes" && @test e["in_effect"]
    esperada == "no" && @test !e["in_effect"]
end

function test_tope()
    # within the Community size limit it always solves
    m = lp(2000, 40)
    optimize!(m)
    @test termination_status(m) == MOI.OPTIMAL
    dentro = objective_value(m)
    for (filas, cols, entera) in ((2001, 40, false), (40, 2001, false), (2001, 40, true))
        m = lp(filas, cols; entera)
        if en_vigor()
            optimize!(m)
            @test termination_status(m) == MOI.OPTIMAL
            @test tope() === nothing
        else
            falla = try
                optimize!(m)
                nothing
            catch e
                e
            end
            @test falla isa KOS.KOSError
            falla isa KOS.KOSError || continue
            @test falla.code == KOS.KOS_ERROR_SIZE_LIMIT && falla.name == "size_limit"
            @test occursin("the model has $filas rows and $cols columns", falla.message)
            @test occursin("up to 2000 rows (constraints) and 2000 columns (variables)", falla.message)
            @test occursin("https://katsenia.com/pricing.html", falla.message)
            @test !startswith(falla.message, "size_limit")
            @test sprint(showerror, falla) == "KOSError: size_limit: " * falla.message
            # nothing was solved, and the same optimizer works for a model within the limit
            @test termination_status(m) == MOI.OPTIMIZE_NOT_CALLED
            @test tope() == (2000, 2000)
        end
    end
    m = lp(2000, 40)
    optimize!(m)
    @test termination_status(m) == MOI.OPTIMAL && objective_value(m) === dentro
end

function runtests()
    @testset "license" begin
        test_estado()
        test_tope()
    end
end

end
