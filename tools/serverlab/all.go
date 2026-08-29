package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// cmdAll is the whole loop, from a checkout to a report: build the packages,
// test them, build the ISO, install a VM from it, measure the VM, write the
// report. It is what a nightly self-hosted runner would call, and what somebody
// verifying a claim in this repository runs once.
//
// --dry-run prints the plan and touches nothing, which is also how the plan is
// reviewed before a two-hour run.
func cmdAll(args []string) error {
	fs, base := newFlagSet("all")
	name := fs.String("name", "srv", "name of the lab VM")
	profile := fs.String("profile", "", "profile to build and install (default: the configured one)")
	suites := fs.String("suites", "", "acceptance suites to run (default: what the lab was installed for)")
	isoPath := fs.String("iso", "", "reuse this ISO instead of building one")
	addons := fs.String("addons", "", "comma-separated addons to apply during the install")
	mac := fs.String("mac", "", "install with selinux or apparmor")
	secboot := fs.Bool("secboot", false, "install with Secure Boot")
	unattended := fs.Bool("unattended-updates", false, "enable the daily update timer at install time")
	hostname := fs.String("hostname", "", "hostname for the installed machine")
	diskGB := fs.Int("disk-gb", 0, "system disk size in GiB")
	dataDiskGB := fs.Int("data-disk-gb", 0, "attach a second, empty disk of this size in GiB")
	skipPkgs := fs.Bool("skip-pkgs", false, "do not rebuild and retest the packages")
	skipISO := fs.Bool("skip-iso", false, "do not build the ISO (implied by --iso)")
	skipReport := fs.Bool("skip-report", false, "do not write a report at the end")
	enforce := fs.Bool("enforce", false, "MAC suites: also run the ENFORCE=1 pass")
	noPublish := fs.Bool("no-publish", false, "keep the evidence private to the lab instead of copying it into pocs/server-install/reference/")
	fresh := fs.Bool("fresh", false, "iso build: discard the scratch tree first")
	if err := fs.Parse(args); err != nil {
		return errHandled
	}
	cfg, err := base.setup()
	if err != nil {
		return err
	}
	if *profile == "" {
		*profile = cfg.Profile
	}
	if *diskGB == 0 {
		*diskGB = cfg.DiskGB
	}
	if *dataDiskGB == 0 {
		*dataDiskGB = cfg.DataDiskGB
	}
	if *isoPath != "" {
		*skipISO = true
	}

	plan := buildPlan(cfg, planOptions{
		name: *name, profile: *profile, suites: *suites, iso: *isoPath,
		addons: *addons, mac: *mac, secboot: *secboot, unattended: *unattended,
		hostname: *hostname, diskGB: *diskGB, dataDiskGB: *dataDiskGB,
		skipPkgs: *skipPkgs, skipISO: *skipISO, skipReport: *skipReport,
		enforce: *enforce, noPublish: *noPublish, fresh: *fresh,
	})

	if cfg.DryRun {
		fmt.Printf("plan for `serverlab all` in %s:\n\n", cfg.Root)
		for index, step := range plan {
			fmt.Printf("  %d. %-14s %s\n", index+1, step.Label, step.Describe)
		}
		fmt.Printf("\n%d steps, nothing was run.\n", len(plan))
		return nil
	}

	session, err := NewSession(cfg, "all")
	if err != nil {
		return err
	}
	defer session.Close()

	var runErr error
	for _, step := range plan {
		session.Printf("")
		session.Printf("── %s ──", step.Label)
		if runErr = step.Run(session); runErr != nil {
			break
		}
	}
	session.Summary()
	if runErr != nil {
		return errHandled
	}
	return nil
}

type planOptions struct {
	name, profile, suites, iso    string
	addons, mac, hostname         string
	secboot, unattended           bool
	diskGB, dataDiskGB            int
	skipPkgs, skipISO, skipReport bool
	enforce, fresh                bool
	noPublish                     bool
}

// planStep is one stage of `all`: a label, a human description used by
// --dry-run, and the work itself.
type planStep struct {
	Label    string
	Describe string
	Run      func(*Session) error
}

