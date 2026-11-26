# The MathOptInterface optimizer over libkos. It is not incremental: `MOI.copy_to` builds the whole KOS model
# (through the exact LP text of lp_text.jl) and JuMP uses it behind its CachingOptimizer, which hands it the whole
# model on each optimize! (`MOI.optimize!(dest, src)` returns copied = false). The parameters are set in an ordered
# list that is applied, in its order, to the model read (the same as someone who reads the file with `kos_read` and
# sets the parameters with `kos_set_param`).

const _AFIN = MOI.ScalarAffineFunction{Float64}
const _CONJUNTOS_DE_FILA = (MOI.LessThan{Float64}, MOI.GreaterThan{Float64}, MOI.EqualTo{Float64},
                            MOI.Interval{Float64})
const _CONJUNTOS_DE_COTA = (MOI.LessThan{Float64}, MOI.GreaterThan{Float64}, MOI.EqualTo{Float64},
                            MOI.Interval{Float64}, MOI.Integer, MOI.ZeroOne)
const _FilaSet = Union{MOI.LessThan{Float64},MOI.GreaterThan{Float64},MOI.EqualTo{Float64},MOI.Interval{Float64}}
const _CotaSet = Union{MOI.LessThan{Float64},MOI.GreaterThan{Float64},MOI.EqualTo{Float64},MOI.Interval{Float64},
                       MOI.Integer,MOI.ZeroOne}

# the statuses of kos.h (by number) and their translation to MOI
const _ESTADOS = (
    "not_solved", "optimal", "optimal_flagged", "infeasible", "dual_infeasible", "unbounded",
    "infeasible_or_unbounded", "iteration_limit", "time_limit", "objective_limit", "work_limit", "node_limit",
    "solution_limit", "target_reached", "gap_after_nodes", "interrupted", "no_verdict",
)

"""
    termination_status_of(kos_status::Integer)

The `MOI.TerminationStatusCode` of a KOS status number (the numbers of `kos.h`). A number this version does not know
(from a newer KOS) is `MOI.OTHER_ERROR`, like `no_verdict`.
"""
function termination_status_of(st::Integer)
    st == 0 && return MOI.OPTIMIZE_NOT_CALLED
    st == 1 && return MOI.OPTIMAL
    st == 2 && return MOI.ALMOST_OPTIMAL
    st == 3 && return MOI.INFEASIBLE
    st == 4 && return MOI.DUAL_INFEASIBLE
    st == 5 && return MOI.DUAL_INFEASIBLE
    st == 6 && return MOI.INFEASIBLE_OR_UNBOUNDED
    st == 7 && return MOI.ITERATION_LIMIT
    st == 8 && return MOI.TIME_LIMIT
    st == 9 && return MOI.OBJECTIVE_LIMIT
    st == 10 && return MOI.OTHER_LIMIT
    st == 11 && return MOI.NODE_LIMIT
    st == 12 && return MOI.SOLUTION_LIMIT
    st == 13 && return MOI.OBJECTIVE_LIMIT
    st == 14 && return MOI.OTHER_LIMIT
    st == 15 && return MOI.INTERRUPTED
    return MOI.OTHER_ERROR
end

# where each MOI constraint went: a row (from 1) or a bound of a column (from 1)
struct _Lugar
    indice::Int
end

"""
    KOS.Optimizer()

A MathOptInterface optimizer for KOS, the Katsenia Optimization Solver (LP and MIP), over its C library `libkos`.

```julia
using JuMP, KOS
model = Model(KOS.Optimizer)
set_attribute(model, "time_limit", 60)      # any KOS parameter by name
set_attribute(model, "profile", "stable")    # a KOS profile
```
"""
mutable struct Optimizer <: MOI.AbstractOptimizer
    # the KOS model of the last copy (C_NULL without a model)
    inner::Ptr{Cvoid}
    # an empty KOS model that validates the parameters when they are set and answers their value
    validador::Ptr{Cvoid}
    # the parameters and profiles set, in their order ("profile" => name for a profile)
    parametros::Vector{Pair{String,String}}
    silent::Bool
    name::String
    # what was copied
    num_columnas::Int
    num_filas::Int
    maximiza::Bool
    factibilidad::Bool
    costo::Vector{Float64}
    # the data handed to KOS (for the Aᵀy of a Farkas certificate, the activity of a ray and the dual objective)
    datos::Union{Nothing,DatosLp}
    # the variable of each column
    variables::Vector{MOI.VariableIndex}
    filas::Dict{MOI.ConstraintIndex,_Lugar}
    conjuntos_fila::Dict{MOI.ConstraintIndex,Any}
    cotas::Dict{MOI.ConstraintIndex,_Lugar}
    conjuntos_cota::Dict{MOI.ConstraintIndex,Any}
    columna::Dict{MOI.VariableIndex,Int}
    tipos::Vector{Tuple{Type,Type}}
    nombres_var::Dict{MOI.VariableIndex,String}
    nombres_res::Dict{MOI.ConstraintIndex,String}
    # what was solved
    resuelto::Bool
    estado::Int
    objetivo::Union{Nothing,Float64}
    x::Union{Nothing,Vector{Float64}}
    actividad::Union{Nothing,Vector{Float64}}
    duales::Union{Nothing,Vector{Float64}}
    reducidos::Union{Nothing,Vector{Float64}}
    es_mip::Bool
    # the infeasibility certificates (computed on demand): `nothing` not computed yet, `missing` if there is none
    farkas::Union{Nothing,Missing,Vector{Float64}}
    rayo::Union{Nothing,Missing,Vector{Float64}}
    # the conflict (the IIS of KOS): its status, the rows and the sides of the columns that form it
    conflicto::MOI.ConflictStatusCode
    filas_en_conflicto::Set{Int}
    cotas_en_conflicto::Set{Tuple{Int,Bool}}
    binaria::Vector{Bool}
    # the side of the bound of each column that comes from the [0, 1] of a binary (and not from a user bound)
    de_binaria::Vector{Tuple{Bool,Bool}}

    function Optimizer()
        validador = _kos_create()
        m = new(C_NULL, validador, Pair{String,String}[], false, "", 0, 0, false, false, Float64[], nothing,
                MOI.VariableIndex[], Dict{MOI.ConstraintIndex,_Lugar}(), Dict{MOI.ConstraintIndex,Any}(),
                Dict{MOI.ConstraintIndex,_Lugar}(), Dict{MOI.ConstraintIndex,Any}(),
                Dict{MOI.VariableIndex,Int}(), Tuple{Type,Type}[], Dict{MOI.VariableIndex,String}(),
                Dict{MOI.ConstraintIndex,String}(), false, 0, nothing, nothing, nothing, nothing, nothing, false,
                nothing, nothing, MOI.COMPUTE_CONFLICT_NOT_CALLED, Set{Int}(), Set{Tuple{Int,Bool}}(), Bool[],
                Tuple{Bool,Bool}[])
        finalizer(_libera, m)
        return m
    end
