# serverlab is the driver for everything in this repository that is worth
# repeating: the package build, the ISO build, a lab install, the acceptance
# runs and the report written from their evidence.
#
#   make serverlab      build bin/serverlab (gitignored)
#   make test           the driver's Go tests and the profile's shell tests
#   make shell-test     only test/shell (the profile's runtime commands)
#   make doctor         what this host is still missing
#
# The bash scripts under pkgs/, iso/ and pocs/ stay runnable by hand; serverlab
# calls them, it does not replace them.

GO ?= go
BIN := bin/serverlab
SRC := $(wildcard tools/serverlab/*.go) tools/serverlab/go.mod

.PHONY: serverlab test shell-test doctor clean

serverlab: $(BIN)

$(BIN): $(SRC)
	@mkdir -p bin
	cd tools/serverlab && CGO_ENABLED=0 $(GO) build -trimpath -o ../../$(BIN) .
	@echo "built $(BIN)"

test: shell-test
	cd tools/serverlab && test -z "$$(gofmt -l .)" || { gofmt -l .; echo "run gofmt -w"; exit 1; }
	cd tools/serverlab && $(GO) vet ./...
	cd tools/serverlab && $(GO) test ./...

# The profile's runtime commands, against fixture trees: no root, no pacman, no
# machine. Anything heavier is pkgs/test.sh or an acceptance list under pocs/.
shell-test:
	./test/shell

doctor: $(BIN)
	./$(BIN) doctor

clean:
	rm -rf bin
