package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// The cloud image pipeline.
//
// An ISO installs one machine, interactively or from an autoinstall drive. An
// image is the other shape of the same profile: one artifact, copied to many
// machines, where nothing that makes a machine itself may be baked in. The
// three commands here are the whole life of that artifact:
//
//	serverlab image build     install a throwaway machine, strip it, convert it
//	serverlab image test      boot the result with a NoCloud seed and assert
//	serverlab image publish   upload it to a GitHub release of this repository
//
// Like every other subcommand, this one owns no logic: the leaves are
// pocs/lab/mkcidata.sh and vm.sh (already the install path), pocs/image/*.sh
// (generalize, convert, seed) and pocs/server-install/acceptance-cloud.sh.
// What lives here is the order, the naming and the settings file that lets
// `serverlab report` write the run up afterwards.

// imageBuildUser is the account the build VM is installed with and the account
// generalization removes. It is deliberately NOT `omarchy`: the image's
// cloud-init default user is called that, and a leftover would be
// indistinguishable from a correctly created one.
const imageBuildUser = "imgbuild"

// imageTestUser is the account the NoCloud seed asks cloud-init to create. The
// image ships no account at all, so this name existing on a booted machine is
// itself one of the assertions.
const imageTestUser = "demo"

func cmdImage(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: serverlab image build|test|publish [flags]")
	}
	switch args[0] {
	case "build":
		return imageBuild(args[1:])
	case "test":
		return imageTest(args[1:])
	case "publish":
		return imagePublish(args[1:])
	default:
		return fmt.Errorf("unknown image action %q (build, test, publish)", args[0])
	}
}

// imageDir is where built images land: gitignored, beside the scripts that
// make them, the same convention pkgs/out and iso/release follow.
func imageDir(cfg *Config) string { return cfg.Script("pocs", "image", "out") }

// imageName encodes what is IN an image, because an image whose name does not
// say whether it enforces SELinux is an image somebody will launch by mistake.
func imageName(date, mac string, secboot bool, addons []string) string {
	name := "omarchy-server-" + date
	if mac != "" {
		name += "-" + mac
	}
	if secboot {
		name += "-secureboot"
	}
	for _, addon := range addons {
		// `cloud` is in every image by definition and says nothing.
		if addon != "cloud" {
			name += "-" + addon
		}
	}
	return name + "-x86_64.qcow2"
}

// ── build ───────────────────────────────────────────────────────────────────

func imageBuild(args []string) error {
	fs, base := newFlagSet("image build")
	name := fs.String("name", "cloudimg", "name of the throwaway build VM (and its lab directory)")
	profile := fs.String("profile", "", "install profile (default: the configured one)")
	addons := fs.String("addons", "", "extra addons on top of `cloud`, comma-separated")
	mac := fs.String("mac", "", "mandatory access control to bake in: selinux or apparmor")
	secboot := fs.Bool("secboot", false, "build a Secure Boot image (keys are generated at FIRST BOOT, never baked in)")
	isoPath := fs.String("iso", "", "ISO to install from (default: the newest matching one in iso/release)")
	out := fs.String("out", "", "output image path (default: pocs/image/out/omarchy-server-<date>...qcow2)")
	diskGB := fs.Int("disk-gb", 0, "build disk size in GiB (default: the configured one)")
	waitSecs := fs.Int("wait", 1800, "seconds to wait for the install to finish")
	keep := fs.Bool("keep", false, "keep the build VM's disk after the conversion")
	if err := fs.Parse(args); err != nil {
		return errHandled
	}

	cfg, err := base.setup()
	if err != nil {
		return err
	}
	if *profile == "" {
		*profile = cfg.Profile
	}
	if *diskGB == 0 {
		*diskGB = cfg.DiskGB
	}
	if *mac != "" && *mac != "selinux" && *mac != "apparmor" {
		return fmt.Errorf("--mac takes selinux or apparmor, not %q", *mac)
	}

	iso := *isoPath
	if iso == "" {
		if iso, err = newestISO(cfg, *profile); err != nil {
			return err
		}
	}
	if iso, err = filepath.Abs(iso); err != nil {
		return err
	}

	// `cloud` first and always: it is what makes the artifact an image rather
	// than a copy of somebody's server.
	addonList := append([]string{"cloud"}, splitList(*addons)...)

	target := *out
	if target == "" {
		target = filepath.Join(imageDir(cfg), imageName(time.Now().Format("2006-01-02"), *mac, *secboot, addonList))
	} else if !filepath.IsAbs(target) {
		target = filepath.Join(cfg.Root, target)
	}

	lab := &Lab{
		Name:       *name,
		Profile:    *profile,
		Addons:     addonList,
		MAC:        *mac,
		SecureBoot: *secboot,
		DiskGB:     *diskGB,
		MemoryMB:   cfg.MemoryMB,
		CPUs:       cfg.CPUs,
		ISO:        iso,
		SSHUser:    imageBuildUser,
		Out:        cfg.LabOut(*name),
		Created:    time.Now(),
	}

	session, err := NewSession(cfg, "image-build")
	if err != nil {
		return err
	}
	defer session.Close()

	err = runImageBuild(session, lab, target, *waitSecs, *keep)
	session.Summary()
	if err != nil {
		return err
	}
	session.Printf("image: %s", target)
	return nil
}