end

function _libera(m::Optimizer)
    _kos_free(m.inner)
    m.inner = C_NULL
    _kos_free(m.validador)
    m.validador = C_NULL
    return nothing
end

Base.show(io::IO, ::Optimizer) = print(io, "A KOS optimizer")

"""
    KOS.kos_model(model::KOS.Optimizer)

The pointer to the `kos_model` of the last copy (`C_NULL` before one), for calls to the C API of `kos.h` that this
wrapper does not expose. It belongs to the optimizer: do not free it, and do not use it after the next copy.
"""
kos_model(m::Optimizer) = m.inner

"""
    KOS.interrupt!(model::KOS.Optimizer)

Asks the solve in progress to stop, from another task or thread (`kos_interrupt`). The solve ends with the status
`MOI.INTERRUPTED` (a MIP keeps its best solution and bound). Without a solve in progress it does nothing. Julia needs
more than one thread (`julia -t 2`) for another task to run while KOS solves.
"""
function interrupt!(m::Optimizer)
    p = m.inner
    p == C_NULL || _kos_interrupt(p)
    return nothing
end

"""
    KOS.write_model(model::KOS.Optimizer, path::AbstractString)

Writes the model of the last copy, exactly as KOS has it (MPS, or LP by the extension `.lp`), with the generic names
KOS.jl gives to columns (`x1`, `x2`, ...) and rows (`r1`, `r2`, ...). `kos solve` on that file with the same
parameters gives the same result, bit for bit (an LP file always; MPS except a row range that MPS cannot hold
exactly, which KOS warns about).
"""
function write_model(m::Optimizer, path::AbstractString)
    m.inner == C_NULL && error("there is no model: call MOI.copy_to or JuMP.optimize! first")
    _kos_write(m.inner, path, lowercase(splitext(path)[2]) == ".lp" ? KOS_FORMAT_LP : KOS_FORMAT_MPS)
    return nothing
end

"""
    KOS.parameters(model::KOS.Optimizer)

The parameters and profiles set on the optimizer, in order (`"profile" => name` for a profile).
"""
parameters(m::Optimizer) = copy(m.parametros)

# --- the basics ---------------------------------------------------------------------------------------------------

MOI.get(::Optimizer, ::MOI.SolverName) = "KOS"
MOI.get(::Optimizer, ::MOI.SolverVersion) = version_string()

function _sin_resultados!(m::Optimizer)
    m.resuelto = false
    m.estado = 0
    m.objetivo = nothing
    m.x = nothing
    m.actividad = nothing
    m.duales = nothing
    m.reducidos = nothing
    m.farkas = nothing
    m.rayo = nothing
    m.conflicto = MOI.COMPUTE_CONFLICT_NOT_CALLED
    empty!(m.filas_en_conflicto)
    empty!(m.cotas_en_conflicto)
    return nothing
end

function MOI.empty!(m::Optimizer)
    _kos_free(m.inner)
    m.inner = C_NULL
    m.num_columnas = 0
    m.num_filas = 0
    m.maximiza = false
    m.factibilidad = false
    m.costo = Float64[]
    m.datos = nothing
    m.variables = MOI.VariableIndex[]
    empty!(m.filas)
    empty!(m.conjuntos_fila)
    empty!(m.cotas)
    empty!(m.conjuntos_cota)
    empty!(m.columna)
    empty!(m.tipos)
    empty!(m.nombres_var)
    empty!(m.nombres_res)
    m.name = ""
    m.es_mip = false
    m.binaria = Bool[]
    m.de_binaria = Tuple{Bool,Bool}[]
    _sin_resultados!(m)
    return nothing
end

MOI.is_empty(m::Optimizer) = m.inner == C_NULL && m.num_columnas == 0 && isempty(m.filas) && isempty(m.cotas)

MOI.supports_incremental_interface(::Optimizer) = false

MOI.supports(::Optimizer, ::MOI.Name) = true
MOI.get(m::Optimizer, ::MOI.Name) = m.name
MOI.set(m::Optimizer, ::MOI.Name, v::String) = (m.name = v; nothing)

MOI.supports(::Optimizer, ::MOI.VariableName, ::Type{MOI.VariableIndex}) = true
MOI.get(m::Optimizer, ::MOI.VariableName, v::MOI.VariableIndex) = get(m.nombres_var, v, "")
MOI.supports(::Optimizer, ::MOI.ConstraintName, ::Type{<:MOI.ConstraintIndex}) = true
MOI.get(m::Optimizer, ::MOI.ConstraintName, c::MOI.ConstraintIndex) = get(m.nombres_res, c, "")

