# meta-johnblue: force a newer host compiler for the native nodejs build.
#
# nodejs 24.x bundles the "ada" URL-parser library, whose header (ada.h)
# relies on fully constexpr std::string support (C++20 / P0980), which
# landed in libstdc++ starting with GCC 12. The Ubuntu 22.04 host default
# is GCC 11, which fails with "call to non-'constexpr' function" errors.
#
# gcc-native.bbclass sets BUILD_CC/BUILD_CXX unconditionally (even from a
# bbappend, since BBCLASSEXTEND applies the class after recipe+bbappend
# parsing), so overriding those variables directly gets clobbered. Instead,
# prepend a directory with gcc/g++ wrapper scripts so the plain "gcc"/"g++"
# commands BUILD_CC/BUILD_CXX invoke resolve to GCC 12.
PATH:prepend := "${THISDIR}/gcc12-wrapper:"
