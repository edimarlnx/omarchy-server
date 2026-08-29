package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// The report generator turns a lab's evidence files into a report with the
// same structure as the hand-written ones in reports/:
//
//	title + Date/Subject/Result   from the lab settings and the acceptance trailers
//	## Scope                      what this run covers, from the lab settings
//	## Environment                ISO name/size/sha256, VM shape, firmware, autoinstall
//	## Method                     the commands that produced it
//	## Results                    one table per acceptance suite, parsed from
//	                              acceptance*.txt, plus the surface metrics and
//	                              the reboot verdict
//	## Evidence                   links to the raw files
//	## Limitations                a placeholder for what only a human can say
//
// What it cannot write is the prose a report earns its place with — why a
// number moved, which bug the run found, what the result does not prove. Those
// sections are marked as pending rather than invented.

// SuiteReport is one acceptance list inside a report.
type SuiteReport struct {
	Suite    string // base, secureboot, selinux, apparmor
	Heading  string
	File     string // path the report links to, relative to reports/
	Result   *AcceptanceResult
	Enforced bool
}

// ReportInput is everything RenderReport needs. It is a plain struct so the
// renderer is testable without a lab, a VM or a filesystem.
type ReportInput struct {
	Title   string
	Date    string
	Subject string
	Lab     *Lab
	ISO     ISOInfo
	Suites  []SuiteReport
	Surface *SurfaceMetrics
	Reboot  *RebootResult
	Methods []string // the commands, one per line, as they go into the bash block
	// EvidenceLinks are (label, path-relative-to-reports) pairs.
	EvidenceLinks [][2]string
	// Generator names the tool and is printed in the limitations section, so
	// a reader knows the prose was not written by hand.
	Generator string
}

// Totals adds the verdicts of every suite in the report.
func (in ReportInput) Totals() (passed, failed int) {
	for _, suite := range in.Suites {
		if suite.Result == nil {
			continue
		}
		passed += suite.Result.Passed
		failed += suite.Result.Failed
	}
	return
}