MOI.supports(::Optimizer, ::MOI.ObjectiveSense) = true
MOI.supports(::Optimizer, ::MOI.ObjectiveFunction{<:Union{_AFIN,MOI.VariableIndex}}) = true
MOI.supports_constraint(::Optimizer, ::Type{_AFIN}, ::Type{<:_FilaSet}) = true
MOI.supports_constraint(::Optimizer, ::Type{MOI.VariableIndex}, ::Type{<:_CotaSet}) = true
MOI.supports_add_constrained_variable(::Optimizer, ::Type{<:_CotaSet}) = true

MOI.get(m::Optimizer, ::MOI.NumberOfVariables) = m.num_columnas
MOI.get(m::Optimizer, ::MOI.ListOfVariableIndices) = sort!(collect(keys(m.columna)); by = v -> v.value)
MOI.is_valid(m::Optimizer, v::MOI.VariableIndex) = haskey(m.columna, v)
MOI.is_valid(m::Optimizer, c::MOI.ConstraintIndex) = haskey(m.filas, c) || haskey(m.cotas, c)

function MOI.get(m::Optimizer, ::MOI.ListOfConstraintTypesPresent)
    return unique!(Tuple{Type,Type}[t for t in m.tipos])
end

function MOI.get(m::Optimizer, ::MOI.NumberOfConstraints{F,S}) where {F,S}
    return count(c -> c isa MOI.ConstraintIndex{F,S}, Iterators.flatten((keys(m.filas), keys(m.cotas))))
end

function MOI.get(m::Optimizer, ::MOI.ListOfConstraintIndices{F,S}) where {F,S}
    r = MOI.ConstraintIndex{F,S}[c for c in Iterators.flatten((keys(m.filas), keys(m.cotas)))
                                 if c isa MOI.ConstraintIndex{F,S}]
    return sort!(r; by = c -> c.value)
end

MOI.get(m::Optimizer, ::MOI.ObjectiveSense) =
    m.factibilidad ? MOI.FEASIBILITY_SENSE : (m.maximiza ? MOI.MAX_SENSE : MOI.MIN_SENSE)

function MOI.get(m::Optimizer, ::MOI.ConstraintSet, c::MOI.ConstraintIndex)
    haskey(m.conjuntos_fila, c) && return m.conjuntos_fila[c]
    haskey(m.conjuntos_cota, c) && return m.conjuntos_cota[c]
    throw(MOI.InvalidIndex(c))
end

MOI.get(m::Optimizer, ::MOI.ConstraintFunction, c::MOI.ConstraintIndex{MOI.VariableIndex}) =
    MOI.VariableIndex(c.value)

# --- the parameters ---------------------------------------------------------------------------------------------

# the text that KOS reads for a Julia value
_texto_de(v::Bool) = v ? "on" : "off"
_texto_de(v::Integer) = string(v)
_texto_de(v::AbstractFloat) = isinf(v) ? (v > 0 ? "inf" : "-inf") : repr(Float64(v))
_texto_de(v::AbstractString) = String(v)
_texto_de(::Nothing) = "none"
_texto_de(v) = throw(ArgumentError("KOS parameters take a Bool, a number, a String or nothing, not $(typeof(v))"))

# sets a parameter or a profile on the validator (which checks it) and, if there is one, on the model; then adds it
# to the list
function _fija!(m::Optimizer, nombre::String, valor::String)
    if nombre == "profile"
        _kos_set_profile(m.validador, valor)
        m.inner == C_NULL || _kos_set_profile(m.inner, valor)
    else
        _kos_set_param(m.validador, nombre, valor)
        m.inner == C_NULL || _kos_set_param(m.inner, nombre, valor)
    end
    push!(m.parametros, nombre => valor)
    return nothing
end

MOI.supports(::Optimizer, ::MOI.RawOptimizerAttribute) = true

function MOI.set(m::Optimizer, attr::MOI.RawOptimizerAttribute, valor)
    nombre = strip(attr.name)
    try
        _fija!(m, String(nombre), _texto_de(valor))
    catch e
        if e isa KOSError && e.name == "unknown_parameter"
            throw(MOI.UnsupportedAttribute(attr, e.message))
        end
        rethrow()
    end
    return nothing
end

function MOI.get(m::Optimizer, attr::MOI.RawOptimizerAttribute)
    if attr.name == "profile"
        for (k, v) in Iterators.reverse(m.parametros)
            k == "profile" && return v
        end
        return nothing
    end
    try
        return _kos_get_param(m.validador, attr.name)
    catch e
        if e isa KOSError && e.name == "unknown_parameter"
            throw(MOI.UnsupportedAttribute(attr, e.message))
        end
        rethrow()
    end
end

MOI.supports(::Optimizer, ::MOI.Silent) = true
MOI.get(m::Optimizer, ::MOI.Silent) = m.silent
# the KOS library writes nothing to the output: Silent is only stored
MOI.set(m::Optimizer, ::MOI.Silent, v::Bool) = (m.silent = v; nothing)

MOI.supports(::Optimizer, ::MOI.TimeLimitSec) = true
MOI.set(m::Optimizer, ::MOI.TimeLimitSec, v::Union{Nothing,Real}) =
    _fija!(m, "time_limit", v === nothing ? "none" : _texto_de(Float64(v)))
function MOI.get(m::Optimizer, ::MOI.TimeLimitSec)
    v = _kos_get_param(m.validador, "time_limit")
    return v == "none" ? nothing : parse(Float64, v)
end

