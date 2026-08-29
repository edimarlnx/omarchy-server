package main

import (
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var update = flag.Bool("update", false, "rewrite the golden files")

// TestRenderReportGolden pins the whole shape of a generated report against a
// golden file, built from the same evidence files a real run produces. A change
// to any section shows up here as a diff, which is the point: the reports are
// the published record and their structure is not allowed to drift silently.
func TestRenderReportGolden(t *testing.T) {
	acceptance, err := ParseAcceptanceFile(filepath.Join("testdata", "acceptance.txt"))
	if err != nil {
		t.Fatal(err)
	}
	surface, err := ParseSurfaceFile(filepath.Join("testdata", "surface.txt"))
	if err != nil {
		t.Fatal(err)
	}
	reboot, err := ParseRebootFile(filepath.Join("testdata", "reboot-check.txt"))
	if err != nil {
		t.Fatal(err)
	}

	lab := &Lab{
		Name:     "srv",
		Profile:  "server",
		DiskGB:   40,
		MemoryMB: 8192,
		CPUs:     4,
		ISO:      "/repo/iso/release/omarchy-2026.08.29-x86_64-server-local.iso",
		Out:      "/repo/pocs/lab/out-srv",
		Created:  time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC),
	}

	input := ReportInput{
		Date:      "2026-08-29",
		Lab:       lab,
		Generator: "serverlab report",
		ISO: ISOInfo{
			Name:   "omarchy-2026.08.29-x86_64-server-local.iso",
			Size:   3149234176,
			SHA256: "0000000000000000000000000000000000000000000000000000000000000000",
		},
		Suites: []SuiteReport{{
			Suite:   "base",
			Heading: suiteHeading("base", false),
			File:    "../pocs/lab/out-srv/evidence/acceptance.txt",
			Result:  acceptance,
		}},
		Surface: surface,
		Reboot:  reboot,
		Methods: reportMethods(lab),
		EvidenceLinks: [][2]string{
			{"the acceptance run, raw", "../pocs/lab/out-srv/evidence/acceptance.txt"},
			{"the attack-surface measurements, raw", "../pocs/lab/out-srv/evidence/surface.txt"},
			{"the reboot survival check", "../pocs/lab/out-srv/evidence/reboot-check.txt"},
		},
	}
	input.Title = defaultTitle(lab)
	input.Subject = defaultSubject(lab)

	got := RenderReport(input)
	golden := filepath.Join("testdata", "report.golden.md")
	if *update {
		if err := os.WriteFile(golden, []byte(got), 0o644); err != nil {
			t.Fatal(err)
		}
		t.Logf("wrote %s", golden)
		return
	}
	want, err := os.ReadFile(golden)
	if err != nil {
		t.Fatalf("%v (run `go test ./... -update` to create it)", err)
	}
	if got != string(want) {
		t.Errorf("report differs from %s\n--- got ---\n%s", golden, got)
	}
}

// TestRenderReportSections checks the properties the golden file cannot: that
// every section the hand-written reports have is present, and in that order.
func TestRenderReportSections(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("testdata", "report.golden.md"))
	if err != nil {
		t.Skip("no golden file yet")
	}
	report := string(data)
	sections := []string{
		"# ", "**Date:**", "**Subject:**", "**Result:**",
		"## Scope", "## Environment", "## Method", "## Results",
		"### Acceptance", "### Attack surface", "### Reboot survival",
		"## Evidence", "## Limitations",
	}
	position := 0
	for _, section := range sections {
		index := strings.Index(report[position:], section)
		if index < 0 {
			t.Fatalf("section %q missing or out of order", section)
		}
		position += index
	}
}

// TestReportLinksPreferPublishedEvidence is the contract of `lab test`
// publishing by default: a report links to the committed copy under
// pocs/server-install/reference/ when that copy is the file the report was
// written from, and falls back to the lab's private directory when it is not —
// so a link never points at somebody else's run.
func TestReportLinksPreferPublishedEvidence(t *testing.T) {
	root := t.TempDir()
	cfg := defaultConfig(root)
	lab := &Lab{Name: "srv", Profile: "server", ISO: "/repo/x.iso", Out: filepath.Join(root, "pocs", "lab", "out-srv")}

	evidence := lab.evidenceDir()
	reference := filepath.Join(root, "pocs", "server-install", "reference", "srv")
	for _, dir := range []string{evidence, reference} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	acceptance, err := os.ReadFile(filepath.Join("testdata", "acceptance.txt"))
	if err != nil {
		t.Fatal(err)
	}
	write := func(dir, name string, data []byte) {
		if err := os.WriteFile(filepath.Join(dir, name), data, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write(evidence, "acceptance.txt", acceptance)
	write(reference, "acceptance.txt", acceptance)

	surface, err := os.ReadFile(filepath.Join("testdata", "surface.txt"))
	if err != nil {
		t.Fatal(err)
	}
	write(evidence, "surface.txt", surface)
	// A reference copy left over from a different lab must not be linked.
	write(reference, "surface.txt", append(surface, []byte("\nfrom another run\n")...))

	input, err := buildReportInput(cfg, lab, "", "", "2026-08-29")
	if err != nil {
		t.Fatal(err)
	}
	links := map[string]string{}
	for _, link := range input.EvidenceLinks {
		links[filepath.Base(link[1])] = link[1]
	}
	if want := "../pocs/server-install/reference/srv/acceptance.txt"; links["acceptance.txt"] != want {
		t.Errorf("acceptance link = %q, want %q", links["acceptance.txt"], want)
	}
	if want := "../pocs/lab/out-srv/evidence/surface.txt"; links["surface.txt"] != want {
		t.Errorf("surface link = %q, want %q (a stale published copy is not the record)", links["surface.txt"], want)
	}
}

func TestAppendIndexRow(t *testing.T) {
	root := t.TempDir()
	reports := filepath.Join(root, "reports")
	if err := os.MkdirAll(reports, 0o755); err != nil {
		t.Fatal(err)
	}
	index := strings.Join([]string{
		"## Reports, newest first",
		"",
		"| Date | Report | Subject | Result |",
		"|---|---|---|---|",
		"| 2026-08-28 | [Older](2026-08-28-older.md) | something | ok |",
		"",
	}, "\n")
	if err := os.WriteFile(filepath.Join(reports, "README.md"), []byte(index), 0o644); err != nil {
		t.Fatal(err)
	}

	cfg := defaultConfig(root)
	input := ReportInput{
		Title:   "A new run",
		Date:    "2026-08-29",
		Subject: "the subject",
		Lab:     &Lab{Name: "srv"},
		Suites:  []SuiteReport{{Result: &AcceptanceResult{Passed: 37, Failed: 0}}},
	}
	if err := appendIndexRow(cfg, input, filepath.Join(reports, "2026-08-29-srv.md")); err != nil {
		t.Fatal(err)
	}

	data, err := os.ReadFile(filepath.Join(reports, "README.md"))
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(string(data), "\n")
	// Newest first: the new row goes directly under the separator.
	if lines[4] != "| 2026-08-29 | [A new run](2026-08-29-srv.md) | the subject | 37 passed, 0 failed |" {
		t.Errorf("row = %q", lines[4])
	}
	if !strings.Contains(string(data), "2026-08-28-older.md") {
		t.Error("the existing rows must survive")
	}
}
