# The thin layer over the C API of KOS (kos.h, ABI 1): the constants, the loading of the library and one Julia
# function per call that the wrapper uses. Each call that fails throws `KOSError` with the code and the message of
# `kos_last_error`, which is read on the same thread right after (there is no yield point between the two calls, so
# the task does not change threads).

const KOS_ABI_VERSION = 1

const KOS_OK = 0
const KOS_ERROR_NO_SOLUTION = 8
const KOS_ERROR_NOT_APPLICABLE = 9
const KOS_ERROR_BUFFER_TOO_SMALL = 12
const KOS_ERROR_SIZE_LIMIT = 13

const KOS_FORMAT_MPS = 1
const KOS_FORMAT_LP = 2
const KOS_MINIMIZE = 1
const KOS_MAXIMIZE = -1

const KOS_INFO_ITERATIONS = 0
const KOS_INFO_NODES = 1
const KOS_INFO_BOUND = 2
const KOS_INFO_GAP = 3
const KOS_INFO_SECONDS = 4
const KOS_INFO_WORK = 5

"""
    KOSError(code, name, message)

An error returned by the KOS C library: `code` is the number of `kos.h`, `name` its stable name
(`"unknown_parameter"`, `"invalid_value"`, `"file_format"`, ...) and `message` what happened.
"""
struct KOSError <: Exception
    code::Int
    name::String
    message::String
end

Base.showerror(io::IO, e::KOSError) = print(io, "KOSError: ", e.name, ": ", e.message)

# the pointers to the functions of libkos, resolved when the package loads
const _FUNCIONES = (
    :kos_abi_version, :kos_version_string, :kos_last_error, :kos_error_string, :kos_status_string,
    :kos_create, :kos_read, :kos_free, :kos_write, :kos_get_dims,
    :kos_set_param, :kos_get_param, :kos_set_profile, :kos_num_params, :kos_param_name,
    :kos_solve, :kos_interrupt, :kos_get_status, :kos_get_objective, :kos_get_solution, :kos_get_row_activity,
    :kos_get_duals, :kos_get_reduced_costs, :kos_get_info, :kos_write_certificate,
    :kos_get_flag_origin, :kos_get_no_verdict_reason, :kos_is_integer, :kos_set_sense, :kos_set_obj_coef,
    :kos_compute_iis, :kos_get_iis_rows, :kos_get_iis_cols, :kos_license_status,
)
const _PUNTEROS = Dict{Symbol,Ptr{Cvoid}}()
const _RUTA = Ref{String}("")
const _ORIGEN = Ref{String}("")
const _ERROR_DE_CARGA = Ref{String}("")

"""
    KOS.library_path()

The path of the KOS C library in use, or `""` if it could not be loaded (see `KOS.load_error()`).
"""
library_path() = _RUTA[]

"""
    KOS.library_source()

How KOS.jl found the KOS C library in use: `"KOS_LIBRARY"` (the path of `ENV["KOS_LIBRARY"]`), `"python"` (the
library that comes with the Python package `kos-solver`) or `"system"` (the system's loader); `""` if none was
loaded.
"""
library_source() = _ORIGEN[]

"""
    KOS.load_error()

Why the KOS C library could not be loaded (`""` if it was).
"""
load_error() = _ERROR_DE_CARGA[]

# How many seconds to wait for the answer of a Python (a `Ref` so that the tests can shorten it).
const _PLAZO_DE_PYTHON = Ref(10.0)

# What Python is asked: where the library that comes with the `kos-solver` package is. Without the working directory
# among the module paths (with `-c` it comes first): a `kos.py` in that directory is not the installed package.
const _CODIGO_DE_PYTHON = "import sys\n" *
                          "sys.path[:] = [p for p in sys.path if p not in ('', '.')]\n" *
                          "import kos\n" *
                          "print(kos.library_path())\n"

# The Pythons of the PATH that are asked, in order and without repeating the same executable.
function _pythons()
    v = String[]
    for nombre in ("python3", "python")
        exe = Sys.which(nombre)
        exe === nothing && continue
        any(x -> realpath(x) == realpath(exe), v) || push!(v, exe)
    end
    return v
end

