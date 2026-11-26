# Bitwise against KOS directly. For each instance of the bank that bitwise/prepare_bank.py builds (an MPS with the
# rows grouped in the type order of KOS.jl, and its .dat): the JuMP model built from the .dat and solved with
# KOS.Optimizer gives the same as `kos_read` of the MPS with the same parameters: the status, the objective, the
# solution, the row activity, the duals and the reduced costs, the iterations, the nodes and the work, bit for bit;
# and what JuMP and MOI give (value, dual) is what KOS gives, with the sign convention of MOI (σy on the rows and σd
# on the bounds).
#
# The bank goes in ENV["KOS_JL_BANK"] (a folder with the .mps and .dat files); without it, the test does not run.
# Without a license in effect (the Community edition), an instance over the size limit is not solved: both paths
# must give the same error, `size_limit`.

module TestBitwise

using Test
using JuMP
import MathOptInterface as MOI
import KOS

struct Dat
    maximiza::Bool
    constante::Float64
    col_inf::Vector{Float64}
    col_sup::Vector{Float64}
    entera::Vector{Bool}
    costo::Vector{Float64}
    tipo::Vector{String}
    fila_inf::Vector{Float64}
    fila_sup::Vector{Float64}
    cols::Vector{Vector{Int}}
    vals::Vector{Vector{Float64}}
end

_num(s) = s == "inf" ? Inf : s == "-inf" ? -Inf : parse(Float64, s)

function lee_dat(ruta)
    lineas = readlines(ruta)
    @assert lineas[1] == "KOSDAT 1"
    maximiza = split(lineas[2])[2] == "max"
    constante = _num(split(lineas[3])[2])
    n = parse(Int, split(lineas[4])[2])
    col_inf, col_sup, entera = zeros(n), zeros(n), fill(false, n)
    for j in 1:n
        p = split(lineas[4+j])
        col_inf[j], col_sup[j], entera[j] = _num(p[1]), _num(p[2]), p[3] == "1"
    end
    p = split(lineas[5+n])
    costo = zeros(n)
    k = parse(Int, p[2])
    for t in 1:k
        costo[parse(Int, p[1+2t])+1] = _num(p[2+2t])
    end
    filas = parse(Int, split(lineas[6+n])[2])
    tipo, fi, fs, cols, vals = String[], Float64[], Float64[], Vector{Int}[], Vector{Float64}[]
    for i in 1:filas
        p = split(lineas[6+n+i])
        push!(tipo, p[1])
        push!(fi, _num(p[2]))
        push!(fs, _num(p[3]))
        k = parse(Int, p[4])
        push!(cols, [parse(Int, p[3+2t]) + 1 for t in 1:k])
        push!(vals, [_num(p[4+2t]) for t in 1:k])
    end
    return Dat(maximiza, constante, col_inf, col_sup, entera, costo, tipo, fi, fs, cols, vals)
end

_bits(a::Float64, b::Float64) = reinterpret(UInt64, a) == reinterpret(UInt64, b)
_bits(a::Vector{Float64}, b::Vector{Float64}) = length(a) == length(b) && all(_bits(x, y) for (x, y) in zip(a, b))
_bits(::Nothing, ::Nothing) = true
_bits(a, b) = false

# the JuMP model of the .dat: columns in their order, bounds as variable constraints, rows by type in their order
function arma(d::Dat; al_reves::Bool = false)
    m = Model(KOS.Optimizer)
    n = length(d.costo)
    x = @variable(m, [1:n])
    for j in 1:n
        l, u = d.col_inf[j], d.col_sup[j]
        if _bits(l, u)
            fix(x[j], l)
        else
            l > -Inf && set_lower_bound(x[j], l)
            u < Inf && set_upper_bound(x[j], u)
        end
        d.entera[j] && set_integer(x[j])
    end
    filas = ConstraintRef[]
    for i in eachindex(d.tipo)
        f = AffExpr(0.0)
        for (j, v) in zip(d.cols[i], d.vals[i])
            add_to_expression!(f, v, x[j])
        end
        t, l, u = d.tipo[i], d.fila_inf[i], d.fila_sup[i]
        c = if t == "LT"
            @constraint(m, f in MOI.LessThan(u))
        elseif t == "GT"
            @constraint(m, f in MOI.GreaterThan(l))
        elseif t == "EQ"
            @constraint(m, f in MOI.EqualTo(l))
        else
            @constraint(m, f in MOI.Interval(l, u))
        end
        push!(filas, c)
    end
    # reversed: the other sense with the costs and the constant negated (the same problem)
    s = al_reves ? -1.0 : 1.0
    obj = AffExpr(s * d.constante)
    for j in 1:n
        d.costo[j] != 0.0 && add_to_expression!(obj, s * d.costo[j], x[j])
    end
    @objective(m, xor(d.maximiza, al_reves) ? MOI.MAX_SENSE : MOI.MIN_SENSE, obj)
    return m, x, filas
