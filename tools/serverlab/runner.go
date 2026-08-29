package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Session is one invocation of serverlab. It owns the run log, the wall-clock
// record of every step and the dry-run switch.
//
// The log is written to pocs/lab/runs/<timestamp>-<command>.log (gitignored)
// and its path is printed at the end of the run, so a failure that scrolled
// past is still readable — and so a CI runner has one file to upload.
type Session struct {
	Config *Config
	Name   string // the subcommand, used in the log file name
	Log    *os.File
	Path   string
	Steps  []StepResult
	Start  time.Time
}

// StepResult is one script invocation and what it cost.
type StepResult struct {
	Label    string
	Duration time.Duration
	Err      error
	Skipped  bool
	Note     string
}

// Step describes a command to run: which script, with which arguments, in
// which directory and with which extra environment.
type Step struct {
	Label string   // the prefix every output line gets
	Args  []string // argv, Args[0] is the program
	Dir   string   // working directory, defaults to the repository root
	Env   []string // extra KEY=VALUE entries on top of the process environment

	// Capture, when set, receives the raw output of the command in addition
	// to the prefixed stream. This is how an acceptance run becomes an
	// evidence file without the scripts having to know about serverlab.
	Capture io.Writer
}

func NewSession(cfg *Config, name string) (*Session, error) {
	session := &Session{Config: cfg, Name: name, Start: time.Now()}
	// A dry run touches no filesystem at all, the run log included: the whole
	// point of --dry-run is that it can be aimed at anything, so it must not
	// leave a file behind either. Printf falls back to the terminal alone.
	if !cfg.DryRun {
		dir := filepath.Join(cfg.Root, "pocs", "lab", "runs")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, err
		}
		session.Path = filepath.Join(dir, fmt.Sprintf("%s-%s.log", time.Now().Format("20060102-150405"), name))
		file, err := os.Create(session.Path)
		if err != nil {
			return nil, err
		}
		session.Log = file
	}
	session.Printf("=== serverlab %s — %s ===", name, time.Now().Format(time.RFC3339))
	if cfg.Path != "" {
		session.Printf("config: %s", cfg.Path)
	}
	return session, nil
}

// Close writes the trailer and prints where the log went.
func (s *Session) Close() {
	s.Printf("=== finished in %s ===", round(time.Since(s.Start)))
	if s.Log == nil {
		return
	}
	_ = s.Log.Close()
	fmt.Printf("\nlog: %s\n", s.Path)
}

// Printf writes one line to both the terminal and the run log.
func (s *Session) Printf(format string, args ...any) {
	line := fmt.Sprintf(format, args...)
	fmt.Println(line)
	if s.Log != nil {
		fmt.Fprintln(s.Log, line)
	}
}

// logf writes to the run log only.
func (s *Session) logf(format string, args ...any) {
	if s.Log != nil {
		fmt.Fprintf(s.Log, format+"\n", args...)
	}
}

// Run executes one step, streaming its output line by line with a prefix. It
// returns the step's error; the caller decides whether to stop, and every
// caller in this tool does — a lab whose ISO did not build has nothing to say.
func (s *Session) Run(step Step) error {
	dir := step.Dir
	if dir == "" {
		dir = s.Config.Root
	}
	printable := strings.Join(step.Args, " ")
	if len(step.Env) > 0 {
		printable = strings.Join(step.Env, " ") + " " + printable
	}

	if s.Config.DryRun {
		s.Printf("[%s] (dry run) %s", step.Label, printable)
		s.Steps = append(s.Steps, StepResult{Label: step.Label, Skipped: true, Note: "dry run"})
		return nil
	}

	s.Printf("[%s] $ %s", step.Label, printable)
	started := time.Now()

	cmd := exec.Command(step.Args[0], step.Args[1:]...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), step.Env...)
	// The scripts talk to a terminal only through their own output, so one
	// merged stream keeps the interleaving they intended.
	reader, writer := io.Pipe()
	cmd.Stdout = writer
	cmd.Stderr = writer
	cmd.Stdin = nil

	if err := cmd.Start(); err != nil {
		s.Steps = append(s.Steps, StepResult{Label: step.Label, Duration: time.Since(started), Err: err})
		return fmt.Errorf("%s: %w", step.Label, err)
	}

	done := make(chan struct{})
	go func() {
		defer close(done)
		scanner := bufio.NewScanner(reader)
		// Some of the collectors print a whole journal in one line.
		scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
		for scanner.Scan() {
			line := scanner.Text()
			fmt.Printf("[%s] %s\n", step.Label, line)
			s.logf("[%s] %s", step.Label, line)
			if step.Capture != nil {
				fmt.Fprintln(step.Capture, line)
			}
		}
	}()

	runErr := cmd.Wait()
	_ = writer.Close()
	<-done
	elapsed := time.Since(started)

	result := StepResult{Label: step.Label, Duration: elapsed, Err: runErr}
	s.Steps = append(s.Steps, result)
	if runErr != nil {
		s.Printf("[%s] FAILED after %s: %v", step.Label, round(elapsed), runErr)
		return fmt.Errorf("%s: %w", step.Label, runErr)
	}
	s.Printf("[%s] ok in %s", step.Label, round(elapsed))
	return nil
}

// Skip records a step that was deliberately not run, so the summary table
// still accounts for it.
func (s *Session) Skip(label, why string) {
	s.Printf("[%s] skipped: %s", label, why)
	s.Steps = append(s.Steps, StepResult{Label: label, Skipped: true, Note: why})
}

// Summary prints the timing table every long-running command ends with.
func (s *Session) Summary() {
	if len(s.Steps) == 0 {
		return
	}
	width := len("Step")
	for _, step := range s.Steps {
		if len(step.Label) > width {
			width = len(step.Label)
		}
	}
	s.Printf("")
	s.Printf("%-*s  %-10s  %s", width, "Step", "Duration", "Result")
	s.Printf("%s  %s  %s", strings.Repeat("-", width), strings.Repeat("-", 10), strings.Repeat("-", 8))
	for _, step := range s.Steps {
		switch {
		case step.Skipped:
			s.Printf("%-*s  %-10s  skipped (%s)", width, step.Label, "-", step.Note)
		case step.Err != nil:
			s.Printf("%-*s  %-10s  FAILED", width, step.Label, round(step.Duration))
		default:
			s.Printf("%-*s  %-10s  ok", width, step.Label, round(step.Duration))
		}
	}
	s.Printf("total: %s", round(time.Since(s.Start)))
}

// Failed reports whether any step of this session failed.
func (s *Session) Failed() bool {
	for _, step := range s.Steps {
		if step.Err != nil {
			return true
		}
	}
	return false
}

func round(d time.Duration) time.Duration {
	if d < time.Second {
		return d.Round(time.Millisecond)
	}
	return d.Round(time.Second)
}
