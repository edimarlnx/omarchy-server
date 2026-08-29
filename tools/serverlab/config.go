package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Config is everything serverlab needs to know about this checkout: where the
// sibling repositories are, what a lab VM looks like by default, and which
// profile is meant when none is named.
//
// Every field has a working default for this repository, so the tool runs with
// no serverlab.toml at all. The file overrides the defaults, and an environment
// variable overrides the file — the same order the bash scripts use for
// OMARCHY_PKGS_DIR and TUI_TOOLS_DIR, whose names are honoured here so a shell
// that already exports them keeps working.
type Config struct {
	// Root is the repository root, the directory holding pocs/, pkgs/, iso/.
	Root string
	// Path is the serverlab.toml this config was read from, empty when none.
	Path string

	PkgsRepo           string // the omarchy-server-pkgs checkout (repo B)
	TuiTools           string // holds the tui-tools checkouts (tui-firewall, tui-systemd)
	UpstreamOmarchy    string // upstream/omarchy clone
	UpstreamOmarchyISO string // upstream/omarchy-iso clone

	Profile string // default ISO/install profile

	DiskGB     int // system disk of a lab VM
	DataDiskGB int // optional second disk, 0 for none
	MemoryMB   int
	CPUs       int

	// MinFreeGB is what `doctor` expects to find free on the filesystem
	// holding the repository: an ISO build plus a VM disk needs room.
	MinFreeGB int

	DryRun bool
}

func defaultConfig(root string) *Config {
	return &Config{
		Root:               root,
		PkgsRepo:           filepath.Join(filepath.Dir(root), "omarchy-server-pkgs"),
		TuiTools:           filepath.Join(filepath.Dir(root), "tui-tools-org"),
		UpstreamOmarchy:    filepath.Join(root, "upstream", "omarchy"),
		UpstreamOmarchyISO: filepath.Join(root, "upstream", "omarchy-iso"),
		Profile:            "server",
		DiskGB:             40,
		DataDiskGB:         0,
		MemoryMB:           8192,
		CPUs:               4,
		MinFreeGB:          40,
	}
}

// FindRoot walks up from dir looking for the marker files that identify this
// repository. SERVERLAB_ROOT short-circuits it, which is what a CI runner that
// checks the repository out somewhere unusual would set.
func FindRoot(dir string) (string, error) {
	if env := os.Getenv("SERVERLAB_ROOT"); env != "" {
		return filepath.Abs(env)
	}
	dir, err := filepath.Abs(dir)
	if err != nil {
		return "", err
	}
	for {
		if isRepoRoot(dir) {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("not inside an omarchy-server checkout (no pocs/lab/vm.sh above %s)", dir)
		}
		dir = parent
	}
}

func isRepoRoot(dir string) bool {
	for _, marker := range []string{
		filepath.Join(dir, "pocs", "lab", "vm.sh"),
		filepath.Join(dir, "iso", "build.sh"),
	} {
		if _, err := os.Stat(marker); err != nil {
			return false
		}
	}
	return true
}

// LoadConfig reads serverlab.toml (when it exists) on top of the defaults for
// root, then applies the environment overrides. path may be empty, in which
// case <root>/serverlab.toml is used when present.
func LoadConfig(root, path string) (*Config, error) {
	cfg := defaultConfig(root)

	if path == "" {
		if env := os.Getenv("SERVERLAB_CONFIG"); env != "" {
			path = env
		} else {
			candidate := filepath.Join(root, "serverlab.toml")
			if _, err := os.Stat(candidate); err == nil {
				path = candidate
			}
		}
	}
	if path != "" {
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		sections, err := parseTOML(string(data))
		if err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		if err := cfg.applyTOML(sections); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		cfg.Path = path
	}

	cfg.applyEnv()
	cfg.resolvePaths()
	return cfg, nil
}

func (c *Config) applyTOML(sections map[string]map[string]string) error {
	get := func(section, key string) (string, bool) {
		if s, ok := sections[section]; ok {
			v, ok := s[key]
			return v, ok
		}
		return "", false
	}
	setString := func(section, key string, target *string) {
		if v, ok := get(section, key); ok {
			*target = v
		}
	}
	var err error
	setInt := func(section, key string, target *int) {
		v, ok := get(section, key)
		if !ok {
			return
		}
		n, convErr := strconv.Atoi(v)
		if convErr != nil {
			err = fmt.Errorf("%s.%s: %q is not a number", section, key, v)
			return
		}
		*target = n
	}

	setString("paths", "pkgs_repo", &c.PkgsRepo)
	setString("paths", "tui_tools", &c.TuiTools)
	setString("paths", "upstream_omarchy", &c.UpstreamOmarchy)
	setString("paths", "upstream_omarchy_iso", &c.UpstreamOmarchyISO)
	setString("defaults", "profile", &c.Profile)
	setInt("vm", "disk_gb", &c.DiskGB)
	setInt("vm", "data_disk_gb", &c.DataDiskGB)
	setInt("vm", "memory_mb", &c.MemoryMB)
	setInt("vm", "cpus", &c.CPUs)
	setInt("host", "min_free_gb", &c.MinFreeGB)
	return err
}

