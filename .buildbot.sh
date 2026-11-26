#!/bin/sh

set -eu

git submodule update --init

# Build and run tests without Yk.
make
make test
make clean

# Install Rust.
export CARGO_HOME="$PWD/.cargo"
export RUSTUP_HOME="$PWD/.rustup"
export RUSTUP_INIT_SKIP_PATH_CHECK="yes"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs > rustup.sh
sh rustup.sh --default-host x86_64-unknown-linux-gnu \
    --default-toolchain nightly \
    --no-modify-path \
    --profile minimal \
    -y
export PATH="$PWD/.cargo/bin:$PATH"

# Clone and build Yk.
git clone --depth 1 --recurse-submodules --shallow-submodules https://github.com/ykjit/yk
cd yk
echo "yk commit: $(git show -s --format=%H)"
cat << EOF2 >> Cargo.toml
[profile.release-with-asserts]
inherits = "release"
debug-assertions = true
overflow-checks = true
EOF2

cd ykllvm
ykllvm_hash=$(git rev-parse HEAD)
if [ -f /opt/ykllvm_cache/ykllvm-release-with-assertions-"${ykllvm_hash}".tgz ]; then
    mkdir inst
    cd inst
    tar xfz /opt/ykllvm_cache/ykllvm-release-with-assertions-"${ykllvm_hash}".tgz
    cd ..
    if inst/bin/clang --version > /dev/null; then
        YKB_YKLLVM_BIN_DIR="$(pwd)/inst/bin"
        export YKB_YKLLVM_BIN_DIR
    else
        echo "Warning: cached ykllvm not runnable; building from scratch" >&2
        rm -rf inst
    fi
fi
cd ..

YKB_YKLLVM_BUILD_ARGS="define:CMAKE_C_COMPILER=/usr/bin/clang,define:CMAKE_CXX_COMPILER=/usr/bin/clang++" \
    cargo build
export PATH="$PWD/bin:$PATH"
cd ..

# Build with Yk and run tests.
make YK_BUILD_TYPE=debug YK_CONFIG="$(pwd)/yk/bin/yk-config"
YK_SIDETRACE_THRESHOLD=1 YKD_SERIALISE_COMPILATION=1 YK_HOT_THRESHOLD=1 ./CSOM -cp Smalltalk TestSuite/TestHarness.som