// RenderReport writes the markdown of a report.
func RenderReport(in ReportInput) string {
	var b strings.Builder
	passed, failed := in.Totals()

	fmt.Fprintf(&b, "# %s\n\n", in.Title)
	fmt.Fprintf(&b, "**Date:** %s\n", in.Date)
	fmt.Fprintf(&b, "**Subject:** %s\n", in.Subject)
	fmt.Fprintf(&b, "**Result:** **%d passed, %d failed** on VM `%s`\n\n", passed, failed, in.Lab.Name)

	// ── Scope ───────────────────────────────────────────────────────────
	b.WriteString("## Scope\n\n")
	b.WriteString(scopeParagraph(in))
	b.WriteString("\n")

	// ── Environment ─────────────────────────────────────────────────────
	b.WriteString("## Environment\n\n")
	b.WriteString("| | |\n|---|---|\n")
	fmt.Fprintf(&b, "| VM | `%s`, QEMU/KVM `q35`, %d vCPU, %s RAM, %d GiB virtio disk%s |\n",
		in.Lab.Name, in.Lab.CPUs, humanMemory(in.Lab.MemoryMB), in.Lab.DiskGB, dataDiskNote(in.Lab))
	fmt.Fprintf(&b, "| Firmware | %s |\n", firmwareNote(in.Lab))
	fmt.Fprintf(&b, "| ISO | `%s` |\n", in.ISO.Name)
	if in.ISO.Size > 0 {
		fmt.Fprintf(&b, "| ISO size | %s (%d bytes) |\n", humanSize(in.ISO.Size), in.ISO.Size)
	}
	if in.ISO.SHA256 != "" {
		fmt.Fprintf(&b, "| ISO sha256 | `%s` |\n", in.ISO.SHA256)
	}
	fmt.Fprintf(&b, "| Autoinstall | `%s` |\n", cidataCommand(in.Lab))
	if timestamp := runTimestamp(in); timestamp != "" {
		fmt.Fprintf(&b, "| Run | `%s` |\n", timestamp)
	}
	b.WriteString("\n")

	// ── Method ──────────────────────────────────────────────────────────
	b.WriteString("## Method\n\n")
	b.WriteString("```bash\n")
	for _, line := range in.Methods {
		b.WriteString(line + "\n")
	}
	b.WriteString("```\n\n")
	b.WriteString("`collect.sh` and `surface.sh` run **before** the acceptance lists: the\n")
	b.WriteString("acceptance workload installs the `docker` addon and then runs an update, both\n")
	b.WriteString("of which change the package set the measurements record. `reboot-check.sh`\n")
	b.WriteString("runs last, because it takes the VM down.\n\n")

	// ── Results ─────────────────────────────────────────────────────────
	b.WriteString("## Results\n\n")
	for _, suite := range in.Suites {
		if suite.Result == nil {
			continue
		}
		fmt.Fprintf(&b, "### %s\n\n", suite.Heading)
		fmt.Fprintf(&b, "**%d passed, %d failed.** Full evidence in [`%s`](%s).\n\n",
			suite.Result.Passed, suite.Result.Failed, filepath.Base(suite.File), suite.File)
		b.WriteString("| # | Item | Verdict | Evidence |\n|---|---|---|---|\n")
		for _, check := range suite.Result.Checks {
			fmt.Fprintf(&b, "| %d | %s | **%s** | %s |\n",
				check.Number, escapeCell(check.Name), check.Status, evidenceCell(check))
		}
		b.WriteString("\n")
	}

	if in.Surface != nil {
		b.WriteString("### Attack surface\n\n")
		b.WriteString("| Metric | Value |\n|---|---|\n")
		for _, row := range [][2]string{
			{"Packages installed", in.Surface.Packages},
			{"Explicitly installed", in.Surface.Explicit},
			{"Installed as a dependency", in.Surface.Dependencies},
			{"Installed size (MiB)", in.Surface.InstalledSize},
			{"`linux-firmware` (MiB)", in.Surface.LinuxFirmware},
			{"Enabled unit files", in.Surface.EnabledUnits},
			{"Masked unit files", in.Surface.MaskedUnits},
			{"Listening sockets (`ss -ltnup`)", in.Surface.Listening},
			{"setuid/setgid binaries", in.Surface.SetuidBins},
			{"Services running as root", in.Surface.RootServices},
		} {
			if row[1] == "" {
				continue
			}
			fmt.Fprintf(&b, "| %s | **%s** |\n", row[0], row[1])
		}
		b.WriteString("\n")
	}

	if in.Reboot != nil {
		b.WriteString("### Reboot survival\n\n")
		if in.Reboot.Rebooted {
			b.WriteString("The machine came back over ssh after `systemctl reboot`.\n\n")
		} else {
			b.WriteString("**The reboot check did not confirm a reboot.**\n\n")
		}
		b.WriteString("| | |\n|---|---|\n")
		for _, row := range [][2]string{
			{"Verdict", in.Reboot.Detail},
			{"ssh", in.Reboot.Answered},
			{"Boot", in.Reboot.Boot},
			{"Failed units", in.Reboot.FailedUnits},
		} {
			if row[1] == "" {
				continue
			}
			fmt.Fprintf(&b, "| %s | %s |\n", row[0], escapeCell(row[1]))
		}
		b.WriteString("\n")
	}

	// ── Evidence ────────────────────────────────────────────────────────
	b.WriteString("## Evidence\n\n")
	for _, link := range in.EvidenceLinks {
		fmt.Fprintf(&b, "- [`%s`](%s) — %s\n", filepath.Base(link[1]), link[1], link[0])
	}
	b.WriteString("\n")

	// ── Limitations ─────────────────────────────────────────────────────
	b.WriteString("## Limitations\n\n")
	fmt.Fprintf(&b, "_Written by `%s` from the evidence files listed above._ The tables are the\n", in.Generator)
	b.WriteString("run; what the run does **not** prove is not in them, and belongs here:\n\n")
	b.WriteString("- TODO: what this environment does not cover (hardware, firmware, network).\n")
	b.WriteString("- TODO: which numbers are host noise rather than a conclusion.\n")
	b.WriteString("- TODO: the bugs this run found, and what changed because of them.\n")

	return b.String()
}