end

# what a KOS solve leaves in the model `p`
function resultados(p::Ptr{Cvoid})
    filas, cols = KOS._kos_dims(p)
    return (
        estado = KOS._kos_status(p),
        objetivo = KOS._kos_objective(p),
        x = KOS._kos_vector(:kos_get_solution, p, cols),
        actividad = KOS._kos_vector(:kos_get_row_activity, p, filas),
        y = KOS._kos_vector(:kos_get_duals, p, filas),
        d = KOS._kos_vector(:kos_get_reduced_costs, p, cols),
        iteraciones = KOS._kos_info(p, KOS.KOS_INFO_ITERATIONS),
        nodos = KOS._kos_info(p, KOS.KOS_INFO_NODES),
        trabajo = KOS._kos_info(p, KOS.KOS_INFO_WORK),
    )
end

function iguales(a, b)
    return a.estado == b.estado && all(_bits(getfield(a, k), getfield(b, k)) for k in
                                       (:objetivo, :x, :actividad, :y, :d, :iteraciones, :nodos, :trabajo))
end

"""
Solves the instance `nombre` of the bank with the parameters `params` by both paths and compares. Returns
(equal, KOS status, what differs).
"""
function compara(banco, nombre, params; al_reves::Bool = false)
    d = lee_dat(joinpath(banco, nombre * ".dat"))
    m, x, filas = arma(d; al_reves)
    for (k, v) in params
        set_attribute(m, k, v)
    end
    optimize!(m)
    o = unsafe_backend(m)
    a = resultados(KOS.kos_model(o))
    directo = KOS._kos_read(joinpath(banco, nombre * ".mps"), KOS.KOS_FORMAT_MPS)
    try
        if al_reves
            # KOS directly with the sense changed and the costs negated (kos_set_sense and kos_set_obj_coef)
            @assert d.constante == 0.0
            KOS._revisa(ccall(KOS._f(:kos_set_sense), Cint, (Ptr{Cvoid}, Cint), directo,
                              d.maximiza ? KOS.KOS_MINIMIZE : KOS.KOS_MAXIMIZE))
            # the zero costs stay +0.0, as in the JuMP model (which does not have those terms)
            for j in eachindex(d.costo)
                d.costo[j] == 0.0 && continue
                KOS._revisa(ccall(KOS._f(:kos_set_obj_coef), Cint, (Ptr{Cvoid}, Int64, Cdouble), directo, j - 1,
                                  -d.costo[j]))
            end
        end
        for (k, v) in params
            KOS._kos_set_param(directo, k, KOS._texto_de(v))
        end
        KOS._kos_solve(directo)
        b = resultados(directo)
        difiere = [k for k in (:estado, :objetivo, :x, :actividad, :y, :d, :iteraciones, :nodos, :trabajo)
                   if !(k == :estado ? getfield(a, k) == getfield(b, k) : _bits(getfield(a, k), getfield(b, k)))]
        # what MOI gives: the values, the duals with σ and the bounds with σd
        σ = xor(d.maximiza, al_reves) ? -1.0 : 1.0
        moi_bien = true
        if b.x !== nothing
            moi_bien &= _bits(value.(x), b.x)
            moi_bien &= _bits(Float64[value(c) for c in filas], b.actividad)
            moi_bien &= _bits(objective_value(m), b.objetivo)
        end
        if b.y !== nothing
            moi_bien &= all(_bits(dual(filas[i]), σ * b.y[i]) for i in eachindex(filas))
            for j in eachindex(x)
                dd = σ * b.d[j]
                if is_fixed(x[j])
                    moi_bien &= _bits(dual(FixRef(x[j])), dd)
                elseif has_lower_bound(x[j]) && has_upper_bound(x[j])
                    moi_bien &= _bits(dual(LowerBoundRef(x[j])), max(dd, 0.0))
                    moi_bien &= _bits(dual(UpperBoundRef(x[j])), min(dd, 0.0))
                elseif has_lower_bound(x[j])
                    moi_bien &= _bits(dual(LowerBoundRef(x[j])), dd)
                elseif has_upper_bound(x[j])
                    moi_bien &= _bits(dual(UpperBoundRef(x[j])), dd)
                end
            end
        end
        moi_bien &= termination_status(m) == KOS.termination_status_of(b.estado)
        moi_bien || push!(difiere, :moi)
        return isempty(difiere), KOS.status_string(b.estado), difiere
    finally
        KOS._kos_free(directo)
    end
