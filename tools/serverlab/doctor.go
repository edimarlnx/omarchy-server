package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

// cmdDoctor answers one question: can this host run the lab, and if not, what
// is missing. Every check names the thing it wants and, when it is absent, the
// command that provides it — a fresh checkout on a fresh machine should be able
// to get to green from this output alone.
func cmdDoctor(args []string) error {
	fs, base := newFlagSet("doctor")
	if err := fs.Parse(args); err != nil {
		return errHandled
	}
	cfg, err := base.setup()
	if err != nil {
		return err
	}

	fmt.Printf("repository: %s\n", cfg.Root)
	if cfg.Path != "" {
		fmt.Printf("config:     %s\n", cfg.Path)
	} else {
		fmt.Printf("config:     (defaults; no serverlab.toml)\n")
	}
	fmt.Println()

	missing := 0
	report := func(ok bool, name, detail, remedy string) {
		if ok {
			fmt.Printf("  ok    %-22s %s\n", name, detail)
			return
		}
		missing++
		fmt.Printf("  MISS  %-22s %s\n", name, detail)
		if remedy != "" {
			fmt.Printf("        → %s\n", remedy)
		}
	}

	fmt.Println("tools")
	for _, tool := range []struct{ name, why, remedy string }{
		{"docker", "package and ISO builds run in a container", "install docker and add yourself to the docker group"},
		{"qemu-system-x86_64", "the lab VM", "install qemu-full / qemu-system-x86"},
		{"qemu-img", "the lab VM's disk", "install qemu-img"},
		{"xorriso", "the cidata autoinstall drive", "install xorriso (libisoburn)"},
		{"jq", "mkcidata.sh validates the archinstall JSON", "install jq"},
		{"openssl", "the lab password hash", "install openssl"},
		{"socat", "the QEMU monitor socket (screenshots)", "install socat"},
		{"ssh", "every pocs/ helper talks to the VM over ssh", "install openssh"},
		{"rsync", "iso/build.sh lays the overlay over the scratch tree", "install rsync"},
		{"git", "upstream clones and the scratch reset", "install git"},
		{"go", "building serverlab itself", "install go"},
		{"virt-fw-vars", "--secboot puts OVMF into setup mode", "install python-virt-firmware (Arch) / virt-firmware (Fedora)"},
		{"gh", "publishing the packages repository", "install github-cli and run `gh auth login`"},
	} {
		path, err := exec.LookPath(tool.name)
		detail := tool.why
		if err == nil {
			detail = path
		}
		report(err == nil, tool.name, detail, tool.remedy)
	}

	fmt.Println("\nfirmware")
	ovmf := "/usr/share/edk2/ovmf"
	for _, file := range []string{
		"OVMF_CODE_4M.qcow2", "OVMF_VARS_4M.qcow2",
		"OVMF_CODE_4M.secboot.qcow2", "OVMF_VARS_4M.secboot.qcow2",
	} {
		path := filepath.Join(ovmf, file)
		_, err := os.Stat(path)
		remedy := "install edk2-ovmf; the lab reads " + ovmf
		report(err == nil, file, path, remedy)
	}

	fmt.Println("\ncheckouts")
	for _, checkout := range []struct{ name, path, marker, remedy string }{
		{"omarchy-server-pkgs", cfg.PkgsRepo, "pkgbuilds",
			"git clone https://github.com/edimarlnx/omarchy-server-pkgs.git " + cfg.PkgsRepo},
		{"upstream/omarchy", cfg.UpstreamOmarchy, ".git",
			"git clone https://github.com/basecamp/omarchy.git " + cfg.UpstreamOmarchy},
		{"upstream/omarchy-iso", cfg.UpstreamOmarchyISO, ".git",
			"git clone https://github.com/omacom-io/omarchy-iso.git " + cfg.UpstreamOmarchyISO},
	} {
		_, err := os.Stat(filepath.Join(checkout.path, checkout.marker))
		report(err == nil, checkout.name, checkout.path, checkout.remedy)
	}

	fmt.Println("\nservices and credentials")
	dockerErr := exec.Command("docker", "info").Run()
	report(dockerErr == nil, "docker daemon", "docker info", "start docker, or add your user to the docker group")
	if _, err := exec.LookPath("gh"); err == nil {
		ghErr := exec.Command("gh", "auth", "status").Run()
		report(ghErr == nil, "gh auth", "gh auth status", "gh auth login (only needed for `serverlab pkgs publish`)")
	}
	if _, err := os.Stat("/dev/kvm"); err == nil {
		report(true, "/dev/kvm", "hardware virtualisation available", "")
	} else {
		report(false, "/dev/kvm", "vm.sh boots with accel=kvm", "enable virtualisation in the firmware, or add your user to the kvm group")
	}

	fmt.Println("\nartifacts and space")
	free, err := freeGiB(cfg.Root)
	if err == nil {
		report(free >= cfg.MinFreeGB, "free disk space",
			fmt.Sprintf("%d GiB free on the filesystem holding the repository (want %d)", free, cfg.MinFreeGB),
			"an ISO is ~3 GiB and each lab VM disk grows to a few GiB; free some space")
	}
	// The OCI CLI is not a prerequisite for anything in this repository: it is
	// only needed by pocs/image/oci/, which the owner runs by hand against a
	// tenancy this host may not even have credentials for. A note, not a check.
	if path, err := exec.LookPath("oci"); err == nil {
		fmt.Printf("  ok    %-22s %s\n", "oci (optional)", path)
	} else {
		fmt.Printf("  note  %-22s not installed; only pocs/image/oci/ needs it\n", "oci (optional)")
	}
	if image, err := newestImage(cfg); err == nil {
		fmt.Printf("  ok    %-22s %s\n", "pocs/image/out", filepath.Base(image))
	} else {
		fmt.Printf("  note  %-22s no cloud image yet; `serverlab image build` makes one\n", "pocs/image/out")
	}
	if iso, err := newestISO(cfg, cfg.Profile); err == nil {
		fmt.Printf("  ok    %-22s %s\n", "iso/release", filepath.Base(iso))
	} else {
		fmt.Printf("  note  %-22s no ISO yet; `serverlab iso build` makes one\n", "iso/release")
	}
	if labs := existingLabs(cfg); len(labs) > 0 {
		fmt.Printf("  ok    %-22s %s\n", "labs", strings.Join(labs, ", "))
	}

	fmt.Println()
	if missing > 0 {
		fmt.Printf("%d prerequisite(s) missing.\n", missing)
		return errHandled
	}
	fmt.Println("all prerequisites present.")
	return nil
}

// freeGiB reports the space available to this user on the filesystem holding
// path.
func freeGiB(path string) (int, error) {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(path, &stat); err != nil {
		return 0, err
	}
	return int(uint64(stat.Bavail) * uint64(stat.Bsize) / (1024 * 1024 * 1024)), nil
}

// existingLabs lists the labs this checkout already has settings for.
func existingLabs(cfg *Config) []string {
	matches, _ := filepath.Glob(filepath.Join(cfg.Root, "pocs", "lab", "out-*", "lab.json"))
	var names []string
	for _, match := range matches {
		lab, err := os.ReadFile(match)
		if err != nil {
			continue
		}
		_ = lab
		names = append(names, strings.TrimPrefix(filepath.Base(filepath.Dir(match)), "out-"))
	}
	return names
}
