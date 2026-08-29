package main

import (
	"os"
	"regexp"
	"strconv"
	"strings"
)

// The acceptance scripts share one output shape, and this is the reader for
// it. A block is:
//
//	[PASS] the name of the check
//	      $ the remote command
//	      the output it was judged on
//	      ...
//
// with a blank line between blocks, a header line naming the VM and the time,
// and a trailer counting the verdicts. Evidence lines are indented by exactly
// six spaces (the scripts' `printf '      %s\n'`); a command that spans several
// source lines keeps its own indentation, which is how a continuation is told
// apart from output.

var (
	acceptanceHeaderRe = regexp.MustCompile(`^===\s*(.*?)\s*===$`)
	acceptanceVMRe     = regexp.MustCompile(`VM '([^']+)'`)
	acceptanceTimeRe   = regexp.MustCompile(`\d{4}-\d{2}-\d{2}T[\d:]+[+\-Z][\d:]*`)
	acceptanceTotalRe  = regexp.MustCompile(`^===\s*(\d+) passed,\s*(\d+) failed\s*===$`)
	acceptanceCheckRe  = regexp.MustCompile(`^\[(PASS|FAIL)\]\s+(.*)$`)
	// pacman prints these into the middle of otherwise clean evidence on a
	// machine whose sync databases were never downloaded. They are noise in a
	// results table and are dropped from the one-line summary, never from the
	// evidence file itself.
	acceptanceNoiseRe = regexp.MustCompile(`^(warning: database file for|Warning: Permanently added)`)
)

// Check is one acceptance item.
type Check struct {
	Number   int
	Name     string
	Status   string // PASS or FAIL
	Command  string
	Evidence []string
}

// Summary is the single evidence line a results table quotes: the last line
// the check actually produced, which is the one the script's pattern matched.
func (c Check) Summary() string {
	for i := len(c.Evidence) - 1; i >= 0; i-- {
		line := strings.TrimSpace(c.Evidence[i])
		if line == "" || acceptanceNoiseRe.MatchString(line) {
			continue
		}
		return line
	}
	return ""
}

// AcceptanceResult is a parsed acceptance run.
type AcceptanceResult struct {
	Title     string // the header without the VM and the timestamp
	VM        string
	Timestamp string
	Checks    []Check
	Passed    int
	Failed    int
	// Counted is the trailer's own count. It is kept separate from
	// len(Checks) so a truncated file is visible rather than silently
	// reported as a smaller, passing run.
	Counted bool
}

// ParseAcceptanceFile reads an acceptance evidence file.
func ParseAcceptanceFile(path string) (*AcceptanceResult, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return ParseAcceptance(string(data)), nil
}

// ParseAcceptance reads the output of any of the acceptance scripts.
func ParseAcceptance(text string) *AcceptanceResult {
	result := &AcceptanceResult{}
	var current *Check
	inCommand := false

	flush := func() {
		if current != nil {
			result.Checks = append(result.Checks, *current)
			current = nil
		}
	}

	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimRight(line, "\r")

		if match := acceptanceTotalRe.FindStringSubmatch(line); match != nil {
			flush()
			result.Passed, _ = strconv.Atoi(match[1])
			result.Failed, _ = strconv.Atoi(match[2])
			result.Counted = true
			continue
		}
		if match := acceptanceHeaderRe.FindStringSubmatch(line); match != nil && result.Title == "" {
			flush()
			header := match[1]
			if vm := acceptanceVMRe.FindStringSubmatch(header); vm != nil {
				result.VM = vm[1]
			}
			if ts := acceptanceTimeRe.FindString(header); ts != "" {
				result.Timestamp = ts
			}
			// Everything before the first em-dash separator is the title.
			result.Title = strings.TrimSpace(strings.SplitN(header, "—", 2)[0])
			continue
		}
		if match := acceptanceCheckRe.FindStringSubmatch(line); match != nil {
			flush()
			current = &Check{Number: len(result.Checks) + 1, Status: match[1], Name: strings.TrimSpace(match[2])}
			inCommand = false
			continue
		}
		if current == nil {
			continue
		}
		if strings.TrimSpace(line) == "" {
			inCommand = false
			continue
		}
		body, isEvidence := strings.CutPrefix(line, "      ")
		switch {
		case isEvidence && strings.HasPrefix(body, "$ ") && current.Command == "":
			current.Command = strings.TrimPrefix(body, "$ ")
			inCommand = true
		case isEvidence:
			// A six-space line after the command is output.
			inCommand = false
			current.Evidence = append(current.Evidence, body)
		case inCommand:
			// Less indentation while the command is still being read: the
			// command was written across several source lines.
			current.Command += "\n" + strings.TrimSpace(line)
		default:
			current.Evidence = append(current.Evidence, strings.TrimSpace(line))
		}
	}
	flush()

	if !result.Counted {
		// No trailer (an interrupted run): count what is there, so the
		// report says something true instead of "0 passed, 0 failed".
		for _, check := range result.Checks {
			if check.Status == "PASS" {
				result.Passed++
			} else {
				result.Failed++
			}
		}
	}
	return result
}