end

"""
Without a license in effect, an instance over the size limit gives `size_limit` by both paths, with the same message.
"""
function tope_en_los_dos(banco, nombre, params)
    d = lee_dat(joinpath(banco, nombre * ".dat"))
    m, _, _ = arma(d)
    for (k, v) in params
        set_attribute(m, k, v)
    end
    por_jump = try
        optimize!(m)
        nothing
    catch e
        e
    end
    directo = KOS._kos_read(joinpath(banco, nombre * ".mps"), KOS.KOS_FORMAT_MPS)
    por_kos = try
        KOS._kos_solve(directo)
        nothing
    catch e
        e
    finally
        KOS._kos_free(directo)
    end
    return por_jump isa KOS.KOSError && por_kos isa KOS.KOSError && por_jump.name == "size_limit" &&
           por_kos.name == "size_limit" && por_jump.message == por_kos.message
end

function runtests(; banco = get(ENV, "KOS_JL_BANK", ""), lp_params = Pair{String,Any}[],
                  mip_params = Pair{String,Any}["work_limit" => 0.5])
    if isempty(banco)
        @test_skip "ENV[\"KOS_JL_BANK\"] not set"
        return (0, 0)
    end
    # the instances: the .dat files of the folder and of its subfolders (netlib, infeasible, MIP), by relative path
    nombres = String[]
    for (raiz, _, archivos) in walkdir(banco), f in archivos
        endswith(f, ".dat") && push!(nombres, relpath(joinpath(raiz, splitext(f)[1]), banco))
    end
    sort!(nombres)
    total, bien, sobre_el_tope = 0, 0, 0
    # the size limit of the edition in effect: (rows, columns), or `nothing` with a license in effect
    tope = KOS._json(KOS.license_status())["size_limit"]
    @testset "bitwise" begin
        for nombre in nombres
            d = lee_dat(joinpath(banco, nombre * ".dat"))
            params = any(d.entera) ? mip_params : lp_params
            if tope !== nothing && (length(d.tipo) > tope[1] || length(d.costo) > tope[2])
                igual = tope_en_los_dos(banco, nombre, params)
                sobre_el_tope += 1
                println(igual ? "same" : "DIFFERENT", " ", nombre, " size_limit (", length(d.tipo), " x ",
                        length(d.costo), ")")
                @test igual
                continue
            end
            for al_reves in (false, true)
                # the opposite sense, for the LPs without an objective constant
                al_reves && (any(d.entera) || d.constante != 0.0) && continue
                igual, estado, difiere = compara(banco, nombre, params; al_reves)
                total += 1
                bien += igual
                println(igual ? "same" : "DIFFERENT", " ", nombre, al_reves ? " (reversed)" : "", " ", estado, " ",
                        join(string.(difiere), ","))
                @test igual
            end
        end
    end
    println("bitwise: $bien of $total", sobre_el_tope > 0 ? "; over the edition's size limit: $sobre_el_tope" : "")
    return (bien, total)
end

end
