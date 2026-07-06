package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

const tickInterval = 2 * time.Second

type model struct {
	dir    string
	width  int
	height int

	snap *Snapshot
	err  error
	errAt time.Time

	loading bool
	seq     int

	editorErr error

	showResume bool
	resumeVP   viewport.Model
}

func newModel(dir string) model {
	// seq 1 / loading true match the load dispatched by Init.
	return model{dir: dir, width: 100, height: 40, seq: 1, loading: true}
}

type snapshotMsg struct {
	seq  int
	snap *Snapshot
	err  error
}

type tickMsg time.Time

type resumeLoadedMsg struct {
	content string
	err     error
}

type editorFinishedMsg struct{ err error }

func loadSnapshotCmd(dir string, seq int) tea.Cmd {
	return func() tea.Msg {
		snap, err := BuildSnapshot(dir)
		return snapshotMsg{seq: seq, snap: snap, err: err}
	}
}

func tickCmd() tea.Cmd {
	return tea.Tick(tickInterval, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func loadResumeCmd(dir string) tea.Cmd {
	return func() tea.Msg {
		content, err := ReadResume(dir)
		return resumeLoadedMsg{content: content, err: err}
	}
}

func (m model) Init() tea.Cmd {
	return tea.Batch(loadSnapshotCmd(m.dir, m.seq), tickCmd())
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.resumeVP.Width = max(0, msg.Width-4)
		m.resumeVP.Height = max(0, msg.Height-4)
		return m, nil

	case tea.KeyMsg:
		if m.showResume {
			switch msg.String() {
			case "ctrl+c":
				return m, tea.Quit
			case "esc", "q":
				m.showResume = false
				return m, nil
			}
			var cmd tea.Cmd
			m.resumeVP, cmd = m.resumeVP.Update(msg)
			return m, cmd
		}
		switch msg.String() {
		case "q", "ctrl+c":
			return m, tea.Quit
		case "r":
			return m, loadResumeCmd(m.dir)
		case "s":
			return m, suspendForSteerCmd(m.dir)
		}
		return m, nil

	case snapshotMsg:
		if msg.seq != m.seq {
			return m, nil // stale result from a superseded load
		}
		m.loading = false
		if msg.err != nil {
			// Keep the last good snapshot; View renders it with a footer warning.
			m.err = msg.err
			m.errAt = time.Now()
			return m, nil
		}
		m.snap = msg.snap
		m.err = nil
		return m, nil

	case tickMsg:
		if m.loading {
			return m, tickCmd() // previous load still in flight; skip this one
		}
		m.seq++
		m.loading = true
		return m, tea.Batch(loadSnapshotCmd(m.dir, m.seq), tickCmd())

	case resumeLoadedMsg:
		vp := viewport.New(max(0, m.width-4), max(0, m.height-4))
		if msg.err != nil {
			vp.SetContent("(could not read RESUME.md: " + msg.err.Error() + ")")
		} else {
			vp.SetContent(msg.content)
		}
		m.resumeVP = vp
		m.showResume = true
		return m, nil

	case editorFinishedMsg:
		m.editorErr = msg.err
		if m.loading {
			return m, nil
		}
		m.seq++
		m.loading = true
		return m, loadSnapshotCmd(m.dir, m.seq)
	}
	return m, nil
}

func suspendForSteerCmd(dir string) tea.Cmd {
	editor := strings.TrimSpace(os.Getenv("EDITOR"))
	if editor == "" {
		editor = "vi"
	}
	// $EDITOR may be a composite value ("code --wait"); split into binary+args.
	parts := strings.Fields(editor)
	path := filepath.Join(dir, ".m2herd", "inbox", "STEER.md")
	c := exec.Command(parts[0], append(parts[1:], path)...)
	return tea.ExecProcess(c, func(err error) tea.Msg { return editorFinishedMsg{err: err} })
}

func (m model) View() string {
	if m.showResume {
		title := styleBold.Render("RESUME.md") + "  " + styleDim.Render("(esc to close)")
		box := lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(colBorder).
			Padding(0, 1).
			Width(m.width - 2)
		return box.Render(title + "\n\n" + m.resumeVP.View())
	}
	if m.snap == nil {
		// Full error screen only when there has never been a good snapshot.
		if m.err != nil {
			return styleRed.Render("m2herd-tui: " + m.err.Error())
		}
		return styleDim.Render("m2herd-tui: loading …")
	}
	out := Render(m.snap, m.width)
	if m.err != nil {
		out += "\n" + styleRed.Render(fmt.Sprintf("refresh error: %s (%s ago)", m.err.Error(), ageString(time.Since(m.errAt))))
	}
	if m.editorErr != nil {
		out += "\n" + styleRed.Render("editor error: "+m.editorErr.Error())
	}
	return out
}