func runImageBuild(s *Session, lab *Lab, target string, waitSecs int, keep bool) error {
	cfg := s.Config

	if !cfg.DryRun {
		if _, err := os.Stat(lab.ISO); err != nil {
			return fmt.Errorf("ISO not found: %s", lab.ISO)
		}
		if err := lab.save(); err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
	}

	// 1. the autoinstall drive. Same script the lab uses, with two differences
	//    that are the whole point: the account is a throwaway one that
	//    generalization removes, and the `cloud` addon is applied during the
	//    install so the packages come from the ISO's offline mirror rather than
	//    from a network the build host may not want to depend on.
	//
	//    The alternative the deferred-provisioning path offers -- an install
	//    that bakes NO credentials at all -- is not taken here, and
	//    docs/cloud-image.md says why: `omarchy-provision-owner`'s setup form is
	//    still gum-only on this profile (docs/iso-server.md §7 item 1), so a
	//    `defer-provisioning` install has no non-interactive source of answers
	//    and would hang on its first boot. A throwaway account that is provably
	//    removed, and asserted absent by acceptance-cloud.sh, reaches the same
	//    end state through a path that exists today.
	cidata := []string{
		cfg.Script("pocs", "lab", "mkcidata.sh"),
		"--profile", lab.Profile,
		"--user", imageBuildUser,
		"--disk-size-gb", strconv.Itoa(lab.DiskGB),
		"--addons", strings.Join(lab.Addons, ","),
		"--out", lab.Out,
	}
	if lab.MAC != "" {
		cidata = append(cidata, "--mac", lab.MAC)
	}
	if lab.SecureBoot {
		cidata = append(cidata, "--secureboot")
	}
	if err := s.Run(Step{Label: "cidata", Args: cidata}); err != nil {
		return err
	}

	// 2-4. install the machine. Identical to `lab up`, because a cloud image is
	//      an ordinary install of this profile plus the removal of everything
	//      personal — not a separate build path that could drift from it.
	if _, err := os.Stat(filepath.Join(lab.Out, "vm", lab.Name, "disk.qcow2")); err == nil {
		s.Skip("vm create", "disk already exists")
	} else {
		create := []string{cfg.Script("pocs", "lab", "vm.sh"), lab.Name, "create", "--disk-gb", strconv.Itoa(lab.DiskGB)}
		if lab.SecureBoot {
			create = append(create, "--secboot")
		}
		if err := s.Run(Step{Label: "vm create", Args: create, Env: lab.env()}); err != nil {
			return err
		}
	}
	if err := s.Run(Step{
		Label: "vm start",
		Args: []string{cfg.Script("pocs", "lab", "vm.sh"), lab.Name, "start",
			"--iso", lab.ISO, "--cidata", filepath.Join(lab.Out, "cidata.iso")},
		Env: lab.env(),
	}); err != nil {
		return err
	}
	if err := s.Run(Step{
		Label: "wait-ssh",
		Args:  []string{cfg.Script("pocs", "lab", "vm.sh"), lab.Name, "wait-ssh", strconv.Itoa(waitSecs)},
		Env:   lab.env(),
	}); err != nil {
		return err
	}

	// 5. strip the identity and stop the machine.
	if err := s.Run(Step{
		Label: "generalize",
		Args:  []string{cfg.Script("pocs", "image", "generalize.sh"), lab.Name, imageBuildUser},
		// generalize.sh reads the build account from its second argument and
		// passes --remove-all-users itself; see its header for why a named
		// account is not enough.
		Env: lab.env(),
	}); err != nil {
		return err
	}

	// 6. convert. The VM is stopped by now; converting a running machine's disk
	//    would capture a filesystem mid-write.
	if err := s.Run(Step{
		Label: "convert",
		Args: []string{cfg.Script("pocs", "image", "convert.sh"),
			filepath.Join(lab.Out, "vm", lab.Name, "disk.qcow2"), target},
	}); err != nil {
		return err
	}

	if !keep && !cfg.DryRun {
		// The build disk is 40 GiB of a machine that no longer exists. Keeping
		// it is the exception (--keep), not the default, because the next build
		// would otherwise refuse to create a VM whose disk is still there.
		disk := filepath.Join(lab.Out, "vm", lab.Name, "disk.qcow2")
		if err := os.Remove(disk); err == nil {
			s.Printf("removed the build disk (%s); --keep next time to inspect it", disk)
		}
	}
	return nil
}

