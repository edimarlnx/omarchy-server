package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"
)

// Lab is what a VM was installed with, stored as lab.json inside the lab's own
// LAB_OUT directory. `lab up` writes it and `lab test` reads it, which is how
// the test command knows that a machine carrying the `selinux` marker wants the
// SELinux acceptance list and not just the base one.
//
// It lives with the disk and the cidata drive rather than in the repository:
// the directory is gitignored, the settings are true only for that machine, and
// deleting the directory deletes the whole lab.
type Lab struct {
	Name              string    `json:"name"`
	Profile           string    `json:"profile"`
	Hostname          string    `json:"hostname,omitempty"`
	Addons            []string  `json:"addons,omitempty"`
	MAC               string    `json:"mac,omitempty"`
	SecureBoot        bool      `json:"secureBoot"`
	UnattendedUpdates bool      `json:"unattendedUpdates"`
	DiskGB            int       `json:"diskGb"`
	DataDiskGB        int       `json:"dataDiskGb,omitempty"`
	MemoryMB          int       `json:"memoryMb"`
	CPUs              int       `json:"cpus"`
	ISO               string    `json:"iso"`
	Out               string    `json:"out"`
	Created           time.Time `json:"created"`
}

func (l *Lab) settingsPath() string { return filepath.Join(l.Out, "lab.json") }