# The path of the library that comes with the `kos-solver` of the Python `exe`, or `nothing` if that Python does not
# give it (it does not start, does not have the package, takes longer than the timeout or answers something that is
# not the path of a file).
function _pregunta_a_python(exe::AbstractString)
    p = try
        open(pipeline(`$exe -c $_CODIGO_DE_PYTHON`; stdin = devnull, stderr = devnull), "r")
    catch
        return nothing
    end
    if timedwait(() -> process_exited(p), _PLAZO_DE_PYTHON[]; pollint = 0.02) != :ok
        kill(p)
        close(p)
        return nothing
    end
    texto = read(p, String)
    close(p)
    success(p) || return nothing
    lineas = split(texto, '\n'; keepempty = false)
    isempty(lineas) && return nothing
    ruta = String(strip(lineas[end]))
    return (isabspath(ruta) && isfile(ruta)) ? ruta : nothing
end

# Loads `candidata` (a path, or a name that the system's loader resolves) and checks that it is libkos with the ABI
# of this package. If it is, it is put in use and the function returns `nothing`; if not, it returns why and changes
# nothing.
function _carga(candidata::AbstractString, origen::String)
    handle = try
        Libdl.dlopen(candidata)
    catch e
        return replace(e isa ErrorException ? e.msg : sprint(showerror, e), r"\s*\n\s*" => " ")
    end
    ruta = Libdl.dlpath(handle)
    punteros = Dict{Symbol,Ptr{Cvoid}}()
    for f in _FUNCIONES
        p = Libdl.dlsym(handle, f; throw_error = false)
        p === nothing && return "the library $ruta has no function $f: it is not libkos with ABI version " *
                                "$KOS_ABI_VERSION"
        punteros[f] = p
    end
    abi = ccall(punteros[:kos_abi_version], Cint, ())
    abi == KOS_ABI_VERSION || return "the library $ruta has ABI version $abi; KOS.jl needs $KOS_ABI_VERSION"
    merge!(empty!(_PUNTEROS), punteros)
    _RUTA[] = ruta
    _ORIGEN[] = origen
    return nothing
end

# The names by which the system's loader finds libkos: its SONAME and the link name.
_nombres_del_sistema() = Sys.islinux() ? ("libkos.so.1", "libkos") : ("libkos",)

const _COMO_INSTALARLA = "Install it in one of two ways: (1) `pip install --pre kos-solver`, the Python package, " *
                         "which brings the library (KOS.jl asks `python3` for `kos.library_path()`); or (2) the " *
                         "download of https://katsenia.com/downloads.html, with lib/libkos.so.1 where the system " *
                         "finds shared libraries. Or set ENV[\"KOS_LIBRARY\"] to the full path of the library " *
                         "(libkos.so.1 on Linux) before `using KOS`."

# Finds libkos and puts it in use. In order: the one of ENV["KOS_LIBRARY"] (if it is set, that one and no other: a
# path that does not work is reported, not replaced by another library); the one that comes with the Python package
# `kos-solver` (the Pythons of the PATH are asked); the one that the system's loader finds.
function _carga_biblioteca()
    empty!(_PUNTEROS)
    _RUTA[] = ""
    _ORIGEN[] = ""
    _ERROR_DE_CARGA[] = ""
    pedida = get(ENV, "KOS_LIBRARY", "")
    if !isempty(pedida)
        falla = _carga(pedida, "KOS_LIBRARY")
        if falla !== nothing
            _ERROR_DE_CARGA[] = "the KOS C library could not be loaded from ENV[\"KOS_LIBRARY\"] = \"$pedida\": " *
                                falla
        end
        return
    end
    fallas = String[]
    for exe in _pythons()
        ruta = _pregunta_a_python(exe)
        ruta === nothing && continue
        falla = _carga(ruta, "python")
        falla === nothing && return
        push!(fallas, "the one of the Python package ($exe): $falla")
    end
    for nombre in _nombres_del_sistema()
        _carga(nombre, "system") === nothing && return
    end
    _ERROR_DE_CARGA[] = "the KOS C library (libkos) was not found. " * _COMO_INSTALARLA *
                        (isempty(fallas) ? "" : " Found, but not usable: " * join(fallas, "; ") * ".")
    return
end

function _f(nombre::Symbol)
    p = get(_PUNTEROS, nombre, C_NULL)
    if p == C_NULL
        error(isempty(_ERROR_DE_CARGA[]) ? "the KOS C library is not loaded" : _ERROR_DE_CARGA[])
    end
    return p
end

_cadena(p::Cstring) = p == C_NULL ? "" : unsafe_string(p)

# kos_last_error gives "code: message"; KOSError keeps the message without the code (showerror prepends it once)
function _revisa(codigo::Cint)
    if codigo != KOS_OK
        mensaje = _cadena(ccall(_f(:kos_last_error), Cstring, ()))
        nombre = _cadena(ccall(_f(:kos_error_string), Cstring, (Cint,), codigo))
        if startswith(mensaje, nombre * ": ")
            mensaje = mensaje[ncodeunits(nombre)+3:end]
        end
        throw(KOSError(Int(codigo), nombre, mensaje))
    end
    return nothing
