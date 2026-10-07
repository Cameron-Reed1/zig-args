#!/usr/bin/env bash


function expect_success() {
    $@ > /dev/null 2>&1
    if [ "$?" -eq "0" ]; then
        echo -e "[\x1b[32m✓\x1b[0m] $@"
    else
        echo -e "[\x1b[31mX\x1b[0m] $@"
    fi
}

function expect_failure() {
    $@ > /dev/null 2>&1
    if [ "$?" -eq "1" ]; then
        echo -e "[\x1b[32m✓\x1b[0m] $@"
    else
        echo -e "[\x1b[31mX\x1b[0m] $@"
    fi
}

expect_failure ./zig-out/bin/args
expect_success ./zig-out/bin/args cmd1
expect_failure ./zig-out/bin/args cmd1 --value
expect_success ./zig-out/bin/args cmd1 --value hello
expect_success ./zig-out/bin/args cmd2 --value 255
expect_failure ./zig-out/bin/args cmd2 --value 256
expect_failure ./zig-out/bin/args cmd2 --value -1
expect_success ./zig-out/bin/args cmd3
expect_success ./zig-out/bin/args cmd3 --value
expect_success ./zig-out/bin/args cmd4
expect_success ./zig-out/bin/args cmd5
expect_success ./zig-out/bin/args cmd5 cmd51
expect_failure ./zig-out/bin/args cmd5 cmd52
expect_success ./zig-out/bin/args cmd5 cmd52 --value 30000
expect_success ./zig-out/bin/args --global 1 cmd5 cmd52 --value 30000
expect_success ./zig-out/bin/args cmd5 --global 1 cmd52 --value 30000
expect_success ./zig-out/bin/args cmd5 cmd52 --global 1 --value 30000
expect_success ./zig-out/bin/args cmd5 cmd52 --value 30000 --global 1
