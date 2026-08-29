package main

import (
	"bufio"
	"crypto/sha256"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// cmdISO builds an Omarchy ISO for a profile, through iso/build.sh.
func cmdISO(args []string) error {
	if len(args) == 0 || args[0] != "build" {
		return fmt.Errorf("usage: serverlab iso build [--profile server|desktop] [--fresh] [--debug]")
	}
	fs, base := newFlagSet("iso build")
	profile := fs.String("profile", "", "ISO profile (default: the configured one)")
	fresh := fs.Bool("fresh", false, "discard the scratch tree before building")
	debug := fs.Bool("debug", false, "build with OMARCHY_INSTALL_DEBUG=1 in the ISO")
	if err := fs.Parse(args[1:]); err != nil {
		return errHandled
	}
	cfg, err := base.setup()
	if err != nil {
		return err
	}
	if *profile == "" {
		*profile = cfg.Profile
	}

	session, err := NewSession(cfg, "iso-build")
	if err != nil {
		return err
	}
	defer session.Close()

	err = isoBuild(session, *profile, *fresh, *debug)
	session.Summary()
	if err != nil {
		return err
	}
	if iso, findErr := newestISO(cfg, *profile); findErr == nil {
		session.Printf("ISO: %s", iso)
	}
	return nil
}

func isoBuild(s *Session, profile string, fresh, debug bool) error {
	cfg := s.Config
	args := []string{cfg.Script("iso", "build.sh"), "--profile", profile}
	if fresh {
		args = append(args, "--fresh")
	}
	if debug {
		args = append(args, "--debug")
	}
	return s.Run(Step{
		Label: "iso build",
		Args:  args,
		Env:   []string{"OMARCHY_PKGS_DIR=" + cfg.PkgsRepo, "TUI_TOOLS_DIR=" + cfg.TuiTools},
	})
}

// newestISO picks the most recently written ISO in iso/release/. A profile
// hint narrows the choice to the files whose name carries it, which is how
// `-server-local` ISOs are told apart from a desktop parity build.
func newestISO(cfg *Config, profile string) (string, error) {
	matches, err := filepath.Glob(filepath.Join(cfg.Root, "iso", "release", "*.iso"))
	if err != nil || len(matches) == 0 {
		return "", fmt.Errorf("no ISO in iso/release; run `serverlab iso build`")
	}
	preferred := matches[:0:0]
	for _, match := range matches {
		if profile == "" || strings.Contains(filepath.Base(match), "-"+profile+"-") {
			preferred = append(preferred, match)
		}
	}
	if len(preferred) == 0 {
		preferred = matches
	}
	sort.Slice(preferred, func(i, j int) bool {
		return modTime(preferred[i]).After(modTime(preferred[j]))
	})
	return preferred[0], nil
}

func modTime(path string) (t fileTime) {
	info, err := os.Stat(path)
	if err != nil {
		return
	}
	return fileTime(info.ModTime().UnixNano())
}

type fileTime int64

func (t fileTime) After(other fileTime) bool { return t > other }

// ISOInfo is what a report says about the image a machine was installed from.
type ISOInfo struct {
	Path   string
	Name   string
	Size   int64
	SHA256 string
}

// InspectISO reads the size and the checksum of an ISO. The checksum comes
// from the .sha256 file iso/build.sh writes beside the image when it is there,
// and is computed otherwise — a 3 GiB hash is a few seconds, and a report
// without it is not evidence.
func InspectISO(path string) (ISOInfo, error) {
	info := ISOInfo{Path: path, Name: filepath.Base(path)}
	stat, err := os.Stat(path)
	if err != nil {
		return info, err
	}
	info.Size = stat.Size()

	if sum, err := readSHA256File(path + ".sha256"); err == nil && sum != "" {
		info.SHA256 = sum
		return info, nil
	}
	file, err := os.Open(path)
	if err != nil {
		return info, err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, bufio.NewReaderSize(file, 4*1024*1024)); err != nil {
		return info, err
	}
	info.SHA256 = fmt.Sprintf("%x", hash.Sum(nil))
	return info, nil
}

func readSHA256File(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	fields := strings.Fields(string(data))
	if len(fields) == 0 {
		return "", fmt.Errorf("%s is empty", path)
	}
	return fields[0], nil
}

// humanSize renders a byte count the way the reports quote one.
func humanSize(bytes int64) string {
	const unit = 1024.0
	value := float64(bytes)
	switch {
	case value >= unit*unit*unit:
		return fmt.Sprintf("%.1f GiB", value/(unit*unit*unit))
	case value >= unit*unit:
		return fmt.Sprintf("%.0f MiB", value/(unit*unit))
	default:
		return fmt.Sprintf("%d B", bytes)
	}
}
