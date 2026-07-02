// Command m2herd-tui is a READ-ONLY bubbletea dashboard over an m2herd
// context fabric (.m2herd/). It never writes fabric state and never calls
// mutating herdr/git commands — see CONTRACT-m2herd.md §"read-only doctrine".
package main

import (
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"
)

func main() {
	dir, once, showVersion, err := parseFlags(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, "m2herd-tui: "+err.Error())
		os.Exit(2)
	}
	if showVersion {
		fmt.Println("m2herd-tui " + version)
		return
	}
	if !HasFabric(dir) {
		fmt.Fprintf(os.Stderr, "m2herd-tui: no .m2herd/ at %s (run: m2herd init --dir %s)\n", dir, dir)
		os.Exit(1)
	}

	if once {
		runOnce(dir)
		return
	}

	p := tea.NewProgram(newModel(dir), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "m2herd-tui: "+err.Error())
		os.Exit(1)
	}
}

func parseFlags(args []string) (dir string, once, showVersion bool, err error) {
	dir = "."
	if wd, e := os.Getwd(); e == nil {
		dir = wd
	}
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--dir":
			if i+1 >= len(args) {
				return "", false, false, fmt.Errorf("--dir needs a value")
			}
			dir = args[i+1]
			i++
		case "--once":
			once = true
		case "--version":
			showVersion = true
		case "-h", "--help":
			fmt.Println("m2herd-tui [--dir P] | --once [--dir P] | --version")
			os.Exit(0)
		default:
			return "", false, false, fmt.Errorf("unknown arg: %s", args[i])
		}
	}
	return dir, once, showVersion, nil
}

// runOnce renders exactly one frame to stdout, no altscreen, no tick.
func runOnce(dir string) {
	snap, err := BuildSnapshot(dir)
	if err != nil {
		fmt.Fprintln(os.Stderr, "m2herd-tui: "+err.Error())
		os.Exit(1)
	}
	width := terminalWidth()
	fmt.Println(Render(snap, width))
}

func terminalWidth() int {
	if w := envInt("COLUMNS"); w > 0 {
		return w
	}
	return 100
}

func envInt(name string) int {
	v := os.Getenv(name)
	if v == "" {
		return 0
	}
	n := 0
	for _, c := range v {
		if c < '0' || c > '9' {
			return 0
		}
		n = n*10 + int(c-'0')
	}
	return n
}
