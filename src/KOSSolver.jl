"""
    KOSSolver

A MathOptInterface (and so JuMP) interface to KOS, the Katsenia Optimization Solver: LP and MIP over its C library
`libkos`, which is installed apart: with the Python package (`pip install --pre kos-solver`) or as the download of
https://katsenia.com/downloads.html. KOSSolver.jl finds it by itself, or takes the path of `ENV["KOS_LIBRARY"]` (set
before `using KOSSolver`); `KOSSolver.library_path()` says which one is in use and `KOSSolver.load_error()` why none is.

```julia
using JuMP, KOSSolver
model = Model(KOSSolver.Optimizer)
```
"""
module KOSSolver

import Libdl
import MathOptInterface as MOI

include("libkos.jl")
include("lp_text.jl")
include("certificate.jl")
include("MOI_wrapper.jl")

# Loading the package searches for the library. The package also loads without it (and if the search itself fails):
# whatever needs it then raises the error of `load_error()`.
function __init__()
    try
        _carga_biblioteca()
    catch e
        empty!(_PUNTEROS)
        _RUTA[] = ""
        _ORIGEN[] = ""
        _ERROR_DE_CARGA[] = "the search for the KOS C library failed: " * sprint(showerror, e)
    end
    return nothing
end

end
