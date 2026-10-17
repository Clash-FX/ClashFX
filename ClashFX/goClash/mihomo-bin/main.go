package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/log"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("mihomo-bin", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configFile := flags.String("f", "", "config file path")
	homeDir := flags.String("d", "", "config home directory")
	validateOnly := flags.Bool("t", false, "check configuration and exit")
	if err := flags.Parse(args); err != nil {
		return 2
	}

	if *homeDir != "" {
		constant.SetHomeDir(*homeDir)
	}

	if *configFile != "" {
		if !filepath.IsAbs(*configFile) {
			currentDir, _ := os.Getwd()
			*configFile = filepath.Join(currentDir, *configFile)
		}
		constant.SetConfig(*configFile)
	} else {
		configPath := filepath.Join(constant.Path.HomeDir(), constant.Path.Config())
		constant.SetConfig(configPath)
	}

	if *validateOnly {
		if _, err := executor.Parse(); err != nil {
			fmt.Fprintf(stderr, "Parse config error: %s\n", err.Error())
			return 1
		}
		fmt.Fprintf(stdout, "configuration is valid: %s\n", constant.Path.Config())
		return 0
	}

	fmt.Fprintf(stdout, "mihomo-bin euid=%d uid=%d pid=%d\n", os.Geteuid(), os.Getuid(), os.Getpid())

	cfg, err := executor.Parse()
	if err != nil {
		log.Errorln("Parse config error: %s", err.Error())
		return 1
	}
	if err := hub.ApplyConfigAndValidate(cfg); err != nil {
		log.Errorln("Named inbound listener startup error: %s", err.Error())
		return 1
	}

	fmt.Fprintf(stdout, "mihomo-bin started, config: %s\n", constant.Path.Config())

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh
	return 0
}
