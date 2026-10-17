yk_config := "/path/to/yk/bin/yk-config"

export PATH := parent_directory(yk_config) + ":" + env_var("PATH")
cp        := "Smalltalk:Examples:TestSuite"

build: build-yk

build-release:
    make clean
    make

build-debug:
    make clean
    make debug

build-yk-debug:
    make clean
    make YK_BUILD_TYPE=debug YK_CONFIG={{yk_config}}

build-yk-release:
    make clean
    make YK_BUILD_TYPE=release YK_CONFIG={{yk_config}}
    cp CSOM CSOM-yk.tmp && mv -f CSOM-yk.tmp CSOM-yk

build-yk: build-yk-release

test-som: build-release
    ./CSOM -cp Smalltalk TestSuite/TestHarness.som

test-yk: build-yk-release
    ./CSOM-yk -cp Smalltalk TestSuite/TestHarness.som

clean:
    make clean