func scopeParagraph(in ReportInput) string {
	var b strings.Builder
	fmt.Fprintf(&b, "One machine of the `%s` profile, installed headless from the ISO below by an\n", in.Lab.Profile)
	b.WriteString("autoinstall `cidata` drive with no keyboard and no configurator, then measured\n")
	b.WriteString("and put through the acceptance lists it was installed for")
	extras := []string{}
	if len(in.Lab.Addons) > 0 {
		extras = append(extras, "addons `"+strings.Join(in.Lab.Addons, "`, `")+"` applied during the install")
	}
	if in.Lab.MAC != "" {
		extras = append(extras, "mandatory access control: `"+in.Lab.MAC+"`")
	}
	if in.Lab.SecureBoot {
		extras = append(extras, "Secure Boot with keys the machine generated for itself")
	}
	if in.Lab.UnattendedUpdates {
		extras = append(extras, "the daily update timer enabled at install time")
	}
	if len(extras) > 0 {
		fmt.Fprintf(&b, " (%s)", strings.Join(extras, "; "))
	}
	b.WriteString(".\n")
	return b.String()
}

func firmwareNote(lab *Lab) string {
	if lab.SecureBoot {
		return "OVMF 4M **secboot** variable store, put into Setup Mode before the first boot"
	}
	return "OVMF 4M without Secure Boot"
}

func dataDiskNote(lab *Lab) string {
	if lab.DataDiskGB > 0 {
		return fmt.Sprintf(", plus a %d GiB data disk", lab.DataDiskGB)
	}
	return ""
}

func humanMemory(mb int) string {
	if mb%1024 == 0 {
		return strconv.Itoa(mb/1024) + " GiB"
	}
	return strconv.Itoa(mb) + " MiB"
}

// cidataCommand reconstructs the mkcidata.sh invocation the lab was built
// with, so the Environment table says exactly what the machine was asked for.
func cidataCommand(lab *Lab) string {
	parts := []string{"mkcidata.sh", "--profile", lab.Profile}
	if lab.Hostname != "" {
		parts = append(parts, "--hostname", lab.Hostname)
	}
	if len(lab.Addons) > 0 {
		parts = append(parts, "--addons", strings.Join(lab.Addons, ","))
	}
	if lab.MAC != "" {
		parts = append(parts, "--mac", lab.MAC)
	}
	if lab.SecureBoot {
		parts = append(parts, "--secureboot")
	}
	if lab.UnattendedUpdates {
		parts = append(parts, "--unattended-updates")
	}
	return strings.Join(parts, " ")
}

func runTimestamp(in ReportInput) string {
	for _, suite := range in.Suites {
		if suite.Result != nil && suite.Result.Timestamp != "" {
			return suite.Result.Timestamp
		}
	}
	return ""
}

// evidenceCell renders the one-line evidence a results table shows, as inline
// code when it is a value and as plain text when it is a sentence.
func evidenceCell(check Check) string {
	summary := check.Summary()
	if summary == "" {
		return "—"
	}
	const limit = 110
	if len(summary) > limit {
		summary = summary[:limit-1] + "…"
	}
	return "`" + escapeCell(summary) + "`"
}

// escapeCell keeps a pipe or a newline in evidence from breaking the table.
func escapeCell(text string) string {
	text = strings.ReplaceAll(text, "|", `\|`)
	text = strings.ReplaceAll(text, "\n", " ")
	return strings.TrimSpace(text)
}

// ── the command ─────────────────────────────────────────────────────────────

