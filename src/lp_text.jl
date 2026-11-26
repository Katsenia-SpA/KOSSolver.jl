# The exact LP text of the model handed to KOS (the semantics of docs/CERTIFICADO.md, §1.1, and the form of the KOS
# writer, kos/src/formato_lp.rs): generic names (`x<j>` and `r<i>`, from 1), the objective names every column in its
# order (those with cost 0 as `+ 0 x`), so the columns are numbered in the order of the model; the numbers with the
# shortest decimal representation that reads back as the same double; a range as `lower <= expression <= upper`; an
# empty row with a term `0 x1` (which KOS does not store); the bounds as the writer writes them (only those that are
# not `[0, +inf)`); the integer columns in Generals with their explicit bounds.

"""
The data of a linear or mixed-integer model by rows, in the order in which KOS numbers them.
"""
struct DatosLp
    maximiza::Bool
    constante::Float64
    costo::Vector{Float64}
    col_inf::Vector{Float64}
    col_sup::Vector{Float64}
    entera::Vector{Bool}
    fila_inf::Vector{Float64}
    fila_sup::Vector{Float64}
    # per row, the columns (from 1, increasing, without repeats) and their coefficients (nonzero)
    fila_col::Vector{Vector{Int}}
    fila_val::Vector{Vector{Float64}}
end

_mismos_bits(a::Float64, b::Float64) = reinterpret(UInt64, a) == reinterpret(UInt64, b)

# a finite number: the shortest form that reads back as the same double (that of `repr`, with the grammar of KOS)
function _numero(io::IO, v::Float64)
    if isinf(v)
        print(io, v > 0 ? "inf" : "-inf")
    else
        print(io, repr(v))
    end
end

function _termino(io::IO, v::Float64, j::Int)
    print(io, signbit(v) ? " - " : " + ")
    _numero(io, abs(v))
    print(io, " x", j)
end

"""
    _escribe_lp(io, d::DatosLp)

Writes the LP text of `d`. The data come already checked (no NaN, finite costs and coefficients).
"""
function _escribe_lp(io::IO, d::DatosLp)
    n = length(d.costo)
    println(io, "\\ KOS.jl")
    println(io, d.maximiza ? "Maximize" : "Minimize")
    print(io, " obj:")
    for j in 1:n
        _termino(io, d.costo[j], j)
        j % 8 == 0 && print(io, "\n  ")
    end
    k = d.constante
    if k != 0.0 || signbit(k)
        print(io, signbit(k) ? " - " : " + ")
        _numero(io, abs(k))
    end
    println(io)
    println(io, "Subject To")
    for i in eachindex(d.fila_inf)
        l, u = d.fila_inf[i], d.fila_sup[i]
        rango = l > -Inf && u < Inf && !_mismos_bits(l, u)
        print(io, " r", i, ":")
        if rango
            print(io, " ")
            _numero(io, l)
            print(io, " <=")
        end
        cols, vals = d.fila_col[i], d.fila_val[i]
        if isempty(cols)
            print(io, n > 0 ? " 0 x1" : " 0")
        end
        for k in eachindex(cols)
            _termino(io, vals[k], cols[k])
            k % 8 == 0 && print(io, "\n  ")
        end
        if rango || (l == -Inf && u < Inf)
            print(io, " <= ")
            _numero(io, u)
        elseif _mismos_bits(l, u)
            print(io, " = ")
            _numero(io, l)
        else
            # finite lower bound, or free (>= -inf)
            print(io, " >= ")
            _numero(io, l)
        end
        println(io)
    end
    cotas = false
    for j in 1:n
        l, u = d.col_inf[j], d.col_sup[j]
        if _mismos_bits(l, 0.0) && u == Inf
            continue
        end
        if !cotas
            println(io, "Bounds")
            cotas = true
        end
        if _mismos_bits(l, u)
            print(io, " x", j, " = ")
            _numero(io, l)
        elseif l == -Inf && u == Inf
            print(io, " x", j, " free")
        elseif u == Inf
            print(io, " x", j, " >= ")
            _numero(io, l)
        else
            print(io, " ")
            _numero(io, l)
            print(io, " <= x", j, " <= ")
            _numero(io, u)
        end
        println(io)
    end
    if any(d.entera)
        println(io, "Generals")
        k = 0
        for j in 1:n
            if d.entera[j]
                print(io, " x", j)
                k += 1
                k % 16 == 0 && println(io)
            end
        end
        println(io)
    end
    println(io, "End")
    return nothing
end

"""
    _modelo_de_kos(d::DatosLp)

The KOS model of `d`: writes the LP text to its own temporary file, reads it with `kos_read` and deletes it.
Returns the pointer to the `kos_model` (which the caller frees).
"""
function _modelo_de_kos(d::DatosLp)
    ruta, io = mktemp(; cleanup = true)
    try
        _escribe_lp(io, d)
        close(io)
        return _kos_read(ruta, KOS_FORMAT_LP)
    finally
        isopen(io) && close(io)
        rm(ruta; force = true)
    end
end