MOI.supports(::Optimizer, ::MOI.NumberOfThreads) = true
MOI.set(m::Optimizer, ::MOI.NumberOfThreads, v::Union{Nothing,Integer}) =
    _fija!(m, "threads", v === nothing ? "1" : string(v))
MOI.get(m::Optimizer, ::MOI.NumberOfThreads) = parse(Int, _kos_get_param(m.validador, "threads"))

MOI.supports(::Optimizer, ::MOI.RelativeGapTolerance) = true
MOI.set(m::Optimizer, ::MOI.RelativeGapTolerance, v::Union{Nothing,Real}) =
    _fija!(m, "mip_relative_gap", v === nothing ? "1e-4" : _texto_de(Float64(v)))
MOI.get(m::Optimizer, ::MOI.RelativeGapTolerance) = parse(Float64, _kos_get_param(m.validador, "mip_relative_gap"))

MOI.supports(::Optimizer, ::MOI.AbsoluteGapTolerance) = true
MOI.set(m::Optimizer, ::MOI.AbsoluteGapTolerance, v::Union{Nothing,Real}) =
    _fija!(m, "mip_absolute_gap", v === nothing ? "1e-6" : _texto_de(Float64(v)))
MOI.get(m::Optimizer, ::MOI.AbsoluteGapTolerance) = parse(Float64, _kos_get_param(m.validador, "mip_absolute_gap"))

# --- the copy -------------------------------------------------------------------------------------------------

function _revisa_finito(v::Float64, que)
    isfinite(v) || throw(ArgumentError("KOS: $que is $v: costs, coefficients and constants must be finite"))
    return v
end

function _revisa_cota(v::Float64, que)
    isnan(v) && throw(ArgumentError("KOS: $que is NaN"))
    return v
end

# the coefficients of an affine function by column, summed in the order of its terms and without zeros
function _terminos(f, columna::Dict{MOI.VariableIndex,Int}, que)
    suma = Dict{Int,Float64}()
    orden = Int[]
    for t in f.terms
        j = columna[t.variable]
        c = _revisa_finito(t.coefficient, que)
        if haskey(suma, j)
            suma[j] += c
        else
            suma[j] = c
            push!(orden, j)
        end
    end
    cols = sort!([j for j in orden if suma[j] != 0.0])
    return cols, Float64[suma[j] for j in cols]
end

# a copy that fails (invalid data, something KOS does not support) leaves the optimizer empty
function MOI.copy_to(dest::Optimizer, src::MOI.ModelLike)
    try
        return _copia!(dest, src)
    catch
        MOI.empty!(dest)
        rethrow()
    end
end