func cmdReport(args []string) error {
	fs, base := newFlagSet("report")
	title := fs.String("title", "", "report title (default: derived from the lab)")
	subject := fs.String("subject", "", "the Subject line")
	date := fs.String("date", "", "the Date line and the file name (default: today)")
	out := fs.String("out", "", "output file (default: reports/<date>-<name>.md)")
	noIndex := fs.Bool("no-index", false, "do not append the row to reports/README.md")
	name, rest := splitName(args)
	if err := fs.Parse(rest); err != nil {
		return errHandled
	}
	if name == "" {
		return usageError(fs, "report needs a lab name")
	}

	cfg, err := base.setup()
	if err != nil {
		return err
	}
	lab, err := loadLab(cfg, name)
	if err != nil {
		return err
	}
	if *date == "" {
		*date = time.Now().Format("2006-01-02")
	}
	path := *out
	if path == "" {
		path = filepath.Join(cfg.Root, "reports", fmt.Sprintf("%s-%s.md", *date, name))
	} else if !filepath.IsAbs(path) {
		path = filepath.Join(cfg.Root, path)
	}

	input, err := buildReportInput(cfg, lab, *title, *subject, *date)
	if err != nil {
		return err
	}
	markdown := RenderReport(*input)

	if cfg.DryRun {
		fmt.Printf("would write %s (%d bytes)\n", path, len(markdown))
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(path, []byte(markdown), 0o644); err != nil {
		return err
	}
	fmt.Printf("report: %s\n", path)

	if !*noIndex {
		if err := appendIndexRow(cfg, *input, path); err != nil {
			return err
		}
		fmt.Printf("index:  %s\n", filepath.Join(cfg.Root, "reports", "README.md"))
	}
	return nil
}

// buildReportInput reads the lab's evidence directory and assembles what the
// renderer needs. A missing evidence file is not fatal: the section it feeds
// is left out, which is how a run with --no-reboot still produces a report.
func buildReportInput(cfg *Config, lab *Lab, title, subject, date string) (*ReportInput, error) {
	evidence := lab.evidenceDir()
	if _, err := os.Stat(evidence); err != nil {
		return nil, fmt.Errorf("no evidence for lab %q (%s); run `serverlab lab test %s` first", lab.Name, evidence, lab.Name)
	}

	input := &ReportInput{
		Title:     title,
		Date:      date,
		Subject:   subject,
		Lab:       lab,
		Generator: "serverlab report",
	}
	if info, err := InspectISO(lab.ISO); err == nil {
		input.ISO = info
	} else {
		input.ISO = ISOInfo{Name: filepath.Base(lab.ISO)}
	}

	// Evidence lives in the lab's own (gitignored) directory; a report links
	// to it relative to reports/, which is where the file will sit.
	rel := func(name string) string {
		relative, err := filepath.Rel(filepath.Join(cfg.Root, "reports"), filepath.Join(evidence, name))
		if err != nil {
			return filepath.Join(evidence, name)
		}
		return relative
	}

	for _, suite := range lab.Suites() {
		_, file := suiteScript(suite)
		for _, candidate := range []struct {
			file     string
			enforced bool
		}{{file, false}, {strings.TrimSuffix(file, ".txt") + "-enforce.txt", true}} {
			result, err := ParseAcceptanceFile(filepath.Join(evidence, candidate.file))
			if err != nil {
				continue
			}
			input.Suites = append(input.Suites, SuiteReport{
				Suite:    suite,
				Heading:  suiteHeading(suite, candidate.enforced),
				File:     rel(candidate.file),
				Result:   result,
				Enforced: candidate.enforced,
			})
			input.EvidenceLinks = append(input.EvidenceLinks,
				[2]string{"the acceptance run, raw", rel(candidate.file)})
		}
	}
	if len(input.Suites) == 0 {
		return nil, fmt.Errorf("no acceptance evidence in %s", evidence)
	}

	if surface, err := ParseSurfaceFile(filepath.Join(evidence, "surface.txt")); err == nil {
		input.Surface = surface
		input.EvidenceLinks = append(input.EvidenceLinks,
			[2]string{"the attack-surface measurements, raw", rel("surface.txt")})
	}
	if reboot, err := ParseRebootFile(filepath.Join(evidence, "reboot-check.txt")); err == nil {
		input.Reboot = reboot
		input.EvidenceLinks = append(input.EvidenceLinks,
			[2]string{"the reboot survival check", rel("reboot-check.txt")})
	}
	for _, extra := range [][2]string{
		{"the package list of the installed machine", "packages-all.txt"},
		{"boot timing", "boot-time.txt"},
		{"the install log of the orchestrator", "omarchy-install.log"},
	} {
		if _, err := os.Stat(filepath.Join(evidence, extra[1])); err == nil {
			input.EvidenceLinks = append(input.EvidenceLinks, [2]string{extra[0], rel(extra[1])})
		}
	}

	input.Methods = reportMethods(lab)
	if input.Title == "" {
		input.Title = defaultTitle(lab)
	}
	if input.Subject == "" {
		input.Subject = defaultSubject(lab)
	}
	return input, nil
}

func suiteHeading(suite string, enforced bool) string {
	switch suite {
	case "base":
		return "Acceptance — the base install"
	case "secureboot":
		return "Acceptance — Secure Boot"
	case "selinux":
		if enforced {
			return "Acceptance — SELinux, enforcing"
		}
		return "Acceptance — SELinux, as installed"
	case "apparmor":
		if enforced {
			return "Acceptance — AppArmor, enforce"
		}
		return "Acceptance — AppArmor, as installed"
	default:
		return "Acceptance — " + suite
	}
}

func defaultTitle(lab *Lab) string {
	switch {
	case lab.SecureBoot:
		return "Headless install with Secure Boot, measured"
	case lab.MAC != "":
		return "Headless install with " + lab.MAC + ", measured"
	default:
		return "Headless install of the " + lab.Profile + " profile, measured"
	}
}

func defaultSubject(lab *Lab) string {
	return fmt.Sprintf("one `%s` machine installed from a `cidata` drive and put through the acceptance lists it was installed for", lab.Profile)
}

// reportMethods is the command block a reader reproduces the run with: the
// serverlab commands first, because that is the one-command path, and the
// scripts they call underneath, because those are what actually ran.
func reportMethods(lab *Lab) []string {
	up := "serverlab lab up " + lab.Name + " --profile " + lab.Profile
	if len(lab.Addons) > 0 {
		up += " --addons " + strings.Join(lab.Addons, ",")
	}
	if lab.MAC != "" {
		up += " --mac " + lab.MAC
	}
	if lab.SecureBoot {
		up += " --secboot"
	}
	if lab.UnattendedUpdates {
		up += " --unattended-updates"
	}
	up += " --iso " + filepath.Base(lab.ISO)

	suites := "all"
	if len(lab.Suites()) == 1 {
		suites = lab.Suites()[0]
	}
	return []string{
		"serverlab pkgs build && serverlab pkgs test",
		"serverlab iso build --profile " + lab.Profile,
		up,
		"serverlab lab test " + lab.Name + " --suite " + suites,
		"serverlab report " + lab.Name,
		"",
		"# what those run underneath:",
		"#   pocs/lab/mkcidata.sh " + strings.TrimPrefix(cidataCommand(lab), "mkcidata.sh "),
		"#   pocs/lab/vm.sh " + lab.Name + " create|start|wait-ssh",
		"#   pocs/server-install/collect.sh|surface.sh|acceptance*.sh|reboot-check.sh " + lab.Name,
	}
}

// appendIndexRow adds this report to the table in reports/README.md, newest
// first — the row goes directly under the header separator.
func appendIndexRow(cfg *Config, in ReportInput, reportPath string) error {
	indexPath := filepath.Join(cfg.Root, "reports", "README.md")
	data, err := os.ReadFile(indexPath)
	if err != nil {
		return err
	}
	passed, failed := in.Totals()
	row := fmt.Sprintf("| %s | [%s](%s) | %s | %d passed, %d failed |",
		in.Date, in.Title, filepath.Base(reportPath), in.Subject, passed, failed)

	lines := strings.Split(string(data), "\n")
	for index, line := range lines {
		if !strings.HasPrefix(strings.TrimSpace(line), "|---") {
			continue
		}
		if strings.Contains(lines[index], "|---|---|---|---|") {
			updated := append([]string{}, lines[:index+1]...)
			updated = append(updated, row)
			updated = append(updated, lines[index+1:]...)
			return os.WriteFile(indexPath, []byte(strings.Join(updated, "\n")), 0o644)
		}
	}
	return fmt.Errorf("%s: no reports table to append to", indexPath)
}
