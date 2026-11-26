# KOS.jl

KOS.jl is a [MathOptInterface](https://github.com/jump-dev/MathOptInterface.jl) (MOI) interface to KOS, the
Katsenia Optimization Solver, so that [JuMP](https://jump.dev) models can be solved with KOS. It solves linear
programs (LP) and mixed-integer linear programs (MIP) through the KOS C library `libkos` (the API of `kos.h`).

KOS.jl is licensed under the Apache License, Version 2.0. KOS itself, the library `libkos`, is not part of this
package: it is proprietary software of Katsenia SpA, installed apart and governed by the KOS End-User License
Agreement, <https://katsenia.com/license.html> (see "Editions and licenses" below).

## Installation

KOS.jl needs Julia 1.12 or later and the KOS C library, which is published for Linux on x86_64 and aarch64 (glibc
2.17 or newer).

```julia
import Pkg
Pkg.add("KOS")
```

The KOS library is installed apart, in one of two ways:

- **with the Python package**, which brings the library with it:

  ```
  pip install --pre kos-solver
  ```

- **as a download** that needs no Python: the `.tar.gz` of <https://katsenia.com/downloads.html>, which holds
  `lib/libkos.so.1`. Put it where the system finds shared libraries (for example, copy it to `/usr/local/lib` and run
  `ldconfig`, or name its folder in `LD_LIBRARY_PATH`), or name it in `ENV["KOS_LIBRARY"]`.

KOS.jl looks for the library when the package loads (`using KOS`), in this order:

1. `ENV["KOS_LIBRARY"]`, the full path of the library, if it is set: that one and no other. If it cannot be loaded,
   KOS.jl says why and uses none.
2. The library of the Python package: KOS.jl asks the `python3` of the `PATH` (and then the `python`) for
   `kos.library_path()`.
3. The system's loader, by the name `libkos.so.1`.

```julia
ENV["KOS_LIBRARY"] = "/opt/kos/lib/libkos.so.1"   # only if KOS.jl does not find it by itself
using KOS
KOS.library_path()     # the library in use ("" if none could be loaded)
KOS.library_source()   # how it was found: "KOS_LIBRARY", "python" or "system"
KOS.load_error()       # why none could be loaded ("" if one was)
```

The package loads without the library: `using KOS` does not fail, and the first call that needs the library raises
an error with the text of `KOS.load_error()`, which says how to install it.

## Editions and licenses

Without a license, the KOS library is the Community edition: it solves models of up to 2,000 rows (constraints) and
2,000 columns (variables), also for commercial use. With a larger model, `optimize!` does not solve: it throws
`KOS.KOSError` with the name `"size_limit"` (code 13), and its message has the size of the model, the limit and
<https://katsenia.com/pricing.html>; the model stays unsolved (`termination_status` is `OPTIMIZE_NOT_CALLED`).

```julia
try
    optimize!(model)
catch e
    e isa KOS.KOSError && e.name == "size_limit" || rethrow()
    @warn e.message
end
```

With a license of the Academic, Professional, Lifetime or Enterprise edition in effect on the machine there is no
size limit (<https://katsenia.com/pricing.html>). A machine is activated with the `kos` command, not from Julia:
`kos license activate`, with the `kos` command of the Python package or the one of the download (`bin/kos`), or,
without network, with a license file from the account page (`kos license import FILE`). KOS.jl uses the license of
the machine as it is. An activation made online is renewed by itself when the `kos` command or the Python module
runs, and when KOS.jl uses the library of the download with its `bin/kos` beside `lib/`; with the library of the
Python package or a copy of the library elsewhere, run `kos license renew --if-needed` now and then (from cron, for
example).
`KOS.license_status()` is the status of the license, as the JSON text of the library: `status` (`"community"`
without a license), `in_effect`, `size_limit` (`[2000, 2000]`, or `null` with a license in effect), `edition`,
`message` and the other details.

## Use with JuMP

```julia
using JuMP, KOS
model = Model(KOS.Optimizer)
@variable(model, x >= 0)
@variable(model, 0 <= y <= 3, Int)
@constraint(model, c1, x + y >= 2.5)
@objective(model, Min, 2x + 3y + 1)
set_attribute(model, "time_limit", 60)          # any KOS parameter, by its name
optimize!(model)
termination_status(model), objective_value(model), value(x), value(y)
```

## Parameters

Every KOS parameter is set by its name with `set_attribute(model, name, value)` (or `MOI.RawOptimizerAttribute`):
`true`/`false` for `on`/`off`, a number, a string (`"dual"`, `"0.5g3i-1g"`, ...) or `nothing` for `none`.
`KOS.parameter_names()` lists the names. The name `"profile"` sets a KOS profile (`"stable"`, `"degenerate"`, ...).
An unknown name raises `MOI.UnsupportedAttribute`; a value KOS does not take raises `KOS.KOSError` (with `code`,
`name` and `message`), and nothing changes.

Parameters and profiles apply in the order they are set, the same as `kos_set_param` after `kos_read`. The MOI
attributes map to KOS parameters:

| MOI attribute | KOS parameter |
|---|---|
| `MOI.TimeLimitSec` | `time_limit` (`nothing`: `none`) |
| `MOI.NumberOfThreads` | `threads` |
| `MOI.RelativeGapTolerance` | `mip_relative_gap` |
| `MOI.AbsoluteGapTolerance` | `mip_absolute_gap` |
| `MOI.Silent` | stored only: the KOS library prints nothing |

## How the model reaches KOS

KOS.jl is a non-incremental optimizer: at `optimize!` it copies the whole model to a new KOS model (JuMP keeps the
model in its cache). The copy is exact: KOS.jl writes the model as an LP file
with every number in the shortest decimal form that reads back as the same double, in a private temporary file
that is removed right after `kos_read` reads it. The objective constant goes into the KOS model, so the objective,
the MIP gap, `cutoff` and `objective_target` mean the same as in a model file.

- Columns are the variables in their order of creation, named `x1`, `x2`, ...
- Rows are the affine constraints grouped by type in the order `LessThan`, `GreaterThan`, `EqualTo`, `Interval`,
  and within each type in their order of creation, named `r1`, `r2`, ...
- Variable bounds (`GreaterThan`, `LessThan`, `EqualTo`, `Interval`) are column bounds; a variable without bounds
  is free. `ZeroOne` is an integer column with bounds `[max(l, 0), min(u, 1)]`.
- JuMP names do not reach KOS (any name works, also empty or repeated ones).

The result is the same, bit for bit, as reading that model file with KOS and solving it with the same parameters.
`KOS.write_model(unsafe_backend(model), "model.lp")` writes the model KOS solved (LP with the extension `.lp`, MPS
otherwise), and `kos solve model.lp` with the same parameters gives the same status, objective, values, duals,
iterations and work. The LP file is always exact; MPS is exact except for a row range that MPS cannot hold exactly,
which KOS writes within one unit in the last place, with a warning.

With JuMP, every `optimize!` copies the model to a new KOS model (MOI's cache hands the whole model to a
non-incremental optimizer), so solving again, also after changing only a parameter, is a fresh solve: the same, bit
for bit, as a new model with those parameters. It does not start from the previous basis or continue a MIP.

## Statuses

`raw_status(model)` (and `KOS.Status()`) is the KOS status as KOS names it. The termination status:

| KOS status | `termination_status` | primal status |
|---|---|---|
| `optimal` | `OPTIMAL` | `FEASIBLE_POINT` |
| `optimal_flagged` | `ALMOST_OPTIMAL` | `NEARLY_FEASIBLE_POINT` (also the dual status) |
| `infeasible` | `INFEASIBLE` | `NO_SOLUTION` (LP: dual status `INFEASIBILITY_CERTIFICATE`) |
| `dual_infeasible` | `DUAL_INFEASIBLE` | LP: `INFEASIBILITY_CERTIFICATE` (an improving ray) |
| `unbounded` (MIP) | `DUAL_INFEASIBLE` | `FEASIBLE_POINT` (the integer solution) |
| `infeasible_or_unbounded` | `INFEASIBLE_OR_UNBOUNDED` | `NO_SOLUTION` |
| `iteration_limit` | `ITERATION_LIMIT` | `NO_SOLUTION` |
| `time_limit` | `TIME_LIMIT` | MIP: `FEASIBLE_POINT` with an incumbent |
| `objective_limit` | `OBJECTIVE_LIMIT` | `NO_SOLUTION` (see below) |
| `work_limit` | `OTHER_LIMIT` | MIP: `FEASIBLE_POINT` with an incumbent |
| `node_limit` | `NODE_LIMIT` | as `time_limit` |
| `solution_limit` | `SOLUTION_LIMIT` | `FEASIBLE_POINT` |
| `target_reached` | `OBJECTIVE_LIMIT` | `FEASIBLE_POINT` |
| `gap_after_nodes` | `OTHER_LIMIT` | `FEASIBLE_POINT` |
| `interrupted` | `INTERRUPTED` | MIP: `FEASIBLE_POINT` with an incumbent |
| `no_verdict` | `OTHER_ERROR` | `NO_SOLUTION` (`KOS.NoVerdictReason()` says why) |

A status number this version does not know (from a newer KOS) is `OTHER_ERROR`. KOS's objective limits
(`objective_upper_limit`, `objective_lower_limit`) end an LP solve `OBJECTIVE_LIMIT` only when KOS proves that the
optimum is past the limit, also in a solve from scratch (what KOS.jl always does): an optimum at the limit or within
the tolerance of it is `OPTIMAL`. `KOS.FlagOrigin()` says why an LP
ended `optimal_flagged`; `KOS.Work()` is the deterministic work of the solve. `solve_time_sec`,
`simplex_iterations`, `node_count`, `objective_bound` and `relative_gap` (MIP) come from KOS.

## Duals and signs

LP duals follow the MOI convention, which does not depend on the objective sense: the dual of a `>=` row is
nonnegative and the dual of a `<=` row is nonpositive, when minimizing and when maximizing (maximizing `-f` gives
the same duals as minimizing `f`). KOS reports `y`, the change of the objective per unit increase of the active
bound of each row in the sense of the model, and the reduced costs `d = c - A'y`; KOS.jl returns:

- for a row: `σ y` with `σ = 1` when minimizing and `σ = -1` when maximizing;
- for a variable bound: `σ d`; with both a lower and an upper bound, the positive part goes to the lower bound
  (`GreaterThan`) and the negative part to the upper bound (`LessThan`); `EqualTo` and `Interval` get all of it.

`JuMP.reduced_cost(x)` and `JuMP.shadow_price(c)` then give the sensitivities in the sense of the model.
`dual_objective_value` is computed from those duals. A MIP has no duals.

For an infeasible LP, KOS.jl asks KOS for its certificate (`kos_write_certificate`) and returns the Farkas
multipliers `y` of KOS as the MOI certificate: `-y` for the rows and `A'y` for the variable bounds (split by sign as
above), independent of the objective sense. For an LP that is dual infeasible, the primal ray of the certificate is
the `value` of the variables (`objective_value` is then `c'r`, without the constant). Both are computed only when
asked for (`dual_status`, `primal_status`, `result_count`), within KOS's `certificate_work_limit`.

## Conflicts

`compute_conflict!(model)` after `optimize!` asks KOS for an irreducible infeasible subsystem (IIS) of the LP, or
of the LP relaxation of a MIP (`kos_compute_iis`). `get_attribute(model, MOI.ConflictStatus())` is then
`CONFLICT_FOUND`, and `MOI.ConstraintConflictStatus()` of each constraint is `IN_CONFLICT` or `NOT_IN_CONFLICT`: a
row is in conflict if it is in the IIS; a variable bound if its side is (a `ZeroOne` constraint, for the side of
`[0, 1]` that no other bound of the variable gives). Without an IIS, the last solve decides: with a solution (an
optimal LP, a MIP with an incumbent) the model is feasible, `NO_CONFLICT_EXISTS`; without one (a limit, or a MIP
whose relaxation is feasible but that has no integer solution: KOS has no conflicts of the integrality),
`NO_CONFLICT_FOUND`. An infeasible LP may have several IIS: KOS returns one of them.

## Other functions

- `KOS.interrupt!(unsafe_backend(model))` asks the solve in progress to stop, from another task on another thread
  (start Julia with `-t 2` or more); the solve ends `INTERRUPTED` (a MIP keeps its incumbent).
- `KOS.kos_model(unsafe_backend(model))` is the pointer to the `kos_model` of the last copy, for calls to the C API
  that KOS.jl does not wrap. It belongs to the optimizer.
- `KOS.parameters(unsafe_backend(model))` lists the parameters and profiles set, in order.
- `KOS.termination_status_of(n)` maps a KOS status number to the MOI termination status.

## Not supported

Quadratic objectives and constraints, conic and nonlinear constraints, SOS, indicator and semicontinuous variables
raise `MOI.UnsupportedConstraint` or `MOI.UnsupportedAttribute` with a clear message. Start values
(`set_start_value`, `VariablePrimalStart` and the constraint starts) are ignored: the KOS C API takes no starting
point. Not available yet: basis statuses, `MOI.ObjectiveLimit`, callbacks, and incremental modification
(every change copies the model again). Data with NaN, an infinite coefficient or cost, or a constant inside a
constraint function (JuMP moves those to the set) raise an error before reaching KOS.

## Tests

With the KOS library installed (or named in `ENV["KOS_LIBRARY"]`), the standard way works:

```julia
import Pkg
Pkg.test("KOS"; julia_args = ["-t", "2"])
```

The tests pass with the published library without a license (the Community edition: what is larger than its limit
is expected to end in `size_limit`) and with a license in effect. The interruption test needs two threads (`-t 2`);
with one it is skipped. `ENV["KOS_JL_TESTS"]` picks a subset (`library,license,moi,signs,status,names,bitwise`). The
tests are:

- **library**: where KOS.jl looks for the library and in which order (`ENV["KOS_LIBRARY"]` and no other, then the
  Python package, then the system's loader), with what each case leaves in `KOS.library_path()`,
  `KOS.library_source()` and `KOS.load_error()`.
- **license**: `KOS.license_status()`, and the size limit of the edition in effect: without a license, 2,000 rows
  and 2,000 columns are solved and a larger model throws the `size_limit` error; with one in effect, it is solved.

- **MOI.Test**, the test suite of MathOptInterface, through the cache and the bridges as JuMP uses KOS.jl. Tests of
  what KOS does not support (conic, quadratic, nonlinear, ...) are skipped by MOI.Test itself. Two tests are
  excluded by name: `test_solve_conflict_zeroone_2` (the conflict is integrality alone, and the KOS IIS is that of
  the LP relaxation) and `test_solve_conflict_EqualTo` (its model has two IIS and the test accepts only the other
  one).
- **signs**: duals computed by hand, when minimizing and when maximizing, for `<=`, `>=`, `==` and interval rows and
  for variable bounds, and the relation of MOI's duals with the raw duals of KOS, bit for bit.
- **status**: the table above, real limits (iterations, time, work, objective, nodes, solutions, objective target,
  gap targets), interruption from another thread, infeasibility and unboundedness certificates, conflicts,
  parameters, invalid data.
- **names**: unusual names, the empty model, empty rows, the objective constant and exact numbers.
- **bitwise**: with `ENV["KOS_JL_BANK"]` pointing to a folder made by `test/bitwise/prepare_bank.py`, each model
  built with JuMP and solved by KOS.jl gives the same status, objective, solution, row activities, duals, reduced
  costs, iterations, nodes and work, bit for bit, as `kos_read` of the same model file with the same parameters.
  Without a license in effect, a model larger than the limit of the Community edition must give the same
  `size_limit` error both ways.

`test/mutants.py` checks that the tests catch small changes in the sign, status, conflict and model-text code.
