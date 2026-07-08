package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func newFabricDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, ".m2herd"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".m2herd", "overview.json"), []byte(`{"goal":"smoke"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestAppendSteerCreatesFromNothing(t *testing.T) {
	dir := newFabricDir(t)
	if err := AppendSteer(dir, "pause the docs slice"); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(steerPath(dir))
	if err != nil {
		t.Fatal(err)
	}
	content := string(b)
	idx := strings.Index(content, marker)
	if idx < 0 {
		t.Fatalf("marker missing in created STEER.md:\n%s", content)
	}
	live := strings.TrimSpace(content[idx+len(marker):])
	if !strings.HasPrefix(live, "- [") || !strings.HasSuffix(live, "] pause the docs slice") {
		t.Fatalf("live line malformed: %q", live)
	}
	if got := SteerPendingCount(dir); got != 1 {
		t.Fatalf("SteerPendingCount = %d, want 1", got)
	}
}

func TestAppendSteerAppendsBelowExistingLive(t *testing.T) {
	dir := newFabricDir(t)
	if err := AppendSteer(dir, "first"); err != nil {
		t.Fatal(err)
	}
	if err := AppendSteer(dir, "second"); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(steerPath(dir))
	content := string(b)
	if strings.Count(content, marker) != 1 {
		t.Fatalf("marker duplicated:\n%s", content)
	}
	live := content[strings.Index(content, marker)+len(marker):]
	if !strings.Contains(live, "] first") || !strings.Contains(live, "] second") {
		t.Fatalf("both lines expected below marker, got:\n%s", live)
	}
	if strings.Index(live, "] first") > strings.Index(live, "] second") {
		t.Fatal("append order wrong: second landed before first")
	}
	if got := SteerPendingCount(dir); got != 2 {
		t.Fatalf("SteerPendingCount = %d, want 2", got)
	}
}

func TestCollapseNewlines(t *testing.T) {
	got := collapseNewlines("pause docs\r\n\nresume tui \rship it")
	want := "pause docs; resume tui; ship it"
	if got != want {
		t.Fatalf("collapseNewlines = %q, want %q", got, want)
	}
}

// TestSteerMinibufferFlow drives the model like the terminal would: press i,
// type text (with a multi-line paste), press enter, run the returned command,
// and check STEER.md plus the toast.
func TestSteerMinibufferFlow(t *testing.T) {
	dir := newFabricDir(t)
	var tm tea.Model = newModel(dir)

	key := func(msg tea.KeyMsg) tea.Cmd {
		var cmd tea.Cmd
		tm, cmd = tm.Update(msg)
		return cmd
	}
	key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("i")})
	if !tm.(model).steerActive {
		t.Fatal("i did not open the steer minibuffer")
	}
	key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("pause docs")})
	key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("\nthen resume tui\n"), Paste: true})
	if v := tm.(model).steerValue; v != "pause docs; then resume tui" {
		t.Fatalf("minibuffer value after paste = %q", v)
	}
	cmd := key(tea.KeyMsg{Type: tea.KeyEnter})
	if tm.(model).steerActive {
		t.Fatal("enter did not close the minibuffer")
	}
	if cmd == nil {
		t.Fatal("enter returned no append command")
	}
	msg := cmd() // run appendSteerCmd synchronously
	done, ok := msg.(steerDoneMsg)
	if !ok {
		t.Fatalf("unexpected msg type %T", msg)
	}
	if done.err != nil {
		t.Fatal(done.err)
	}
	tm, _ = tm.Update(done)
	if got := tm.(model).steerToast; got != "steered ✓" {
		t.Fatalf("toast = %q, want steered ✓", got)
	}
	b, _ := os.ReadFile(steerPath(dir))
	if !strings.Contains(string(b), "] pause docs; then resume tui") {
		t.Fatalf("appended line missing:\n%s", string(b))
	}
	if got := SteerPendingCount(dir); got != 1 {
		t.Fatalf("SteerPendingCount = %d, want 1", got)
	}
}

func TestSteerEscCancels(t *testing.T) {
	dir := newFabricDir(t)
	var tm tea.Model = newModel(dir)
	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("i")})
	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("nope")})
	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyEsc})
	m := tm.(model)
	if m.steerActive || m.steerValue != "" {
		t.Fatal("esc did not cancel the minibuffer")
	}
	if _, err := os.Stat(steerPath(dir)); !os.IsNotExist(err) {
		t.Fatal("esc must not create STEER.md")
	}
}