function _copia!(dest::Optimizer, src::MOI.ModelLike)
    MOI.empty!(dest)
    mapa = MOI.Utilities.IndexMap()
    # the model attributes
    funcion_objetivo = nothing
    for attr in MOI.get(src, MOI.ListOfModelAttributesSet())
        if attr isa MOI.Name
            dest.name = MOI.get(src, attr)
        elseif attr isa MOI.ObjectiveSense
            # read below
        elseif attr isa MOI.ObjectiveFunction
            MOI.supports(dest, attr) || throw(MOI.UnsupportedAttribute(attr,
                "KOS solves linear objectives only (an affine function or a single variable)"))
            funcion_objetivo = MOI.get(src, attr)
        else
            throw(MOI.UnsupportedAttribute(attr))
        end
    end
    # the names do not reach KOS and the starting values are ignored (the C API does not take a starting point), as
    # MOI.Utilities.default_copy_to does with a destination that does not support them
    for attr in MOI.get(src, MOI.ListOfVariableAttributesSet())
        attr isa Union{MOI.VariableName,MOI.VariablePrimalStart} && continue
        throw(MOI.UnsupportedAttribute(attr, "KOS.jl does not take this variable attribute"))
    end
    # the columns, in the order of creation
    variables = sort!(MOI.get(src, MOI.ListOfVariableIndices()); by = v -> v.value)
    n = length(variables)
    dest.variables = variables
    for (j, v) in enumerate(variables)
        dest.columna[v] = j
        mapa[v] = v
    end
    if MOI.VariableName() in MOI.get(src, MOI.ListOfVariableAttributesSet())
        for v in variables
            nombre = MOI.get(src, MOI.VariableName(), v)
            isempty(nombre) || (dest.nombres_var[v] = nombre)
        end
    end
    col_inf = fill(-Inf, n)
    col_sup = fill(Inf, n)
    entera = fill(false, n)
    binaria = fill(false, n)
    tipos = MOI.get(src, MOI.ListOfConstraintTypesPresent())
    for (F, S) in tipos
        soportada = (F == MOI.VariableIndex && S in _CONJUNTOS_DE_COTA) || (F == _AFIN && S in _CONJUNTOS_DE_FILA)
        soportada || throw(MOI.UnsupportedConstraint{F,S}(
            "KOS solves LP and MIP: affine constraints in LessThan, GreaterThan, EqualTo or Interval, and variables " *
            "with those bounds, Integer or ZeroOne"))
    end
    for attr in Iterators.flatten([MOI.get(src, MOI.ListOfConstraintAttributesSet{F,S}()) for (F, S) in tipos])
        attr isa Union{MOI.ConstraintName,MOI.ConstraintPrimalStart,MOI.ConstraintDualStart} && continue
        throw(MOI.UnsupportedAttribute(attr, "KOS.jl does not take this constraint attribute"))
    end
    # the bounds and the integrality of the columns
    for S in _CONJUNTOS_DE_COTA
        (MOI.VariableIndex, S) in tipos || continue
        push!(dest.tipos, (MOI.VariableIndex, S))
        cis = sort!(MOI.get(src, MOI.ListOfConstraintIndices{MOI.VariableIndex,S}()); by = c -> c.value)
        for ci in cis
            v = MOI.get(src, MOI.ConstraintFunction(), ci)
            s = MOI.get(src, MOI.ConstraintSet(), ci)
            j = dest.columna[v]
            if s isa MOI.LessThan
                col_sup[j] = _revisa_cota(s.upper, "the upper bound of a variable")
            elseif s isa MOI.GreaterThan
                col_inf[j] = _revisa_cota(s.lower, "the lower bound of a variable")
            elseif s isa MOI.EqualTo
                col_inf[j] = col_sup[j] = _revisa_cota(s.value, "the value of a fixed variable")
            elseif s isa MOI.Interval
                col_inf[j] = _revisa_cota(s.lower, "the lower bound of a variable")
                col_sup[j] = _revisa_cota(s.upper, "the upper bound of a variable")
            elseif s isa MOI.Integer
                entera[j] = true
            else
                entera[j] = true
                binaria[j] = true
            end
            nueva = MOI.ConstraintIndex{MOI.VariableIndex,S}(v.value)
            dest.cotas[nueva] = _Lugar(j)
            dest.conjuntos_cota[nueva] = s
            mapa[ci] = nueva
        end
    end
    dest.de_binaria = fill((false, false), n)
    for j in 1:n
        if binaria[j]
            dest.de_binaria[j] = (!(col_inf[j] >= 0.0), !(col_sup[j] <= 1.0))
            col_inf[j] = max(col_inf[j], 0.0)
            col_sup[j] = min(col_sup[j], 1.0)
        end
    end
    # the rows: the types in the order LessThan, GreaterThan, EqualTo, Interval and, within each, by index
    fila_inf, fila_sup = Float64[], Float64[]
    fila_col, fila_val = Vector{Int}[], Vector{Float64}[]
    for S in _CONJUNTOS_DE_FILA
        (_AFIN, S) in tipos || continue
        push!(dest.tipos, (_AFIN, S))
        cis = sort!(MOI.get(src, MOI.ListOfConstraintIndices{_AFIN,S}()); by = c -> c.value)
        for ci in cis
            f = MOI.get(src, MOI.ConstraintFunction(), ci)
            s = MOI.get(src, MOI.ConstraintSet(), ci)
            if !iszero(f.constant)
                throw(MOI.ScalarFunctionConstantNotZero{Float64,_AFIN,S}(f.constant))
            end
            cols, vals = _terminos(f, dest.columna, "a constraint coefficient")
            l, u = if s isa MOI.LessThan
                -Inf, _revisa_cota(s.upper, "a constraint bound")
            elseif s isa MOI.GreaterThan
                _revisa_cota(s.lower, "a constraint bound"), Inf
            elseif s isa MOI.EqualTo
                v = _revisa_cota(s.value, "a constraint bound")
                v, v
            else
                _revisa_cota(s.lower, "a constraint bound"), _revisa_cota(s.upper, "a constraint bound")
            end
            push!(fila_inf, l)
            push!(fila_sup, u)
            push!(fila_col, cols)
            push!(fila_val, vals)
            nueva = MOI.ConstraintIndex{_AFIN,S}(length(fila_inf))
            dest.filas[nueva] = _Lugar(length(fila_inf))
            dest.conjuntos_fila[nueva] = s
            mapa[ci] = nueva
        end
        if MOI.ConstraintName() in MOI.get(src, MOI.ListOfConstraintAttributesSet{_AFIN,S}())
            for ci in cis
                nombre = MOI.get(src, MOI.ConstraintName(), ci)
                isempty(nombre) || (dest.nombres_res[mapa[ci]] = nombre)
            end
        end
    end
    # the objective
    sentido = MOI.get(src, MOI.ObjectiveSense())
    dest.factibilidad = sentido == MOI.FEASIBILITY_SENSE
    dest.maximiza = sentido == MOI.MAX_SENSE
    costo = zeros(n)
    constante = 0.0
    if !dest.factibilidad && funcion_objetivo !== nothing
        if funcion_objetivo isa MOI.VariableIndex
            costo[dest.columna[funcion_objetivo]] = 1.0
        else
            cols, vals = _terminos(funcion_objetivo, dest.columna, "an objective coefficient")
            costo[cols] .= vals
            constante = _revisa_finito(funcion_objetivo.constant, "the objective constant")
        end
    end
    dest.costo = costo
    dest.num_columnas = n
    dest.num_filas = length(fila_inf)
    dest.es_mip = any(entera)
    dest.binaria = binaria
    datos = DatosLp(dest.maximiza, constante, costo, col_inf, col_sup, entera, fila_inf, fila_sup, fila_col,
                    fila_val)
    dest.datos = datos
    dest.inner = _modelo_de_kos(datos)
    for (k, v) in dest.parametros
        if k == "profile"
            _kos_set_profile(dest.inner, v)
        else
            _kos_set_param(dest.inner, k, v)
        end
    end
    return mapa
end

# --- solving ---------------------------------------------------------------------------------------------------

function MOI.optimize!(m::Optimizer)
    if m.inner == C_NULL
        # without a copy (an empty model): the empty KOS model
        MOI.copy_to(m, MOI.Utilities.Model{Float64}())
    end
    _sin_resultados!(m)
    m.estado = _kos_solve(m.inner)
    m.resuelto = true
    m.objetivo = _kos_objective(m.inner)
    m.x = _kos_vector(:kos_get_solution, m.inner, m.num_columnas)
    m.actividad = m.x === nothing ? nothing : _kos_vector(:kos_get_row_activity, m.inner, m.num_filas)
    if !m.es_mip
        m.duales = _kos_vector(:kos_get_duals, m.inner, m.num_filas)
        m.reducidos = _kos_vector(:kos_get_reduced_costs, m.inner, m.num_columnas)
    end
    return nothing
