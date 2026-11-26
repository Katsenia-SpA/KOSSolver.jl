# The tests of KOS.jl. They need libkos: the one KOS.jl finds by itself (the one of the Python package kos-solver or
# the system's) or the one of ENV["KOS_LIBRARY"]. They pass with the published library without a license (the
# Community edition: what exceeds its size limit expects `size_limit`) and with a license in effect. The interruption
# test needs more than one thread (julia -t 2) and the bitwise test, the bank of ENV["KOS_JL_BANK"] (see
# bitwise/prepare_bank.py). ENV["KOS_JL_TESTS"] picks a subset: "library,license,moi,signs,status,names,bitwise".

using Test
import KOS

isempty(KOS.load_error()) || error(KOS.load_error())

include("test_library.jl")
include("test_license.jl")
include("test_moi.jl")
include("test_signs.jl")
include("test_status.jl")
include("test_names.jl")
include("test_bitwise.jl")

const PEDIDAS = split(get(ENV, "KOS_JL_TESTS", "library,license,moi,signs,status,names,bitwise"), ",")

@testset "KOS.jl" begin
    "library" in PEDIDAS && TestLibrary.runtests()
    "license" in PEDIDAS && TestLicense.runtests()
    "signs" in PEDIDAS && TestSigns.runtests()
    "status" in PEDIDAS && TestStatus.runtests()
    "names" in PEDIDAS && TestNames.runtests()
    "moi" in PEDIDAS && @testset "MOI.Test" begin
        TestMOI.runtests()
    end
    "bitwise" in PEDIDAS && TestBitwise.runtests()
end
