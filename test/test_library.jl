# Where KOSSolver.jl looks for the KOS C library and in what order: the one of ENV["KOS_LIBRARY"] (that one and no
# other), the one of the Python package kos-solver (what the `python3` or the `python` of the PATH answers) and the
# one of the system's loader. The Pythons are fake scripts that print a path; the libraries, copies of the one in
# use. What depends on the system's loader (LD_LIBRARY_PATH is read at startup) runs in another Julia process.
# ENV["KOSSOLVER_JL_EXPECT_SOURCE"] says where the library of this run must come from (KOS_LIBRARY, python or system),
# for whoever runs the tests in a deliberate setup.

module TestLibrary

using Test
import Libdl
import KOSSolver

# a fake "python" in `carpeta`: an sh script with that body
function python_falso(carpeta, cuerpo; nombre = "python3")
    ruta = joinpath(carpeta, nombre)
    write(ruta, "#!/bin/sh\n" * cuerpo * "\n")
    chmod(ruta, 0o755)
    return ruta
end

# the library in use copied to `carpeta` with its SONAME
function copia(carpeta, origen)
    mkpath(carpeta)
    destino = joinpath(carpeta, "libkos.so.1")
    cp(origen, destino; force = true)
    return destino
end

misma(a, b) = !isempty(a) && !isempty(b) && realpath(a) == realpath(b)

# searches for the library again with that environment: (where from, the path, the error)
function carga_con(pares...)
    return withenv(pares...) do
        KOSSolver._carga_biblioteca()
        (KOSSolver.library_source(), KOSSolver.library_path(), KOSSolver.load_error())
    end
end