end

function MOI.optimize!(dest::Optimizer, src::MOI.ModelLike)
    mapa = MOI.copy_to(dest, src)
    MOI.optimize!(dest)
    return mapa, false
end

# --- the infeasibility certificates -----------------------------------------------------------------------------

# the vector `clave` ("dual" or "ray") of the certificate of the last solve, or `missing` if KOS does not give it
function _vector_del_certificado(m::Optimizer, clave::String, tipo::String, largo::Int)
    ruta, io = mktemp(; cleanup = true)
    close(io)
    try
        _kos_write_certificate(m.inner, ruta) || return missing
        doc = _json(read(ruta, String))
        get(doc, "kind", "") == tipo || return missing
        v = get(doc, clave, nothing)
        (v isa Vector && length(v) == largo) || return missing
        return Float64[_numero_del_certificado(x) for x in v]
    finally
        rm(ruta; force = true)
    end
end

function _farkas!(m::Optimizer)
    if m.farkas === nothing
        m.farkas = (m.resuelto && !m.es_mip && m.estado == 3) ?
                   _vector_del_certificado(m, "dual", "infeasible", m.num_filas) : missing
    end
    return m.farkas
end

function _rayo!(m::Optimizer)
    if m.rayo === nothing
        m.rayo = (m.resuelto && !m.es_mip && m.estado == 4) ?
                 _vector_del_certificado(m, "ray", "unbounded", m.num_columnas) : missing
    end
    return m.rayo
end

# --- the results ------------------------------------------------------------------------------------------------

MOI.get(m::Optimizer, ::MOI.TerminationStatus) = m.resuelto ? termination_status_of(m.estado) : MOI.OPTIMIZE_NOT_CALLED

function MOI.get(m::Optimizer, ::MOI.RawStatusString)
    m.resuelto || return "optimize not called"
    return 0 <= m.estado < length(_ESTADOS) ? _ESTADOS[m.estado+1] : status_string(m.estado)
end

"""
    KOS.Status()

The status of the last solve as KOS names it (`"optimal"`, `"optimal_flagged"`, `"work_limit"`, ...), the same as
`MOI.RawStatusString`.
"""
struct Status <: MOI.AbstractModelAttribute end
MOI.is_set_by_optimize(::Status) = true
MOI.get(m::Optimizer, ::Status) = MOI.get(m, MOI.RawStatusString())

"""
    KOS.FlagOrigin()

Why the last LP ended `optimal_flagged` (`"unscaled_violation"`, `"objective_unproven"`, ...), `""` otherwise.
"""
struct FlagOrigin <: MOI.AbstractModelAttribute end
MOI.is_set_by_optimize(::FlagOrigin) = true
MOI.get(m::Optimizer, ::FlagOrigin) = m.inner == C_NULL ? "" : _kos_flag_origin(m.inner)

"""
    KOS.NoVerdictReason()

Why the last LP ended `no_verdict` (`MOI.OTHER_ERROR`), `""` otherwise.
"""
struct NoVerdictReason <: MOI.AbstractModelAttribute end
MOI.is_set_by_optimize(::NoVerdictReason) = true
MOI.get(m::Optimizer, ::NoVerdictReason) = m.inner == C_NULL ? "" : _kos_no_verdict_reason(m.inner)

"""
    KOS.Work()

The deterministic work of the last solve (a unit is about 1e9 visited entries).
"""
struct Work <: MOI.AbstractModelAttribute end
MOI.is_set_by_optimize(::Work) = true
MOI.get(m::Optimizer, ::Work) = _info(m, KOS_INFO_WORK)

function _info(m::Optimizer, que)
    m.resuelto || return 0.0
    v = _kos_info(m.inner, que)
    return v === nothing ? NaN : v
end

function _estado_primal(m::Optimizer)
    m.resuelto || return MOI.NO_SOLUTION
    if m.x !== nothing
        return m.estado == 2 ? MOI.NEARLY_FEASIBLE_POINT : MOI.FEASIBLE_POINT
    end
    return _rayo!(m) isa Vector ? MOI.INFEASIBILITY_CERTIFICATE : MOI.NO_SOLUTION
end

function _estado_dual(m::Optimizer)
    m.resuelto || return MOI.NO_SOLUTION
    if m.duales !== nothing
        return m.estado == 2 ? MOI.NEARLY_FEASIBLE_POINT : MOI.FEASIBLE_POINT
    end
    return _farkas!(m) isa Vector ? MOI.INFEASIBILITY_CERTIFICATE : MOI.NO_SOLUTION
end

function MOI.get(m::Optimizer, attr::MOI.PrimalStatus)
    attr.result_index == 1 || return MOI.NO_SOLUTION
    return _estado_primal(m)
end

function MOI.get(m::Optimizer, attr::MOI.DualStatus)
    attr.result_index == 1 || return MOI.NO_SOLUTION
    return _estado_dual(m)
end

function MOI.get(m::Optimizer, ::MOI.ResultCount)
    m.resuelto || return 0
    return (_estado_primal(m) != MOI.NO_SOLUTION || _estado_dual(m) != MOI.NO_SOLUTION) ? 1 : 0
end

function MOI.get(m::Optimizer, attr::MOI.ObjectiveValue)
    MOI.check_result_index_bounds(m, attr)
    m.factibilidad && return 0.0
    if m.x === nothing
        r = _rayo!(m)
        r isa Vector || throw(MOI.GetAttributeNotAllowed(attr, "KOS has no solution"))
        # the objective of a ray: cᵀr (without the constant)
        return sum(m.costo[j] * r[j] for j in eachindex(r); init = 0.0)
    end
    return m.objetivo
end

