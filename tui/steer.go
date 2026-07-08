package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// The 'i' steer minibuffer is the ONE fabric write the dashboard is allowed
// (CONTRACT v1.4): APPEND a line below the STEER.md marker — steering goes
// through the loop; the TUI never edits state files.

const steerToastDuration = 1500 * time.Millisecond

// steerTemplate mirrors templates/m2herd/inbox/STEER.md so an inbox created
// from nothing reads the same as an engine-scaffolded one.
const steerTemplate = `<!--
.m2herd/inbox/STEER.md — the steering inbox of the m2herd context fabric (STEER.md pattern).

Watchers, humans, and future TUI tiers APPEND intents below the marker — they never touch
the state files directly. The ORCHESTRATOR drains this file (` + "`m2herd next`" + ` says when),
acts on each line with judgment, then clears everything below the marker.

Everything ABOVE the marker is template boilerplate; everything BELOW is live steering.
-->

` + marker + "\n"

func steerPath(dir string) string {
	return filepath.Join(dir, ".m2herd", "inbox", "STEER.md")
}

// collapseNewlines joins a multi-line paste into one steering line: split on
// any newline flavor, trim, drop blanks, join with "; ".
func collapseNewlines(s string) string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	s = strings.ReplaceAll(s, "\r", "\n")
	parts := strings.Split(s, "\n")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return strings.Join(out, "; ")
}

// AppendSteer appends "- [<UTC ts>] <text>" below the STEER.md marker,
// creating the file from the template when absent. It holds the engine's
// <file>.lock flock for the whole read-modify-write and lands the new content
// with a same-dir tmp + rename, so the append is atomic even while the fabric
// is mid-rewrite elsewhere.
func AppendSteer(dir, text string) error {
	text = strings.TrimSpace(collapseNewlines(text))
	if text == "" {
		return nil
	}
	path := steerPath(dir)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	lock, err := os.OpenFile(path+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)

	var content string
	b, err := os.ReadFile(path)
	switch {
	case errors.Is(err, os.ErrNotExist):
		content = steerTemplate
	case err != nil:
		return err
	default:
		content = string(b)
	}
	if !strings.Contains(content, marker) {
		// Degraded inbox (marker lost): re-seed it so the orchestrator's
		// live-tail drain can find the line we are about to add.
		if content != "" && !strings.HasSuffix(content, "\n") {
			content += "\n"
		}
		content += marker + "\n"
	}
	if !strings.HasSuffix(content, "\n") {
		content += "\n"
	}
	content += "- [" + time.Now().UTC().Format(time.RFC3339) + "] " + text + "\n"

	tmp, err := os.CreateTemp(filepath.Dir(path), ".STEER.md.*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	ok := false
	defer func() {
		if !ok {
			_ = os.Remove(tmpName)
		}
	}()
	if _, err := tmp.WriteString(content); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o644); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		return err
	}
	ok = true
	return nil
}

// SteerPendingCount counts the non-empty lines below the STEER.md marker —
// the queue the orchestrator's `next` will drain. 0 when the file or marker
// is absent.
func SteerPendingCount(dir string) int {
	b, err := os.ReadFile(steerPath(dir))
	if err != nil {
		return 0
	}
	content := string(b)
	idx := strings.Index(content, marker)
	if idx < 0 {
		return 0
	}
	n := 0
	for _, line := range strings.Split(content[idx+len(marker):], "\n") {
		if strings.TrimSpace(line) != "" {
			n++
		}
	}
	return n
}

// SteerFooter is the dashboard-footer slice of model state Render needs to
// draw the minibuffer / toast without reaching into the model.
type SteerFooter struct {
	Active    bool
	Value     string
	Toast     string
	ToastRed  bool
	ToastLive bool
}

type steerDoneMsg struct{ err error }

type steerToastMsg time.Time

func appendSteerCmd(dir, text string) tea.Cmd {
	return func() tea.Msg { return steerDoneMsg{err: AppendSteer(dir, text)} }
}

func steerToastCmd() tea.Cmd {
	return tea.Tick(steerToastDuration, func(t time.Time) tea.Msg { return steerToastMsg(t) })
}

func (m model) updateSteerKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c":
		return m, tea.Quit
	case "esc":
		m.steerActive = false
		m.steerValue = ""
		return m, nil
	case "enter":
		text := strings.TrimSpace(collapseNewlines(m.steerValue))
		m.steerActive = false
		m.steerValue = ""
		if text == "" {
			return m, nil
		}
		return m, appendSteerCmd(m.dir, text)
	case "backspace", "ctrl+h":
		if len(m.steerValue) > 0 {
			r := []rune(m.steerValue)
			m.steerValue = string(r[:len(r)-1])
		}
		return m, nil
	}
	if len(msg.Runes) > 0 {
		chunk := string(msg.Runes)
		// Multi-line paste: one steering line per Enter — collapse over the
		// whole joined value so a newline at the paste boundary also turns
		// into "; " and the minibuffer shows exactly what will be appended.
		if strings.ContainsAny(chunk, "\r\n") {
			m.steerValue = collapseNewlines(m.steerValue + chunk)
		} else {
			m.steerValue += chunk
		}
	}
	return m, nil
}