end

"""
    KOS.version_string()

The version of the loaded KOS C library (`"1.0.0"`).
"""
version_string() = _cadena(ccall(_f(:kos_version_string), Cstring, ()))

status_string(st::Integer) = _cadena(ccall(_f(:kos_status_string), Cstring, (Cint,), st))

function _kos_create()
    m = Ref{Ptr{Cvoid}}(C_NULL)
    _revisa(ccall(_f(:kos_create), Cint, (Ptr{Ptr{Cvoid}},), m))
    return m[]
end

function _kos_read(ruta::AbstractString, formato::Integer)
    m = Ref{Ptr{Cvoid}}(C_NULL)
    _revisa(ccall(_f(:kos_read), Cint, (Cstring, Cint, Ptr{Ptr{Cvoid}}), ruta, formato, m))
    return m[]
end

_kos_free(m::Ptr{Cvoid}) = (m != C_NULL && ccall(_f(:kos_free), Cvoid, (Ptr{Cvoid},), m); nothing)

_kos_write(m::Ptr{Cvoid}, ruta::AbstractString, formato::Integer) =
    _revisa(ccall(_f(:kos_write), Cint, (Ptr{Cvoid}, Cstring, Cint), m, ruta, formato))

function _kos_dims(m::Ptr{Cvoid})
    filas, columnas = Ref{Int64}(0), Ref{Int64}(0)
    _revisa(ccall(_f(:kos_get_dims), Cint, (Ptr{Cvoid}, Ptr{Int64}, Ptr{Int64}), m, filas, columnas))
    return Int(filas[]), Int(columnas[])
end

_kos_set_param(m::Ptr{Cvoid}, nombre::AbstractString, valor::AbstractString) =
    _revisa(ccall(_f(:kos_set_param), Cint, (Ptr{Cvoid}, Cstring, Cstring), m, nombre, valor))

_kos_set_profile(m::Ptr{Cvoid}, nombre::AbstractString) =
    _revisa(ccall(_f(:kos_set_profile), Cint, (Ptr{Cvoid}, Cstring), m, nombre))

# an output string in (buf, size) with the size needed in *needed
function _cadena_de_salida(llamada)
    necesario = Ref{Csize_t}(0)
    llamada(C_NULL, Csize_t(0), necesario)
    buf = Vector{UInt8}(undef, necesario[])
    llamada(pointer(buf), Csize_t(length(buf)), necesario)
    return GC.@preserve buf unsafe_string(pointer(buf))
end

"""
    KOS.license_status()

The status of the KOS license on this machine, as the JSON text of `kos_license_status`: an object with `status`
(`"community"` without a license, `"valid"` with one in effect, ...), `in_effect`, `size_limit` (`[2000, 2000]` for
the Community edition, `null` with a license in effect), `edition`, `message` (the status in words) and the other
details. It never contacts a server.
"""
function license_status()
    f = _f(:kos_license_status)
    necesario = Ref{Csize_t}(0)
    _revisa(ccall(f, Cint, (Ptr{UInt8}, Csize_t, Ptr{Csize_t}), C_NULL, Csize_t(0), necesario))
    # each call checks the license again and the text can change its length between two calls: with some slack, and
    # again if it is not enough
    for _ in 1:8
        buf = Vector{UInt8}(undef, necesario[] + 256)
        codigo = ccall(f, Cint, (Ptr{UInt8}, Csize_t, Ptr{Csize_t}), buf, Csize_t(length(buf)), necesario)
        codigo == KOS_ERROR_BUFFER_TOO_SMALL && continue
        _revisa(codigo)
        return GC.@preserve buf unsafe_string(pointer(buf))
    end
    error("the license status kept changing its length")
end

_kos_get_param(m::Ptr{Cvoid}, nombre::AbstractString) = _cadena_de_salida(
    (buf, tam, nec) -> _revisa(ccall(_f(:kos_get_param), Cint,
                                     (Ptr{Cvoid}, Cstring, Ptr{UInt8}, Csize_t, Ptr{Csize_t}), m, nombre, buf, tam, nec)))

"""
    KOS.parameter_names()

The names of every KOS parameter (the ones `MOI.RawOptimizerAttribute` takes), in the order of the library.
"""
function parameter_names()
    n = Ref{Int64}(0)
    _revisa(ccall(_f(:kos_num_params), Cint, (Ptr{Int64},), n))
    return [_cadena_de_salida((buf, tam, nec) -> _revisa(ccall(_f(:kos_param_name), Cint,
                                                               (Int64, Ptr{UInt8}, Csize_t, Ptr{Csize_t}),
                                                               k, buf, tam, nec))) for k in 0:n[]-1]
