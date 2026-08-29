package main

import (
	"os"
	"path/filepath"
	"testing"
)

// TestLabTestDryRunWritesNothing pins the contract of --dry-run on the command
// that has the most to write: `lab test` collects, runs every acceptance list,
// reboots the machine and then copies the result into the COMMITTED evidence
// record. A rehearsal that published would put files nothing measured into
// pocs/server-install/reference/, so the whole run is asserted to leave the
// repository byte-for-byte unchanged — the run log included.
func TestLabTestDryRunWritesNothing(t *testing.T) {
	root := t.TempDir()
	cfg := defaultConfig(root)
	cfg.DryRun = true

	lab := &Lab{
		Name:     "dry",
		Profile:  "server",
		MAC:      "selinux",
		DiskGB:   40,
		MemoryMB: 8192,
		CPUs:     4,
		ISO:      filepath.Join(root, "iso", "release", "nonexistent.iso"),
		Out:      cfg.LabOut("dry"),
	}

	session, err := NewSession(cfg, "lab-test-dry")
	if err != nil {
		t.Fatalf("NewSession: %v", err)
	}
	defer session.Close()

	suites, err := resolveSuites(lab, "all")
	if err != nil {
		t.Fatalf("resolveSuites: %v", err)
	}
	if err := runLabTest(session, lab, suites, false, false, true, true); err != nil {
		t.Fatalf("runLabTest: %v", err)
	}

	if entries := tree(t, root); len(entries) > 0 {
		t.Errorf("a dry run wrote %d path(s) under the repository root: %v", len(entries), entries)
	}
	if session.Path != "" {
		t.Errorf("a dry run opened a run log at %q", session.Path)
	}
}

// TestPublishEvidenceCopies is the other half: with the dry-run switch off, the
// evidence really does land in the committed record.
func TestPublishEvidenceCopies(t *testing.T) {
	root := t.TempDir()
	cfg := defaultConfig(root)
	lab := &Lab{Name: "dry", Out: cfg.LabOut("dry")}

	evidence := lab.evidenceDir()
	if err := os.MkdirAll(evidence, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(evidence, "acceptance.txt"), []byte("PASS\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	session := &Session{Config: cfg, Name: "test"}
	if err := publishEvidence(session, lab, evidence); err != nil {
		t.Fatalf("publishEvidence: %v", err)
	}
	published := filepath.Join(referenceDir(cfg, lab.Name), "acceptance.txt")
	if _, err := os.Stat(published); err != nil {
		t.Errorf("expected %s to exist: %v", published, err)
	}
}

// tree lists every path below root, relative to it.
func tree(t *testing.T, root string) []string {
	t.Helper()
	var found []string
	err := filepath.Walk(root, func(path string, _ os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if path == root {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		found = append(found, rel)
		return nil
	})
	if err != nil {
		t.Fatalf("walk %s: %v", root, err)
	}
	return found
}
