#!/usr/bin/env bash
set -euo pipefail

architecture="${1:?usage: build-mediainfokeeper-linux.sh <x64|arm64>}"

case "${architecture}" in
  x64)
    cmake_arch_flags="-march=x86-64 -mtune=generic"
    expected_machine="Advanced Micro Devices X86-64"
    glibc_limit="2.12"
    resource_arch="x64"
    ;;
  arm64)
    cmake_arch_flags="-march=armv8-a -mtune=generic"
    expected_machine="AArch64"
    glibc_limit="2.17"
    resource_arch="arm64"
    ;;
  *)
    echo "Unsupported architecture: ${architecture}" >&2
    exit 2
    ;;
esac

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${repo_dir}/build-mediainfokeeper-linux-${resource_arch}"
artifact_dir="${repo_dir}/artifacts/Resources/Tokenizer/linux/${resource_arch}"
artifact_file="${artifact_dir}/libsimple.so"

rm -rf "${build_dir}" "${artifact_dir}"
mkdir -p "${artifact_dir}"

cmake -S "${repo_dir}" -B "${build_dir}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SQLITE3=OFF \
  -DSIMPLE_WITH_JIEBA=OFF \
  -DBUILD_TEST_EXAMPLE=OFF \
  -DBUILD_STATIC=OFF \
  -DCMAKE_CXX_FLAGS_RELEASE="-O2 -DNDEBUG ${cmake_arch_flags}" \
  -DCMAKE_SHARED_LINKER_FLAGS="-static-libstdc++ -static-libgcc -Wl,--as-needed"

cmake --build "${build_dir}" --config Release --target simple --parallel
strip --strip-unneeded "${build_dir}/src/libsimple.so"
cp "${build_dir}/src/libsimple.so" "${artifact_file}"

machine="$(readelf -h "${artifact_file}" | awk -F: '/Machine:/{sub(/^[[:space:]]+/, "", $2); print $2}')"
if [[ "${machine}" != "${expected_machine}" ]]; then
  echo "Unexpected ELF machine: ${machine}; expected ${expected_machine}" >&2
  exit 1
fi

if ! nm -D --defined-only "${artifact_file}" | grep -E '[[:space:]]sqlite3_simple_init$' >/dev/null; then
  echo "sqlite3_simple_init is not exported" >&2
  exit 1
fi

dynamic_section="$(readelf -d "${artifact_file}")"
for forbidden_dependency in libstdc++.so libgcc_s.so libsqlite3.so; do
  if grep -q "${forbidden_dependency}" <<<"${dynamic_section}"; then
    echo "Forbidden runtime dependency: ${forbidden_dependency}" >&2
    exit 1
  fi
done

if readelf --version-info "${artifact_file}" | grep -E 'GLIBCXX_|CXXABI_' >/dev/null; then
  echo "Unexpected GLIBCXX/CXXABI version dependency" >&2
  exit 1
fi

max_glibc="$(
  readelf --version-info "${artifact_file}" |
    grep -oE 'GLIBC_[0-9]+\.[0-9]+' |
    sed 's/^GLIBC_//' |
    sort -Vu |
    tail -n 1
)"
if [[ -z "${max_glibc}" ]]; then
  echo "Unable to determine GLIBC requirement" >&2
  exit 1
fi

highest_version="$(printf '%s\n%s\n' "${max_glibc}" "${glibc_limit}" | sort -V | tail -n 1)"
if [[ "${highest_version}" != "${glibc_limit}" ]]; then
  echo "GLIBC requirement ${max_glibc} exceeds limit ${glibc_limit}" >&2
  exit 1
fi

sqlite_test="${build_dir}/sqlite3-extension-test"
cc -O2 \
  -DSQLITE_ENABLE_FTS5 \
  -DSQLITE_ENABLE_LOAD_EXTENSION \
  -DSQLITE_THREADSAFE=1 \
  "${repo_dir}/contrib/sqlite3/sqlite3.c" \
  "${repo_dir}/contrib/sqlite3/shell.c" \
  -ldl -lpthread -lm \
  -o "${sqlite_test}"

test_result="$("${sqlite_test}" :memory: <<SQL
.load ${artifact_file} sqlite3_simple_init
CREATE VIRTUAL TABLE docs USING fts5(body, tokenize='simple');
INSERT INTO docs(body) VALUES('中文搜索测试');
SELECT CASE WHEN length(simple_query('中文')) > 0 THEN 'extension-ok' ELSE 'extension-failed' END;
SQL
)"
if ! grep '^extension-ok$' <<<"${test_result}" >/dev/null; then
  echo "SQLite extension smoke test failed" >&2
  echo "${test_result}" >&2
  exit 1
fi

{
  echo "architecture=${architecture}"
  echo "machine=${machine}"
  echo "glibc_max=${max_glibc}"
  echo "glibc_limit=${glibc_limit}"
  echo "pinyin_sha256=$(sha256sum "${repo_dir}/contrib/pinyin.txt" | awk '{print $1}')"
  echo "binary_sha256=$(sha256sum "${artifact_file}" | awk '{print $1}')"
  echo "needed_libraries:"
  grep NEEDED <<<"${dynamic_section}" | sed 's/^/  /'
} | tee "${artifact_dir}/build-info.txt"
