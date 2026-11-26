# The reading of the KOS certificate (a JSON in the open "kos-certificate" format, docs/CERTIFICADO.md): a minimal
# JSON reader of its own (objects, arrays, strings, numbers, true, false, null) and the numbers of the format, which
# are JSON numbers or exact rationals as text ("p", "p/q", with p and q in decimal or in hexadecimal with 0x).

struct _ErrorJson <: Exception
    mensaje::String
end

mutable struct _Lector
    s::String
    i::Int
end

function _blancos!(l::_Lector)
    while l.i <= ncodeunits(l.s) && l.s[l.i] in (' ', '\t', '\n', '\r')
        l.i = nextind(l.s, l.i)
    end
end

_mira(l::_Lector) = l.i <= ncodeunits(l.s) ? l.s[l.i] : '\0'

function _espera!(l::_Lector, c::Char)
    _mira(l) == c || throw(_ErrorJson("expected '$c' at byte $(l.i)"))
    l.i = nextind(l.s, l.i)
end

function _valor!(l::_Lector)
    _blancos!(l)
    c = _mira(l)
    if c == '{'
        _espera!(l, '{')
        d = Dict{String,Any}()
        _blancos!(l)
        if _mira(l) == '}'
            _espera!(l, '}')
            return d
        end
        while true
            _blancos!(l)
            k = _texto!(l)
            _blancos!(l)
            _espera!(l, ':')
            d[k] = _valor!(l)
            _blancos!(l)
            _mira(l) == ',' || break
            _espera!(l, ',')
        end
        _espera!(l, '}')
        return d
    elseif c == '['
        _espera!(l, '[')
        v = Any[]
        _blancos!(l)
        if _mira(l) == ']'
            _espera!(l, ']')
            return v
        end
        while true
            push!(v, _valor!(l))
            _blancos!(l)
            _mira(l) == ',' || break
            _espera!(l, ',')
        end
        _espera!(l, ']')
        return v
    elseif c == '"'
        return _texto!(l)
    elseif startswith(SubString(l.s, l.i), "true")
        l.i += 4
        return true
    elseif startswith(SubString(l.s, l.i), "false")
        l.i += 5
        return false
    elseif startswith(SubString(l.s, l.i), "null")
        l.i += 4
        return nothing
    end
    m = match(r"-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?", l.s, l.i)
    (m === nothing || m.offset != l.i) && throw(_ErrorJson("unexpected character at byte $(l.i)"))
    l.i += ncodeunits(m.match)
    return parse(Float64, m.match)
end

function _texto!(l::_Lector)
    _espera!(l, '"')
    io = IOBuffer()
    while true
        l.i > ncodeunits(l.s) && throw(_ErrorJson("unterminated string"))
        c = l.s[l.i]
        l.i = nextind(l.s, l.i)
        if c == '"'
            break
        elseif c == '\\'
            e = l.s[l.i]
            l.i = nextind(l.s, l.i)
            if e == 'u'
                print(io, Char(parse(UInt16, l.s[l.i:l.i+3]; base = 16)))
                l.i += 4
            else
                print(io, get(Dict('n' => '\n', 't' => '\t', 'r' => '\r', 'b' => '\b', 'f' => '\f'), e, e))
            end
        else
            print(io, c)
        end
    end
    return String(take!(io))
end

function _json(s::String)
    l = _Lector(s, 1)
    v = _valor!(l)
    _blancos!(l)
    l.i > ncodeunits(l.s) || throw(_ErrorJson("text after the JSON value"))
    return v
end

function _entero_del_certificado(t::AbstractString)
    if startswith(t, "0x")
        return parse(BigInt, t[3:end]; base = 16)
    end
    return parse(BigInt, t; base = 10)
end

# a number of the certificate as a double: the JSON numbers as they are; the rationals, rounded to the nearest double
function _numero_del_certificado(x)
    x isa Float64 && return x
    x isa AbstractString || throw(_ErrorJson("a number of the certificate is neither a number nor a rational"))
    negativo = startswith(x, "-")
    t = negativo ? x[2:end] : x
    partes = split(t, '/')
    p = _entero_del_certificado(partes[1])
    q = length(partes) == 2 ? _entero_del_certificado(partes[2]) : big(1)
    v = Float64(p // q)
    return negativo ? -v : v
end