// ── test ────────────────────────────────────────────────────────────────────

func imageTest(args []string) error {
	fs, base := newFlagSet("image test")
	name := fs.String("name", "cloudtest", "name of the test VM (and its lab directory)")
	image := fs.String("image", "", "image to boot (default: the newest in pocs/image/out)")
	diskGB := fs.Int("disk-gb", 40, "disk to launch the image onto; growpart has to fill it")
	hostname := fs.String("hostname", "omarchy-cloud-test", "hostname the NoCloud seed asks for")
	waitSecs := fs.Int("wait", 600, "seconds to wait for ssh to answer")
	noPublish := fs.Bool("no-publish", false, "keep the evidence private to the lab")
	recreate := fs.Bool("recreate", false, "delete an existing test VM disk first")
	if err := fs.Parse(args); err != nil {
		return errHandled
	}

	cfg, err := base.setup()
	if err != nil {
		return err
	}
	target := *image
	if target == "" {
		if target, err = newestImage(cfg); err != nil {
			return err
		}
	}
	if target, err = filepath.Abs(target); err != nil {
		return err
	}

	lab := &Lab{
		Name:     *name,
		Profile:  cfg.Profile,
		Hostname: *hostname,
		DiskGB:   *diskGB,
		MemoryMB: cfg.MemoryMB,
		CPUs:     cfg.CPUs,
		Image:    target,
		ISO:      target,
		SSHUser:  imageTestUser,
		Out:      cfg.LabOut(*name),
		Created:  time.Now(),
	}

	session, err := NewSession(cfg, "image-test")
	if err != nil {
		return err
	}
	defer session.Close()

	err = runImageTest(session, lab, *waitSecs, *recreate, !*noPublish)
	session.Summary()
	if err != nil {
		return err
	}
	session.Printf("evidence: %s", lab.evidenceDir())
	session.Printf("write it up with: serverlab report %s", lab.Name)
	return nil
}

func runImageTest(s *Session, lab *Lab, waitSecs int, recreate, publish bool) error {
	cfg := s.Config
	disk := filepath.Join(lab.Out, "vm", lab.Name, "disk.qcow2")

	if !cfg.DryRun {
		if _, err := os.Stat(lab.Image); err != nil {
			return fmt.Errorf("image not found: %s", lab.Image)
		}
		if recreate {
			_ = os.Remove(disk)
		}
		if err := lab.save(); err != nil {
			return err
		}
	}

	// 1. the NoCloud seed: the only thing this machine is told about itself.
	if err := s.Run(Step{
		Label: "seed",
		Args: []string{cfg.Script("pocs", "image", "mkseed.sh"),
			"--hostname", lab.Hostname, "--user", imageTestUser, "--out", lab.Out},
	}); err != nil {
		return err
	}

	// 2. a VM whose disk is a copy of the image, grown to a bigger disk than
	//    the image was built on. That difference is what growpart has to close.
	if _, err := os.Stat(disk); err == nil {
		s.Skip("vm create", "disk already exists (--recreate to start over)")
	} else {
		if err := s.Run(Step{
			Label: "vm create",
			Args: []string{cfg.Script("pocs", "lab", "vm.sh"), lab.Name, "create",
				"--from-image", lab.Image, "--disk-gb", strconv.Itoa(lab.DiskGB)},
			Env: lab.env(),
		}); err != nil {
			return err
		}
	}

	// 3. boot it. No install ISO — the machine is already installed — and the
	//    seed in the cdrom slot vm.sh calls `cidata`, which is the label
	//    cloud-init's NoCloud datasource looks for.
	if err := s.Run(Step{
		Label: "vm start",
		Args: []string{cfg.Script("pocs", "lab", "vm.sh"), lab.Name, "start",
			"--iso", filepath.Join(lab.Out, "no-install-iso"),
			"--cidata", filepath.Join(lab.Out, "seed.iso")},
		Env: lab.env(),
	}); err != nil {
		return err
	}
	if err := s.Run(Step{
		Label: "wait-ssh",
		Args:  []string{cfg.Script("pocs", "lab", "vm.sh"), lab.Name, "wait-ssh", strconv.Itoa(waitSecs)},
		Env:   lab.env(),
	}); err != nil {
		return err
	}

	// 4. the assertions.
	evidence := lab.evidenceDir()
	if err := os.MkdirAll(evidence, 0o755); err != nil {
		return err
	}
	env := append(lab.env(),
		"BUILD_USER="+imageBuildUser,
		"WANT_HOSTNAME="+lab.Hostname,
		"WANT_DISK_GB="+strconv.Itoa(lab.DiskGB),
	)
	if err := runCaptured(s, Step{
		Label: "acceptance-cloud",
		Args:  []string{cfg.Script("pocs", "server-install", "acceptance-cloud.sh"), lab.Name},
		Env:   env,
	}, filepath.Join(evidence, "acceptance-cloud.txt")); err != nil {
		return err
	}

	// The attack surface of a machine from the image, measured the same way the
	// installed machines are, so the two numbers are comparable.
	if err := s.Run(Step{
		Label: "surface",
		Args:  []string{cfg.Script("pocs", "server-install", "surface.sh"), lab.Name, filepath.Join(evidence, "surface.txt")},
		Env:   env,
	}); err != nil {
		return err
	}

	// A reboot is not a formality on an image: cloud-init must NOT redo its
	// once-per-instance work, and the machine must come back with the identity
	// its first boot gave it rather than a second one.
	if err := runCaptured(s, Step{
		Label: "reboot-check",
		Args:  []string{cfg.Script("pocs", "server-install", "reboot-check.sh"), lab.Name},
		Env:   env,
	}, filepath.Join(evidence, "reboot-check.txt")); err != nil {
		return err
	}

	if publish {
		return publishEvidence(s, lab, evidence)
	}
	return nil
}