# `import KOSSolver` in another Julia process with that environment: (where from, the path, the error)
function en_otro_proceso(pares...)
    entorno = Dict{String,String}(k => v for (k, v) in ENV)
    for (k, v) in pares
        v === nothing ? delete!(entorno, k) : (entorno[k] = v)
    end
    codigo = "import KOSSolver; print(KOSSolver.library_source(), '\\n', KOSSolver.library_path(), '\\n', " *
             "KOSSolver.load_error())"
    orden = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $codigo`
    return split(read(setenv(orden, entorno), String), '\n'; limit = 3)
end

function test_la_de_esta_corrida()
    @test isempty(KOSSolver.load_error())
    @test isfile(KOSSolver.library_path())
    @test KOSSolver.library_source() in ("KOS_LIBRARY", "python", "system")
    pedida = get(ENV, "KOS_LIBRARY", "")
    if !isempty(pedida)
        @test KOSSolver.library_source() == "KOS_LIBRARY"
        @test misma(KOSSolver.library_path(), pedida)
    else
        @test KOSSolver.library_source() != "KOS_LIBRARY"
    end
    esperado = get(ENV, "KOSSOLVER_JL_EXPECT_SOURCE", "")
    isempty(esperado) || @test KOSSolver.library_source() == esperado
    @test occursin(r"^\d+\.\d+\.\d+", KOSSolver.version_string())
end

function test_lo_que_contesta_python(carpeta, biblioteca)
    plazo = KOSSolver._PLAZO_DE_PYTHON[]
    try
        KOSSolver._PLAZO_DE_PYTHON[] = 1.0
        d = mkpath(joinpath(carpeta, "contesta"))
        # the path of a file: accepted, also after other lines
        @test KOSSolver._pregunta_a_python(python_falso(d, "echo '$biblioteca'")) == biblioteca
        @test KOSSolver._pregunta_a_python(python_falso(d, "echo 'a warning'; echo '$biblioteca'")) == biblioteca
        # what is not accepted: it exits with an error, it prints nothing, a relative path, a file that does not exist
        @test KOSSolver._pregunta_a_python(python_falso(d, "echo '$biblioteca'; exit 1")) === nothing
        @test KOSSolver._pregunta_a_python(python_falso(d, "exit 0")) === nothing
        @test cd(() -> KOSSolver._pregunta_a_python(python_falso(d, "echo libkos.so.1")),
                 dirname(biblioteca)) === nothing
        @test KOSSolver._pregunta_a_python(python_falso(d, "echo '$(joinpath(d, "no_esta.so"))'")) === nothing
        @test KOSSolver._pregunta_a_python(joinpath(d, "no_hay_tal_python")) === nothing
        # one that does not answer is abandoned when the timeout expires
        t0 = time()
        @test KOSSolver._pregunta_a_python(python_falso(d, "exec sleep 30")) === nothing
        @test time() - t0 < 10
        # a real Python does not take a kos.py of the working directory for the package
        python = something(Sys.which("python3"), Sys.which("python"), "")
        if !isempty(python)
            aqui = mkpath(joinpath(carpeta, "de_trabajo"))
            write(joinpath(aqui, "kos.py"), "def library_path():\n    return '$biblioteca'\n")
            KOSSolver._PLAZO_DE_PYTHON[] = plazo
            @test cd(() -> KOSSolver._pregunta_a_python(python), aqui) != biblioteca
        end
    finally
        KOSSolver._PLAZO_DE_PYTHON[] = plazo
    end
end

function test_en_este_proceso(carpeta, en_uso)
    b = copia(joinpath(carpeta, "b"), en_uso)
    c = copia(joinpath(carpeta, "c"), en_uso)
    con_python = mkpath(joinpath(carpeta, "con_python"))
    python_falso(con_python, "echo '$b'")
    # the one of KOS_LIBRARY, even if a Python offers another
    origen, ruta, falla = carga_con("KOS_LIBRARY" => c, "PATH" => con_python)
    @test origen == "KOS_LIBRARY" && misma(ruta, c) && isempty(falla)
    # without KOS_LIBRARY, the one the Python of the PATH gives (also with the name `python`)
    origen, ruta, falla = carga_con("KOS_LIBRARY" => nothing, "PATH" => con_python)
    @test origen == "python" && misma(ruta, b) && isempty(falla)
    solo_python = mkpath(joinpath(carpeta, "solo_python"))
    python_falso(solo_python, "echo '$c'"; nombre = "python")
    origen, ruta, falla = carga_con("KOS_LIBRARY" => nothing, "PATH" => solo_python)
    @test origen == "python" && misma(ruta, c) && isempty(falla)
    # with both, python3 is asked first
    python_falso(solo_python, "echo '$b'")
    origen, ruta, falla = carga_con("KOS_LIBRARY" => nothing, "PATH" => solo_python)
    @test origen == "python" && misma(ruta, b)
    # a KOS_LIBRARY that does not work is not replaced by another: there is no library, and the reason is given
    no_esta = joinpath(carpeta, "no_esta", "libkos.so.1")
    texto = joinpath(carpeta, "texto.so")
    write(texto, "this is not a library\n")
    otra = first(l for l in Libdl.dllist() if occursin("libjulia", basename(l)))
    for (mala, porque) in ((no_esta, "No such file"), (texto, ""), (otra, "has no function kos_abi_version"))
        origen, ruta, falla = carga_con("KOS_LIBRARY" => mala, "PATH" => con_python)
        @test origen == "" && ruta == ""
        @test occursin("ENV[\"KOS_LIBRARY\"] = \"$mala\"", falla) && occursin(porque, falla)
        @test_throws ErrorException KOSSolver.version_string()
        @test_throws ErrorException KOSSolver.license_status()
    end
end

function test_en_otro_proceso(carpeta, en_uso)
    a = copia(joinpath(carpeta, "a"), en_uso)
    b = copia(joinpath(carpeta, "b"), en_uso)
    c = copia(joinpath(carpeta, "c"), en_uso)
    con_python = mkpath(joinpath(carpeta, "con_python"))
    python_falso(con_python, "echo '$b'")
    sin_python = mkpath(joinpath(carpeta, "sin_python"))
    del_sistema = dirname(a)
    # KOS_LIBRARY, before the one of Python and the one of the system
    origen, ruta, falla = en_otro_proceso("KOS_LIBRARY" => c, "PATH" => con_python, "LD_LIBRARY_PATH" => del_sistema)
    @test origen == "KOS_LIBRARY" && misma(ruta, c) && isempty(falla)
    # the one of Python, before the one of the system
    origen, ruta, falla = en_otro_proceso("KOS_LIBRARY" => nothing, "PATH" => con_python,
                                          "LD_LIBRARY_PATH" => del_sistema)
    @test origen == "python" && misma(ruta, b) && isempty(falla)
    # without Python, or with one that does not have it, the one of the system
    origen, ruta, falla = en_otro_proceso("KOS_LIBRARY" => nothing, "PATH" => sin_python,
                                          "LD_LIBRARY_PATH" => del_sistema)
    @test origen == "system" && misma(ruta, a) && isempty(falla)
    sin_kos = mkpath(joinpath(carpeta, "sin_kos"))
    python_falso(sin_kos, "echo \"ModuleNotFoundError: No module named 'kos'\" >&2; exit 1")
    origen, ruta, falla = en_otro_proceso("KOS_LIBRARY" => nothing, "PATH" => sin_kos,
                                          "LD_LIBRARY_PATH" => del_sistema)
    @test origen == "system" && misma(ruta, a) && isempty(falla)
    # a KOS_LIBRARY that does not exist: none, even if Python and the system have one
    origen, ruta, falla = en_otro_proceso("KOS_LIBRARY" => joinpath(carpeta, "no_esta.so"), "PATH" => con_python,
                                          "LD_LIBRARY_PATH" => del_sistema)
    @test origen == "" && ruta == "" && occursin("ENV[\"KOS_LIBRARY\"]", falla)
    # nowhere: the package loads anyway and says how to install it (except on a machine that has it installed for all
    # users, where the loader finds it)
    origen, ruta, falla = en_otro_proceso("KOS_LIBRARY" => nothing, "PATH" => sin_python, "LD_LIBRARY_PATH" => nothing)
    if origen == "system"
        @test isfile(ruta)
    else
        @test origen == "" && ruta == ""
        @test occursin("was not found", falla) && occursin("pip install --pre kos-solver", falla)
        @test occursin("https://katsenia.com/downloads.html", falla) && occursin("ENV[\"KOS_LIBRARY\"]", falla)
        # and if the one Python offers is not libkos, it says so
        otra = first(l for l in Libdl.dllist() if occursin("libjulia", basename(l)))
        no_es = mkpath(joinpath(carpeta, "no_es"))
        python_falso(no_es, "echo '$otra'")
        origen, ruta, falla = en_otro_proceso("KOS_LIBRARY" => nothing, "PATH" => no_es, "LD_LIBRARY_PATH" => nothing)
        @test origen == "" && occursin("Found, but not usable", falla) && occursin("has no function", falla)
        @test occursin("pip install --pre kos-solver", falla)
    end
end

function runtests()
    @testset "library" begin
        test_la_de_esta_corrida()
        en_uso, origen = KOSSolver.library_path(), KOSSolver.library_source()
        mktempdir() do carpeta
            try
                test_lo_que_contesta_python(carpeta, copia(joinpath(carpeta, "p"), en_uso))
                test_en_este_proceso(carpeta, en_uso)
            finally
                # the one of this run is put in use again for the other tests
                KOSSolver._carga_biblioteca()
            end
            @test misma(KOSSolver.library_path(), en_uso) && KOSSolver.library_source() == origen
            test_en_otro_proceso(carpeta, en_uso)
        end
    end
end

end