function MOI.get(m::Optimizer, attr::MOI.ObjectiveBound)
    m.resuelto || return m.maximiza ? Inf : -Inf
    if m.es_mip
        b = _kos_info(m.inner, KOS_INFO_BOUND)
        b !== nothing && return b
    elseif m.estado == 1 && m.objetivo !== nothing
        return m.objetivo
    end
    return m.maximiza ? Inf : -Inf
end

function MOI.get(m::Optimizer, attr::MOI.RelativeGap)
    m.resuelto || throw(MOI.GetAttributeNotAllowed(attr, "optimize! has not been called"))
    if m.es_mip
        g = _kos_info(m.inner, KOS_INFO_GAP)
        g !== nothing && return g
    elseif m.estado == 1
        return 0.0
    end
    throw(MOI.GetAttributeNotAllowed(attr, "KOS has no gap for this solve"))
end

MOI.get(m::Optimizer, ::MOI.SolveTimeSec) = _info(m, KOS_INFO_SECONDS)

function MOI.get(m::Optimizer, ::MOI.SimplexIterations)
    v = _info(m, KOS_INFO_ITERATIONS)
    return isnan(v) ? Int64(0) : Int64(v)
end

function MOI.get(m::Optimizer, ::MOI.NodeCount)
    v = _info(m, KOS_INFO_NODES)
    return isnan(v) ? Int64(0) : Int64(v)
end

function MOI.get(m::Optimizer, attr::MOI.VariablePrimal, v::MOI.VariableIndex)
    MOI.check_result_index_bounds(m, attr)
    j = m.columna[v]
    if m.x !== nothing
        return m.x[j]
    end
    r = _rayo!(m)
    r isa Vector || throw(MOI.GetAttributeNotAllowed(attr, "KOS has no primal solution"))
    return r[j]
end

# the activity of a row: the one of KOS for a solution; for a ray, a_i r
function MOI.get(m::Optimizer, attr::MOI.ConstraintPrimal, c::MOI.ConstraintIndex{_AFIN})
    MOI.check_result_index_bounds(m, attr)
    i = m.filas[c].indice
    m.actividad !== nothing && return m.actividad[i]
    r = _rayo!(m)
    r isa Vector || throw(MOI.GetAttributeNotAllowed(attr, "KOS has no primal solution"))
    return _ar(m, r, i)
end

function MOI.get(m::Optimizer, attr::MOI.ConstraintPrimal, c::MOI.ConstraintIndex{MOI.VariableIndex})
    MOI.check_result_index_bounds(m, attr)
    return MOI.get(m, MOI.VariablePrimal(attr.result_index), MOI.VariableIndex(c.value))
end

# The sign of the duals. KOS gives y = ∂z/∂b in the sense of the model and d = c − Aᵀy. MOI defines the duals by
# conic duality, independent of the sense: λ = σy (σ = 1 when minimizing, −1 when maximizing), so a ≥ row has λ ≥ 0
# and a ≤ row, λ ≤ 0. The bounds of a column receive σd: the positive part goes to its lower bound (GreaterThan) and
# the negative part to the upper one (LessThan); EqualTo and Interval receive the whole σd. For a Farkas certificate
# (and KOS's, with F(y) > 0, docs/CERTIFICADO.md §4), MOI asks for −y on the rows and Aᵀy on the bounds, independent
# of the sense.
_sigma(m::Optimizer) = m.maximiza ? -1.0 : 1.0

function MOI.get(m::Optimizer, attr::MOI.ConstraintDual, c::MOI.ConstraintIndex{_AFIN})
    MOI.check_result_index_bounds(m, attr)
    i = m.filas[c].indice
    if m.duales !== nothing
        return _sigma(m) * m.duales[i]
    end
    y = _farkas!(m)
    y isa Vector || throw(MOI.GetAttributeNotAllowed(attr, "KOS has no dual solution"))
    return -y[i]
end

function _dual_de_columna(m::Optimizer, j::Int)
    if m.reducidos !== nothing
        return _sigma(m) * m.reducidos[j]
    end
    y = _farkas!(m)
    y isa Vector || return nothing
    return _aty(m, y)[j]
end

function MOI.get(m::Optimizer, attr::MOI.ConstraintDual, c::MOI.ConstraintIndex{MOI.VariableIndex,S}) where {S}
    MOI.check_result_index_bounds(m, attr)
    S <: Union{MOI.Integer,MOI.ZeroOne} && throw(MOI.GetAttributeNotAllowed(attr, "integrality has no dual"))
    j = m.cotas[c].indice
    d = _dual_de_columna(m, j)
    d === nothing && throw(MOI.GetAttributeNotAllowed(attr, "KOS has no dual solution"))
    if S <: MOI.GreaterThan
        # with both bounds, the part that belongs to the lower one; with only this one, all of it
        return _tiene_cota(m, j, MOI.LessThan{Float64}) ? max(d, 0.0) : d
    elseif S <: MOI.LessThan
        return _tiene_cota(m, j, MOI.GreaterThan{Float64}) ? min(d, 0.0) : d
    end
    return d
end

_tiene_cota(m::Optimizer, j::Int, ::Type{S}) where {S} =
    haskey(m.cotas, MOI.ConstraintIndex{MOI.VariableIndex,S}(_variable_de(m, j).value))

_variable_de(m::Optimizer, j::Int) = m.variables[j]

# Aᵀy with the data handed to KOS
function _aty(m::Optimizer, y::Vector{Float64})
    d = m.datos
    w = zeros(m.num_columnas)
    for i in eachindex(d.fila_col), k in eachindex(d.fila_col[i])
        w[d.fila_col[i][k]] += d.fila_val[i][k] * y[i]
    end
    return w
end