func (c *Config) applyEnv() {
	envString := func(target *string, names ...string) {
		for _, name := range names {
			if v := os.Getenv(name); v != "" {
				*target = v
				return
			}
		}
	}
	envInt := func(target *int, names ...string) {
		for _, name := range names {
			if v := os.Getenv(name); v != "" {
				if n, err := strconv.Atoi(v); err == nil {
					*target = n
				}
				return
			}
		}
	}
	// OMARCHY_PKGS_DIR and TUI_TOOLS_DIR are the names pkgs/build.sh and
	// iso/build.sh already read, so an exported shell keeps working.
	envString(&c.PkgsRepo, "SERVERLAB_PKGS_DIR", "OMARCHY_PKGS_DIR")
	envString(&c.TuiTools, "SERVERLAB_TUI_TOOLS_DIR", "TUI_TOOLS_DIR")
	envString(&c.Profile, "SERVERLAB_PROFILE")
	envInt(&c.DiskGB, "SERVERLAB_DISK_GB")
	envInt(&c.DataDiskGB, "SERVERLAB_DATA_DISK_GB")
	envInt(&c.MemoryMB, "SERVERLAB_MEM_MB")
	envInt(&c.CPUs, "SERVERLAB_CPUS")
	envInt(&c.MinFreeGB, "SERVERLAB_MIN_FREE_GB")
}

// resolvePaths makes every path absolute, reading relative ones against the
// repository root so a serverlab.toml can say "../omarchy-server-pkgs".
func (c *Config) resolvePaths() {
	for _, p := range []*string{&c.PkgsRepo, &c.TuiTools, &c.UpstreamOmarchy, &c.UpstreamOmarchyISO} {
		if *p == "" || filepath.IsAbs(*p) {
			continue
		}
		*p = filepath.Clean(filepath.Join(c.Root, *p))
	}
}

// LabOut is where a lab named name keeps its disk, NVRAM, cidata drive, ssh
// key, lab password, settings and evidence. One directory per lab, matching
// the pocs/lab/out-<something> convention the scripts and .gitignore use.
func (c *Config) LabOut(name string) string {
	return filepath.Join(c.Root, "pocs", "lab", "out-"+name)
}

// Script returns the absolute path of one of the repository's bash leaves.
func (c *Config) Script(parts ...string) string {
	return filepath.Join(append([]string{c.Root}, parts...)...)
}

// parseTOML reads the subset of TOML this tool's configuration needs: comment
// lines, [section] headers and `key = value` pairs whose value is a quoted
// string, an integer or a boolean. Nothing here needs arrays, tables or
// multi-line strings, and a hand-written reader keeps serverlab a single
// dependency-free binary.
func parseTOML(text string) (map[string]map[string]string, error) {
	sections := map[string]map[string]string{}
	section := ""
	sections[section] = map[string]string{}

	for number, raw := range strings.Split(text, "\n") {
		line := strings.TrimSpace(stripComment(raw))
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "[") {
			if !strings.HasSuffix(line, "]") {
				return nil, fmt.Errorf("line %d: unterminated section header %q", number+1, line)
			}
			section = strings.TrimSpace(line[1 : len(line)-1])
			if section == "" {
				return nil, fmt.Errorf("line %d: empty section name", number+1)
			}
			if _, ok := sections[section]; !ok {
				sections[section] = map[string]string{}
			}
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			return nil, fmt.Errorf("line %d: %q is neither a section nor a key = value pair", number+1, line)
		}
		key = strings.TrimSpace(key)
		if key == "" {
			return nil, fmt.Errorf("line %d: empty key", number+1)
		}
		sections[section][key] = unquote(strings.TrimSpace(value))
	}
	return sections, nil
}

// stripComment drops a trailing # comment, leaving a # that is inside a quoted
// value alone.
func stripComment(line string) string {
	inQuotes := false
	for i, r := range line {
		switch r {
		case '"':
			inQuotes = !inQuotes
		case '#':
			if !inQuotes {
				return line[:i]
			}
		}
	}
	return line
}

func unquote(value string) string {
	if len(value) >= 2 && value[0] == '"' && value[len(value)-1] == '"' {
		return value[1 : len(value)-1]
	}
	if len(value) >= 2 && value[0] == '\'' && value[len(value)-1] == '\'' {
		return value[1 : len(value)-1]
	}
	return value
}
