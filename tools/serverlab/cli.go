package main

import (
	"flag"
	"fmt"
	"os"
	"strings"
)

// baseFlags are the two flags every subcommand takes.
type baseFlags struct {
	config string
	dryRun bool
}

func newFlagSet(name string) (*flag.FlagSet, *baseFlags) {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	base := &baseFlags{}
	fs.StringVar(&base.config, "config", "", "serverlab.toml to read")
	fs.BoolVar(&base.dryRun, "dry-run", false, "print the commands instead of running them")
	return fs, base
}

// setup resolves the repository root and loads the configuration for a
// subcommand that has already parsed its flags.
func (b *baseFlags) setup() (*Config, error) {
	cwd, err := os.Getwd()
	if err != nil {
		return nil, err
	}
	root, err := FindRoot(cwd)
	if err != nil {
		return nil, err
	}
	cfg, err := LoadConfig(root, b.config)
	if err != nil {
		return nil, err
	}
	cfg.DryRun = b.dryRun
	return cfg, nil
}

// splitName pulls the leading positional argument out before the flags are
// parsed. Go's flag package stops at the first non-flag token, and every lab
// command is written the way a person writes it — `lab up srv --profile server`
// — so without this the flags after the name would be silently ignored.
func splitName(args []string) (name string, rest []string) {
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		return args[0], args[1:]
	}
	return "", args
}

// splitList turns "a,b , c" into []string{"a","b","c"} and an empty string
// into nil, which is what every comma-separated flag here wants.
func splitList(value string) []string {
	var out []string
	for _, item := range strings.Split(value, ",") {
		item = strings.TrimSpace(item)
		if item != "" {
			out = append(out, item)
		}
	}
	return out
}

func usageError(fs *flag.FlagSet, format string, args ...any) error {
	fmt.Fprintf(os.Stderr, "%s\n\n", fmt.Sprintf(format, args...))
	fs.Usage()
	return errHandled
}