# a_i r with the data handed to KOS
function _ar(m::Optimizer, r::Vector{Float64}, i::Int)
    d = m.datos
    return sum(d.fila_val[i][k] * r[d.fila_col[i][k]] for k in eachindex(d.fila_col[i]); init = 0.0)
end

# what the constraint with set `s` and MOI dual `λ` contributes to the dual objective (Σ s_i λ_i), with the side of
# an interval as MOI chooses it (the finite one; with both, the one of the sign of λ); an infinite bound with λ = 0
# contributes nothing
_por(v::Float64, λ::Float64) = λ == 0.0 ? 0.0 : v * λ
_aporte(s::MOI.LessThan, λ) = _por(s.upper, λ)
_aporte(s::MOI.GreaterThan, λ) = _por(s.lower, λ)
_aporte(s::MOI.EqualTo, λ) = _por(s.value, λ)
function _aporte(s::MOI.Interval, λ)
    if isfinite(s.lower) && (!isfinite(s.upper) || λ > 0)
        return _por(s.lower, λ)
    elseif isfinite(s.upper) && (!isfinite(s.lower) || λ < 0)
        return _por(s.upper, λ)
    end
    return 0.0
end
_aporte(::Union{MOI.Integer,MOI.ZeroOne}, λ) = 0.0

# The MOI dual objective: b₀ + σ Σ sᵢ λᵢ over the rows and the bounds (without b₀ for a Farkas certificate), which is
# what MOI.Utilities.get_fallback computes with the conventions of MOI's docs/src/background/duality.md.
function MOI.get(m::Optimizer, attr::MOI.DualObjectiveValue)
    MOI.check_result_index_bounds(m, attr)
    estado = _estado_dual(m)
    estado == MOI.NO_SOLUTION && throw(MOI.GetAttributeNotAllowed(attr, "KOS has no dual solution"))
    suma = 0.0
    for (c, s) in m.conjuntos_fila
        suma += _aporte(s, MOI.get(m, MOI.ConstraintDual(attr.result_index), c))
    end
    for (c, s) in m.conjuntos_cota
        s isa Union{MOI.Integer,MOI.ZeroOne} && continue
        suma += _aporte(s, MOI.get(m, MOI.ConstraintDual(attr.result_index), c))
    end
    valor = _sigma(m) * suma
    if estado != MOI.INFEASIBILITY_CERTIFICATE && !m.factibilidad
        valor += m.datos.constante
    end
    return valor
end

# --- the conflict (the IIS of KOS) -----------------------------------------------------------------------------

# KOS gives the IIS of the LP (of the relaxation of a MIP). Without an IIS (KOS_ERROR_NOT_APPLICABLE), the status of
# the last solve decides, not the text of the error: with a solution (an optimal or flagged LP, a MIP with an
# incumbent) the model is feasible, NO_CONFLICT_EXISTS; without one (a limit, a MIP infeasible by integrality),
# NO_CONFLICT_FOUND
function MOI.compute_conflict!(m::Optimizer)
    # the conflict is that of the copied model: without a copy (before optimize!) there is no model
    m.inner == C_NULL && error("KOS.jl computes the conflict of the copied model: call optimize! first")
    empty!(m.filas_en_conflicto)
    empty!(m.cotas_en_conflicto)
    r = _kos_iis(m.inner)
    if r === nothing
        m.conflicto = _sin_conflicto(m)
        return
    end
    filas, cols = r
    foreach(f -> push!(m.filas_en_conflicto, f[1]), filas)
    foreach(c -> push!(m.cotas_en_conflicto, c), cols)
    m.conflicto = MOI.CONFLICT_FOUND
    return
end

# the conflict status when KOS gives no IIS, by the last solve
_sin_conflicto(m::Optimizer) = (m.resuelto && m.x !== nothing) ? MOI.NO_CONFLICT_EXISTS : MOI.NO_CONFLICT_FOUND

MOI.get(m::Optimizer, ::MOI.ConflictStatus) = m.conflicto

function _revisa_conflicto(m::Optimizer, attr)
    m.conflicto == MOI.CONFLICT_FOUND ||
        throw(MOI.GetAttributeNotAllowed(attr, "there is no conflict: MOI.ConflictStatus is $(m.conflicto)"))
end

function MOI.get(m::Optimizer, attr::MOI.ConstraintConflictStatus, c::MOI.ConstraintIndex{_AFIN})
    _revisa_conflicto(m, attr)
    return m.filas[c].indice in m.filas_en_conflicto ? MOI.IN_CONFLICT : MOI.NOT_IN_CONFLICT
end

# a variable bound is in the conflict if its side is and the bound is what gives that side: GreaterThan the lower
# side, LessThan the upper side, EqualTo and Interval either; ZeroOne, the side of [0, 1] that no other user bound
# gives; Integer never (the IIS is that of the relaxation)
function MOI.get(m::Optimizer, attr::MOI.ConstraintConflictStatus,
                 c::MOI.ConstraintIndex{MOI.VariableIndex,S}) where {S}
    _revisa_conflicto(m, attr)
    j = m.cotas[c].indice
    inf_binaria, sup_binaria = m.de_binaria[j]
    inferior = (j, false) in m.cotas_en_conflicto
    superior = (j, true) in m.cotas_en_conflicto
    en = if S <: MOI.GreaterThan
        inferior && !inf_binaria
    elseif S <: MOI.LessThan
        superior && !sup_binaria
    elseif S <: Union{MOI.EqualTo,MOI.Interval}
        (inferior && !inf_binaria) || (superior && !sup_binaria)
    elseif S <: MOI.ZeroOne
        (inferior && inf_binaria) || (superior && sup_binaria)
    else
        false
    end
    return en ? MOI.IN_CONFLICT : MOI.NOT_IN_CONFLICT
end
