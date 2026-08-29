package main

import (
	"fmt"
	"os"
	"path/filepath"
)

// cmdPkgs wraps the two package pipelines: the fast local one in this
// repository (pkgs/build.sh, pkgs/test.sh, which build the PKGBUILDs of the
// sibling repository against the WORKING TREE of profile/server/) and the
// published one in omarchy-server-pkgs (scripts/publish.sh, scripts/verify.sh,
// which are what CI runs).
func cmdPkgs(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: serverlab pkgs build|test|verify|publish [flags]")
	}
	action := args[0]
	fs, base := newFlagSet("pkgs " + action)
	build := fs.Bool("build", false, "verify: build the packages in the pkgs repository first")
	yes := fs.Bool("yes", false, "publish: confirm uploading the repository assets")
	if err := fs.Parse(args[1:]); err != nil {
		return errHandled
	}
	cfg, err := base.setup()
	if err != nil {
		return err
	}

	session, err := NewSession(cfg, "pkgs-"+action)
	if err != nil {
		return err
	}
	defer session.Close()

	switch action {
	case "build":
		err = pkgsBuild(session, fs.Args())
	case "test":
		err = pkgsTest(session)
	case "verify":
		err = pkgsVerify(session, *build)
	case "publish":
		err = pkgsPublish(session, *yes)
	default:
		return fmt.Errorf("unknown pkgs action %q (build, test, verify, publish)", action)
	}
	session.Summary()
	return err
}

// pkgsBuild builds the server packages into pkgs/repo/ with the lab signing
// key. Extra arguments name single packages, as pkgs/build.sh accepts.
func pkgsBuild(s *Session, packages []string) error {
	cfg := s.Config
	if err := requirePkgsRepo(cfg); err != nil {
		return err
	}
	args := append([]string{cfg.Script("pkgs", "build.sh")}, packages...)
	return s.Run(Step{
		Label: "pkgs build",
		Args:  args,
		Env:   []string{"OMARCHY_PKGS_DIR=" + cfg.PkgsRepo, "TUI_TOOLS_DIR=" + cfg.TuiTools},
	})
}

// pkgsTest installs the freshly built repository into a clean archlinux
// container and asserts the packaging acceptance criteria.
func pkgsTest(s *Session) error {
	cfg := s.Config
	repo := cfg.Script("pkgs", "repo", "omarchy-server.db.tar.gz")
	if _, err := os.Stat(repo); err != nil && !cfg.DryRun {
		return fmt.Errorf("pkgs/repo is empty; run `serverlab pkgs build` first")
	}
	return s.Run(Step{Label: "pkgs test", Args: []string{cfg.Script("pkgs", "test.sh")}})
}

// pkgsVerify proves the PUBLISHED repository shape: the packages repository
// assembles its database, serves it over HTTP to a container that trusts
// nothing, and refuses a hostile mirror. It runs in the sibling repository
// because that is where the published pipeline lives.
func pkgsVerify(s *Session, buildFirst bool) error {
	cfg := s.Config
	if err := requirePkgsRepo(cfg); err != nil {
		return err
	}
	if buildFirst {
		if err := s.Run(Step{
			Label: "pkgs repo build",
			Args:  []string{filepath.Join(cfg.PkgsRepo, "scripts", "build.sh")},
			Dir:   cfg.PkgsRepo,
		}); err != nil {
			return err
		}
	}
	matches, _ := filepath.Glob(filepath.Join(cfg.PkgsRepo, "out", "*.pkg.tar.zst"))
	if len(matches) == 0 && !cfg.DryRun {
		return fmt.Errorf("%s/out has no packages; run `serverlab pkgs verify --build`", cfg.PkgsRepo)
	}
	if err := s.Run(Step{
		Label: "pkgs publish --local",
		Args:  []string{filepath.Join(cfg.PkgsRepo, "scripts", "publish.sh"), "--local"},
		Dir:   cfg.PkgsRepo,
	}); err != nil {
		return err
	}
	return s.Run(Step{
		Label: "pkgs verify",
		Args:  []string{filepath.Join(cfg.PkgsRepo, "scripts", "verify.sh")},
		Dir:   cfg.PkgsRepo,
	})
}

// pkgsPublish uploads the repository assets to the fixed `repo` GitHub
// release. It is the one subcommand that changes something outside this
// machine, so it refuses to run without --yes and says what it will do.
func pkgsPublish(s *Session, confirmed bool) error {
	cfg := s.Config
	if err := requirePkgsRepo(cfg); err != nil {
		return err
	}
	if !confirmed {
		s.Printf("serverlab pkgs publish uploads the signed [omarchy-server] repository")
		s.Printf("(database + every package in %s/out) as assets of the fixed `repo`", cfg.PkgsRepo)
		s.Printf("GitHub release, replacing the assets that are there now. Every machine")
		s.Printf("with the repository enabled sees the result on its next `pacman -Sy`.")
		s.Printf("")
		s.Printf("Re-run with --yes to do it.")
		return errHandled
	}
	return s.Run(Step{
		Label: "pkgs publish",
		Args:  []string{filepath.Join(cfg.PkgsRepo, "scripts", "publish.sh")},
		Dir:   cfg.PkgsRepo,
	})
}

func requirePkgsRepo(cfg *Config) error {
	if _, err := os.Stat(filepath.Join(cfg.PkgsRepo, "pkgbuilds")); err != nil {
		return fmt.Errorf("%s/pkgbuilds not found; clone omarchy-server-pkgs beside this repository or set paths.pkgs_repo", cfg.PkgsRepo)
	}
	return nil
}
