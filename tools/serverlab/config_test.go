package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseTOML(t *testing.T) {
	sections, err := parseTOML(`
# a comment line
[paths]
pkgs_repo = "../omarchy-server-pkgs"   # trailing comment
tui_tools = '../tui-tools'

[vm]
disk_gb = 40
cpus = 4
`)
	if err != nil {
		t.Fatalf("parseTOML: %v", err)
	}
	if got := sections["paths"]["pkgs_repo"]; got != "../omarchy-server-pkgs" {
		t.Errorf("pkgs_repo = %q", got)
	}
	if got := sections["paths"]["tui_tools"]; got != "../tui-tools" {
		t.Errorf("tui_tools = %q", got)
	}
	if got := sections["vm"]["disk_gb"]; got != "40" {
		t.Errorf("disk_gb = %q", got)
	}
}

func TestParseTOMLRejectsGarbage(t *testing.T) {
	if _, err := parseTOML("[paths\n"); err == nil {
		t.Error("an unterminated section header should be an error")
	}
	if _, err := parseTOML("just a word\n"); err == nil {
		t.Error("a line that is neither a section nor a pair should be an error")
	}
}

func TestLoadConfigDefaultsAndOverrides(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "serverlab.toml")
	contents := `
[paths]
pkgs_repo = "../pkgs-elsewhere"

[defaults]
profile = "desktop"

[vm]
disk_gb = 60
memory_mb = 4096
`
	if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
		t.Fatal(err)
	}

	cfg, err := LoadConfig(root, path)
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if cfg.Profile != "desktop" {
		t.Errorf("profile = %q, want desktop", cfg.Profile)
	}
	if cfg.DiskGB != 60 || cfg.MemoryMB != 4096 {
		t.Errorf("disk/memory = %d/%d", cfg.DiskGB, cfg.MemoryMB)
	}
	// Untouched by the file: the default has to survive.
	if cfg.CPUs != 4 {
		t.Errorf("cpus = %d, want the default 4", cfg.CPUs)
	}
	// Relative paths resolve against the repository root.
	want := filepath.Clean(filepath.Join(root, "../pkgs-elsewhere"))
	if cfg.PkgsRepo != want {
		t.Errorf("pkgs_repo = %q, want %q", cfg.PkgsRepo, want)
	}

	// The environment wins over the file.
	t.Setenv("SERVERLAB_PROFILE", "server")
	t.Setenv("SERVERLAB_DISK_GB", "20")
	cfg, err = LoadConfig(root, path)
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if cfg.Profile != "server" || cfg.DiskGB != 20 {
		t.Errorf("environment override ignored: profile=%q disk=%d", cfg.Profile, cfg.DiskGB)
	}
}

func TestLoadConfigWithoutFile(t *testing.T) {
	root := t.TempDir()
	cfg, err := LoadConfig(root, "")
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if cfg.Profile != "server" || cfg.DiskGB != 40 || cfg.Path != "" {
		t.Errorf("zero-config defaults wrong: %+v", cfg)
	}
	if cfg.LabOut("srv") != filepath.Join(root, "pocs", "lab", "out-srv") {
		t.Errorf("LabOut = %q", cfg.LabOut("srv"))
	}
}
