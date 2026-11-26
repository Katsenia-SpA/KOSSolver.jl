# The MathOptInterface test suite (MOI.Test) on KOS.Optimizer behind the cache and the bridges, as JuMP uses it.

module TestMOI

using Test
import MathOptInterface as MOI
import KOS

# What KOS does not provide and why:
# - the bases (ConstraintBasisStatus, VariableBasisStatus): the C API has them, KOS.jl does not expose them yet;
# - VariablePrimalStart and ConstraintPrimalStart/DualStart: the C API does not take starting points;
# - ObjectiveLimit: it is not mapped.
const EXCLUIDOS_DE_CONFIG = Any[
    MOI.ConstraintBasisStatus,
    MOI.VariableBasisStatus,
    MOI.VariablePrimalStart,
    MOI.ConstraintPrimalStart,
    MOI.ConstraintDualStart,
    MOI.ObjectiveLimit,
]

# The tests of what KOS does not support (conic, quadratic, nonlinear, SOS, ...) end in UnsupportedConstraint or
# UnsupportedAttribute, and MOI.Test counts them as skipped. Only these are excluded by name:
# - test_solve_conflict_zeroone_2: the conflict is the integrality alone (x binary and equal to 1/2) and the IIS of
#   KOS is that of the relaxation, which is feasible: KOS.jl gives NO_CONFLICT_FOUND and the test asks for
#   CONFLICT_FOUND;
# - test_solve_conflict_EqualTo: the model (x, y ≥ 0, x + y = −1, x − y ≥ 1) has two IIS, {x ≥ 0, y ≥ 0,
#   x + y = −1} and {y ≥ 0, x + y = −1, x − y ≥ 1}; KOS gives the second one (irreducible: without any one of the
#   three it is feasible) and the test accepts only the first one.
const EXCLUIDAS = String["test_solve_conflict_zeroone_2", "test_solve_conflict_EqualTo"]

function optimizador()
    return MOI.instantiate(KOS.Optimizer; with_cache_type = Float64, with_bridge_type = Float64)
end

function runtests()
    modelo = optimizador()
    MOI.set(modelo, MOI.Silent(), true)
    config = MOI.Test.Config(; atol = 1e-6, rtol = 1e-6, exclude = EXCLUIDOS_DE_CONFIG)
    # with ENV["KOS_JL_MOI_VERBOSE"] = "1", MOI.Test names each test and says which ones it skips as unsupported
    MOI.Test.runtests(modelo, config; exclude = EXCLUIDAS, verbose = get(ENV, "KOS_JL_MOI_VERBOSE", "") == "1")
    return
end

end