func (l *Lab) save() error {
	if err := os.MkdirAll(l.Out, 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(l, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(l.settingsPath(), append(data, '\n'), 0o644)
}

func loadLab(cfg *Config, name string) (*Lab, error) {
	path := filepath.Join(cfg.LabOut(name), "lab.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("no lab %q (%s); run `serverlab lab up %s` first", name, path, name)
	}
	lab := &Lab{}
	if err := json.Unmarshal(data, lab); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if lab.Out == "" {
		lab.Out = cfg.LabOut(name)
	}
	return lab, nil
}

// evidenceDir is where the collectors and the acceptance runs write, one
// directory per lab so two machines never overwrite each other's record.
func (l *Lab) evidenceDir() string { return filepath.Join(l.Out, "evidence") }

// env is what every pocs/ script needs to talk to this particular VM.
func (l *Lab) env() []string {
	env := []string{"LAB_OUT=" + l.Out}
	if l.MemoryMB > 0 {
		env = append(env, "MEM="+strconv.Itoa(l.MemoryMB))
	}
	if l.CPUs > 0 {
		env = append(env, "CPUS="+strconv.Itoa(l.CPUs))
	}
	return env
}

// Suites returns the acceptance suites this machine was installed for. Every
// machine gets the base list; a Secure Boot or MAC marker adds its own.
func (l *Lab) Suites() []string {
	suites := []string{"base"}
	if l.SecureBoot {
		suites = append(suites, "secureboot")
	}
	if l.MAC != "" {
		suites = append(suites, l.MAC)
	}
	return suites
}

func cmdLab(args []string) error {
	if len(args) < 2 {
		return fmt.Errorf("usage: serverlab lab up|test|down|status|ssh|screenshot NAME [flags]")
	}
	action := args[0]
	switch action {
	case "up":
		return labUp(args[1:])
	case "test":
		return labTest(args[1:])
	case "down", "status", "screenshot":
		return labSimple(action, args[1:])
	case "ssh":
		return labSSH(args[1:])
	default:
		return fmt.Errorf("unknown lab action %q (up, test, down, status, ssh, screenshot)", action)
	}
}

func labUp(args []string) error {
	fs, base := newFlagSet("lab up")
	profile := fs.String("profile", "", "install profile (default: the configured one)")
	addons := fs.String("addons", "", "comma-separated addons to apply during the install")
	mac := fs.String("mac", "", "mandatory access control to install: selinux or apparmor")
	secboot := fs.Bool("secboot", false, "Secure Boot: firmware in setup mode, keys enrolled during the install")
	unattended := fs.Bool("unattended-updates", false, "enable the daily update timer during the install")
	diskGB := fs.Int("disk-gb", 0, "system disk size in GiB (default: the configured one)")
	dataDiskGB := fs.Int("data-disk-gb", 0, "attach a second, empty disk of this size in GiB")
	hostname := fs.String("hostname", "", "hostname for the installed machine (default: the installer's own)")
	isoPath := fs.String("iso", "", "ISO to install from (default: the newest matching one in iso/release)")
	waitSecs := fs.Int("wait", 1800, "seconds to wait for ssh to answer")
	name, rest := splitName(args)
	if err := fs.Parse(rest); err != nil {
		return errHandled
	}
	if name == "" {
		return usageError(fs, "lab up needs a name")
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
	if *mac != "" && *mac != "selinux" && *mac != "apparmor" {
		return fmt.Errorf("--mac takes selinux or apparmor, not %q", *mac)
	}

	iso := *isoPath
	if iso == "" {
		iso, err = newestISO(cfg, *profile)
		if err != nil {
			return err
		}
	}
	if !filepath.IsAbs(iso) {
		if iso, err = filepath.Abs(iso); err != nil {
			return err
		}
	}

	lab := &Lab{
		Name:              name,
		Profile:           *profile,
		Hostname:          *hostname,
		Addons:            splitList(*addons),
		MAC:               *mac,
		SecureBoot:        *secboot,
		UnattendedUpdates: *unattended,
		DiskGB:            *diskGB,
		DataDiskGB:        *dataDiskGB,
		MemoryMB:          cfg.MemoryMB,
		CPUs:              cfg.CPUs,
		ISO:               iso,
		Out:               cfg.LabOut(name),
		Created:           time.Now(),
	}

	session, err := NewSession(cfg, "lab-up-"+name)
	if err != nil {
		return err
	}
	defer session.Close()

	err = runLabUp(session, lab, *waitSecs)
	session.Summary()
	if err != nil {
		return err
	}
	session.Printf("lab %s is up: %s", name, lab.Out)
	return nil
}

func runLabUp(s *Session, lab *Lab, waitSecs int) error {
	cfg := s.Config
	if cfg.DryRun {
		s.Printf("[lab] (dry run) settings would be written to %s", lab.settingsPath())
	} else {
		if _, err := os.Stat(lab.ISO); err != nil {
			return fmt.Errorf("ISO not found: %s", lab.ISO)
		}
		// The settings are saved before the install rather than after it: a
		// run that dies half way still leaves a lab the operator can inspect,
		// take down and start again.
		if err := lab.save(); err != nil {
			return err
		}
	}

	// 1. the autoinstall drive, carrying every marker this machine asked for.
	cidata := []string{
		cfg.Script("pocs", "lab", "mkcidata.sh"),
		"--profile", lab.Profile,
		"--disk-size-gb", strconv.Itoa(lab.DiskGB),
		"--out", lab.Out,
	}
	if lab.Hostname != "" {
		cidata = append(cidata, "--hostname", lab.Hostname)
	}
	if len(lab.Addons) > 0 {
		cidata = append(cidata, "--addons", strings.Join(lab.Addons, ","))
	}
	if lab.MAC != "" {
		cidata = append(cidata, "--mac", lab.MAC)
	}
	if lab.SecureBoot {
		cidata = append(cidata, "--secureboot")
	}
	if lab.UnattendedUpdates {
		cidata = append(cidata, "--unattended-updates")
	}
	if err := s.Run(Step{Label: "cidata", Args: cidata}); err != nil {
		return err
	}

	// 2. the VM. An existing disk is left alone: recreating it would throw
	//    away the machine the operator is about to test.
	if _, err := os.Stat(filepath.Join(lab.Out, "vm", lab.Name, "disk.qcow2")); err == nil {
		s.Skip("vm create", "disk already exists")
	} else {
		create := []string{cfg.Script("pocs", "lab", "vm.sh"), lab.Name, "create", "--disk-gb", strconv.Itoa(lab.DiskGB)}
		if lab.DataDiskGB > 0 {
			create = append(create, "--data-disk-gb", strconv.Itoa(lab.DataDiskGB))
		}
		if lab.SecureBoot {
			create = append(create, "--secboot")
		}
		if err := s.Run(Step{Label: "vm create", Args: create, Env: lab.env()}); err != nil {
			return err
		}
	}

	// 3. boot it with the install ISO and the autoinstall drive attached.
	start := []string{
		cfg.Script("pocs", "lab", "vm.sh"), lab.Name, "start",
		"--iso", lab.ISO,
		"--cidata", filepath.Join(lab.Out, "cidata.iso"),
	}
	if err := s.Run(Step{Label: "vm start", Args: start, Env: lab.env()}); err != nil {
		return err
	}

	// 4. the install runs unattended; ssh answering is what says it finished.
	return s.Run(Step{
		Label: "wait-ssh",
		Args:  []string{cfg.Script("pocs", "lab", "vm.sh"), lab.Name, "wait-ssh", strconv.Itoa(waitSecs)},
		Env:   lab.env(),
	})
}

func labTest(args []string) error {
	fs, base := newFlagSet("lab test")
	suite := fs.String("suite", "", "base, secureboot, selinux, apparmor or all (default: what the lab was installed with)")
	noCollect := fs.Bool("no-collect", false, "skip collect.sh and surface.sh")
	noReboot := fs.Bool("no-reboot", false, "skip reboot-check.sh, which takes the VM down and up")
	enforce := fs.Bool("enforce", false, "MAC suites: also run the ENFORCE=1 pass")
	publish := fs.Bool("publish-evidence", false, "copy the evidence into pocs/server-install/reference/ as well")
	name, rest := splitName(args)
	if err := fs.Parse(rest); err != nil {
		return errHandled
	}
	if name == "" {
		return usageError(fs, "lab test needs a name")
	}

	cfg, err := base.setup()
	if err != nil {
		return err
	}
	lab, err := loadLab(cfg, name)
	if err != nil {
		return err
	}

	suites, err := resolveSuites(lab, *suite)
	if err != nil {
		return err
	}

	session, err := NewSession(cfg, "lab-test-"+name)
	if err != nil {
		return err
	}
	defer session.Close()

	err = runLabTest(session, lab, suites, *noCollect, *noReboot, *enforce, *publish)
	session.Summary()
	return err
}

// resolveSuites turns the --suite flag into the list of acceptance scripts to
// run, refusing a suite the machine was not installed for rather than running
// a SELinux list against a machine with no SELinux.
func resolveSuites(lab *Lab, requested string) ([]string, error) {
	available := lab.Suites()
	switch requested {
	case "", "all":
		return available, nil
	case "base", "secureboot", "selinux", "apparmor":
		if !slices.Contains(available, requested) {
			return nil, fmt.Errorf("lab %q was installed without %s (it has: %s)",
				lab.Name, requested, strings.Join(available, ", "))
		}
		return []string{requested}, nil
	default:
		return nil, fmt.Errorf("unknown suite %q (base, secureboot, selinux, apparmor, all)", requested)
	}
}

func runLabTest(s *Session, lab *Lab, suites []string, noCollect, noReboot, enforce, publish bool) error {
	cfg := s.Config
	evidence := lab.evidenceDir()
	if err := os.MkdirAll(evidence, 0o755); err != nil {
		return err
	}
	s.Printf("evidence: %s", evidence)

	// collect.sh and surface.sh run FIRST: the acceptance lists install the
	// docker addon and then run an update, which change the package set and
	// the disk usage those two measure.
	if !noCollect {
		if err := s.Run(Step{
			Label: "collect",
			Args:  []string{cfg.Script("pocs", "server-install", "collect.sh"), lab.Name, evidence},
			Env:   lab.env(),
		}); err != nil {
			return err
		}
		if err := s.Run(Step{
			Label: "surface",
			Args:  []string{cfg.Script("pocs", "server-install", "surface.sh"), lab.Name, filepath.Join(evidence, "surface.txt")},
			Env:   lab.env(),
		}); err != nil {
			return err
		}
	} else {
		s.Skip("collect", "--no-collect")
	}

	for _, suite := range suites {
		script, file := suiteScript(suite)
		if err := runAcceptance(s, lab, script, filepath.Join(evidence, file), nil); err != nil {
			return err
		}
		if enforce && (suite == "selinux" || suite == "apparmor") {
			target := strings.TrimSuffix(file, ".txt") + "-enforce.txt"
			if err := runAcceptance(s, lab, script, filepath.Join(evidence, target), []string{"ENFORCE=1"}); err != nil {
				return err
			}
		}
	}

	// The reboot check goes last: it takes the VM down and it has to run
	// after an update that may have replaced the kernel.
	if !noReboot {
		if err := runCaptured(s, Step{
			Label: "reboot-check",
			Args:  []string{cfg.Script("pocs", "server-install", "reboot-check.sh"), lab.Name},
			Env:   lab.env(),
		}, filepath.Join(evidence, "reboot-check.txt")); err != nil {
			return err
		}
	} else {
		s.Skip("reboot-check", "--no-reboot")
	}

	if publish {
		if err := publishEvidence(s, evidence); err != nil {
			return err
		}
	}
	return nil
}

// suiteScript maps a suite name to the acceptance script that runs it and the
// evidence file its output is kept in.
func suiteScript(suite string) (script, file string) {
	switch suite {
	case "base":
		return "acceptance.sh", "acceptance.txt"
	default:
		return "acceptance-" + suite + ".sh", "acceptance-" + suite + ".txt"
	}
}

func runAcceptance(s *Session, lab *Lab, script, target string, extraEnv []string) error {
	label := strings.TrimSuffix(script, ".sh")
	if len(extraEnv) > 0 {
		label += " (enforce)"
	}
	return runCaptured(s, Step{
		Label: label,
		Args:  []string{s.Config.Script("pocs", "server-install", script), lab.Name},
		Env:   append(lab.env(), extraEnv...),
	}, target)
}

// runCaptured runs a step and keeps its raw output in a file, which is what
// turns an acceptance run into the evidence a report is written from. The
// acceptance scripts never exit non-zero on a failed check by design, so a
// non-zero status here means the harness itself broke.
func runCaptured(s *Session, step Step, target string) error {
	if s.Config.DryRun {
		step.Label += " > " + filepath.Base(target)
		return s.Run(step)
	}
	file, err := os.Create(target)
	if err != nil {
		return err
	}
	defer file.Close()
	step.Capture = file
	if err := s.Run(step); err != nil {
		return err
	}
	s.Printf("[%s] evidence: %s", step.Label, target)
	return nil
}

// publishEvidence copies a run's artifacts over the committed record in
// pocs/server-install/reference/. It is opt-in: an automated run must not
// silently overwrite the artifacts an earlier report was written from.
func publishEvidence(s *Session, evidence string) error {
	target := s.Config.Script("pocs", "server-install", "reference")
	entries, err := os.ReadDir(evidence)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		data, err := os.ReadFile(filepath.Join(evidence, entry.Name()))
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(target, entry.Name()), data, 0o644); err != nil {
			return err
		}
	}
	s.Printf("evidence published into %s", target)
	return nil
}

func labSimple(action string, args []string) error {
	fs, base := newFlagSet("lab " + action)
	name, rest := splitName(args)
	if err := fs.Parse(rest); err != nil {
		return errHandled
	}
	if name == "" {
		return usageError(fs, "lab %s needs a name", action)
	}
	cfg, err := base.setup()
	if err != nil {
		return err
	}
	lab, err := loadLab(cfg, name)
	if err != nil {
		return err
	}

	vmAction := action
	if action == "down" {
		vmAction = "stop"
	}

	session, err := NewSession(cfg, "lab-"+action+"-"+name)
	if err != nil {
		return err
	}
	defer session.Close()

	if action == "status" {
		none := func(value string) string {
			if value == "" {
				return "none"
			}
			return value
		}
		session.Printf("lab %s: profile=%s addons=%s mac=%s secboot=%v unattended-updates=%v disk=%dG data-disk=%dG",
			lab.Name, lab.Profile, none(strings.Join(lab.Addons, ",")), none(lab.MAC),
			lab.SecureBoot, lab.UnattendedUpdates, lab.DiskGB, lab.DataDiskGB)
		session.Printf("iso: %s", lab.ISO)
		session.Printf("out: %s", lab.Out)
		session.Printf("suites: %s", strings.Join(lab.Suites(), ", "))
	}
	err = session.Run(Step{
		Label: "vm " + vmAction,
		Args:  []string{cfg.Script("pocs", "lab", "vm.sh"), lab.Name, vmAction},
		Env:   lab.env(),
	})
	return err
}

// labSSH hands the terminal to ssh rather than streaming it: an interactive
// session needs its own stdin, and a prefix in front of a shell prompt helps
// nobody.
func labSSH(args []string) error {
	fs, base := newFlagSet("lab ssh")
	name, rest := splitName(args)
	if err := fs.Parse(rest); err != nil {
		return errHandled
	}
	if name == "" {
		return usageError(fs, "lab ssh needs a name")
	}
	cfg, err := base.setup()
	if err != nil {
		return err
	}
	lab, err := loadLab(cfg, name)
	if err != nil {
		return err
	}
	argv := append([]string{cfg.Script("pocs", "lab", "vm.sh"), lab.Name, "ssh"}, fs.Args()...)
	if cfg.DryRun {
		fmt.Println(strings.Join(lab.env(), " ") + " " + strings.Join(argv, " "))
		return nil
	}
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Dir = cfg.Root
	cmd.Env = append(os.Environ(), lab.env()...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		return errHandled
	}
	return nil
}