func buildPlan(cfg *Config, opts planOptions) []planStep {
	var plan []planStep

	if !opts.skipPkgs {
		plan = append(plan,
			planStep{"pkgs build", "pkgs/build.sh — build and sign the server packages into pkgs/repo/",
				func(s *Session) error { return pkgsBuild(s, nil) }},
			planStep{"pkgs test", "pkgs/test.sh — install them in a clean archlinux container",
				func(s *Session) error { return pkgsTest(s) }},
		)
	}
	if !opts.skipISO {
		plan = append(plan, planStep{"iso build",
			fmt.Sprintf("iso/build.sh --profile %s — build the ISO with the profile's offline mirror", opts.profile),
			func(s *Session) error { return isoBuild(s, opts.profile, opts.fresh, false) }})
	}

	// The lab is assembled at run time, not at plan time: when the plan
	// includes an ISO build, the image to install from is the one that build
	// produced, which does not exist yet while the plan is being printed.
	labDescribe := fmt.Sprintf("mkcidata + vm create + start + wait-ssh for `%s` (profile %s", opts.name, opts.profile)
	if opts.mac != "" {
		labDescribe += ", mac " + opts.mac
	}
	if opts.secboot {
		labDescribe += ", secure boot"
	}
	if opts.addons != "" {
		labDescribe += ", addons " + opts.addons
	}
	labDescribe += "), " + describeVM(cfg, opts)
	if opts.iso != "" {
		labDescribe += ", from " + filepath.Base(opts.iso)
	} else {
		labDescribe += ", from the newest ISO in iso/release"
	}

	var lab *Lab
	plan = append(plan, planStep{"lab up", labDescribe, func(s *Session) error {
		iso := opts.iso
		if iso == "" {
			found, err := newestISO(cfg, opts.profile)
			if err != nil {
				return err
			}
			iso = found
		}
		absolute, err := filepath.Abs(iso)
		if err != nil {
			return err
		}
		lab = &Lab{
			Name: opts.name, Profile: opts.profile, Hostname: opts.hostname,
			Addons: splitList(opts.addons), MAC: opts.mac,
			SecureBoot: opts.secboot, UnattendedUpdates: opts.unattended,
			DiskGB: opts.diskGB, DataDiskGB: opts.dataDiskGB,
			MemoryMB: cfg.MemoryMB, CPUs: cfg.CPUs,
			ISO: absolute, Out: cfg.LabOut(opts.name), Created: time.Now(),
		}
		return runLabUp(s, lab, 1800)
	}})

	testDescribe := "collect + surface + acceptance"
	if opts.suites != "" {
		testDescribe += " (" + opts.suites + ")"
	}
	testDescribe += " + reboot-check, into the lab's evidence directory"
	plan = append(plan, planStep{"lab test", testDescribe, func(s *Session) error {
		resolved, err := resolveSuites(lab, opts.suites)
		if err != nil {
			return err
		}
		return runLabTest(s, lab, resolved, false, false, opts.enforce, !opts.noPublish)
	}})

	if !opts.skipReport {
		plan = append(plan, planStep{"report",
			"reports/" + time.Now().Format("2006-01-02") + "-" + opts.name + ".md, and the index row",
			func(s *Session) error {
				date := time.Now().Format("2006-01-02")
				input, err := buildReportInput(cfg, lab, "", "", date)
				if err != nil {
					return err
				}
				path := filepath.Join(cfg.Root, "reports", date+"-"+opts.name+".md")
				if err := os.WriteFile(path, []byte(RenderReport(*input)), 0o644); err != nil {
					return err
				}
				if err := appendIndexRow(cfg, *input, path); err != nil {
					return err
				}
				s.Printf("report: %s", path)
				return nil
			}})
	}
	return plan
}

// describeVM is used by the dry-run plan to say what shape the VM will have.
func describeVM(cfg *Config, opts planOptions) string {
	return strings.Join([]string{
		strconv.Itoa(cfg.CPUs) + " vCPU",
		humanMemory(cfg.MemoryMB),
		strconv.Itoa(opts.diskGB) + " GiB disk",
	}, ", ")
}
