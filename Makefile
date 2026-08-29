# serverlab is the driver for everything in this repository that is worth
# repeating: the package build, the ISO build, a lab install, the acceptance
# runs and the report written from their evidence.
#
#   make serverlab      build bin/serverlab (gitignored)
#   make test           gofmt + go vet + go test for the driver
#   make doctor         what this host is still missing
#
# The bash scripts under pkgs/, iso/ and pocs/ stay runnable by hand; serverlab
# calls them, it does not replace them.

GO ?= go
BIN := bin/serverlab
SRC := $(wildcard tools/serverlab/*.go) tools/serverlab/go.mod

.PHONY: serverlab test doctor clean

serverlab: $(BIN)

$(BIN): $(SRC)
	@mkdir -p bin
	cd tools/serverlab && CGO_ENABLED=0 $(GO) build -trimpath -o ../../$(BIN) .
	@echo "built $(BIN)"

test:
	cd tools/serverlab && test -z "$$(gofmt -l .)" || { gofmt -l .; echo "run gofmt -w"; exit 1; }
	cd tools/serverlab && $(GO) vet ./...
	cd tools/serverlab && $(GO) test ./...

doctor: $(BIN)
	./$(BIN) doctor

clean:
	rm -rf bin