// newestImage picks the most recently written image in pocs/image/out.
func newestImage(cfg *Config) (string, error) {
	matches, err := filepath.Glob(filepath.Join(imageDir(cfg), "*.qcow2"))
	if err != nil || len(matches) == 0 {
		return "", fmt.Errorf("no image in pocs/image/out; run `serverlab image build`")
	}
	newest := matches[0]
	for _, match := range matches[1:] {
		if modTime(match).After(modTime(newest)) {
			newest = match
		}
	}
	return newest, nil
}

// ── publish ─────────────────────────────────────────────────────────────────

// imagePublish uploads the image and its checksum to a GitHub release of THIS
// repository. Like `pkgs publish` it changes something outside this machine, so
// it refuses to run without --yes and prints the plan instead.
func imagePublish(args []string) error {
	fs, base := newFlagSet("image publish")
	image := fs.String("image", "", "image to publish (default: the newest in pocs/image/out)")
	tag := fs.String("tag", "", "release tag (default: image-<date of the image>)")
	yes := fs.Bool("yes", false, "confirm creating the release and uploading the assets")
	if err := fs.Parse(args); err != nil {
		return errHandled
	}
	cfg, err := base.setup()
	if err != nil {
		return err
	}
	target := *image
	if target == "" {
		if target, err = newestImage(cfg); err != nil {
			return err
		}
	}
	if target, err = filepath.Abs(target); err != nil {
		return err
	}
	if *tag == "" {
		*tag = "image-" + time.Now().Format("2006-01-02")
	}

	session, err := NewSession(cfg, "image-publish")
	if err != nil {
		return err
	}
	defer session.Close()

	size := int64(0)
	if info, err := os.Stat(target); err == nil {
		size = info.Size()
	}

	if !*yes {
		session.Printf("serverlab image publish uploads a cloud image as a GitHub release asset")
		session.Printf("of this repository. It is a PUBLIC repository: anyone will be able to")
		session.Printf("download and boot what this uploads.")
		session.Printf("")
		session.Printf("  release: %s", *tag)
		session.Printf("  asset:   %s (%s)", filepath.Base(target), humanSize(size))
		session.Printf("  asset:   %s", filepath.Base(target)+".sha256")
		session.Printf("")
		session.Printf("Before running it, satisfy yourself that the image carries no account,")
		session.Printf("no password, no ssh host key and no Secure Boot key — that is what")
		session.Printf("`serverlab image test` asserts and what reports/ records.")
		session.Printf("")
		session.Printf("Re-run with --yes to do it.")
		return errHandled
	}

	// A 2 GiB per-asset ceiling, checked here rather than discovered at the end
	// of an upload.
	if size > 2*1024*1024*1024 {
		return fmt.Errorf("%s is %s, over the 2 GiB release-asset limit", filepath.Base(target), humanSize(size))
	}

	notes := fmt.Sprintf("Omarchy Server cloud image.\n\n"+
		"See `docs/cloud-image.md` for what is generalized, how to boot it on\n"+
		"libvirt/Proxmox/OCI, and how Secure Boot and SELinux behave at first boot.\n\n"+
		"    sha256sum -c %s.sha256\n", filepath.Base(target))

	return session.Run(Step{
		Label: "gh release",
		Args: []string{"gh", "release", "create", *tag,
			target, target + ".sha256",
			"--title", "Cloud image " + *tag,
			"--notes", notes},
		Dir: cfg.Root,
	})
}