// SurfaceMetrics is what surface.sh measured, reduced to the rows the reports
// tabulate.
type SurfaceMetrics struct {
	Packages      string
	Explicit      string
	Dependencies  string
	InstalledSize string
	LinuxFirmware string
	EnabledUnits  string
	MaskedUnits   string
	Listening     string
	SetuidBins    string
	RootServices  string
}

// ParseSurfaceFile reads surface.txt. The file is sectioned, and three of the
// numbers wanted here are a bare `count:` whose meaning is the section it is
// in, so the reader tracks the section as it goes.
func ParseSurfaceFile(path string) (*SurfaceMetrics, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return ParseSurface(string(data)), nil
}

func ParseSurface(text string) *SurfaceMetrics {
	metrics := &SurfaceMetrics{}
	section := ""
	for _, raw := range strings.Split(text, "\n") {
		line := strings.TrimSpace(raw)
		if strings.HasPrefix(line, "===") {
			section = strings.TrimSpace(strings.Trim(line, "= "))
			continue
		}
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		value = strings.TrimSpace(value)
		switch key {
		case "installed":
			metrics.Packages = value
		case "explicit":
			metrics.Explicit = value
		case "dependency":
			metrics.Dependencies = value
		case "installed size (MiB)":
			metrics.InstalledSize = value
		case "linux-firmware (MiB)":
			metrics.LinuxFirmware = value
		case "listening tcp+udp":
			metrics.Listening = value
		case "count":
			switch section {
			case "enabled units":
				metrics.EnabledUnits = value
			case "masked units":
				metrics.MaskedUnits = value
			case "setuid / setgid binaries":
				metrics.SetuidBins = value
			case "services running as root":
				metrics.RootServices = value
			}
		}
	}
	return metrics
}

// RebootResult is the verdict of reboot-check.sh.
type RebootResult struct {
	Rebooted    bool
	Detail      string // the "boot time moved from … to …" line
	Answered    string // the "ssh answered Ns after the reboot request" line
	FailedUnits string // systemd's own "N loaded units listed." line
	Boot        string // the "Startup finished in …" line of the boot that came back
}

// systemd ends `systemctl --failed` with this line, and it is the honest
// answer to "did anything break", where the table header above it is not.
var failedUnitsRe = regexp.MustCompile(`^\d+ loaded units listed`)

func ParseRebootFile(path string) (*RebootResult, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return ParseReboot(string(data)), nil
}

func ParseReboot(text string) *RebootResult {
	result := &RebootResult{}
	for _, raw := range strings.Split(text, "\n") {
		line := strings.TrimSpace(raw)
		switch {
		case strings.HasPrefix(line, "rebooted:"):
			result.Rebooted = true
			result.Detail = line
		case strings.HasPrefix(line, "FAIL:"):
			result.Detail = line
		case strings.HasPrefix(line, "ssh answered"):
			result.Answered = line
		case strings.HasPrefix(line, "Startup finished"):
			result.Boot = line
		case failedUnitsRe.MatchString(line):
			result.FailedUnits = line
		}
	}
	return result
}
