// Command serverlab drives the omarchy-server lab from one place.
//
// It owns no build logic of its own. The bash scripts under pkgs/, iso/,
// pocs/lab/ and pocs/server-install/ stay the leaves — they follow the
// conventions of upstream Omarchy and are what a reader should be able to run
// by hand — and serverlab is the orchestrator that calls them with the right
// environment, streams their output with a prefix, records how long each step
// took, stops at the first failure and writes a run log.
//
// The point is that everything repetitive in this repository is one command:
//
//	serverlab doctor                       what this host is missing
//	serverlab pkgs build|test|verify|publish
//	serverlab iso build --profile server
//	serverlab lab up srv --profile server
//	serverlab lab test srv --suite base
//	serverlab report srv
//	serverlab all --profile server         all of the above, from scratch
//
// No daemon, no state outside the repository: each lab keeps its settings in
// its own LAB_OUT directory, so a later `lab test` knows what the machine was
// installed with. A self-hosted runner calls the same subcommands.
package main

import (
	"errors"
	"fmt"
	"os"
)

const usage = `serverlab — one command for the omarchy-server lab

Usage:
  serverlab doctor                       check the host prerequisites
  serverlab pkgs build [PKG...]          build the server packages (pkgs/build.sh)
  serverlab pkgs test                    install them in a clean container
  serverlab pkgs verify                  prove the published repo (pkgs repo, scripts/verify.sh)
  serverlab pkgs publish --yes           upload the repo assets to GitHub
  serverlab iso build [--profile P] [--fresh] [--debug]
  serverlab lab up NAME [flags]          cidata + create + start + wait-ssh
  serverlab lab test NAME [--suite S]    collect + surface + acceptance + reboot-check
  serverlab lab status|down|ssh|screenshot NAME
  serverlab report NAME [flags]          write reports/YYYY-MM-DD-<name>.md
  serverlab all [flags]                  pkgs -> iso -> lab up -> lab test -> report

Common flags:
  --dry-run        print the commands instead of running them
  --config PATH    serverlab.toml to read (default: <repo root>/serverlab.toml)

Run "serverlab <command> --help" for the flags of a command.
`

func main() {
	if err := dispatch(os.Args[1:]); err != nil {
		if errors.Is(err, errHandled) {
			os.Exit(1)
		}
		fmt.Fprintf(os.Stderr, "serverlab: %v\n", err)
		os.Exit(1)
	}
}

// errHandled marks a failure whose message was already printed by the step
// that produced it, so main does not print it a second time.
var errHandled = errors.New("failed")

func dispatch(args []string) error {
	if len(args) == 0 {
		fmt.Print(usage)
		return nil
	}
	switch args[0] {
	case "doctor":
		return cmdDoctor(args[1:])
	case "pkgs":
		return cmdPkgs(args[1:])
	case "iso":
		return cmdISO(args[1:])
	case "lab":
		return cmdLab(args[1:])
	case "report":
		return cmdReport(args[1:])
	case "all":
		return cmdAll(args[1:])
	case "help", "-h", "--help":
		fmt.Print(usage)
		return nil
	default:
		return fmt.Errorf("unknown command %q\n\n%s", args[0], usage)
	}
}
