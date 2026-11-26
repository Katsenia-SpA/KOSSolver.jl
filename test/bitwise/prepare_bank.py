"""Prepares the bank of the bitwise test of KOS.jl.

For each input MPS it writes to the output folder:
- `<name>.mps`: the same file with the ROWS lines reordered (the rows grouped in the type order of KOS.jl:
  LessThan, GreaterThan, EqualTo, Interval; within each type, in the order of the file). Only ROWS lines change
  place: KOS reads it as the original with the rows permuted, and it is what "KOS directly" reads.
- `<name>.dat`: the model of that file (read with the reader of kos-verify, which follows the semantics of KOS) in a
  simple text that the Julia test builds with JuMP in the same order: columns in their order, rows by type.

Format of `.dat` (numbers with `repr`, which read back as the same double; `inf`/`-inf`):
    KOSDAT 1
    sense min|max
    constant K
    cols N
    L U I            (N lines: bounds and integrality 0/1)
    cost K j c ...   (the nonzero costs)
    rows M
    T L U K j v ...  (M lines, T in LT, GT, EQ, IV)

Usage: python3 -I prepare_bank.py PATH_TO_KOS_VERIFY OUTPUT_FOLDER FILE.mps...
"""

import math
import struct
import sys
from pathlib import Path

ORDEN = ("LT", "GT", "EQ", "IV")


def bits(v):
    return struct.pack("<d", v)


def tipo_de(l, u):
    if bits(l) == bits(u):
        return "EQ"
    if l > -math.inf and u < math.inf:
        return "IV"
    if l > -math.inf:
        return "GT"
    if u < math.inf:
        return "LT"
    return "IV"


def num(v):
    if math.isinf(v):
        return "inf" if v > 0 else "-inf"
    return repr(float(v))


def lineas_de_rows(kv, texto):
    """The indices of the ROWS data lines and the name of each one, with the reader (free or fixed format) that reads
    the file."""
    for fijo in (False, True):
        lector = kv._LectorMps(fijo)
        try:
            lector.lee(texto)
        except kv._ErrorDeLectura:
            continue
        lineas = kv._lineas(texto)
        r, seccion = [], None
        for k, crudo in enumerate(lineas):
            linea = crudo.rstrip("\r\n")
            if not kv._recorta(linea) or linea.startswith("*"):
                continue
            if linea[0] not in " \t":
                seccion = kv._mayusculas(kv._partes(linea)[0]) if kv._partes(linea) else ""
                continue
            if seccion == "ROWS":
                c = lector.campos(linea, kv._ROWS)
                r.append((k, c[1]))
        return lineas, r
    raise ValueError("neither free nor fixed format")


def prepara(kv, ruta, salida):
    texto = kv._leer_texto(ruta)
    m = kv.lee_mps(texto)
    tipos = {m.nombres_fila[i]: tipo_de(m.fila_inf[i], m.fila_sup[i]) for i in range(m.filas)}
    lineas, rows = lineas_de_rows(kv, texto)
    # the constraint rows, grouped by type; the N rows (objective and free) stay first, in their order
    n_filas = [(k, nombre) for k, nombre in rows if nombre not in tipos]
    por_tipo = {t: [(k, nombre) for k, nombre in rows if tipos.get(nombre) == t] for t in ORDEN}
    nuevas = n_filas + [p for t in ORDEN for p in por_tipo[t]]
    assert len(nuevas) == len(rows)
    posiciones = [k for k, _ in rows]
    reordenadas = list(lineas)
    for pos, (k, _) in zip(posiciones, nuevas):
        reordenadas[pos] = lineas[k]
    nombre = Path(ruta).stem
    destino = Path(salida) / f"{nombre}.mps"
    destino.write_text("\n".join(reordenadas) + "\n", encoding="utf-8")
    p = kv.lee_mps(kv._leer_texto(destino))
    # the permuted model is the original with the rows in another order
    orden = [nombre_f for _, nombre_f in nuevas if nombre_f in tipos]
    assert p.nombres_fila == orden, ruta
    viejo = {n: i for i, n in enumerate(m.nombres_fila)}
    for i, n in enumerate(p.nombres_fila):
        assert bits(p.fila_inf[i]) == bits(m.fila_inf[viejo[n]]) and bits(p.fila_sup[i]) == bits(m.fila_sup[viejo[n]])
    assert p.costo == m.costo and p.col_inf == m.col_inf and p.col_sup == m.col_sup and p.enteras == m.enteras
    assert bits(p.constante) == bits(m.constante) and p.maximiza == m.maximiza
    for j in range(m.num_columnas):
        assert sorted((m.nombres_fila[i], v) for i, v in m.columnas[j]) == sorted(
            (p.nombres_fila[i], v) for i, v in p.columnas[j])
    # the .dat of the permuted model
    filas = [[] for _ in range(p.filas)]
    for j, col in enumerate(p.columnas):
        for i, v in col:
            filas[i].append((j, v))
    out = ["KOSDAT 1", "sense " + ("max" if p.maximiza else "min"), "constant " + num(p.constante),
           f"cols {p.num_columnas}"]
    for j in range(p.num_columnas):
        out.append(f"{num(p.col_inf[j])} {num(p.col_sup[j])} {1 if p.enteras[j] else 0}")
    costos = [(j, c) for j, c in enumerate(p.costo) if c != 0.0]
    out.append("cost " + " ".join([str(len(costos))] + [f"{j} {num(c)}" for j, c in costos]))
    out.append(f"rows {p.filas}")
    for i in range(p.filas):
        t = tipo_de(p.fila_inf[i], p.fila_sup[i])
        out.append(" ".join([t, num(p.fila_inf[i]), num(p.fila_sup[i]), str(len(filas[i]))]
                            + [f"{j} {num(v)}" for j, v in filas[i]]))
    (Path(salida) / f"{nombre}.dat").write_text("\n".join(out) + "\n", encoding="utf-8")
    return p.filas, p.num_columnas, sum(p.enteras)


def main():
    sys.path.insert(0, sys.argv[1])
    import kos_verify as kv
    salida = Path(sys.argv[2])
    salida.mkdir(parents=True, exist_ok=True)
    for ruta in sys.argv[3:]:
        try:
            m, n, e = prepara(kv, ruta, salida)
            print(f"{Path(ruta).stem} {m} {n} {e}")
        except kv.ErrorDelModelo as err:
            print(f"{Path(ruta).stem} SKIPPED {err}")


if __name__ == "__main__":
    main()