end

# kos_solve without blocking the garbage collector of the other threads: kos_interrupt can come from another task
function _kos_solve(m::Ptr{Cvoid})
    st = Ref{Cint}(0)
    f = _f(:kos_solve)
    codigo = @ccall gc_safe = true $f(m::Ptr{Cvoid}, st::Ptr{Cint})::Cint
    _revisa(codigo)
    return Int(st[])
end

_kos_interrupt(m::Ptr{Cvoid}) = _revisa(ccall(_f(:kos_interrupt), Cint, (Ptr{Cvoid},), m))

function _kos_status(m::Ptr{Cvoid})
    st = Ref{Cint}(0)
    _revisa(ccall(_f(:kos_get_status), Cint, (Ptr{Cvoid}, Ptr{Cint}), m, st))
    return Int(st[])
end

# a result that may not exist: `nothing` with the "there is none" codes (no solution, not applicable)
function _opcional(llamada)
    codigo = llamada()
    if codigo == KOS_ERROR_NO_SOLUTION || codigo == KOS_ERROR_NOT_APPLICABLE
        return false
    end
    _revisa(codigo)
    return true
end

function _kos_objective(m::Ptr{Cvoid})
    z = Ref{Cdouble}(NaN)
    ok = _opcional(() -> ccall(_f(:kos_get_objective), Cint, (Ptr{Cvoid}, Ptr{Cdouble}), m, z))
    return ok ? z[] : nothing
end

function _kos_vector(nombre::Symbol, m::Ptr{Cvoid}, n::Integer)
    v = Vector{Cdouble}(undef, n)
    ok = _opcional(() -> ccall(_f(nombre), Cint, (Ptr{Cvoid}, Ptr{Cdouble}, Int64), m, v, n))
    return ok ? v : nothing
end

function _kos_info(m::Ptr{Cvoid}, que::Integer)
    v = Ref{Cdouble}(NaN)
    ok = _opcional(() -> ccall(_f(:kos_get_info), Cint, (Ptr{Cvoid}, Cint, Ptr{Cdouble}), m, que, v))
    return ok ? v[] : nothing
end

function _kos_write_certificate(m::Ptr{Cvoid}, ruta::AbstractString)
    f = _f(:kos_write_certificate)
    codigo = @ccall gc_safe = true $f(m::Ptr{Cvoid}, ruta::Cstring)::Cint
    if codigo == KOS_ERROR_NO_SOLUTION || codigo == KOS_ERROR_NOT_APPLICABLE
        return false
    end
    _revisa(codigo)
    return true
end

const KOS_SIDE_UPPER = 1

# the IIS of the LP (of the relaxation of a MIP): the rows and columns with their side (true: the upper one), or
# `nothing` if it does not apply (KOS_ERROR_NOT_APPLICABLE: the LP is feasible or not proven infeasible)
function _kos_iis(m::Ptr{Cvoid})
    filas, cols = Ref{Int64}(0), Ref{Int64}(0)
    f = _f(:kos_compute_iis)
    codigo = @ccall gc_safe = true $f(m::Ptr{Cvoid}, filas::Ptr{Int64}, cols::Ptr{Int64})::Cint
    codigo == KOS_ERROR_NOT_APPLICABLE && return nothing
    _revisa(codigo)
    partes = map(((:kos_get_iis_rows, filas[]), (:kos_get_iis_cols, cols[]))) do (nombre, k)
        indice, lado = Vector{Int64}(undef, k), Vector{Cint}(undef, k)
        _revisa(ccall(_f(nombre), Cint, (Ptr{Cvoid}, Ptr{Int64}, Ptr{Cint}, Int64), m, indice, lado, k))
        return [(Int(i) + 1, l == KOS_SIDE_UPPER) for (i, l) in zip(indice, lado)]
    end
    return partes[1], partes[2]
end

_kos_flag_origin(m::Ptr{Cvoid}) = _cadena_de_salida(
    (buf, tam, nec) -> _revisa(ccall(_f(:kos_get_flag_origin), Cint,
                                     (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Ptr{Csize_t}), m, buf, tam, nec)))

_kos_no_verdict_reason(m::Ptr{Cvoid}) = _cadena_de_salida(
    (buf, tam, nec) -> _revisa(ccall(_f(:kos_get_no_verdict_reason), Cint,
                                     (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Ptr{Csize_t}), m, buf, tam, nec)))
