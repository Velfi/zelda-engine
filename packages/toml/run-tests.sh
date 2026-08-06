#!/usr/bin/env bash
# Also compatible with zsh, but not POSIX sh.
#
# Run the toml-test compliance tests: https://github.com/toml-lang/toml-test

# Decoder and encoder commands; leave encoder blank if writing TOML isn't supported.
decoder="./toml_decode"

encoder="./toml_encode" # No encoder tests

# Version of the TOML specification to test.
toml=1.1.0

# Find toml-test
tt=
if [[ -x "./toml-test" ]] && [[ ! -d "./toml-test" ]]; then
    tt="./toml-test"
elif command -v "toml-test" >/dev/null; then
    tt="toml-test"
elif [[ -n "$(go env GOBIN)" ]] && [[ -x "$(go env GOBIN)/toml-test" ]]; then
    tt="$(go env GOPATH)/toml-test"
elif [[ -n "$(go env GOPATH)" ]] && [[ -x "$(go env GOPATH)/bin/toml-test" ]]; then
    tt="$(go env GOPATH)/bin/toml-test"
elif [[ -x "$HOME/go/bin/toml-test" ]]; then
    tt="$HOME/go/bin/toml-test"
fi
if ! command -v "$tt" >/dev/null; then
    echo >&2 'install toml-test with:'
    echo >&2 '    % go install github.com/toml-lang/toml-test/v2/cmd/toml-test@v2.2.0'
    echo >&2
    echo >&2 'Or download a binary from:'
    echo >&2 '    https://github.com/toml-lang/toml-test/releases'
    exit 1
fi

# Run toml-test
odin build . -out:"$decoder" -define:DECODER=true
odin build . -out:"$encoder" -define:ENCODER=true
echo >&2 "Running tests with: $tt"
"$tt" test -toml="$toml" -skip-must-err -decoder="$decoder" -encoder="${encoder}" "$@"
