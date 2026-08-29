package main

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestParseAcceptanceFile(t *testing.T) {
	result, err := ParseAcceptanceFile(filepath.Join("testdata", "acceptance.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if result.VM != "srv" {
		t.Errorf("VM = %q, want srv", result.VM)
	}
	if result.Timestamp != "2026-08-29T04:32:43-03:00" {
		t.Errorf("Timestamp = %q", result.Timestamp)
	}
	if result.Title != "Server install acceptance" {
		t.Errorf("Title = %q", result.Title)
	}
	if result.Passed != 6 || result.Failed != 0 {
		t.Errorf("verdicts = %d passed, %d failed", result.Passed, result.Failed)
	}
	if !result.Counted {
		t.Error("the trailer should have been read")
	}
	if len(result.Checks) != 6 {
		t.Fatalf("parsed %d checks, want 6", len(result.Checks))
	}

	first := result.Checks[0]
	if first.Number != 1 || first.Name != "default target is multi-user.target" || first.Status != "PASS" {
		t.Errorf("first check = %+v", first)
	}
	if first.Command != "systemctl get-default" {
		t.Errorf("first command = %q", first.Command)
	}
	if got := first.Summary(); got != "multi-user.target" {
		t.Errorf("first summary = %q", got)
	}

	// The pacman warnings a machine with empty sync databases prints stay in
	// the evidence but must never become the line a results table quotes.
	second := result.Checks[1]
	if got := second.Summary(); got != "graphical=0" {
		t.Errorf("second summary = %q, want graphical=0", got)
	}
	if len(second.Evidence) < 6 {
		t.Errorf("the warnings should still be in the evidence: %v", second.Evidence)
	}
}

func TestParseAcceptanceMultiLineCommand(t *testing.T) {
	// A command written across several source lines keeps its own, smaller
	// indentation; only six-space lines are output.
	text := strings.Join([]string{
		"=== Server install acceptance — VM 'srv' — 2026-08-29T04:32:43-03:00 ===",
		"",
		"[PASS] the update timer ships disabled and toggles",
		`      $ shipped=$(systemctl is-enabled omarchy-server-update.timer 2>&1);`,
		`   ~/.lab-sudo omarchy-server-update enable >/dev/null 2>&1;`,
		`   echo "shipped=$shipped"`,
		"      shipped=disabled enabled=enabled disabled=disabled",
		"",
		"=== 1 passed, 0 failed ===",
	}, "\n")

	result := ParseAcceptance(text)
	if len(result.Checks) != 1 {
		t.Fatalf("parsed %d checks", len(result.Checks))
	}
	check := result.Checks[0]
	if !strings.HasPrefix(check.Command, "shipped=$(systemctl") || !strings.Contains(check.Command, `echo "shipped=$shipped"`) {
		t.Errorf("command = %q", check.Command)
	}
	if len(check.Evidence) != 1 || check.Evidence[0] != "shipped=disabled enabled=enabled disabled=disabled" {
		t.Errorf("evidence = %v", check.Evidence)
	}
}

func TestParseAcceptanceWithoutTrailer(t *testing.T) {
	// An interrupted run has no trailer. The verdicts must come from the
	// checks that are there rather than reading as "0 passed, 0 failed".
	text := strings.Join([]string{
		"=== Server install acceptance — VM 'srv' — 2026-08-29T04:32:43-03:00 ===",
		"",
		"[PASS] one",
		"      $ true",
		"      ok",
		"",
		"[FAIL] two",
		"      $ false",
		"      not ok",
		"",
	}, "\n")

	result := ParseAcceptance(text)
	if result.Counted {
		t.Error("there is no trailer to count")
	}
	if result.Passed != 1 || result.Failed != 1 {
		t.Errorf("verdicts = %d/%d", result.Passed, result.Failed)
	}
}

func TestParseSurfaceFile(t *testing.T) {
	metrics, err := ParseSurfaceFile(filepath.Join("testdata", "surface.txt"))
	if err != nil {
		t.Fatal(err)
	}
	for _, check := range []struct{ name, got, want string }{
		{"packages", metrics.Packages, "320"},
		{"explicit", metrics.Explicit, "57"},
		{"dependencies", metrics.Dependencies, "263"},
		{"installed size", metrics.InstalledSize, "2344"},
		{"linux-firmware", metrics.LinuxFirmware, "408"},
		{"enabled units", metrics.EnabledUnits, "17"},
		{"masked units", metrics.MaskedUnits, "5"},
		{"setuid binaries", metrics.SetuidBins, "19"},
		{"root services", metrics.RootServices, "12"},
		{"listening", metrics.Listening, "8"},
	} {
		if check.got != check.want {
			t.Errorf("%s = %q, want %q", check.name, check.got, check.want)
		}
	}
}

func TestParseRebootFile(t *testing.T) {
	result, err := ParseRebootFile(filepath.Join("testdata", "reboot-check.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if !result.Rebooted {
		t.Error("the machine did reboot in this fixture")
	}
	if !strings.Contains(result.Detail, "boot time moved from") {
		t.Errorf("detail = %q", result.Detail)
	}
	if result.Answered != "ssh answered 1s after the reboot request" {
		t.Errorf("answered = %q", result.Answered)
	}
	if result.FailedUnits != "0 loaded units listed." {
		t.Errorf("failed units = %q", result.FailedUnits)
	}
	if !strings.HasPrefix(result.Boot, "Startup finished in") {
		t.Errorf("boot = %q", result.Boot)
	}
}
