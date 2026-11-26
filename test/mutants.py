"""The mutants of KOS.jl: small changes in the delicate parts (the signs of the duals, the statuses, the LP text,
where the library is searched for and in what order) that the tests must kill. For each mutant it copies the package
to FOLDER/KOS.jl, applies the change (a text that appears exactly once), runs the quick tests (library, license,
signs, status, names and the bitwise test on the small bank) with a Julia environment that uses that copy, and
records whether some test fails (killed), whether they all pass (survived), whether the package does not load or
whether the tests do not finish within the timeout ("no verdict"): those last two do not count as killed. Before
that it runs the tests without a mutant, which must pass: if not, it stops.

Usage: python3 -I mutants.py FOLDER SMALL_BANK [name...]
       (julia in the PATH, KOS_LIBRARY with the path of libkos; the mutants of the library search also need a
       python3 in the PATH, and the one of the size-limit code needs a library without a license in effect)
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

PAQUETE = Path(__file__).resolve().parent.parent
# the timeout of each run of the tests, in seconds
PLAZO = 420

# (name, file, text, replacement)
MUTANTES = [
    ("sigma_always_1", "src/MOI_wrapper.jl", "_sigma(m::Optimizer) = m.maximiza ? -1.0 : 1.0",
     "_sigma(m::Optimizer) = 1.0"),
    ("row_dual_without_sigma", "src/MOI_wrapper.jl", "        return _sigma(m) * m.duales[i]",
     "        return m.duales[i]"),
    ("bound_dual_without_sigma", "src/MOI_wrapper.jl", "        return _sigma(m) * m.reducidos[j]",
     "        return m.reducidos[j]"),
    ("farkas_without_sign", "src/MOI_wrapper.jl", "    return -y[i]\nend", "    return y[i]\nend"),
    ("lower_bound_gets_negative_part", "src/MOI_wrapper.jl",
     "_tiene_cota(m, j, MOI.LessThan{Float64}) ? max(d, 0.0) : d",
     "_tiene_cota(m, j, MOI.LessThan{Float64}) ? min(d, 0.0) : d"),
    ("upper_bound_gets_positive_part", "src/MOI_wrapper.jl",
     "_tiene_cota(m, j, MOI.GreaterThan{Float64}) ? min(d, 0.0) : d",
     "_tiene_cota(m, j, MOI.GreaterThan{Float64}) ? max(d, 0.0) : d"),
    ("dual_objective_without_sigma", "src/MOI_wrapper.jl", "    valor = _sigma(m) * suma", "    valor = suma"),
    ("interval_other_side", "src/MOI_wrapper.jl", "    if isfinite(s.lower) && (!isfinite(s.upper) || λ > 0)",
     "    if isfinite(s.lower) && (!isfinite(s.upper) || λ < 0)"),
    ("flagged_is_optimal", "src/MOI_wrapper.jl", "st == 2 && return MOI.ALMOST_OPTIMAL",
     "st == 2 && return MOI.OPTIMAL"),
    ("work_is_time", "src/MOI_wrapper.jl", "st == 10 && return MOI.OTHER_LIMIT", "st == 10 && return MOI.TIME_LIMIT"),
    ("target_is_optimal", "src/MOI_wrapper.jl", "st == 13 && return MOI.OBJECTIVE_LIMIT",
     "st == 13 && return MOI.OPTIMAL"),
    ("interrupted_is_time", "src/MOI_wrapper.jl", "st == 15 && return MOI.INTERRUPTED",
     "st == 15 && return MOI.TIME_LIMIT"),
    ("mip_unbounded_is_optimal", "src/MOI_wrapper.jl", "st == 5 && return MOI.DUAL_INFEASIBLE",
     "st == 5 && return MOI.OPTIMAL"),
    ("flagged_primal_feasible", "src/MOI_wrapper.jl",
     "        return m.estado == 2 ? MOI.NEARLY_FEASIBLE_POINT : MOI.FEASIBLE_POINT\n    end\n    return _rayo!",
     "        return MOI.FEASIBLE_POINT\n    end\n    return _rayo!"),
    ("constant_with_other_sign", "src/lp_text.jl", "        print(io, signbit(k) ? \" - \" : \" + \")",
     "        print(io, signbit(k) ? \" + \" : \" - \")"),
    ("binary_without_lower_bound", "src/MOI_wrapper.jl", "            col_inf[j] = max(col_inf[j], 0.0)\n", ""),
    ("range_as_equality", "src/lp_text.jl", "        rango = l > -Inf && u < Inf && !_mismos_bits(l, u)",
     "        rango = false"),
    ("rows_not_sorted_by_type", "src/MOI_wrapper.jl",
     "const _CONJUNTOS_DE_FILA = (MOI.LessThan{Float64}, MOI.GreaterThan{Float64}, MOI.EqualTo{Float64},",
     "const _CONJUNTOS_DE_FILA = (MOI.GreaterThan{Float64}, MOI.LessThan{Float64}, MOI.EqualTo{Float64},"),
    ("parameters_not_applied_on_copy", "src/MOI_wrapper.jl", "    for (k, v) in dest.parametros\n",
     "    for (k, v) in Pair{String,String}[]\n"),
    ("ray_without_activity", "src/MOI_wrapper.jl", "    return _ar(m, r, i)\nend", "    return 0.0\nend"),
    ("row_conflict_inverted", "src/MOI_wrapper.jl",
     "m.filas[c].indice in m.filas_en_conflicto ? MOI.IN_CONFLICT : MOI.NOT_IN_CONFLICT",
     "m.filas[c].indice in m.filas_en_conflicto ? MOI.NOT_IN_CONFLICT : MOI.IN_CONFLICT"),
    ("conflict_without_binary", "src/MOI_wrapper.jl", "        (inferior && inf_binaria) || (superior && sup_binaria)",
     "        false"),
    ("conflict_exists_without_solution", "src/MOI_wrapper.jl",
     "(m.resuelto && m.x !== nothing) ? MOI.NO_CONFLICT_EXISTS : MOI.NO_CONFLICT_FOUND", "MOI.NO_CONFLICT_EXISTS"),
    ("error_with_repeated_code", "src/libkos.jl", "        if startswith(mensaje, nombre * \": \")",
     "        if false"),
    # --- where the library is searched for ---
    ("kos_library_or_else_another", "src/libkos.jl", "        end\n        return\n    end\n    fallas = String[]",
     "        end\n        falla === nothing && return\n    end\n    fallas = String[]"),
    ("without_asking_python", "src/libkos.jl", "    for exe in _pythons()\n        ruta = _pregunta_a_python(exe)",
     "    for exe in String[]\n        ruta = _pregunta_a_python(exe)"),
    ("system_before_python", "src/libkos.jl", "    fallas = String[]\n    for exe in _pythons()",
     "    fallas = String[]\n    for nombre in _nombres_del_sistema()\n"
     "        _carga(nombre, \"system\") === nothing && return\n    end\n    for exe in _pythons()"),
    ("python_before_python3", "src/libkos.jl", "    for nombre in (\"python3\", \"python\")",
     "    for nombre in (\"python\", \"python3\")"),
    ("python_without_timeout", "src/libkos.jl", "process_exited(p), _PLAZO_DE_PYTHON[]; pollint",
     "process_exited(p), 1000.0; pollint"),
    ("python_that_fails", "src/libkos.jl", "    success(p) || return nothing\n", ""),
    ("relative_path_from_python", "src/libkos.jl", "    return (isabspath(ruta) && isfile(ruta)) ? ruta : nothing",
     "    return isfile(ruta) ? ruta : nothing"),
    ("python_with_working_directory", "src/libkos.jl",
     "                          \"sys.path[:] = [p for p in sys.path if p not in ('', '.')]\\n\" *\n", ""),
    ("missing_function", "src/libkos.jl",
     "        p === nothing && return \"the library $ruta has no function $f: it is not libkos with ABI version \" *\n"
     "                                \"$KOS_ABI_VERSION\"\n", "        p === nothing && continue\n"),
    ("source_not_recorded", "src/libkos.jl", "    _ORIGEN[] = origen\n", ""),
    ("size_limit_code", "src/libkos.jl", "const KOS_ERROR_SIZE_LIMIT = 13", "const KOS_ERROR_SIZE_LIMIT = 14"),
]


def corre(carpeta, banco):
    """The quick tests with the copy of FOLDER/KOS.jl: "pass", "fail" (some test fails or errors inside its
    testset), "no_load" (any other exit with an error: the package or the tests do not load) or "no_verdict" (they
    do not finish within the timeout)."""
    entorno = dict(os.environ, KOS_JL_BANK=str(banco), KOS_JL_TESTS="library,license,signs,status,names,bitwise")
    try:
        r = subprocess.run(["julia", "-t", "2", f"--project={carpeta / 'env'}",
                            str(carpeta / "KOS.jl/test/runtests.jl")],
                           env=entorno, capture_output=True, text=True, timeout=PLAZO)
    except subprocess.TimeoutExpired:
        # without a mutant they take less than a minute; an expired timeout does not prove that the mutant changes a
        # result
        return "no_verdict", f"do not finish in {PLAZO} s"
    salida = r.stdout + r.stderr
    if r.returncode == 0:
        return "pass", salida[-3000:]
    if "Some tests did not pass" in salida:
        return "fail", salida[-3000:]
    return "no_load", salida[-3000:]


def prepara(carpeta):
    copia = carpeta / "KOS.jl"
    if copia.exists():
        shutil.rmtree(copia)
    shutil.copytree(PAQUETE, copia, ignore=shutil.ignore_patterns("Manifest.toml"))
    return copia


def main():
    carpeta = Path(sys.argv[1]).resolve()
    banco = Path(sys.argv[2]).resolve()
    pedidos = set(sys.argv[3:])
    carpeta.mkdir(parents=True, exist_ok=True)
    prepara(carpeta)
    if not (carpeta / "env/Manifest.toml").exists():
        subprocess.run(["julia", f"--project={carpeta / 'env'}", "-e",
                        f'using Pkg; Pkg.develop(path="{carpeta / "KOS.jl"}"); '
                        'Pkg.add(["JuMP", "MathOptInterface", "Test"])'],
                       check=True)
    # without a mutant, the tests pass
    prepara(carpeta)
    estado, salida = corre(carpeta, banco)
    print("no mutant:", estado, flush=True)
    if estado != "pass":
        print(salida)
        sys.exit(2)
    muertos, vivos, no_cargan, no_concluyen = [], [], [], []
    for nombre, archivo, texto, reemplazo in MUTANTES:
        if pedidos and nombre not in pedidos:
            continue
        copia = prepara(carpeta)
        ruta = copia / archivo
        fuente = ruta.read_text(encoding="utf-8")
        assert fuente.count(texto) == 1, (nombre, fuente.count(texto))
        ruta.write_text(fuente.replace(texto, reemplazo), encoding="utf-8")
        estado, salida = corre(carpeta, banco)
        {"pass": vivos, "fail": muertos, "no_load": no_cargan, "no_verdict": no_concluyen}[estado].append(nombre)
        print({"pass": "SURVIVED ", "fail": "killed ", "no_load": "DOES NOT LOAD ", "no_verdict": "NO VERDICT "}[estado]
              + nombre, flush=True)
        if estado == "no_load":
            print(salida)
    prepara(carpeta)
    print(f"mutants: {len(muertos)} killed, {len(vivos)} survived {vivos}, {len(no_cargan)} do not load {no_cargan}, "
          f"{len(no_concluyen)} no verdict {no_concluyen}")
    sys.exit(0 if not vivos and not no_cargan and not no_concluyen else 1)


if __name__ == "__main__":
    main()
